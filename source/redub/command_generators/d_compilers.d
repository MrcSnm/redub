module redub.command_generators.d_compilers;
import redub.buildapi;
import redub.command_generators.commons;
import redub.compiler_identification;
import redub.command_generators.ldc;

string[] parseBuildConfiguration(AcceptedCompiler comp, const BuildConfiguration b, OS target)
{
    import std.path;
    string function(ValidDFlags) mapper = getFlagMapper(comp);

    
    string[] commands = [mapper(ValidDFlags.enableColor), mapper(ValidDFlags.preserveNames)];
    with(b)
    {
        commands~= dFlags;
        if(isDebug) commands~= "-debug";
        if(comp == AcceptedCompiler.ldc2)
        {
            ///commands~= "--cache-retrieval=hardlink"; // Doesn't work on Windows when using a multi drives projects
            commands~= "--cache=.ldc2_cache";
            commands~= "--cache-prune";
        }

        if(b.arch)
        {
            commands~= mapArch(comp, b.arch);
        }
        commands = mapAppendPrefix(commands, debugVersions, mapper(ValidDFlags.debugVersions), false);
        commands = mapAppendPrefix(commands, versions, mapper(ValidDFlags.versions), false);
        commands = mapAppendPrefix(commands, importDirectories, mapper(ValidDFlags.importPaths), true);

        if(targetType.isLinkedSeparately)
            commands~= mapper(ValidDFlags.compileOnly);
        commands = mapAppendPrefix(commands, stringImportPaths, mapper(ValidDFlags.stringImportPaths), true);


        if(targetType.isStaticLibrary)
            commands~= mapper(ValidDFlags.buildAsLibrary);
        else if(targetType == TargetType.dynamicLibrary)
            commands~= mapper(ValidDFlags.buildAsShared);

        commands~= mapper(ValidDFlags.objectDir)~getObjectDir(b.workingDir).escapePath;
        commands~= mapper(ValidDFlags.outputFile) ~ getConfigurationOutputPath(b, target).escapePath;
    
        putSourceFiles(commands, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, ".d");

    }

    return commands;
}

string getTargetTypeFlag(TargetType t, AcceptedCompiler c)
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

string function(ValidDFlags) getFlagMapper(AcceptedCompiler comp)
{
    switch(comp)
    {
        case AcceptedCompiler.dmd: return &dmdFlags;
        case AcceptedCompiler.ldc2: return &ldcFlags;
        default: throw new Exception("Compiler sent is not a D compiler.");
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
        case inline: return "-inline";
        case noBoundsCheck: return "-noboundscheck";
        case unittests: return "-unittest";
        case syntaxOnly: return "-o-";
        case profile: return "-profile";
        case profileGC: return "-profile=gc";
        case coverage: return "-cov";
        case coverageCTFE: return "-cov=ctfe";
        
        case enableColor: return "-color=on";
        case stringImportPaths: return "-J=";
        case versions: return "-version=";
        case debugVersions: return "-debug=";
        case importPaths: return "-I";
        case objectDir: return "-od";
        case outputFile: return "-of";
        case buildAsLibrary: return "-lib";
        case buildAsShared: return "-shared";
        case compileOnly: return "-c";
        case arch: throw new Exception("arch not supported by dmd.");
        case preserveNames: return "-op";
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
        case inline: return "-enable-inlining";
        case noBoundsCheck: return "-boundscheck=off";
        case unittests: return "-unittest";
        case syntaxOnly: return "-o-";
        case profile: return "-fdmd-trace-functions";
        case profileGC: return "";
        case coverage: return "-cov";
        case coverageCTFE: return "-cov=ctfe";

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
    }
}

string mapArch(AcceptedCompiler compiler, string arch)
{
    if(compiler != AcceptedCompiler.ldc2)
        throw new Exception("Only ldc2 supports --arch flag");

    switch (arch) 
    {
        case "": return null;
        case "x86":  return "-march=x86";
        case "x86_mscoff":  return "-march=x86";
        case "x86_64":  return "-march=x86-64";
        case "aarch64":  return "-march=aarch64";
        case "powerpc64":  return "-march=powerpc64";
        default: return "-mtriple="~arch;
    }
}

enum ValidDFlags
{
    @"buildOption" debugMode,
    @"buildOption" debugInfo,
    @"buildOption" releaseMode,
    @"buildOption" optimize,
    @"buildOption" inline,
    @"buildOption" noBoundsCheck,
    @"buildOption" unittests,
    @"buildOption" syntaxOnly,
    @"buildOption" profile,
    @"buildOption" profileGC,
    @"buildOption" coverage,
    @"buildOption" coverageCTFE,

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
    preserveNames
}