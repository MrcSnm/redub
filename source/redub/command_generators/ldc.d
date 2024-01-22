module redub.command_generators.ldc;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;



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

        if(targetType.isLinkedSeparately)
            commands~= "-c"; //Compile only
        commands~= stringImportPaths.map!((sip) => "-J="~sip).array;
        commands~= dFlags;

        if(targetType.isStaticLibrary)
        {
            string outFlag = getTargetTypeFlag(targetType);
            if(outFlag) commands~= outFlag;
        }

        commands~= "--od="~getObjectDir(b.workingDir);

        if(targetType == TargetType.dynamicLibrary)
        {
            // commands~= "--dllimport=all";
            // commands~= "--fvisibility=public";
        }
        if(targetType.isStaticLibrary)
            commands~= "--of="~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        else
            commands~= "--of="~buildNormalizedPath(outputDirectory, name~getObjectExtension(os));

        foreach(path; sourcePaths)
            commands~= getDSourceFiles(buildNormalizedPath(workingDir, path));
        foreach(f; sourceFiles)
        {
            if(!isAbsolute(f)) commands ~= buildNormalizedPath(workingDir, f);
            else commands ~= f;
        }
    }

    return commands;
}

string getTargetTypeFlag(TargetType o)
{
    final switch(o) with(TargetType)
    {
        case none: throw new Error("Invalid targetType: none");
        case autodetect, executable, sourceLibrary: return null;
        case library, staticLibrary: return "--lib";
        case dynamicLibrary: return "--shared";
    }
}