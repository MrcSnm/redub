module command_generators.linkers;
public import redub.compiler_identification;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;


string[] parseLinkConfiguration(immutable BuildConfiguration b, OS target, Compiler compiler)
{
    import std.algorithm.iteration;
    import std.path;
    import std.array;
    string[] commands;

    with(b)
    {
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        
        if (targetType.isLinkedSeparately)
        {
            commands = mapAppend(commands, libraryPaths, (string lp) => "-L-L"~lp);
            commands = mapAppendReverse(commands, libraries, (string l) => "-L-l"~l);
            commands~= getLinkFiles(b.sourceFiles);
            commands = mapAppend(commands, linkFlags, (string l) => "-L"~l);
            
            commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
            commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        }
        else if(!compiler.isDCompiler) //Generates a static library using archiver. FIXME: BuildRequirements should know its files.
        {
            commands~= "--format=default";
            commands~= "rcs";
            commands~= buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
            putObjectFiles(commands, b, os);
        }
    }

    return commands;
}

string[] parseLinkConfigurationMSVC(immutable BuildConfiguration b, OS target, Compiler compiler)
{
    import std.algorithm.iteration;
    import std.path;
    import std.array;
    string[] commands;
    with(b)
    {
        if(targetType == TargetType.dynamicLibrary)
            commands~= getTargetTypeFlag(targetType, compiler);
        commands~= libraryPaths.map!((lp) => "-L/LIBPATH:"~lp).array;
        commands~= getLinkFiles(b.sourceFiles);
        commands~= libraries.map!((l) => "-L"~l~".lib").array;
        commands~= linkFlags.map!((l) => "-L"~l).array;
        
        commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
        commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
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


private void putObjectFiles(ref string[] target, immutable BuildConfiguration b, OS os)
{
    import std.file;
    import std.path;
    string[] objectFiles;
    putSourceFiles(objectFiles, b.workingDir, b.sourcePaths, b.sourceFiles, b.excludeSourceFiles, ".c", ".cpp", ".cc", ".i", ".cxx", ".c++");
    target = mapAppend(target, objectFiles, (string src) => setExtension(src, getObjectExtension(os)));
}