module command_generators.dmd;
import buildapi;
import command_generator;
import command_generators.command_generator;

string parseBuildConfiguration(BuildConfiguration b, OS target)
{
    import std.path:buildNormalizedPath;
    import std.algorithm.iteration:map;
    
    string[] commands;
    with(b)
    {
        if(isDebug) commands~= "-debug";
        commands~= versions.map!((v) => "-version="~v);
        commands~= importDirectories.map!((i) => "-I"~i);
        commands~= libraries.map!((l) => "-l"~l~getLibraryExtension(target));
        commands~= libraryPaths.map!((lp) => "-L-L"~lp);

        if(outputDirectory)
        {
            commands~= "-od"~outputDirectory;
            commands~= "-of"~buildNormalizedPath(outputDirectory, name, outputType.getExtension);
        }
        else
        {
            commands~= "-of"~name~outputType.getExtension;
        }
    }
    return commands;
}