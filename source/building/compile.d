module building.compile;

import buildapi;
import std.system;
import std.concurrency;
static import command_generators.dmd;
static import command_generators.ldc;

void compile(BuildRequirements req, OS os, string compiler, 
    out int status, out string sink, out string compilationFlagsSink
)
{
    import std.process;
    string[] flags;
    switch(compiler)
    {
        case "dmd":
            flags = command_generators.dmd.parseBuildConfiguration(cast(immutable)req.cfg, os);
            break;
        case "ldc", "ldc2":
            flags = command_generators.ldc.parseBuildConfiguration(cast(immutable)req.cfg, os);
            break;
        default: throw new Error("Unsupported compiler "~compiler);
    }
    string cmds = escapeShellCommand(compiler ~ flags);
    auto ret = executeShell(cmds);
    status = ret.status;
    sink = ret.output;
    compilationFlagsSink = cmds;
}

struct CompilationResult
{
    string compilationCommand;
    string message;
    int status;
    shared ProjectNode node;
}

void compile2(immutable BuildConfiguration cfg, shared ProjectNode pack, OS os, string compiler)
{
    import std.process;
    string[] flags;
    CompilationResult res = CompilationResult((cast()pack).name);
    switch(compiler)
    {
        case "dmd":
            flags = command_generators.dmd.parseBuildConfiguration(cfg, os);
            break;
        case "ldc", "ldc2":
            flags = command_generators.ldc.parseBuildConfiguration(cfg, os);
            break;
        default: throw new Error("Unsupported compiler "~compiler);
    }
    res.compilationCommand = escapeShellCommand(compiler ~ flags);
    res.node = pack;
    auto ret = executeShell(res.compilationCommand);
    res.status = ret.status;
    res.message = ret.output;

    ownerTid.send(res);
}

bool link()
{
    return false;
}


bool buildProject(ProjectNode[][] steps, ProjectNode tree, string compiler)
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


bool buildProject2(ProjectNode root, string compiler, OS os)
{
    import std.concurrency;
    import std.stdio;
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    bool nextIsRoot;
    while(true)
    {
        foreach(dep; dependencyFreePackages)
            spawn(&compile2, dep.requirements.cfg.idup, cast(shared)dep, os, compiler.idup);
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            import core.thread;
            writeln("Compilation of project '", finishedPackage.name,
                "' using flags\n\t", res.compilationCommand, 
                "\nFailed with message\n\t", res.message
            );
            thread_joinAll();
            return false;
        }
        else
        {
            writeln("Compilation of project ", finishedPackage.name, " finished!");
            finishedPackage.becomeIndependent();
            if(nextIsRoot)
                break;
            dependencyFreePackages = root.findLeavesNodes();
            if(dependencyFreePackages.length >= 1 && dependencyFreePackages[0] is root)
                nextIsRoot = true;
        }
    }
    return true;
}