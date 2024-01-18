module command_generators.automatic;
public import std.system;
public import buildapi;
import std.process;
static import command_generators.dmd;
static import command_generators.ldc;
string getCompileCommands(immutable BuildConfiguration cfg, OS os, string compiler)
{
    string[] flags;
    switch(compiler)
    {
        case "dmd":
            flags = command_generators.dmd.parseBuildConfiguration(cfg, os);
            break;
        case "ldc", "ldc2":
            compiler = "ldc2";
            flags = command_generators.ldc.parseBuildConfiguration(cfg, os);
            break;
        default: throw new Error("Unsupported compiler "~compiler);
    }

    return escapeShellCommand(compiler ~ flags);
}

string getLinkCommands(immutable BuildConfiguration cfg, OS os, string compiler)
{
    import command_generators.linkers;
    string[] flags;
    version(Windows) flags = parseLinkConfigurationMSVC(cfg, os, compiler);
    else flags = parseLinkConfiguration(cfg, os, compiler);

    switch(compiler)
    {
        case "dmd": break;
        case "ldc", "ldc2": compiler = "ldc2"; break;
        default: throw new Error("Unsupported compiler "~compiler);
    }
    return escapeShellCommand(compiler ~ flags);
}