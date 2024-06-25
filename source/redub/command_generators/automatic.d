module redub.command_generators.automatic;
public import std.system;
public import redub.buildapi;
public import redub.compiler_identification;
import std.process;

static import redub.command_generators.gnu_based;
static import redub.command_generators.gnu_based_ccplusplus;
static import redub.command_generators.dmd;
static import redub.command_generators.ldc;


string[] getCompilationFlags(const BuildConfiguration cfg, OS os, Compiler compiler)
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
        default:throw new Exception("Unsupported compiler '"~compiler.binOrPath~"'");
    }

}

string getCompileCommands(const BuildConfiguration cfg, OS os, Compiler compiler)
{
    string[] flags = getCompilationFlags(cfg,os,compiler);
    return escapeShellCommand(compiler.binOrPath) ~ " " ~ processFlags(flags);
}

string getLinkCommands(const BuildRequirements req, OS os, Compiler compiler)
{
    import command_generators.linkers;
    string[] flags;
    
    version(Windows) flags = parseLinkConfigurationMSVC(req, os, compiler);
    else flags = parseLinkConfiguration(req, os, compiler);

    if(compiler.compiler == AcceptedCompiler.invalid)
        throw new Exception("Unsupported compiler '" ~ compiler.binOrPath~"'");

    if(compiler.isDCompiler)
        return escapeShellCommand(compiler.binOrPath) ~ " "~ processFlags(flags);
    return escapeShellCommand(compiler.archiver) ~ " " ~ processFlags(flags);
}


/** 
 * Executes escaleShellCommand for fixing issues such as -rpath=$ORIGIN expanding to -rpath="" which may cause some issues
 * this will guarantee that no command is expanded by the shell environment
 * Params:
 *   flags = The compiler or linker flags
 */
private auto processFlags(string[] flags)
{
    import std.algorithm.iteration;
    import std.array:join;
    return (map!((string v) => escapeShellCommand(v))(flags)).join(" ");
}