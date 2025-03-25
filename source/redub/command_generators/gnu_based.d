module redub.command_generators.gnu_based;

public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.logging;
import redub.building.cache;

/// Parse G++ configuration
string[] parseBuildConfiguration(const BuildConfiguration b, CompilingSession s, string mainPackhash, bool isRoot, const string[] extensions...)
{
    import std.algorithm.iteration:map;
    import std.file;
    import redub.misc.path;
    
    string[] commands;
    
    with(b)
    {
        if(isDebug) commands~= "-g";
        commands~= "-r";

        commands = mapAppendPrefix(commands, versions, "-D", false);
        commands~= dFlags;
        commands = mapAppendPrefix(commands, importDirectories, "-I", true);
        putSourceFiles(commands, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, extensions);


        string outFlag = getTargetTypeFlag(targetType);
        string cacheDir = getCacheOutputDir(mainPackhash, b, s, isRoot);

        mkdirRecurse(cacheDir);
        if(outFlag)
            commands~= outFlag;
        commands~= "-o";
        if(outFlag)
            commands ~= buildNormalizedPath(cacheDir, getConfigurationOutputName(b, s.os)).escapePath;
        else
            commands ~= buildNormalizedPath(cacheDir, getObjectOutputName(b, os)).escapePath;
    }

    return commands;
}

string getTargetTypeFlag(TargetType o)
{
    final switch(o) with(TargetType)
    {
        case invalid, none: throw new Exception("Invalid targetType");
        case autodetect, executable, sourceLibrary, staticLibrary, library: return null;
        case dynamicLibrary: return "-shared";
    }
}