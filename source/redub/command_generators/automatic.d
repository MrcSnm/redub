module redub.command_generators.automatic;
public import std.system;
public import redub.buildapi;
public import redub.tooling.compiler_identification;

static import redub.command_generators.dmd;
static import redub.command_generators.ldc;
static import redub.command_generators.gnu_based;
static import redub.command_generators.clang;
static import redub.command_generators.cl;

string escapeCompilationCommands(string compilerBin, string[] flags)
{
    import std.process;
    return escapeShellCommand(compilerBin) ~ " " ~ processFlags(flags);
}

/**
 * Dispatches to the appropriate compiler backend to generate compilation flags
 * Params:
 *   cfg = the configuration that will be parsed
 *   s = Session for determining how to build it, compiler, os and ISA matters
 *   mainPackHash = This will be used as a directory in some of outputs
 *   isRoot = Whether this is the root package
 * Returns: The compilation commands those arguments generates
 */
string[] getCompilationFlags(const BuildConfiguration cfg, CompilingSession s, string mainPackHash, bool isRoot, bool singleCall = false)
{
    import redub.command_generators.commons;
    switch(cfg.getCompiler(s.compiler).compiler) with(AcceptedCompiler)
    {
        case gxx:
            return redub.command_generators.gnu_based.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, cppExt);
        case clang:
            return redub.command_generators.clang.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, cppExt);
        case cl:
            return redub.command_generators.cl.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, cppExt);
        case gcc:
            return redub.command_generators.gnu_based.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, cExt);
        case dmd:
            return redub.command_generators.dmd.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, singleCall);
        case ldc2:
            return redub.command_generators.ldc.parseBuildConfiguration(cfg, s, mainPackHash, isRoot, singleCall);
        default:throw new Exception("Unsupported compiler '"~cfg.getCompiler(s.compiler).bin~"'");
    }
}

string[] getLinkFlags(const ThreadBuildData data, CompilingSession s, string mainPackHash, bool includeOutput = true, bool includeDFlags = true)
{
    import redub.command_generators.commons;
    import redub.command_generators.linkers;
    CompilerBinary c = data.cfg.getCompiler(s.compiler);
    if(isWindows(s.os))
    {
        if(c.isDCompiler)
            return parseLinkConfigurationMSVC(data, s, mainPackHash, includeOutput, includeDFlags);
        if(c.compiler == AcceptedCompiler.cl)
            return parseLinkConfigurationCL(data, s, mainPackHash, includeOutput, includeDFlags);
        return parseLinkConfiguration(data, s, mainPackHash, includeOutput, includeDFlags);
    }
    return parseLinkConfiguration(data, s, mainPackHash, includeOutput, includeDFlags);
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
 * Executes escapeShellCommand to fix issues such as -rpath=$ORIGIN expanding to -rpath="",
 * which may cause problems. This guarantees that no argument is expanded by the shell environment.
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