module redub.command_generators.clang;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.logging;
import redub.building.cache;

///Flags shared by the batch and per-source compilation strategies.
private void putBaseCompilationFlags(ref string[] cmds, const BuildConfiguration b, CompilationInfo s)
{
    version(Apple)
    {
        if(s.targetOS.isApple)
        {
            cmds~= "-isysroot";
            cmds~= s.macosSysroot;
        }
    }
    if(b.isDebug) cmds~= "-g";
    cmds = mapAppendPrefix(cmds, b.versions, "-D", false);
    cmds~= b.dFlags;
    cmds = mapAppendPrefix(cmds, b.importDirectories, "-I", true);
}

/// Parse Clang configuration
string[] parseBuildConfiguration(const BuildConfiguration b, CompilationInfo s, string mainPackhash, bool isRoot, const string[] extensions...)
{
    import std.algorithm.iteration:map;
    import std.file;
    import redub.misc.path;

    string[] cmds;

    with(b)
    {
        putBaseCompilationFlags(cmds, b, s);
        if(targetType.isLinkedSeparately || targetType.isStaticLibrary)
        {
            cmds~= "-r";
            ///Clang links the C runtime when doing a relocatable link, which
            ///would statically inject crt/libc/libgcc into the resulting object
            ///and cause duplicate symbol errors when the final artifact links.
            cmds~= "-nostdlib";
        }
        putSourceFiles(cmds, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, extensions);


        ///Dynamic libraries are linked in the link step, not in the compile step.
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
 * its own object file instead of a single relocatable (-r) object. This avoids
 * embedding the C runtime/library objects into the intermediate objects.
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
        putBaseCompilationFlags(cmds, b, s);
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