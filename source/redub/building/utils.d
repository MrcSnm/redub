module redub.building.utils;
import redub.buildapi;

auto execCompilerBase(const BuildConfiguration cfg, string compilerBin, string[] compileFlags, out string compilationCommands, bool isDCompiler)
{
    import std.system;
    import std.process;
    import std.file;
    import redub.command_generators.automatic;
    import redub.command_generators.commons;
    if(std.system.os.isWindows && isDCompiler)
    {
        string cmdFile = createCommandFile(cfg, compileFlags, compilationCommands);
        compilationCommands = compilerBin ~ " "~compilationCommands;
        scope(exit)
            std.file.remove(cmdFile);
        return executeShell(compilerBin~ " @"~cmdFile, null, Config.none, size_t.max, cfg.workingDir);
    }
    compilationCommands = escapeCompilationCommands(compilerBin, compileFlags);
    return executeShell(compilationCommands, null, Config.none, size_t.max, cfg.workingDir);
}

auto execCompiler(const BuildConfiguration cfg, string compilerBin, string[] compileFlags, out string compilationCommands, Compiler compiler, string inputDir)
{
    import std.file;
    import redub.api;
    import std.path;

    import redub.compiler_identification;
    import redub.command_generators.commons;
    //Remove existing binary, since it won't be replaced by simply executing commands
    string outDir = getConfigurationOutputPath(cfg, os);
    if(exists(outDir))
        remove(outDir);

    auto ret = execCompilerBase(cfg, compilerBin, compileFlags, compilationCommands, cfg.getCompiler(compiler).isDCompiler);

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

auto linkBase(const ThreadBuildData data, CompilingSession session, string rootHash, out string compilationCommand)
{
    import redub.command_generators.automatic;
    CompilerBinary c = data.cfg.getCompiler(session.compiler);
    return execCompilerBase(
        data.cfg,
        c.bin,
        getLinkFlags(data, session,  rootHash),
        compilationCommand,
        c.isDCompiler,
    );
}

/**
 * Generates a static library using archiver. FIXME: BuildRequirements should know its files.
 * Params:
 *   data = The data containing project information
 *   s = Compiling Session
 *   command = Command for being able to print it later
 */
auto executeArchiver(const ThreadBuildData data, CompilingSession s, out string command)
{
    import std.process;
    import std.array;
    import redub.command_generators.commons;
    import redub.compiler_identification;
    import std.path;
    Archiver a = s.compiler.archiver;

    string[] cmd = [a.bin];
    final switch(a.type) with(AcceptedArchiver)
    {
        case ar, llvmAr: cmd~= ["rcs"]; break;
        case libtool: cmd~= ["-static", "-o"]; break;
        case none: break;
    }

    cmd~= buildNormalizedPath(data.cfg.outputDirectory, getOutputName(data.cfg, s.os, s.isa));

    putObjectFiles(cmd, data.cfg, s.os, data.cfg.getCompiler(s.compiler).compiler == AcceptedCompiler.gcc ? cExt : cppExt);
    command = cmd.join(" ");

    return executeShell(command);
}

private void putObjectFiles(ref string[] target, const BuildConfiguration b, OS os, scope const string[] extensions...)
{
    import redub.command_generators.commons;
    import std.file;
    import std.path;
    string[] objectFiles;
    putSourceFiles(objectFiles, b.workingDir, b.sourcePaths, b.sourceFiles, b.excludeSourceFiles, extensions);
    target = mapAppend(target, objectFiles, (string src) => setExtension(src, getObjectExtension(os)));
}