module building.compile;
import building.cache;
import buildapi;
import std.system;
import std.concurrency;
import command_generators.automatic;

void compile(BuildRequirements req, OS os, string compiler, 
    out int status, out string sink, out string compilationFlagsSink
)
{
    import std.process;
    string cmds = getCompileCommands(cast(immutable)req.cfg, os, compiler);
    auto ret = executeShell(cmds);
    status = ret.status;
    sink = ret.output;
    compilationFlagsSink = cmds;
}

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
private ExecutionResult executeCommands(const string[] commandsList, string listName, ref CompilationResult res, string workingDir)
{
    import std.process;
    foreach(cmd; commandsList)
    {
        auto execRes  = executeShell(cmd, null, Config.none, size_t.max, workingDir);
        if(execRes.status)
        {
            res.status = execRes.status;
            res.message = "Result of "~listName~" command '"~cmd~"' "~execRes.output;
            return execRes;
        }
    }
    return ExecutionResult(0, "Success");
}

void compile2(immutable BuildConfiguration cfg, shared ProjectNode pack, OS os, string compiler, CompilationCache cache)
{
    import std.file;
    import std.process;
    import std.datetime.stopwatch;
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
        if(executeCommands(cfg.preBuildCommands, "preBuildCommand", res, cfg.workingDir).status)
            return;
        res.compilationCommand = getCompileCommands(cfg, os, compiler);
        auto ret = executeShell(res.compilationCommand);
        res.status = ret.status;
        res.message = ret.output;
        if(res.status == 0)
        {
            if(executeCommands(cfg.postBuildCommands, "postBuildCommand", res, cfg.workingDir).status)
                return;
            if(cfg.targetType != TargetType.executable && executeCommands(cfg.postGenerateCommands, "postGenerateCommand", res, cfg.workingDir).status)
                return;
        }
        res.cache.dateCache = hashFromDates(cfg);
    }
    catch(Throwable e)
    {
        res.status = 1;
        res.message = e.toString;
    }
}


CompilationResult link(immutable BuildConfiguration cfg, OS os, string compiler)
{
    import std.process;
    CompilationResult ret;
    ret.compilationCommand = getLinkCommands(cfg, os, compiler);

    auto exec = executeShell(ret.compilationCommand);
    ret.status = exec.status;
    ret.message = exec.output;
    if(cfg.targetType == TargetType.executable)
        executeCommands(cfg.postGenerateCommands, "postGenerateCommand", ret, cfg.workingDir);

    return ret;
}


bool buildProject(ProjectNode[][] steps, string compiler)
{
    import std.algorithm.searching:maxCount;
    import std.parallelism;
    size_t maxSize;
    string[] outputSink;
    string[] compilationFlagsSink;
    int[] statusSink;
    foreach(depth; steps) if(depth.length > maxSize) maxSize = depth.length;
    outputSink = new string[](maxSize);
    compilationFlagsSink = new string[](maxSize);
    statusSink = new int[](maxSize);

    foreach_reverse(dep; steps)
    {
        foreach(i, ProjectNode proj; parallel(dep))
        {
            compile(proj.requirements, os, compiler, statusSink[i], outputSink[i], compilationFlagsSink[i]);
        }
        
        foreach(i; 0..dep.length)
        {
            import std.stdio;
            if(statusSink[i])
            {
                writeln("Compilation of project '", dep[i].name,"' using flags\n\t", compilationFlagsSink[i], "\nFailed with message\n\t",
                outputSink[i]);
                return false;
            }
            else
                writeln("Compilation of project ", dep[i].name, " finished!");
        }

    }
    return true;
}


bool buildProjectParallelSimple(ProjectNode root, string compiler, OS os)
{
    import std.concurrency;
    import std.stdio;
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    string mainPackHash = hashFrom(root.requirements);
    bool[ProjectNode] spawned;
    while(true)
    {
        // writeln("Building ", dependencyFreePackages[0].name, " with args ", getCompileCommands(dependencyFreePackages[0].requirements.cfg.idup, os, compiler));
        foreach(dep; dependencyFreePackages)
        {
            if(!(dep in spawned))
            {
                spawned[dep] = true;
                spawn(&compile2, 
                    dep.requirements.cfg.idup, cast(shared)dep, os, 
                    compiler.idup, CompilationCache.get(mainPackHash, dep.requirements)
                );
            }
        }
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            import core.thread;
            printError(finishedPackage, res);
            return false;
        }
        else
        {
            printSucceed(finishedPackage, res.msNeeded);
            finishedPackage.becomeIndependent();
            dependencyFreePackages = root.findLeavesNodes();
            if(finishedPackage is root)
                break;
        }
    }
    return doLink(root.requirements.idup, os, compiler, mainPackHash, root.isUpToDate);
}


bool buildProjectFullyParallelized(ProjectNode root, string compiler, OS os)
{
    import std.concurrency;
    import std.stdio;
    string mainPackHash = hashFrom(root.requirements);
    CompilationCache[] cache = cacheStatusForProject(root);
    size_t i = 0;
    foreach(pack; root.collapse)
    {
        // writeln("Building ", pack.name, " with args ", getCompileCommands(pack.requirements.cfg.idup, os, compiler));
        spawn(&compile2, 
            pack.requirements.cfg.idup, 
            cast(shared)pack, os, compiler.idup, 
            cache[i++]
        );
    }
    foreach(pack; root.collapse)
    {
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            import core.thread;
            printError(finishedPackage, res);
            thread_joinAll();
            return false;
        }
        else
        {
            updateCache(mainPackHash, res.cache);
            printSucceed(finishedPackage, res.msNeeded);
        }
    }
    return doLink(root.requirements.idup, os, compiler, mainPackHash, root.isUpToDate);
}

private void printSucceed(ProjectNode node, size_t msecs)
{
    import std.stdio;
    if(node.isUpToDate)
        writeln("Project ", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"] up to date check in ", msecs, "ms");
    else 
        writeln("Compilation of project ", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"] finished in ", msecs, "ms");
}
private void printError(ProjectNode node, CompilationResult res)
{
    import std.stdio;
    writeln("Compilation of project '", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"] ",
        "' using flags\n\t", res.compilationCommand, 
        "\nFailed after ", res.msNeeded,"ms with message\n\t", res.message
    );
}

private bool doLink(immutable BuildRequirements req, OS os, string compiler, string mainPackHash, bool isUpToDate)
{
    import std.stdio;
    if(req.cfg.targetType.isStaticLibrary || isUpToDate)
    {
        if(isUpToDate)
            writeln("Project ", req.name, " is up to date, skipping linking");
        updateCache(mainPackHash, CompilationCache.get(mainPackHash, req), true);
        return true;
    }
    CompilationResult linkRes = link(req.cfg, os, compiler);
    if(linkRes.status)
    {
        writeln("Linking of project ", req.name, " failed with flags: \n\t",
            linkRes.compilationCommand,"\n\t\t  :\n\t",
            linkRes.message
        );
        return false;
    }
    else
    {
        writeln("Linking of project ", req.name, " finished!");
        updateCache(mainPackHash, CompilationCache.get(mainPackHash, req), true);

    }

    return true;
}