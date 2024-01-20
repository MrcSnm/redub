module command_generators.gnu_based;

public import buildapi;
public import std.system;
import command_generators.commons;

/// Parse G++ configuration
string[] parseBuildConfiguration(immutable BuildConfiguration b, OS os)
{
    import std.algorithm.iteration:map;
    import std.array:array;
    import std.path;
    
    string[] commands = [""];
    with(b)
    {
        if(isDebug) commands~= "-g";
        commands~= versions.map!((v) => "-D"~v~"=1").array;
        commands~= importDirectories.map!((i) => "-I"~i).array;

        if(targetType == TargetType.executable)
            commands~= "-c"; //Compile only
        
        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        if(targetType != TargetType.executable)
            commands~= "-o "~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        else
            commands~= "-o "~buildNormalizedPath(outputDirectory, name~getObjectExtension(os));

        foreach(path; sourcePaths)
            commands~= getCSourceFiles(buildNormalizedPath(workingDir, path));
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
        case autodetect, executable, sourceLibrary, staticLibrary: return null;
        case dynamicLibrary: return "-shared";
        case library: return null;
    }
}