module command_generators.dmd;
import buildapi;
import command_generators.commons;

string[] parseBuildConfiguration(immutable BuildConfiguration b, OS target)
{
    import std.path;
    import std.array:array;
    import std.algorithm.iteration:map;
    
    string[] commands = ["-color=on"];
    with(b)
    {
        if(isDebug) commands~= "-debug";
        commands~= versions.map!((v) => "-version="~v).array;
        commands~= importDirectories.map!((i) => "-I"~i).array;

        if(targetType == TargetType.executable)
            commands~= "-c"; //Compile only
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

private string getTargetTypeFlag(TargetType o)
{
    final switch(o) with(TargetType)
    {
        case autodetect, executable, sourceLibrary: return null;
        case library, staticLibrary: return "-lib";
        case sharedLibrary: return "-shared";
    }
}