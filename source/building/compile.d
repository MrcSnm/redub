module building.compile;

import buildapi;
import std.system;
static import command_generators.dmd;
static import command_generators.ldc;

void compile(BuildRequirements req, OS os, string compiler, out int status, out string sink)
{
    import std.process;
    string[] flags;
    switch(compiler)
    {
        case "dmd":
            flags = command_generators.dmd.parseBuildConfiguration(req.cfg, os);
            break;
        case "ldc", "ldc2":
            flags = command_generators.ldc.parseBuildConfiguration(req.cfg, os);
            break;
        default: throw new Error("Unsupported compiler "~compiler);
    }
    string cmds = escapeShellCommand(compiler ~ flags);
    auto ret = executeShell(cmds);
    status = ret.status;
    sink = ret.output;
}

bool link()
{
    return false;
}


bool buildProject(ProjectNode[][] steps, string compiler)
{
    import std.algorithm.searching:maxCount;
    import std.parallelism;
    size_t maxSize;
    string[] outputSink;
    int[] statusSink;
    foreach(depth; steps) if(depth.length > maxSize) maxSize = depth.length;
    outputSink = new string[](maxSize);
    statusSink = new int[](maxSize);

    foreach_reverse(dep; steps)
    {
        foreach(i, ProjectNode proj; parallel(dep))
        {
            compile(proj.requirements, os, compiler, statusSink[i], outputSink[i]);
        }
        
        foreach(i; 0..dep.length)
        {
            import std.stdio;
            if(statusSink[i])
            {
                writeln("Compilation of project ", dep[i].name, " failed with: \n", outputSink[i]);
                return false;
            }
            else
                writeln("Compilation of project ", dep[i].name, " finished!");
        }

    }
    return true;
}