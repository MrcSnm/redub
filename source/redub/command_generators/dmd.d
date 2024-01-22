module redub.command_generators.dmd;
import redub.buildapi;
import redub.command_generators.commons;

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

        if(targetType.isLinkedSeparately)
            commands~= "-c"; //Compile only
        commands~= stringImportPaths.map!((sip) => "-J="~sip).array;
        commands~= dFlags;


        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        commands~= "-od"~getObjectDir(b.workingDir);

        if(targetType.isStaticLibrary)
            commands~= "-of"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        else
            commands~= "-of"~buildNormalizedPath(outputDirectory, name~getObjectExtension(os));

        
        putSourceFiles(commands, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, ".d");
    }

    return commands;
}

string getTargetTypeFlag(TargetType o)
{
    final switch(o) with(TargetType)
    {
        case none: throw new Error("Invalid targetType: none");
        case autodetect, executable, sourceLibrary: return null;
        case library, staticLibrary: return "-lib";
        case dynamicLibrary: return "-shared";
    }
}