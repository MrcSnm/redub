module redub.command_generators.automatic;
public import std.system;
public import redub.buildapi;
public import redub.compiler_identification;
import std.process;

static import redub.command_generators.gnu_based;
static import redub.command_generators.gnu_based_ccplusplus;
static import redub.command_generators.dmd;
static import redub.command_generators.ldc;


string[] getCompilationFlags(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case gxx:
            return redub.command_generators.gnu_based_ccplusplus.parseBuildConfiguration(cfg, os);
        case gcc:
            return redub.command_generators.gnu_based.parseBuildConfiguration(cfg, os);
        case dmd:
            return redub.command_generators.dmd.parseBuildConfiguration(cfg, os);
        case ldc2:
            return redub.command_generators.ldc.parseBuildConfiguration(cfg, os);
        default:throw new Error("Unsupported compiler '"~compiler.binOrPath~"'");
    }

}

string getCompileCommands(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    import std.array:join;
    string[] flags = getCompilationFlags(cfg,os,compiler);
    return escapeShellCommand(compiler.binOrPath) ~ flags.join(" ");
}

string getLinkCommands(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    import std.array:join;
    import command_generators.linkers;
    string[] flags;
    
    version(Windows) flags = parseLinkConfigurationMSVC(cfg, os, compiler);
    else flags = parseLinkConfiguration(cfg, os, compiler);

    if(compiler.compiler == AcceptedCompiler.invalid)
        throw new Error("Unsupported compiler '" ~ compiler.binOrPath~"'");

    if(compiler.isDCompiler)
        return escapeShellCommand(compiler.binOrPath) ~ " "~ flags.join(" ");
    return escapeShellCommand(compiler.archiver) ~ flags.join(" ");
}