module command_generators.gnu_based_ccplusplus;

public import buildapi;
public import std.system;
import command_generators.commons;
import logging;

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

        if(isDebug) commands~= "-g ";
     
        string[2][] standards = [ [ "C++17", "--std=c++17" ], [ "C++20", "--std=c++20" ], 
                                    [ "C++14", "--std=c++14" ], [ "C++11", "--std=c++11" ] ]; 

        foreach (string[2] key; standards)
        {
            /* check for a c++ standard */
            if (b.dFlags.canFind(key[0]))
            {
                commands ~= key[1]; // FIXME
            }
        }

        commands~="-v";

        foreach(f; sourceFiles)
        {
            if(!isAbsolute(f)) commands ~= buildNormalizedPath(workingDir, f);
            else commands ~= f;
        }

        commands~= importDirectories.map!((i) => "-I"~i).array;

        if(targetType == TargetType.executable)
            commands~= "-c"; //Compile only
        
        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        foreach(path; sourcePaths)
            commands~= getCppSourceFiles(buildNormalizedPath(workingDir, path));

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