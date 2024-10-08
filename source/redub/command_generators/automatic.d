module redub.command_generators.automatic;
public import std.system;
public import redub.buildapi;
public import redub.compiler_identification;

static import redub.command_generators.gnu_based;
static import redub.command_generators.gnu_based_ccplusplus;
static import redub.command_generators.dmd;
static import redub.command_generators.ldc;

string escapeCompilationCommands(string compilerBin, string[] flags)
{
    import std.process;
    return escapeShellCommand(compilerBin) ~ " " ~ processFlags(flags);
}

/**
 * This must be used on Windows since they need a command file
 * Params:
 *   cfg =
 *   os =
 *   compiler =
 *   mainPackHash =
 * Returns: The compilation commands those arguments generates
 */
string[] getCompilationFlags(const BuildConfiguration cfg, OS os, Compiler compiler, string mainPackHash)
{
    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case gxx:
            return redub.command_generators.gnu_based_ccplusplus.parseBuildConfiguration(cfg, os, compiler, mainPackHash);
        case gcc:
            return redub.command_generators.gnu_based.parseBuildConfiguration(cfg, os, compiler, mainPackHash);
        case dmd:
            return redub.command_generators.dmd.parseBuildConfiguration(cfg, os, compiler, mainPackHash);
        case ldc2:
            return redub.command_generators.ldc.parseBuildConfiguration(cfg, os, compiler, mainPackHash);
        default:throw new Exception("Unsupported compiler '"~compiler.binOrPath~"'");
    }
}

string[] getLinkFlags(const ThreadBuildData data, OS os, Compiler compiler, string mainPackHash)
{
    import command_generators.linkers;
    version(Windows)
        return parseLinkConfigurationMSVC(data, os, compiler, mainPackHash);
    else
        return parseLinkConfiguration(data, os, compiler, mainPackHash);
}

string getLinkerBin(Compiler compiler)
{
    if(compiler.isDCompiler)
        return compiler.binOrPath;
    return compiler.archiver;
}


string getLinkCommands(const ThreadBuildData data, OS os, Compiler compiler, string mainPackHash)
{
    import std.process;
    string[] flags = getLinkFlags(data, os, compiler, mainPackHash);
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
    import std.process;
    return (map!((string v) => escapeShellCommand(v))(flags)).join(" ");
}