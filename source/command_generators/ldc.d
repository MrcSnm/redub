module command_generators.ldc;
public import buildapi;
public import std.system;
import command_generators.commons;



string[] parseBuildConfiguration(immutable BuildConfiguration b, OS os)
{
    import std.algorithm.iteration:map;
    import std.array:array;
    import std.path;
    
    string[] commands = ["--enable-color=true"];
    with(b)
    {
        if(isDebug) commands~= "-debug";
        commands~= versions.map!((v) => "--d-version="~v).array;
        commands~= importDirectories.map!((i) => "-I"~i).array;

        if(targetType == TargetType.executable)
            commands~= "-c"; //Compile only
        // else
        //     commands~= "--o-";
        commands~= stringImportPaths.map!((sip) => "-J="~sip).array;
        commands~= dFlags;

        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        commands~= "--od="~getObjectDir(b.workingDir);
        if(targetType != TargetType.executable)
            commands~= "--of="~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        else
            commands~= "--of="~buildNormalizedPath(outputDirectory, name~getObjectExtension(os));

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
        case library, staticLibrary: return "--lib";
        case sharedLibrary: return "--shared";
    }
}