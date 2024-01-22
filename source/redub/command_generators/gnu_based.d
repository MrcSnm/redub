module redub.command_generators.gnu_based;

public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.logging;

/// Parse G++ configuration
string[] parseBuildConfiguration(immutable BuildConfiguration b, OS os)
{
    import std.algorithm.iteration:map;
    import std.array:array;
    import std.path;
    
    string[] commands;
    
    with(b)
    {
        import std.algorithm: canFind;

        if(isDebug) commands~= "-g";

        commands~= versions.map!((v) => "-D"~v~"=1").array;
        commands~= dFlags;
        commands~="-v";
        commands~= importDirectories.map!((i) => "-I"~i).array;
        putSourceFiles(commands, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, ".c", ".i");


        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        if(targetType.isLinkedSeparately)
        {
            commands~= "-o";
            commands ~= buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
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
        case dynamicLibrary: return "-shared";
        case staticLibrary, library: return "-c";
    }
}