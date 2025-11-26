module redub.building.utils;
import redub.buildapi;
public import redub.misc.shell;
import core.sys.posix.sys.ioctl;

string[] getHighPriorityCmd(string[] compileFlags)
{
    version(Posix)
    {
        import std.array;
        string[] ret = new string[compileFlags.length + 3];
        ret[0..3] = ["nice", "-n", "0"].staticArray;
        ret[3..$] = compileFlags;
        return ret;
    }
    return compileFlags;
}

ProcessExec2 execCompiler(const BuildConfiguration cfg, Compiler compiler, string[] compileFlags, out string compilationCommands, bool hasHighPriority, out string cmdFile, const string[string] env)
{
    import std.system;
    import std.file;
    import redub.command_generators.automatic;
    import redub.command_generators.commons;


    CompilerBinary cBin = cfg.getCompiler(compiler);
    string compilerBin = cBin.bin;

    if(std.system.os.isWindows && cBin.isDCompiler)
    {
        cmdFile = createCommandFile(cfg, compileFlags, compilationCommands);
        compilationCommands = compilerBin ~ " "~compilationCommands;
        ProcessExec2 ret = executeProcess2([compilerBin, "@"~cmdFile], env, Config.none, size_t.max, cfg.workingDir);

        version(Windows)
        {
            if(hasHighPriority)
            {
                import core.sys.windows.winbase;
                SetPriorityClass(ret.pipe.pid.osHandle, REALTIME_PRIORITY_CLASS);
            }
        }
        return ret;
    }
    compilationCommands = escapeCompilationCommands(compilerBin, compileFlags);
    return executeProcess2(cast(const(char)[][])getHighPriorityCmd(compileFlags), env, Config.none, size_t.max, cfg.workingDir);
}


auto finishCompilerExec(const BuildConfiguration cfg, Compiler compiler, string inputDir, string outDir, ProcessExec2 p)
{
    import std.file;
    import redub.api;
    import std.path;
    import redub.tooling.compiler_identification;
    import redub.command_generators.commons;

    auto ret = waitProcessExec(p);
    if(ret.status == 0)
    {
        //For working around bug 3541, 24748, dmd generates .obj files besides files, redub will move them out
        //of there to the object directory
        if(cfg.outputsDeps && cfg.preservePath && cfg.getCompiler(compiler).compiler == AcceptedCompiler.dmd)
            moveGeneratedObjectFiles(cfg.sourcePaths, cfg.sourceFiles, cfg.excludeSourceFiles, getObjectDir(inputDir),getObjectExtension(os));
        copyDir(inputDir, dirName(outDir));
    }
    return ret;
}




ProcessExec2 linkBase(const ThreadBuildData data, CompilingSession session, string rootHash, out string compilationCommand, out string cmdFile)
{
    import redub.command_generators.automatic;
    return execCompiler(
        data.cfg,session.compiler,
        getLinkFlags(data, session,  rootHash),
        compilationCommand,
        true,
        cmdFile,
        data.env
    );
}

/**
 * Generates a static library using archiver. FIXME: BuildRequirements should know its files.
 * Params:
 *   data = The data containing project information
 *   s = Compiling Session
 *   command = Command for being able to print it later
 */
auto executeArchiver(const ThreadBuildData data, CompilingSession s, string mainPackHash, out string command)
{
    import std.process;
    import std.array;
    import redub.command_generators.commons;
    import redub.tooling.compiler_identification;
    import std.path;
    import redub.building.cache;

    string[] cmd = [data.archiver.bin];
    final switch(data.archiver.type) with(AcceptedArchiver)
    {
        case ar, llvmAr: cmd~= ["rcs"]; break;
        case llvmLib: break;
        case lib: break;
        case libtool: cmd~= ["-static", "-o"]; break;
        case none: throw new Exception("No archiver registered."); break;
    }
    if(data.archiver.type == AcceptedArchiver.llvmLib || data.archiver.type == AcceptedArchiver.lib)
        cmd~= "/out:"~buildNormalizedPath(data.cfg.outputDirectory, getOutputName(data.cfg, s.os, s.isa));
    else
        cmd~= buildNormalizedPath(data.cfg.outputDirectory, getOutputName(data.cfg, s.os, s.isa));

    string cacheDir = getCacheOutputDir(mainPackHash, data.cfg, s, data.extra.isRoot);

    putSourceFiles(cmd, null, [cacheDir], data.cfg.sourceFiles, data.cfg.excludeSourceFiles, ".o", ".obj");

    return execute(cmd, data.env);
}