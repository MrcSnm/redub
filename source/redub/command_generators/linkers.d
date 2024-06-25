module command_generators.linkers;
public import redub.compiler_identification;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;


string[] parseLinkConfiguration(const BuildRequirements req, OS target, Compiler compiler)
{
    import std.path;
    string[] commands;

    const BuildConfiguration b = req.cfg;

    with(b)
    {
        if(compiler.isDCompiler)
        {
            import redub.command_generators.d_compilers;
                    
            if (targetType.isLinkedSeparately)
            {
                commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(b, target));
                commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
            }
            if(b.arch)
                commands~= mapArch(compiler.compiler, b.arch);
            commands~= filterLinkFlags(b.dFlags);
        }
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        
        if (targetType.isLinkedSeparately)
        {
            ///Use library full path for the base file
            commands = mapAppendReverse(commands, req.extra.librariesFullPath, (string l) => getOutputName(TargetType.staticLibrary, l, target));
            commands = mapAppendPrefix(commands, linkFlags, "-L", false);
            commands = mapAppendPrefix(commands, libraryPaths, "-L-L", true);
            commands = mapAppendReverse(commands, libraries, (string l) => "-L-l"~l);
            commands~= getLinkFiles(b.sourceFiles);
            
        }
        else if(!compiler.isDCompiler) //Generates a static library using archiver. FIXME: BuildRequirements should know its files.
        {
            commands~= "--format=default";
            commands~= "rcs";
            commands~= buildNormalizedPath(outputDirectory, getOutputName(b, target));
            putObjectFiles(commands, b, target);
        }
    }

    return commands;
}

string[] parseLinkConfigurationMSVC(const BuildRequirements req, OS target, Compiler compiler)
{
    import std.algorithm.iteration;
    import std.path;

    const BuildConfiguration b = req.cfg;

    if(!target.isWindows) return parseLinkConfiguration(req, target, compiler);
    string[] commands;
    with(b)
    {
        if(compiler.isDCompiler)
        {
            import redub.command_generators.d_compilers;
            if(b.arch)
                commands~= mapArch(compiler.compiler, b.arch);
            commands~= filterLinkFlags(b.dFlags);
        }
        if(!compiler.usesIncremental)
        {
            commands~= "-L/INCREMENTAL:NO";
        }
        
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        
        commands = mapAppendReverse(commands, req.extra.librariesFullPath, (string l) => (l~getLibraryExtension(target)).escapePath);

        commands = mapAppendPrefix(commands, linkFlags, "-L", false);

        commands = mapAppendPrefix(commands, libraryPaths, "-L/LIBPATH:", true);
        commands~= getLinkFiles(b.sourceFiles);
        commands = mapAppend(commands, libraries, (string l) => "-L"~l~".lib");
        
        commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target)).escapePath;
        commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, target)).escapePath;
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


private void putObjectFiles(ref string[] target, const BuildConfiguration b, OS os)
{
    import std.file;
    import std.path;
    string[] objectFiles;
    putSourceFiles(objectFiles, b.workingDir, b.sourcePaths, b.sourceFiles, b.excludeSourceFiles, ".c", ".cpp", ".cc", ".i", ".cxx", ".c++");
    target = mapAppend(target, objectFiles, (string src) => setExtension(src, getObjectExtension(os)));
}