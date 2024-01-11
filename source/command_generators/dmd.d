module command_generators.dmd;
import buildapi;
import command_generators.commons;

string[] parseBuildConfiguration(immutable BuildConfiguration b, OS target)
{
    import std.path;
    import std.array:array;
    import std.algorithm.iteration:map;
    
    string[] commands;
    with(b)
    {
        if(isDebug) commands~= "-debug";
        commands~= versions.map!((v) => "-version="~v).array;
        commands~= importDirectories.map!((i) => "-I"~i).array;

        if(targetType == TargetType.executable)
        {
            commands~= "-c"; //Compile only
            commands~= libraryPaths.map!((lp) => "-L-L"~lp).array;
            commands~= libraries.map!((l) => "-L-l"~l).array;
        }
        commands~= stringImportPaths.map!((sip) => "-J="~sip).array;
        commands~= dFlags;

        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        if(outputDirectory)
            commands~= "-od"~outputDirectory;
        if(targetType != TargetType.executable)
            commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        else
            commands~= "-of"~buildNormalizedPath(outputDirectory, name~getObjectExtension(os));

        foreach(path; sourcePaths)
            commands~= getSourceFiles(buildNormalizedPath(workingDir, path));
        foreach(f; sourceFiles)
        {
            if(!isAbsolute(f)) commands ~= buildNormalizedPath(workingDir, f);
            else commands ~= f;
        }
    }

    return commands;
}

string[] parseLinkConfiguration(immutable BuildConfiguration b, OS target)
{
    import std.algorithm.iteration;
    import std.path;
    import std.array;
    string[] commands;
    with(b)
    {
        commands~= libraryPaths.map!((lp) => "-L-L"~lp).array;
        commands~= libraries.map!((l) => "-L-l"~l).array;
        commands~= linkFlags.map!((l) => "-L"~l).array;
        commands~= buildNormalizedPath(outputDirectory, name~getObjectExtension(target));
        commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
    }
    return commands;
}

private string getTargetTypeFlag(TargetType o)
{
    final switch(o) with(TargetType)
    {
        case autodetect, executable, sourceLibrary: return null;
        case library, staticLibrary: return "-lib";
        case sharedLibrary: return "-shared";
    }
}