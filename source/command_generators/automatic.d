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
    string[] flags;
    switch(compiler)
    {
        case "dmd":
            version(Windows)flags = command_generators.dmd.parseLinkConfigurationMSVC(cfg, os);
            else flags = command_generators.dmd.parseLinkConfiguration(cfg, os);
            break;
        case "ldc", "ldc2":
            compiler = "ldc2";
            version(Windows) flags = command_generators.ldc.parseLinkConfiguration(cfg, os);
            else flags = command_generators.ldc.parseLinkConfiguration(cfg, os);
            break;
        default: throw new Error("Unsupported compiler "~compiler);
    }
    return escapeShellCommand(compiler ~ flags);
}