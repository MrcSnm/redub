module building.compile;

import buildapi;
import std.system;
import std.concurrency;
import command_generators.automatic;
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
}

void compile2(immutable BuildConfiguration cfg, shared ProjectNode pack, OS os, string compiler)
{
    import std.process;
    import std.datetime.stopwatch;
    CompilationResult res;
    res.node = pack;
    StopWatch sw = StopWatch(AutoStart.yes);
    try
    {
        res.compilationCommand = getCompileCommands(cfg, os, compiler);
        auto ret = executeShell(res.compilationCommand);
        res.status = ret.status;
        res.message = ret.output;
    }
    catch(Throwable e)
    {
        res.status = 1;
        res.message = e.toString;
    }
    finally {
        res.msNeeded = sw.peek.total!"msecs";
        ownerTid.send(res);
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
    bool[ProjectNode] spawned;
    while(true)
    {
        writeln("Building ", dependencyFreePackages[0].name, " with args ", getCompileCommands(dependencyFreePackages[0].requirements.cfg.idup, os, compiler));
        foreach(dep; dependencyFreePackages)
        {
            if(!(dep in spawned))
            {
                spawned[dep] = true;
                spawn(&compile2, dep.requirements.cfg.idup, cast(shared)dep, os, compiler.idup);
            }
        }
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            import core.thread;
            printError(finishedPackage.name, res);
            return false;
        }
        else
        {
            printSucceed(finishedPackage.name, res.msNeeded);
            finishedPackage.becomeIndependent();
            dependencyFreePackages = root.findLeavesNodes();
            if(finishedPackage is root)
                break;
        }
    }
    return doLink(root.requirements.cfg.idup, os, compiler);
}


bool buildProjectFullyParallelized(ProjectNode root, string compiler, OS os)
{
    import std.concurrency;
    import std.stdio;
    ProjectNode[] allPackages = root.collapse();
    foreach(pack; allPackages)
    {
        spawn(&compile2, pack.requirements.cfg.idup, cast(shared)pack, os, compiler.idup);
    }
    foreach(pack; allPackages)
    {
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            import core.thread;
            printError(finishedPackage.name, res);
            thread_joinAll();
            return false;
        }
        else
            printSucceed(finishedPackage.name, res.msNeeded);
    }
    return doLink(root.requirements.cfg.idup, os, compiler);
}

private void printSucceed(string name, size_t msecs)
{
    import std.stdio;
    writeln("Compilation of project ", name, " finished in ", msecs, "ms");
}
private void printError(string name, CompilationResult res)
{
    import std.stdio;
    writeln("Compilation of project '", name,
        "' using flags\n\t", res.compilationCommand, 
        "\nFailed after ", res.msNeeded,"ms with message\n\t", res.message
    );
}

private bool doLink(immutable BuildConfiguration cfg, OS os, string compiler)
{
    import std.stdio;
    if(cfg.targetType.isStaticLibrary) return true;
    CompilationResult linkRes = link(cfg, os, compiler);
    if(linkRes.status)
    {
        writeln("Linking of project ", cfg.name, " failed:\n\t",
            linkRes.message
        );
        return false;
    }
    else
        writeln("Linking of project ", cfg.name, " finished!");

    return true;
}