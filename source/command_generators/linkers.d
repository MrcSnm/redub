module command_generators.linkers;
public import buildapi;
public import std.system;
import command_generators.commons;


string[] parseLinkConfiguration(immutable BuildConfiguration b, OS target)
{
    import std.algorithm.iteration;
    import std.path;
    import std.array;
    string[] commands;
    with(b)
    {
        commands~= libraryPaths.map!((lp) => "-L-L"~lp).array;
        commands~= libraries.map!((l) => "-L-l"~l).reverseArray;
        commands~= getLinkFiles(b.sourceFiles);
        commands~= linkFlags.map!((l) => "-L"~l).array;
        
        commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
        commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
    }
    return commands;
}

string[] parseLinkConfigurationMSVC(immutable BuildConfiguration b, OS target)
{
    import std.algorithm.iteration;
    import std.path;
    import std.array;
    string[] commands;
    with(b)
    {
        commands~= libraryPaths.map!((lp) => "-L/LIBPATH:"~lp).array;
        commands~= getLinkFiles(b.sourceFiles);
        commands~= libraries.map!((l) => "-L"~l~".lib").array;
        commands~= linkFlags.map!((l) => "-L"~l).array;
        
        commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
        commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
    }
    return commands;
}
