module command_generators.automatic;
public import std.system;
public import buildapi;
public import compiler_identification;
import std.process;

static import command_generators.gnu_based;
static import command_generators.gnu_based_ccplusplus;
static import command_generators.dmd;
static import command_generators.ldc;


string[] getCompilationFlags(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case gxx:
            return command_generators.gnu_based_ccplusplus.parseBuildConfiguration(cfg, os);
        case gcc:
            return command_generators.gnu_based.parseBuildConfiguration(cfg, os);
        case dmd:
            return command_generators.dmd.parseBuildConfiguration(cfg, os);
        case ldc2:
            return command_generators.ldc.parseBuildConfiguration(cfg, os);
        default:throw new Error("Unsupported compiler "~compiler.binOrPath);
    }

}

string getCompileCommands(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    string[] flags = getCompilationFlags(cfg,os,compiler);
    return escapeShellCommand(compiler.binOrPath ~ flags);
}

string getLinkCommands(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    import command_generators.linkers;
    string[] flags;
    
    version(Windows) flags = parseLinkConfigurationMSVC(cfg, os, compiler);
    else flags = parseLinkConfiguration(cfg, os, compiler);

    if(compiler.compiler == AcceptedCompiler.invalid)
        throw new Error("Unsupported compiler " ~ compiler.binOrPath);

    if(compiler.isDCompiler)
        return escapeShellCommand(compiler.binOrPath ~ flags);
    return escapeShellCommand(compiler.archiver ~ flags);
}