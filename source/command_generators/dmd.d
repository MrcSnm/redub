module command_generators.dmd;
import buildapi;
import command_generators.commons;

string[] parseBuildConfiguration(BuildConfiguration b, OS target)
{
    import std.path:buildNormalizedPath;
    import std.array:array;
    import std.algorithm.iteration:map;
    
    string[] commands;
    with(b)
    {
        if(isDebug) commands~= "-debug";
        commands~= versions.map!((v) => "-version="~v).array;
        commands~= importDirectories.map!((i) => "-I"~i).array;
        commands~= libraries.map!((l) => "-l"~l~getLibraryExtension(target)).array;
        commands~= libraryPaths.map!((lp) => "-L-L"~lp).array;

        string outFlag = getOutputTypeFlag(outputType);
        if(outFlag) commands~= outFlag;

        if(outputDirectory)
        {
            commands~= "-od"~outputDirectory;
            commands~= "-of"~buildNormalizedPath(outputDirectory, name, outputType.getExtension(os));
        }
        else
        {
            commands~= "-of"~name~outputType.getExtension(os);
        }
    }
    return commands;
}

private string getOutputTypeFlag(OutputType o)
{
    final switch(o)
    {
        case OutputType.executable: return null;
        case OutputType.library: return "-lib";
        case OutputType.sharedLibrary: return "-shared";
    }
}