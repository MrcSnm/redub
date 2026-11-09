module redub.command_generators.gnu_based;

public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.logging;
import redub.building.cache;

///Flags shared by the batch and per-source compilation strategies.
private void putBaseCompilationFlags(ref string[] cmds, const BuildConfiguration b)
{
    if(b.isDebug) cmds~= "-g";
    cmds = mapAppendPrefix(cmds, b.versions, "-D", false);
    cmds~= b.dFlags;
    cmds = mapAppendPrefix(cmds, b.importDirectories, "-I", true);
}

/// Parse G++ configuration
string[] parseBuildConfiguration(const BuildConfiguration b, CompilationInfo s, string mainPackhash, bool isRoot, const string[] extensions...)
{
    import std.algorithm.iteration:map;
    import std.file;
    import redub.misc.path;

    string[] cmds;

    with(b)
    {
        putBaseCompilationFlags(cmds, b);
        cmds~= "-r";

        putSourceFiles(cmds, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, extensions);


        ///Dynamic libraries are linked in the link step. The compile step must only
        ///produce an object/relocatable file, otherwise gcc gets "-r -shared".
        string outFlag = targetType == TargetType.dynamicLibrary ? null : getTargetTypeFlag(targetType);
        string cacheDir = getCacheOutputDir(mainPackhash, b, s, isRoot);

        mkdirRecurse(cacheDir);
        if(outFlag)
            cmds~= outFlag;
        cmds~= "-o";
        if(outFlag)
            cmds ~= buildNormalizedPath(cacheDir, getConfigurationOutputName(b, s.targetOS)).escapePath;
        else
            cmds ~= buildNormalizedPath(cacheDir, getObjectOutputName(b, os)).escapePath;
    }

    return cmds;
}

/**
 * Generates one compilation command per source file, so each source produces
 * its own object file.
 */
string[][] parsePerSourceBuildConfiguration(const BuildConfiguration b, CompilationInfo s, string cacheDir, const string[] extensions...)
{
    import std.file : mkdirRecurse;
    import std.path : dirName;

    string[][] commands;
    mkdirRecurse(cacheDir);

    foreach(source; getSourceFileList(b, extensions))
    {
        string[] cmds;
        putBaseCompilationFlags(cmds, b);
        cmds~= "-c";
        cmds~= source;
        cmds~= "-o";
        string objectPath = getPerSourceObjectPath(cacheDir, source, b.workingDir, s.targetOS);
        mkdirRecurse(dirName(objectPath));
        cmds~= objectPath.escapePath;
        commands~= cmds;
    }
    return commands;
}

string getTargetTypeFlag(TargetType o)
{
    final switch(o) with(TargetType)
    {
        case invalid, none: throw new Exception("Invalid targetType");
        case autodetect, executable, sourceLibrary, staticLibrary, library: return null;
        case external: return null;
        case dynamicLibrary: return "-shared";
    }
}