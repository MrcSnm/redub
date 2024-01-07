module building.compile;

import buildapi;
import std.system;
static import command_generators.dmd;
static import command_generators.ldc;

bool compile(BuildRequirements req, OS os, string compiler)
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
    return wait(spawnShell(cmds)) == 0;
}

bool link()
{
    return false;
}


bool buildProject(ProjectNode[][] steps, string compiler)
{
    foreach_reverse(dep; steps)
        foreach(ProjectNode proj; dep)
        {
            if(!compile(proj.requirements, os, compiler))
                return false;
        }
    return true;
}