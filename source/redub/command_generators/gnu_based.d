module redub.command_generators.gnu_based;

public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.logging;

/// Parse G++ configuration
string[] parseBuildConfiguration(const BuildConfiguration b, CompilingSession s, string requirementCache, bool isRoot, const string[] extensions...)
{
    import std.algorithm.iteration:map;
    import redub.misc.path;
    
    string[] commands;
    
    with(b)
    {
        if(isDebug) commands~= "-g";

        commands = mapAppendPrefix(commands, versions, "-D", false);
        commands~= dFlags;
        commands = mapAppendPrefix(commands, importDirectories, "-I", true);
        putSourceFiles(commands, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, extensions);


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
        case invalid, none: throw new Exception("Invalid targetType");
        case autodetect, executable, sourceLibrary: return null;
        case dynamicLibrary: return "-shared";
        case staticLibrary, library: return "-c";
    }
}