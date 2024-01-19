module command_generators.gnu_based_ccplusplus;

public import buildapi;
public import std.system;
import command_generators.commons;

/// Parse GCC configuration
string[] parseBuildConfiguration(immutable BuildConfiguration b, OS os)
{
    import std.algorithm.iteration:map;
    import std.array:array;
    import std.path;
    
    string[] commands = [ "" ];
    with(b)
    {
        if(isDebug) commands~= "-g ";
        commands~= "--std=c++17"; // FIXME
        commands~="-v";

        foreach(f; sourceFiles)
        {
            if(!isAbsolute(f)) commands ~= buildNormalizedPath(workingDir, f);
            else commands ~= f;
        }

        commands~= importDirectories.map!((i) => "-I"~i).array;

        if(targetType == TargetType.executable)
            commands~= "-c"; //Compile only
        // else
        //     commands~= "--o-";
        
        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        foreach(path; sourcePaths)
            commands~= getSourceFiles(buildNormalizedPath(workingDir, path));

        if(targetType != TargetType.executable)
            commands~= "-o"~buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        else
            commands~= "-o"~buildNormalizedPath(outputDirectory, name~getObjectExtension(os));
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