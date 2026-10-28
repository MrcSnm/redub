module redub.command_generators.cl;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.logging;
import redub.building.cache;

/// Parse CL configuration
string[] parseBuildConfiguration(const BuildConfiguration b, CompilingSession s, string mainPackhash, bool isRoot, const string[] extensions...)
{
    import std.algorithm.iteration:map;
    import std.file;
    import redub.misc.path;

    string[] cmds = ["/Wall"];

    with(b)
    {
        if(isDebug) cmds~= "/Zi";
        if(targetType.isLinkedSeparately || targetType.isStaticLibrary)
            cmds~= "/c";

        cmds = mapAppendPrefix(cmds, versions, "/D", false);
        cmds~= dFlags;
        cmds = mapAppendPrefix(cmds, importDirectories, "/I", true);
        putSourceFiles(cmds, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, extensions);


        ///Dynamic libraries are linked in the link step, not here. Compiling
        ///multiple sources into one /Fo<file> is invalid for cl, so always
        ///write one .obj per source into the cache directory.
        string cacheDir = getCacheOutputDir(mainPackhash, b, s, isRoot);

        mkdirRecurse(cacheDir);
        cmds ~= "/Fo"~cacheDir.escapePath;
    }

    return cmds;
}

string getTargetTypeFlag(TargetType o)
{
    final switch(o) with(TargetType)
    {
        case invalid, none: throw new Exception("Invalid targetType");
        case autodetect, executable, sourceLibrary, staticLibrary, library: return null;
        case dynamicLibrary: return "/LD";
    }
}