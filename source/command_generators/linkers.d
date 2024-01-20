module command_generators.linkers;
public import compiler_identification;
public import buildapi;
public import std.system;
import command_generators.commons;


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
        commands~= libraryPaths.map!((lp) => "-L-L"~lp).array;
        commands~= libraries.map!((l) => "-L-l"~l).reverseArray;
        commands~= getLinkFiles(b.sourceFiles);
        commands~= linkFlags.map!((l) => "-L"~l).array;
        
        commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
        commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
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
    static import command_generators.dmd;
    static import command_generators.ldc;
    static import command_generators.gnu_based;
    static import command_generators.gnu_based_ccplusplus;

    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case dmd: return command_generators.dmd.getTargetTypeFlag(o);
        case ldc2: return command_generators.ldc.getTargetTypeFlag(o);
        case gcc: return command_generators.gnu_based.getTargetTypeFlag(o);
        case gxx: return command_generators.gnu_based_ccplusplus.getTargetTypeFlag(o);
        default: throw new Error("Unsupported compiler "~compiler.binOrPath);
    }
}