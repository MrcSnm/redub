module command_generators.gnu_based;

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

        if(isDebug) commands~= "-g";

        commands~= versions.map!((v) => "-D"~v~"=1").array;
     
        string[2][] standards = [ [ "C17", "--std=c17" ], 
                                    [ "C11", "--std=c11" ], [ "C99", "--std=c99" ], 
                                    [ "ANSI", "--std=c89" ] ]; 

        foreach (string[2] key; standards)
        {
            /* check for a c++ standard */
            if (b.dFlags.canFind(key[1]) ||
                b.dFlags.canFind(key[0]))
            {
                commands ~= key[1];
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

        foreach(path; sourcePaths)
            commands~= getCppSourceFiles(buildNormalizedPath(workingDir, path));

        string outFlag = getTargetTypeFlag(targetType);
        if(outFlag) commands~= outFlag;

        if(targetType == TargetType.executable ||
            targetType == TargetType.dynamicLibrary)
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