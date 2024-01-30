module command_generators.linkers;
public import redub.compiler_identification;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;


string[] parseLinkConfiguration(const BuildConfiguration b, OS target, Compiler compiler)
{
    import std.path;
    import std.array;
    string[] commands;

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
            auto mapper = getFlagMapper(compiler.compiler);
            if(b.arch) commands~= mapper(ValidDFlags.arch) ~ b.arch;
            commands~= filterLinkFlags(b.dFlags);
        }
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        
        if (targetType.isLinkedSeparately)
        {
            commands = mapAppendPrefix(commands, linkFlags, "-L");
            commands = mapAppendPrefix(commands, libraryPaths, "-L-L");
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

string[] parseLinkConfigurationMSVC(const BuildConfiguration b, OS target, Compiler compiler)
{
    import std.algorithm.iteration;
    import std.path;
    import std.array;

    if(!target.isWindows) return parseLinkConfiguration(b, target, compiler);
    string[] commands;
    with(b)
    {
        if(compiler.isDCompiler)
        {
            import redub.command_generators.d_compilers;
            auto mapper = getFlagMapper(compiler.compiler);
            if(b.arch) commands~= mapper(ValidDFlags.arch) ~ b.arch;
            commands~= filterLinkFlags(b.dFlags);
        }
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        commands = mapAppendPrefix(commands, linkFlags, "-L");

        commands = mapAppendPrefix(commands, libraryPaths, "-L/LIBPATH:");
        commands~= getLinkFiles(b.sourceFiles);
        commands = mapAppend(commands, libraries, (string l) => "-L"~l~".lib");
        
        commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
        commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, target));
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
        default: throw new Error("Unsupported compiler "~compiler.binOrPath);
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