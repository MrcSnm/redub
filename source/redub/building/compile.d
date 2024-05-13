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
    shared CompilationCache cache;
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

void execCompilation(immutable BuildRequirements req, shared ProjectNode pack, OS os, Compiler compiler, shared CompilationCache cache, immutable string[string] env)
{
    import std.file;
    import std.process;
    import std.datetime.stopwatch;
    import redub.command_generators.commons;

    CompilationResult res;
    res.node = pack;
    StopWatch sw = StopWatch(AutoStart.yes);
    immutable BuildConfiguration cfg = req.cfg;
    scope(exit)
    {
        res.msNeeded = sw.peek.total!"msecs";
        res.cache.requirementCache = cache.requirementCache;
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
                CompilationResult linkRes = link(req, os, compiler, env);
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
        
        // res.cache = cast(shared)CompilationCache.make(cache.requirementCache, req, os);
    }
    catch(Throwable e)
    {
        res.status = 1;
        res.message = e.toString;
    }
}


CompilationResult link(const BuildRequirements req, OS os, Compiler compiler, immutable string[string] env)
{
    import std.process;
    CompilationResult ret;

    ret.compilationCommand = getLinkCommands(req, os, compiler);

    auto exec = executeShell(ret.compilationCommand);
    ret.status = exec.status;
    ret.message = exec.output;

    if(exec.status != 0)
        return ret;

    if(req.cfg.targetType.isLinkedSeparately)
        executeCommands(req.cfg.postGenerateCommands, "postGenerateCommand", ret, req.cfg.workingDir, env);

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
                    dep.requirements.idup, cast(shared)dep, os, 
                    compiler, cast(shared)CompilationCache.get(mainPackHash, dep.requirements, compiler),
                    env
                );
            }
        }
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            buildFailed(finishedPackage, res, compiler);
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
    return doLink(root, os, compiler, mainPackHash, env);
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
            pack.requirements.idup, 
            cast(shared)pack, os, compiler, 
            cast(shared)cache[i++],
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
            buildFailed(finishedPackage, res, compiler);
            thread_joinAll();
            return false;
        }
        else
        {
            // updateCache(mainPackHash, CompilationCache.make(res.cache.requirementCache, cast()res.node.requirements, os));
            buildSucceeded(finishedPackage, res);
        }
    }
    return doLink(root, os, compiler, mainPackHash, env);
}

private void buildSucceeded(ProjectNode node, CompilationResult res)
{
    if(node.isUpToDate)
        infos("Up-to-Date: ", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"]. Took ", res.msNeeded, "ms");
    else
    {
        infos("Built: ", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"]. Took ", res.msNeeded, "ms");
        vlog("\n\t", res.compilationCommand, " \n");

    } 
}
private void buildFailed(const ProjectNode node, CompilationResult res, const Compiler compiler)
{
    import redub.misc.github_tag_check;
    errorTitle("Build Failure: '", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"]' \n\t",
        RedubVersionShort, "\n\t", compiler.getCompilerWithVersion, "\n\tFailed with flags: \n\n\t",
        res.compilationCommand, 
        "\nFailed after ", res.msNeeded,"ms with message\n\t", res.message
    );
    showNewerVersionMessage();
}

private bool doLink(ProjectNode root, OS os, Compiler compiler, string mainPackHash, immutable string[string] env)
{
    bool isUpToDate = root.isUpToDate;
    bool shouldSkipLinking = isUpToDate || (compiler.isDCompiler && root.requirements.cfg.targetType.isStaticLibrary);

    if(!shouldSkipLinking)
    {
        CompilationResult linkRes = link(root.requirements, os, compiler, env);
        if(linkRes.status)
        {
            import redub.misc.github_tag_check;
            errorTitle("Linking Error at \"", root.name, "\". \n\t"~ RedubVersionShort~ "\n\t" ~ compiler.getCompilerWithVersion ~ "\n\tFailed with flags: \n\n\t",
                linkRes.compilationCommand,"\n\t\t  :\n\t",
                linkRes.message,
            );
            showNewerVersionMessage();
            return false;
        }
        else
        {
            infos("Linked: ", root.name, " finished!");
            vlog("\n\t", linkRes.compilationCommand, " \n");
        }
    }
    if(isUpToDate)
        infos("Up-to-Date: ", root.name, ", skipping linking");
    else 
    {
        AdvCacheFormula cache;
        foreach(node; root.collapse)
        {
            if(!node.isUpToDate)
            {
                CompilationCache existingCache = CompilationCache.get(mainPackHash, node.requirements, compiler);
                const AdvCacheFormula existingFormula = existingCache.getFormula();
                updateCache(mainPackHash, CompilationCache.make(existingCache.requirementCache, node.requirements, os, &existingFormula, &cache));
            }
        }
        updateCacheOnDisk();
    }
        
    return true;
}