/**
*   This module provides a way to build redub plugins.
*   Redub plugins are meant to be a replacement for usage of rdmd
*   Since rdmd is an external program, it's cache evaluation is not so good, and it doesn't have 
*   a real integration with build system, a build plugin is the best way for improving it
*/
module redub.plugin.build;
import redub.buildapi;
import core.simd;


private immutable string apiImport = import("redub/plugin/api.d");

string getPluginImportDir()
{
    import redub.building.cache;
    import std.path;
    return buildNormalizedPath(getCacheFolder(), "plugins", "import");
}
private void writePluginImport()
{
    import std.path;
    import std.file;
    string importPath = buildNormalizedPath(getPluginImportDir(), "redub", "plugin");
    if(!exists(importPath))
        mkdirRecurse(importPath);

    string importFilePath = buildNormalizedPath(importPath, "api.d");

    if(exists(importFilePath))
    {
        static string cachedFile;
        if(cachedFile == null)
            cachedFile = readText(importFilePath);
        if(cachedFile == apiImport)
            return;
    }

    std.file.write(buildNormalizedPath(importPath, "api.d"), apiImport);
}

BuildConfiguration injectPluginCfg(BuildConfiguration base, string pluginName)
{
    import redub.building.cache;
    base.targetName = base.name = pluginName;
    base.versions~= "RedubPlugin";
    base.dFlags~= "-i";
    base.sourcePaths~= getPluginImportDir();
    base.importDirectories~= getPluginImportDir();
    base.targetType = TargetType.dynamicLibrary;

    return base;
}

void buildPlugin(string pluginName, string inputFile)
{
    import redub.command_generators.automatic;
    import redub.command_generators.commons;
    import redub.building.utils;
    import redub.building.cache;
    import redub.compiler_identification;
    import redub.logging;
    import std.path;
    import std.file;
    writePluginImport();


    if(exists(inputFile) && isDir(inputFile))
    {
        buildPluginProject(inputFile);
        return;
    }



    BuildConfiguration b = injectPluginCfg(BuildConfiguration.init, pluginName);
    b.sourceFiles = [inputFile];


    CompilingSession s = CompilingSession(getCompiler, os, instructionSetArchitecture);

    string buildCmds;
    string inDir = getCacheOutputDir("plugins", b, s);

    errorTitle("", execCompiler(b, s.compiler.binOrPath, getCompilationFlags(b, s, "plugins"), buildCmds, s.compiler, inDir).output);
    errorTitle("Plugin Flags: ", buildCmds);
    errorTitle("", linkBase(const ThreadBuildData(b, ExtraInformation()), s, "plugins", buildCmds).output);
    errorTitle("Plugin Flags: ", buildCmds);
}


void buildPluginProject(string pluginDir)
{
    import redub.api;
    import redub.logging;
    writePluginImport();

    LogLevel level = getLogLevel();
    setLogLevel(LogLevel.error);


    ProjectDetails pluginDetails = resolveDependencies(false, os, CompilationDetails(includeEnvironmentVariables: false), ProjectToParse(null, pluginDir));
    if(!pluginDetails.tree)
        throw new Exception("Could not build plugin at path "~pluginDir);

    pluginDetails.tree.requirements.cfg = injectPluginCfg(pluginDetails.tree.requirements.cfg, pluginDetails.tree.name);
    pluginDetails = buildProject(pluginDetails);
    setLogLevel(level);
}