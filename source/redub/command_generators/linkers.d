module redub.command_generators.linkers;
public import redub.tooling.compiler_identification;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;


///Rough way to check for start-group. Might need a proper linker identification in the future.
bool canEmitStartGroup(OS os, ISA isa, AcceptedLinker linker)
{
    if(os.isWindows)
        return false;
    if(isa == ISA.webAssembly || cast(OSExtension)os == OSExtension.emscripten)
        return false;
    if(os.isApple)
        return false;
    if(isa == ISA.arm) //TODO: Added because PSVita is an ARM target and it is currently the only target without detection
        return false;
    return true;
}


string[] parseLinkConfiguration(const ThreadBuildData data, CompilationInfo s, string requirementCache, bool includeOutput = true, bool includeDFlags = true)
{
    import redub.misc.path;
    import redub.building.cache;
    string[] cmds;
    AcceptedLinker linker = s.compiler.linker;
    bool emitStartGroup = canEmitStartGroup(s.targetOS, s.isa, linker);

    const BuildConfiguration b = data.cfg;
    CompilerBinary c = b.getCompiler(s.compiler);
    with(b)
    {
        {
            import redub.command_generators.d_compilers;

            if (includeOutput && targetType.hasBuildableOutput)
            {
                string cacheDir = getCacheOutputDir(requirementCache, b, s, data.extra.isRoot);
                string objExtension = getObjectExtension(s.targetOS);
                if(c.isDCompiler)
                    cmds~= "-of="~buildNormalizedPath(cacheDir, getOutputName(b, s.targetOS)).escapePath;
                else
                {
                    cmds~= "-o";
                    cmds~= buildNormalizedPath(cacheDir, getOutputName(b, s.targetOS)).escapePath;
                }
                if(b.reuseObjects)
                    putSourceFiles(cmds, null, [getObjectDir(cacheDir)], null, null, objExtension);
                else if(c.isDCompiler)
                    cmds~= buildNormalizedPath(outputDirectory, targetName~objExtension).escapePath;
                else
                    ///C/C++ sources are compiled to individual objects in the
                    ///cache directory, so link all of them.
                    putSourceFiles(cmds, null, [cacheDir], null, null, objExtension);
            }
            if(c.isDCompiler && includeOutput)
            {
                string arch = mapArch(c.compiler, b.arch);
                if(arch)
                    cmds~= arch;
            }
            if(includeDFlags)
                cmds~= filterLinkFlags(b.dFlags);
        }
        if(targetType.isAnyLibrary)
            cmds~= getTargetTypeFlag(targetType, c);

        if (targetType.isLinkedSeparately)
        {
            //Only linux supports start/end group and no-as-needed. OSX does not
            if(emitStartGroup)
            {
                if(c.isDCompiler)
                {
                    cmds~= "-L--no-as-needed";
                    cmds~= "-L--start-group";
                }
                else
                {
                    cmds~= "-Wl,--no-as-needed";
                    cmds~= "-Wl,--start-group";
                }
            }
            ///Use library full path for the base file
            cmds = mapAppendReverse(cmds, data.extra.librariesFullPath, (string l)
            {
                string libPath = getOutputName(TargetType.staticLibrary, l, s.targetOS);
                return c.isDCompiler ? "-L"~libPath : libPath;
            });
            if(emitStartGroup)
                cmds~= c.isDCompiler ? "-L--end-group" : "-Wl,--end-group";

            if(s.targetOS.isApple)
            {
                foreach(framework; frameworks)
                {
                    if(c.isDCompiler)
                        cmds~= ["-L-framework", "-L"~framework];
                    else
                        cmds~= ["-framework", framework];
                }
            }
            cmds = mapAppendPrefix(cmds, linkFlags, c.isDCompiler ? "-L" : "", false);
            cmds = mapAppendPrefix(cmds, libraryPaths, c.isDCompiler ? "-L-L" : "-L", true);
            cmds~= getLinkFiles(b.sourceFiles);
            import std.path:isAbsolute;
            cmds = mapAppend(cmds, libraries, (string l)
            {
                if(l.isAbsolute)
                    return c.isDCompiler ? "-L"~l : l;
                return (c.isDCompiler ? "-L-l" : "-l")~stripLibraryExtension(l);
            });

        }
    }

    return cmds;
}

string[] parseLinkConfigurationCL(const ThreadBuildData data, CompilationInfo s, string requirementCache, bool includeOutput = true, bool includeDFlags = true)
{
    import redub.misc.path;
    import redub.building.cache;

    string[] cmds;
    const BuildConfiguration b = data.cfg;
    with(b)
    {
        string cacheDir = getCacheOutputDir(requirementCache, b, s, data.extra.isRoot);
        if(includeOutput)
            cmds~= "/OUT:"~buildNormalizedPath(cacheDir, getOutputName(b, s.targetOS)).escapePath;
        if(!s.compiler.linkIncremental)
            cmds~= "/INCREMENTAL:NO";
        if(targetType == TargetType.dynamicLibrary)
            cmds~= "/DLL";

        cmds = mapAppendReverse(cmds, data.extra.librariesFullPath,
            (string l) => (l~getLibraryExtension(s.targetOS)).escapePath);
        cmds = mapAppendPrefix(cmds, libraryPaths, "/LIBPATH:", true);
        if(includeOutput)
            putSourceFiles(cmds, null, [cacheDir], null, null, ".obj");
        cmds~= getLinkFiles(b.sourceFiles);
        cmds = mapAppend(cmds, libraries, (string l) => stripLibraryExtension(l)~".lib");
        cmds~= linkFlags;
    }
    return cmds;
}

string[] parseLinkConfigurationMSVC(const ThreadBuildData data, CompilationInfo s, string requirementCache, bool includeOutput = true, bool includeDFlags = true)
{
    import std.algorithm.iteration;
    import redub.misc.path;
    import std.string;
    import redub.building.cache;

    string[] cmds;
    const BuildConfiguration b = data.cfg;
    CompilerBinary c = b.getCompiler(s.compiler);
    with(b)
    {
        string cacheDir = getCacheOutputDir(requirementCache, b, s, data.extra.isRoot);
        if(includeOutput)
        {
            cmds~= "-of"~buildNormalizedPath(cacheDir, getOutputName(b, s.targetOS)).escapePath;
            string objExtension = getObjectExtension(s.targetOS);
            if(b.reuseObjects)
                putSourceFiles(cmds, null, [getObjectDir(cacheDir)], null, null, objExtension);
            else
                cmds~= buildNormalizedPath(outputDirectory, targetName~objExtension).escapePath;
        }

        if(c.isDCompiler)
        {
            import redub.command_generators.d_compilers;
            if(includeOutput)
            {
                string arch = mapArch(c.compiler, b.arch);
                if(arch)
                    cmds~= arch;
            }
            if(includeDFlags)
                cmds~= filterLinkFlags(b.dFlags);
        }
        if(!s.compiler.linkIncremental)
        {
            cmds~= "-L/INCREMENTAL:NO";
        }

        if(targetType.isAnyLibrary)
            cmds~= getTargetTypeFlag(targetType, c);

        cmds = mapAppendReverse(cmds, data.extra.librariesFullPath, (string l) => (l~getLibraryExtension(s.targetOS)).escapePath);

        cmds = mapAppendPrefix(cmds, linkFlags, "-L", false);

        cmds = mapAppendPrefix(cmds, libraryPaths, "-L/LIBPATH:", true);
        cmds~= getLinkFiles(b.sourceFiles);
        if(data.cfg.targetIcon)
        {
            import redub.misc.win_icon;
            cmds~= getWindowsResourceName(data.cfg.targetIcon);
        }
        cmds = mapAppend(cmds, libraries, (string l) => "-L"~stripLibraryExtension(l)~".lib");

    }
    return cmds;
}


string getTargetTypeFlag(TargetType o, CompilerBinary compiler)
{
    static import redub.command_generators.d_compilers;
    static import redub.command_generators.gnu_based;
    static import redub.command_generators.clang;

    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case dmd, ldc2, nmc: return redub.command_generators.d_compilers.getTargetTypeFlag(o, compiler);
        case gcc, gxx: return redub.command_generators.gnu_based.getTargetTypeFlag(o);
        case clang: return redub.command_generators.clang.getTargetTypeFlag(o);
        default: throw new Exception("Unsupported compiler "~compiler.bin);
    }
}