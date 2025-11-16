module redub.command_generators.clang;
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
    
    string[] cmds;
    
    with(b)
    {
        if(isDebug) cmds~= "-g";
        if(targetType.isLinkedSeparately || targetType.isStaticLibrary)
            cmds~= "-c";

        cmds = mapAppendPrefix(cmds, versions, "-D", false);
        cmds~= dFlags;
        cmds = mapAppendPrefix(cmds, importDirectories, "-I", true);
        putSourceFiles(cmds, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, extensions);


        string outFlag = getTargetTypeFlag(targetType);
        string cacheDir = getCacheOutputDir(mainPackhash, b, s, isRoot);

        mkdirRecurse(cacheDir);
        if(outFlag)
            cmds~= outFlag;
        cmds~= "-o";
        if(outFlag)
            cmds ~= buildNormalizedPath(cacheDir, getConfigurationOutputName(b, s.os)).escapePath;
        else
            cmds ~= buildNormalizedPath(cacheDir, getObjectOutputName(b, os)).escapePath;
    }

    return cmds;
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