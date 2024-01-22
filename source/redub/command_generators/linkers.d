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
            commands~= libraryPaths.map!((lp) => "-L-L"~lp).array;
            commands~= libraries.map!((l) => "-L-l"~l).reverseArray;
            commands~= getLinkFiles(b.sourceFiles);
            commands~= linkFlags.map!((l) => "-L"~l).array;
            
            commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
            commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        }
        else //Generates a static library using archiver. FIXME: BuildRequirements should know its files.
        {
            commands~= "--format=default";
            commands~= "rcs";
            commands~= buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
            commands~= getObjectFiles(b, os);
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
    static import redub.command_generators.dmd;
    static import redub.command_generators.ldc;
    static import redub.command_generators.gnu_based;
    static import redub.command_generators.gnu_based_ccplusplus;

    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case dmd: return redub.command_generators.dmd.getTargetTypeFlag(o);
        case ldc2: return redub.command_generators.ldc.getTargetTypeFlag(o);
        case gcc: return redub.command_generators.gnu_based.getTargetTypeFlag(o);
        case gxx: return redub.command_generators.gnu_based_ccplusplus.getTargetTypeFlag(o);
        default: throw new Error("Unsupported compiler "~compiler.binOrPath);
    }
}


private string[] getObjectFiles(immutable BuildConfiguration b, OS os)
{
    import std.file;
    import std.path;
    import std.array;
    import std.algorithm.iteration;

    string[] objectFiles;
    objectFiles~= b.sourceFiles.map!((string src) => setExtension(src, getObjectExtension(os))).array;

    foreach(path; b.sourcePaths)
        objectFiles~= getCppSourceFiles(path).map!((string src) => setExtension(src, getObjectExtension(os))).array;

    return objectFiles;
}