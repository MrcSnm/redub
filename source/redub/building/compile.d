module redub.building.compile;
import redub.building.cache;
import redub.logging;
import redub.buildapi;
import std.system;
import std.concurrency;
import redub.compiler_identification;
import redub.command_generators.automatic;

struct CompilationResult
{
    string compilationCommand;
    string message;
    size_t msNeeded;
    int status;
    shared ProjectNode node;
    CompilationCache cache;
}

import std.typecons;
alias ExecutionResult = Tuple!(int, "status", string, "output");
/**
*   If any command has status, it will stop executing them and return
*/
private ExecutionResult executeCommands(const string[] commandsList, string listName, ref CompilationResult res, string workingDir, immutable string[string] env)
{
    import std.process;
    foreach(cmd; commandsList)
    {
        auto execRes  = executeShell(cmd, env, Config.none, size_t.max, workingDir);
        if(execRes.status)
        {
            res.status = execRes.status;
            res.message = "Result of "~listName~" command '"~cmd~"' "~execRes.output;
            return execRes;
        }
    }
    return ExecutionResult(0, "Success");
}

void execCompilation(immutable BuildConfiguration cfg, shared ProjectNode pack, OS os, Compiler compiler, CompilationCache cache, immutable string[string] env)
{
    import std.file;
    import std.process;
    import std.datetime.stopwatch;
    import redub.command_generators.commons;

    CompilationResult res;
    res.node = pack;
    res.cache.requirementCache = cache.requirementCache;
    StopWatch sw = StopWatch(AutoStart.yes);
    scope(exit)
    {
        res.msNeeded = sw.peek.total!"msecs";
        ownerTid.send(res);
    }
    try
    {
        if(pack.isUpToDate)
        {
            res.cache = cache;
            return;
        }
        //Remove existing binary, since it won't be replaced by simply executing commands
        string outDir = getConfigurationOutputPath(cfg, os);
        if(exists(outDir))
            remove(outDir);
        
        if(executeCommands(cfg.preBuildCommands, "preBuildCommand", res, cfg.workingDir, env).status)
            return;

        ExecutionResult ret;
        if(isDCompiler(compiler) && std.system.os.isWindows)
        {
            string[] flags = getCompilationFlags(cfg, os, compiler);
            string commandFile = createCommandFile(cfg, os, compiler, flags, res.compilationCommand);
            res.compilationCommand = compiler.binOrPath ~ " "~res.compilationCommand;
            ret = executeShell(compiler.binOrPath ~ " @"~commandFile);
            std.file.remove(commandFile);
        }
        else
        {
            ///Creates a folder to C output since it doesn't do automatically.
            if(!isDCompiler(compiler))
                createOutputDirFolder(cfg);
            res.compilationCommand = getCompileCommands(cfg, os, compiler);
            ret = executeShell(res.compilationCommand, null, Config.none, size_t.max, cfg.workingDir);

            if(!isDCompiler(compiler) && !ret.status) //Always requires link.
            {
                CompilationResult linkRes = link(cfg, os, compiler, env);
                ret.status = linkRes.status;
                ret.output~= linkRes.message;
                res.compilationCommand~= linkRes.compilationCommand;
            }
        }
        

        res.status = ret.status;
        res.message = ret.output;

        if(res.status == 0)
        {
            if(executeCommands(cfg.postBuildCommands, "postBuildCommand", res, cfg.workingDir, env).status)
                return;
            if(!cfg.targetType.isLinkedSeparately && executeCommands(cfg.postGenerateCommands, "postGenerateCommand", res, cfg.workingDir, env).status)
                return;
        }
        
        res.cache.dateCache = hashFromDates(cfg,null);
    }
    catch(Throwable e)
    {
        res.status = 1;
        res.message = e.toString;
    }
}


CompilationResult link(immutable BuildConfiguration cfg, OS os, Compiler compiler, immutable string[string] env)
{
    import std.process;
    CompilationResult ret;

    ret.compilationCommand = getLinkCommands(cfg, os, compiler);

    auto exec = executeShell(ret.compilationCommand);
    ret.status = exec.status;
    ret.message = exec.output;

    if(exec.status != 0)
        return ret;

    if(cfg.targetType.isLinkedSeparately)
        executeCommands(cfg.postGenerateCommands, "postGenerateCommand", ret, cfg.workingDir, env);

    return ret;
}


bool buildProjectParallelSimple(ProjectNode root, Compiler compiler, OS os)
{
    import std.concurrency;
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    string mainPackHash = hashFrom(root.requirements, compiler);
    bool[ProjectNode] spawned;

    import std.process;
    immutable string[string] env = cast(immutable)(environment.toAA);
    while(true)
    {
        foreach(dep; dependencyFreePackages)
        {
            if(!(dep in spawned))
            {
                spawned[dep] = true;
                spawn(&execCompilation, 
                    dep.requirements.cfg.idup, cast(shared)dep, os, 
                    compiler, CompilationCache.get(mainPackHash, dep.requirements, compiler),
                    env
                );
            }
        }
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            buildFailed(finishedPackage, res);
            return false;
        }
        else
        {
            buildSucceeded(finishedPackage, res);
            finishedPackage.becomeIndependent();
            dependencyFreePackages = root.findLeavesNodes();
            if(finishedPackage is root)
                break;
        }
    }
    return doLink(root.requirements.idup, os, compiler, mainPackHash, root.isUpToDate, env);
}


bool buildProjectFullyParallelized(ProjectNode root, Compiler compiler, OS os)
{
    import std.concurrency;
    string mainPackHash = hashFrom(root.requirements, compiler);
    CompilationCache[] cache = cacheStatusForProject(root, compiler);
    import std.process;
    immutable string[string] env = cast(immutable)(environment.toAA);
    size_t i = 0;
    foreach(pack; root.collapse)
    {
        spawn(&execCompilation, 
            pack.requirements.cfg.idup, 
            cast(shared)pack, os, compiler, 
            cache[i++],
            env
        );
    }
    foreach(pack; root.collapse)
    {
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            import core.thread;
            buildFailed(finishedPackage, res);
            thread_joinAll();
            return false;
        }
        else
        {
            updateCache(mainPackHash, res.cache);
            buildSucceeded(finishedPackage, res);
        }
    }
    return doLink(root.requirements.idup, os, compiler, mainPackHash, root.isUpToDate, env);
}

private void buildSucceeded(ProjectNode node, CompilationResult res)
{
    if(node.isUpToDate)
        infos("Up-to-Date: ", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"]. Took ", res.msNeeded, "ms");
    else
    {
        // writeln("Succesfully built with cmd:", res.compilationCommand);
        infos("Built: ", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"]. Took ", res.msNeeded, "ms");
        vlog("\n\t", res.compilationCommand, " \n");

    } 
}
private void buildFailed(ProjectNode node, CompilationResult res)
{
    errorTitle("Build Failure: '", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"] ",
        "' using flags\n\t", res.compilationCommand, 
        "\nFailed after ", res.msNeeded,"ms with message\n\t", res.message
    );
}

private bool doLink(immutable BuildRequirements req, OS os, Compiler compiler, string mainPackHash, bool isUpToDate, immutable string[string] env)
{
    if(isUpToDate || (compiler.isDCompiler && req.cfg.targetType.isStaticLibrary))
    {
        if(isUpToDate)
            infos("Up-to-Date: ", req.name, ", skipping linking");
        updateCache(mainPackHash, CompilationCache.get(mainPackHash, req, compiler), true);
        return true;
    }
    CompilationResult linkRes = link(req.cfg, os, compiler, env);
    if(linkRes.status)
    {
        errorTitle("Linking Error: ", req.name, ". Failed with flags: \n\t",
            linkRes.compilationCommand,"\n\t\t  :\n\t",
            linkRes.message
        );
        return false;
    }
    else
    {
        infos("Linked: ", req.name, " finished!");
        vlog("\n\t", linkRes.compilationCommand, " \n");
        updateCache(mainPackHash, CompilationCache.get(mainPackHash, req, compiler), true);

    }

    return true;
}