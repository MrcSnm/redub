module command_generators.linkers;
public import redub.tooling.compiler_identification;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;


string[] parseLinkConfiguration(const ThreadBuildData data, CompilingSession s, string requirementCache)
{
    import redub.misc.path;
    import redub.building.cache;
    string[] cmds;
    AcceptedLinker linker = s.compiler.linker;
    bool emitStartGroup = s.isa != ISA.webAssembly && linker != AcceptedLinker.ld64 && cast(OSExtension)s.os != OSExtension.emscripten;


    const BuildConfiguration b = data.cfg;
    CompilerBinary c = b.getCompiler(s.compiler);
    with(b)
    {
        {
            import redub.command_generators.d_compilers;

            if (targetType.isLinkedSeparately)
            {
                string cacheDir = getCacheOutputDir(requirementCache, b, s, data.extra.isRoot);
                string objExtension = getObjectExtension(s.os);
                if(c.isDCompiler)
                    cmds~= "-of"~buildNormalizedPath(cacheDir, getOutputName(b, s.os)).escapePath;
                else
                {
                    cmds~= "-o";
                    cmds~= buildNormalizedPath(cacheDir, getOutputName(b, s.os)).escapePath;
                }
                if(b.outputsDeps)
                    putSourceFiles(cmds, null, [getObjectDir(cacheDir)], null, null, objExtension);
                else
                    cmds~= buildNormalizedPath(outputDirectory, targetName~objExtension).escapePath;
            }
            if(c.isDCompiler)
            {
                string arch = mapArch(c.compiler, b.arch);
                if(arch)
                    cmds~= arch;
            }
            cmds~= filterLinkFlags(b.dFlags);
        }
        if(targetType == TargetType.dynamicLibrary)
            cmds~= getTargetTypeFlag(targetType, c);

        if (targetType.isLinkedSeparately)
        {
            //Only linux supports start/end group and no-as-needed. OSX does not
            if(emitStartGroup)
            {
                cmds~= "-L--no-as-needed";
                cmds~= "-L--start-group";
            }
            ///Use library full path for the base file
            cmds = mapAppendReverse(cmds, data.extra.librariesFullPath, (string l) => "-L"~getOutputName(TargetType.staticLibrary, l, s.os));
            if(emitStartGroup)
                cmds~= "-L--end-group";

            if(s.os.isApple)
            {
                foreach(framework; frameworks)
                    cmds~= ["-L-framework", "-L"~framework];
            }
            cmds = mapAppendPrefix(cmds, linkFlags, "-L", false);
            cmds = mapAppendPrefix(cmds, libraryPaths, "-L-L", true);
            cmds~= getLinkFiles(b.sourceFiles);
            cmds = mapAppend(cmds, libraries, (string l) => "-L-l"~stripLibraryExtension(l));

        }
    }

    return cmds;
}

string[] parseLinkConfigurationMSVC(const ThreadBuildData data, CompilingSession s, string requirementCache)
{
    import std.algorithm.iteration;
    import redub.misc.path;
    import std.string;
    import redub.building.cache;


    if(!s.os.isWindows) return parseLinkConfiguration(data, s, requirementCache);
    string[] cmds;
    const BuildConfiguration b = data.cfg;
    CompilerBinary c = b.getCompiler(s.compiler);
    with(b)
    {
        string cacheDir = getCacheOutputDir(requirementCache, b, s, data.extra.isRoot);
        cmds~= "-of"~buildNormalizedPath(cacheDir, getOutputName(b, s.os)).escapePath;
        string objExtension = getObjectExtension(s.os);
        if(b.outputsDeps)
            putSourceFiles(cmds, null, [getObjectDir(cacheDir)], null, null, objExtension);
        else
            cmds~= buildNormalizedPath(outputDirectory, targetName~objExtension).escapePath;

        if(c.isDCompiler)
        {
            import redub.command_generators.d_compilers;
            string arch = mapArch(c.compiler, b.arch);
            if(arch)
                cmds~= arch;
            cmds~= filterLinkFlags(b.dFlags);
        }
        if(!s.compiler.usesIncremental)
        {
            cmds~= "-L/INCREMENTAL:NO";
        }

        if(targetType == TargetType.dynamicLibrary)
            cmds~= getTargetTypeFlag(targetType, c);

        cmds = mapAppendReverse(cmds, data.extra.librariesFullPath, (string l) => (l~getLibraryExtension(s.os)).escapePath);

        cmds = mapAppendPrefix(cmds, linkFlags, "-L", false);

        cmds = mapAppendPrefix(cmds, libraryPaths, "-L/LIBPATH:", true);
        cmds~= getLinkFiles(b.sourceFiles);
        cmds = mapAppend(cmds, libraries, (string l) => "-L"~stripLibraryExtension(l)~".lib");

    }
    return cmds;
}


string getTargetTypeFlag(TargetType o, CompilerBinary compiler)
{
    static import redub.command_generators.d_compilers;
    static import redub.command_generators.gnu_based;

    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case dmd, ldc2: return redub.command_generators.d_compilers.getTargetTypeFlag(o, compiler.compiler);
        case gcc, gxx: return redub.command_generators.gnu_based.getTargetTypeFlag(o);
        default: throw new Exception("Unsupported compiler "~compiler.bin);
    }
}