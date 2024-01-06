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

        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        if(outputDirectory)
        {
            commands~= "-od"~outputDirectory;
            commands~= "-of"~buildNormalizedPath(outputDirectory, name, targetType.getExtension(os));
        }
        else
        {
            commands~= "-of"~name~targetType.getExtension(os);
        }
    }
    return commands;
}

private string getTargetTypeFlag(TargetType o)
{
    final switch(o)
    {
        case TargetType.executable: return null;
        case TargetType.library: return "-lib";
        case TargetType.sharedLibrary: return "-shared";
    }
}