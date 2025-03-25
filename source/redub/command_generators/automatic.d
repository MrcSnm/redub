module redub.command_generators.automatic;
public import std.system;
public import redub.buildapi;
public import redub.compiler_identification;

static import redub.command_generators.gnu_based;
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
 *   cfg = the configuration that will be parsed
 *   s = Session for determining how to build it, compiler, os and ISA matters
 *   mainPackHash = This will be used as a directory in some of outputs
 * Returns: The compilation commands those arguments generates
 */
string[] getCompilationFlags(const BuildConfiguration cfg, CompilingSession s, string mainPackHash, bool isRoot)
{
    import redub.command_generators.commons;
    switch(cfg.getCompiler(s.compiler).compiler) with(AcceptedCompiler)
    {
        case gxx:
            return redub.command_generators.gnu_based.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, cppExt);
        case gcc:
            return redub.command_generators.gnu_based.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, cExt);
        case dmd:
            return redub.command_generators.dmd.parseBuildConfiguration(cfg, s, mainPackHash, isRoot);
        case ldc2:
            return redub.command_generators.ldc.parseBuildConfiguration(cfg, s, mainPackHash, isRoot);
        default:throw new Exception("Unsupported compiler '"~cfg.getCompiler(s.compiler).bin~"'");
    }
}

string[] getLinkFlags(const ThreadBuildData data, CompilingSession s, string mainPackHash)
{
    import command_generators.linkers;
    version(Windows)
        return parseLinkConfigurationMSVC(data, s, mainPackHash);
    else
        return parseLinkConfiguration(data, s, mainPackHash);
}


string getLinkCommands(const ThreadBuildData data, CompilingSession s, string mainPackHash)
{
    import std.process;
    string[] flags = getLinkFlags(data, s, mainPackHash);

    CompilerBinary c = data.cfg.getCompiler(s.compiler);
    if(c.compiler == AcceptedCompiler.invalid)
        throw new Exception("Unsupported compiler '" ~ c.bin~"'");

    return escapeShellCommand(c.bin) ~ " "~ processFlags(flags);
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