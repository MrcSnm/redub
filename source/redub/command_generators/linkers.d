module command_generators.linkers;
public import redub.compiler_identification;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;


string[] parseLinkConfiguration(const ThreadBuildData data, OS target, Compiler compiler, string requirementCache)
{
    import std.path;
    import redub.building.cache;
    string[] commands;

    const BuildConfiguration b = data.cfg;
    with(b)
    {
        if(compiler.isDCompiler)
        {
            import redub.command_generators.d_compilers;

            if (targetType.isLinkedSeparately)
            {
                string cacheDir = getCacheOutputDir(requirementCache, b, compiler, os);
                string objExtension = getObjectExtension(target);
                commands~= "-of"~buildNormalizedPath(cacheDir, getOutputName(b, target)).escapePath;
                if(b.outputsDeps)
                    putSourceFiles(commands, null, [getObjectDir(cacheDir)], null, null, objExtension);
                else
                    commands~= buildNormalizedPath(outputDirectory, name~objExtension).escapePath;
            }
            string arch = mapArch(compiler.compiler, b.arch);
            if(arch)
                commands~= arch;
            commands~= filterLinkFlags(b.dFlags);
        }
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        
        if (targetType.isLinkedSeparately)
        {
            ///Use library full path for the base file
            commands = mapAppendReverse(commands, data.extra.librariesFullPath, (string l) => getOutputName(TargetType.staticLibrary, l, target));
            commands = mapAppendPrefix(commands, linkFlags, "-L", false);
            commands = mapAppendPrefix(commands, libraryPaths, "-L-L", true);
            commands = mapAppendReverse(commands, libraries, (string l) => "-L-l"~stripExtension(l));
            commands~= getLinkFiles(b.sourceFiles);
            
        }
        else if(!compiler.isDCompiler) //Generates a static library using archiver. FIXME: BuildRequirements should know its files.
        {
            commands~= "--format=default";
            commands~= "rcs";
            commands~= buildNormalizedPath(outputDirectory, getOutputName(b, target));
            putObjectFiles(commands, b, target, ".c", ".cpp", ".cc", ".i", ".cxx", ".c++");
        }
    }

    return commands;
}

string[] parseLinkConfigurationMSVC(const ThreadBuildData data, OS target, Compiler compiler, string requirementCache)
{
    import std.algorithm.iteration;
    import std.path;
    import std.string;
    import redub.building.cache;


    if(!target.isWindows) return parseLinkConfiguration(data, target, compiler, requirementCache);
    string[] commands;
    const BuildConfiguration b = data.cfg;
    with(b)
    {
        string cacheDir = getCacheOutputDir(requirementCache, b, compiler, target);
        commands~= "-of"~buildNormalizedPath(cacheDir, getOutputName(b, target)).escapePath;
        string objExtension = getObjectExtension(target);
        if(b.outputsDeps)
            putSourceFiles(commands, null, [getObjectDir(cacheDir)], null, null, objExtension);
        else
            commands~= buildNormalizedPath(outputDirectory, name~objExtension).escapePath;

        if(compiler.isDCompiler)
        {
            import redub.command_generators.d_compilers;
            string arch = mapArch(compiler.compiler, b.arch);
            if(arch)
                commands~= arch;
            commands~= filterLinkFlags(b.dFlags);
        }
        if(!compiler.usesIncremental)
        {
            commands~= "-L/INCREMENTAL:NO";
        }
        
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        
        commands = mapAppendReverse(commands, data.extra.librariesFullPath, (string l) => (l~getLibraryExtension(target)).escapePath);

        commands = mapAppendPrefix(commands, linkFlags, "-L", false);

        commands = mapAppendPrefix(commands, libraryPaths, "-L/LIBPATH:", true);
        commands~= getLinkFiles(b.sourceFiles);
        commands = mapAppend(commands, libraries, (string l) => "-L"~stripExtension(l)~".lib");

    }
    return commands;
}


string getTargetTypeFlag(TargetType o, Compiler compiler)
{
    static import redub.command_generators.d_compilers;
    static import redub.command_generators.gnu_based;
    static import redub.command_generators.gnu_based_ccplusplus;

    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case dmd, ldc2: return redub.command_generators.d_compilers.getTargetTypeFlag(o, compiler.compiler);
        case gcc: return redub.command_generators.gnu_based.getTargetTypeFlag(o);
        case gxx: return redub.command_generators.gnu_based_ccplusplus.getTargetTypeFlag(o);
        default: throw new Exception("Unsupported compiler "~compiler.binOrPath);
    }
}


private void putObjectFiles(ref string[] target, const BuildConfiguration b, OS os, scope const string[] extensions...)
{
    import std.file;
    import std.path;
    string[] objectFiles;
    putSourceFiles(objectFiles, b.workingDir, b.sourcePaths, b.sourceFiles, b.excludeSourceFiles, extensions);
    target = mapAppend(target, objectFiles, (string src) => setExtension(src, getObjectExtension(os)));
}