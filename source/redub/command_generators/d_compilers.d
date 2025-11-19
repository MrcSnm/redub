module redub.command_generators.d_compilers;
import redub.buildapi;
import redub.command_generators.commons;
import redub.tooling.compiler_identification;
import redub.command_generators.ldc;
import redub.building.cache;

string[] parseBuildConfiguration(const BuildConfiguration b, CompilingSession s, string mainPackhash, bool isRoot)
{
    import redub.misc.path;
    string function(ValidDFlags) mapper = getFlagMapper(s.compiler.d);
    AcceptedCompiler comp = s.compiler.d.compiler;


    string[] cmds = [mapper(ValidDFlags.enableColor)];
    string preserve = mapper(ValidDFlags.preserveNames);
    if(preserve) cmds ~= preserve;
    with(b)
    {
        if(isDebug) cmds~= "-debug";
        if(compilerVerbose) cmds~= mapper(ValidDFlags.verbose);
        if(compilerVerboseCodeGen) cmds~= mapper(ValidDFlags.verboseCodeGen);


        string cacheDir = getCacheOutputDir(mainPackhash, b, s, isRoot);
        ///Whenever a single output file is specified, DMD does not output obj files
        ///For LDC, it does output them anyway
        if(b.getCompiler(s.compiler).compiler == AcceptedCompiler.ldc2 && !b.outputsDeps)
        {
            import std.file;
            string ldcObjOutDir = escapePath(cacheDir~ "_obj");
            mkdirRecurse(ldcObjOutDir);

            cmds~= mapper(ValidDFlags.objectDir) ~ ldcObjOutDir;
        }
        else if(b.outputsDeps)
            cmds~= mapper(ValidDFlags.objectDir)~getObjectDir(cacheDir).escapePath;

        cmds~= dFlags;
        if(comp == AcceptedCompiler.ldc2 && !s.os.isApple) //Broken on apple
        {
            ///cmds~= "--cache-retrieval=hardlink"; // Doesn't work on Windows when using a multi drives projects
            cmds~= "--cache=.ldc2_cache";
            cmds~= "--cache-prune";
        }


        cmds = mapAppendPrefix(cmds, debugVersions, mapper(ValidDFlags.debugVersions), false);
        cmds = mapAppendPrefix(cmds, versions, mapper(ValidDFlags.versions), false);
        cmds = mapAppendPrefix(cmds, importDirectories, mapper(ValidDFlags.importPaths), true);

        cmds = mapAppendPrefix(cmds, stringImportPaths, mapper(ValidDFlags.stringImportPaths), true);

        if(changedBuildFiles.length)
            cmds~= changedBuildFiles;
        else
            putSourceFiles(cmds, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, ".d");

        string arch = mapArch(comp, b.arch);
        if(arch)
            cmds~= arch;

        if(targetType.isLinkedSeparately)
            cmds~= mapper(ValidDFlags.compileOnly);
        if(targetType.isStaticLibrary)
            cmds~= mapper(ValidDFlags.buildAsLibrary);
        else if(targetType == TargetType.dynamicLibrary)
            cmds~= mapper(ValidDFlags.buildAsShared);


        //Output path for libs must still be specified
        if(!b.outputsDeps || targetType.isStaticLibrary)
            cmds~= mapper(ValidDFlags.outputFile) ~ buildNormalizedPath(cacheDir, getConfigurationOutputName(b, s.os)).escapePath;

        if(b.outputsDeps)
            cmds~= mapper(ValidDFlags.deps) ~ (buildNormalizedPath(cacheDir)~".deps").escapePath;

    }

    return cmds;
}

string getTargetTypeFlag(TargetType t, CompilerBinary c)
{
    auto mapper = getFlagMapper(c);
    switch(t) with(TargetType)
    {
        case executable, autodetect: return null;
        case library, staticLibrary: return mapper(ValidDFlags.buildAsLibrary);
        case dynamicLibrary: return mapper(ValidDFlags.buildAsShared);
        default: throw new Exception("Unsupported target type");
    }
}


/**
 *
 * Params:
 *   dflags = The dFlags which should contain link flags
 * Returns: Only the link flags.
 */
string[] filterLinkFlags(const string[] dflags)
{
    import std.algorithm.iteration:filter;
    import std.array;
    auto filtered = dflags.filter!((df => isLinkerDFlag(df)));
    return cast(string[])(filtered.array);
}

///Courtesy directly from dub
bool isLinkerDFlag(string arg)
{
    static bool startsWith(string input, string what)
    {
        if(input.length < what.length || what.length == 0) return false;
        return input[0..what.length] == what;
    }
    if (arg.length > 2 && arg[0..2] == "--")
        arg = arg[1..$]; // normalize to 1 leading hyphen

    switch (arg) {
        case "-g", "-gc", "-m32", "-m64", "-shared", "-lib",
                "-betterC", "-disable-linker-strip-dead", "-static":
            return true;
        default:
            return startsWith(arg, "-L")
                || startsWith(arg, "-Xcc=")
                || startsWith(arg, "-defaultlib=")
                || startsWith(arg, "-platformlib=")
                || startsWith(arg, "-flto")
                || startsWith(arg, "-fsanitize=")
                || startsWith(arg, "-gcc=")
                || startsWith(arg, "-link-")
                || startsWith(arg, "-linker=")
                || startsWith(arg, "-march=")
                || startsWith(arg, "-mscrtlib=")
                || startsWith(arg, "-mtriple=");
    }
}

string function(ValidDFlags) getFlagMapper(CompilerBinary comp)
{
    import redub.api;
    final switch(comp.compiler)
    {
        case AcceptedCompiler.dmd: return &dmdFlags;
        case AcceptedCompiler.ldc2: return &ldcFlags;
        case AcceptedCompiler.gcc, AcceptedCompiler.gxx: return &gccFlags;
        case AcceptedCompiler.clang: return &clangFlags;
        case AcceptedCompiler.cl: return &clFlags;
        case AcceptedCompiler.invalid: throw new RedubException(comp.bin);
    }
}

string dmdFlags(ValidDFlags flag)
{
    final switch(flag) with (ValidDFlags)
    {
        case debugMode: return "-debug";
        case debugInfo: return "-g";
        case releaseMode: return "-release";
        case optimize: return "-O";
        case optimizeSize: return "-O";
        case inline: return "-inline";
        case noBoundsCheck: return "-noboundscheck";
        case unittests: return "-unittest";
        case syntaxOnly: return "-o-";
        case profile: return "-profile";
        case profileGC: return "-profile=gc";
        case coverage: return "-cov";
        case coverageCTFE: return "-cov=ctfe";
        case mixinFile: return "-mixin=mixed_in.d";
        case verbose: return "-v";
        case verboseCodeGen: return "-vasm";
        case timeTrace: return "-ftime-trace";
        case timeTraceFile: return "-ftime-trace-file=trace.json";
        case enableColor: return "-color=on";
        case stringImportPaths: return "-J=";
        case versions: return "-version=";
        case debugVersions: return "-debug=";
        case importPaths: return "-I";
        case objectDir: return "-od=";
        case outputFile: return "-of=";
        case buildAsLibrary: return "-lib";
        case buildAsShared: return "-shared";
        case compileOnly: return "-c";
        case arch: throw new Exception("arch not supported by dmd.");
        case preserveNames: return "-op";
        case deps: return "-deps=";
    }
}

string ldcFlags(ValidDFlags flag)
{
    final switch(flag) with (ValidDFlags)
    {
        case debugMode: return "-d-debug";
        case debugInfo: return "-g";
        case releaseMode: return "-release";
        case optimize: return "-O3";
        case optimizeSize: return "-Oz";
        case inline: return "-enable-inlining";
        case noBoundsCheck: return "-boundscheck=off";
        case unittests: return "-unittest";
        case syntaxOnly: return "-o-";
        case profile: return "-fdmd-trace-functions";
        case profileGC: return "";
        case coverage: return "-cov";
        case coverageCTFE: return "-cov=ctfe";
        case mixinFile: return "-mixin=mixed_in.d";
        case verbose: return "-v";
        case verboseCodeGen: return "--v-cg";
        case timeTrace: return "--ftime-trace";
        case timeTraceFile: return "--ftime-trace-file=trace.json";
        case enableColor: return "--enable-color=true";
        case stringImportPaths: return "-J=";
        case versions: return "--d-version=";
        case debugVersions: return "--d-debug=";
        case importPaths: return "-I";
        case objectDir: return "--od=";
        case outputFile: return "--of=";
        case buildAsLibrary: return "--lib";
        case buildAsShared: return "--shared";
        case compileOnly: return "-c";
        case arch: return "--mtriple=";
        case preserveNames: return "--oq";
        case deps: return "--deps=";
    }
}

string gccFlags(ValidDFlags flag)
{
    final switch(flag) with (ValidDFlags)
    {
        case debugMode: return null;
        case debugInfo: return "-g";
        case releaseMode: return "-O3";
        case optimize: return "-O3";
        case optimizeSize: return "-Oz";
        case inline: return "-finline";
        case noBoundsCheck: return null;
        case unittests: return null;
        case syntaxOnly: return "-S";
        case profile: return null;
        case profileGC: return null;
        case coverage: return null;
        case coverageCTFE: return null;
        case mixinFile: return null;
        case verbose: return "-v";
        case verboseCodeGen: return null;
        case timeTrace: return null;
        case timeTraceFile: return null;
        case enableColor: return null;
        case stringImportPaths: return "-I";
        case versions: return "-D";
        case debugVersions: return "-D";
        case importPaths: return "-I";
        case objectDir: return null;
        case outputFile: return "-o";
        case buildAsLibrary: return null;
        case buildAsShared: return "-shared";
        case compileOnly: return "-c";
        case arch: return null;
        case preserveNames: return null;
        case deps: return null;
    }
}

string clangFlags(ValidDFlags flag)
{
    final switch(flag) with (ValidDFlags)
    {
        case debugMode: return null;
        case debugInfo: return "-g";
        case releaseMode: return "-O3";
        case optimize: return "-O3";
        case optimizeSize: return "-Oz";
        case inline: return "-finline-hint-functions";
        case noBoundsCheck: return null;
        case unittests: return null;
        case syntaxOnly: return "-fsyntax-only";
        case profile: return null;
        case profileGC: return null;
        case coverage: return null;
        case coverageCTFE: return null;
        case mixinFile: return null;
        case verbose: return "-v";
        case verboseCodeGen: return null;
        case timeTrace: return "-ftime-trace";
        case timeTraceFile: return null;
        case enableColor: return null;
        case stringImportPaths: return "-I";
        case versions: return "-D";
        case debugVersions: return "-D";
        case importPaths: return "-I";
        case objectDir: return null;
        case outputFile: return "-o";
        case buildAsLibrary: return null;
        case buildAsShared: return null;
        case compileOnly: return "-c";
        case arch: return null;
        case preserveNames: return null;
        case deps: return null;
    }
}

string clFlags(ValidDFlags flag)
{
    final switch(flag) with (ValidDFlags)
    {
        case debugMode: return null;
        case debugInfo: return "/Zi";
        case releaseMode: return null;
        case optimize: return "/O2";
        case optimizeSize: return "/O1";
        case inline: return null;
        case noBoundsCheck: return null;
        case unittests: return null;
        case syntaxOnly: return "/Zs";
        case profile: return null;
        case profileGC: return null;
        case coverage: return null;
        case coverageCTFE: return null;
        case mixinFile: return null;
        case verbose: return null;
        case verboseCodeGen: return null;
        case timeTrace: return null;
        case timeTraceFile: return null;
        case enableColor: return null;
        case stringImportPaths: return "/I";
        case versions: return "/D";
        case debugVersions: return "/D";
        case importPaths: return "/I";
        case objectDir: return null;
        case outputFile: return "/Fe";
        case buildAsLibrary: return null;
        case buildAsShared: return null;
        case compileOnly: return "/c";
        case arch: return null;
        case preserveNames: return null;
        case deps: return null;
    }
}


// Determines whether the specified process is running under WOW64 or an Intel64 of x64 processor.
version (Windows)
private bool isWow64() {
	// See also: https://docs.microsoft.com/de-de/windows/desktop/api/sysinfoapi/nf-sysinfoapi-getnativesysteminfo
	import core.sys.windows.winbase : GetNativeSystemInfo, SYSTEM_INFO;
	import core.sys.windows.winnt : PROCESSOR_ARCHITECTURE_AMD64;

	static bool result;
    static bool hasLoadedResult = false;

	// A process's architecture won't change over while the process is in memory
	// Return the cached result
    if(!hasLoadedResult)
    {
        SYSTEM_INFO systemInfo;
        GetNativeSystemInfo(&systemInfo);
        result = systemInfo.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64;
        hasLoadedResult = true;
    }

	return result;
}

string mapArch(AcceptedCompiler compiler, string arch)
{
    if(compiler == AcceptedCompiler.ldc2)
    {
        switch (arch)
        {
            case "": return null;
            case "x86": return "-march=x86";
            case "x86_mscoff":  return "-march=x86";
            case "x86_64":  return "-march=x86-64";
            case "aarch64":  return "-march=aarch64";
            case "powerpc64":  return "-march=powerpc64";
            default: return "-mtriple="~arch;
        }
    }
    else if(compiler == AcceptedCompiler.dmd)
    {
        switch(arch)
        {
            case "x86", "x86_omf", "x86_mscoff": return "-m32";
            case "x64", "x86_64": return "-m64";
            default:
            {
                version(Windows)
                {
                    return isWow64() ? "-m64": "-m32";
                }
                else  return null;
            }
        }
    }
    else throw new Exception("Unsupported compiler for mapping arch.");
}

enum ValidDFlags
{
    @"buildOption" debugMode,
    @"buildOption" debugInfo,
    @"buildOption" releaseMode,
    @"buildOption" optimize,
    @"buildOption" optimizeSize,
    @"buildOption" inline,
    @"buildOption" noBoundsCheck,
    @"buildOption" unittests,
    @"buildOption" syntaxOnly,
    @"buildOption" profile,
    @"buildOption" profileGC,
    @"buildOption" coverage,
    @"buildOption" coverageCTFE,

    verbose,
    verboseCodeGen,
    timeTrace,
    timeTraceFile,
    mixinFile,
    enableColor,
    stringImportPaths,
    versions,
    debugVersions,
    importPaths,
    objectDir,
    outputFile,
    buildAsLibrary,
    buildAsShared,
    compileOnly,
    arch,
    preserveNames,
    deps
}