/**
*   This module provides a way to build redub plugins.
*   Redub plugins are meant to be a replacement for usage of rdmd
*   Since rdmd is an external program, it's cache evaluation is not so good, and it doesn't have
*   a real integration with build system, a build plugin is the best way for improving it
*/
module redub.plugin.build;
import redub.buildapi;
import core.simd;
import redub.tree_generators.dub;

version(DigitalMars)
    enum DefaultCompiler = "dmd";
else
    enum DefaultCompiler = "ldc2";


private immutable string apiImport = import("redub/plugin/api.d");

string getPluginImportDir()
{
    import redub.building.cache;
    import redub.misc.path;
    return buildNormalizedPath(getCacheFolder(), "plugins", "import");
}
private void writePluginImport()
{
    import redub.misc.path;
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

BuildConfiguration injectPluginCfg(BuildConfiguration base, string pluginName, CompilationInfo cInfo)
{
    import redub.building.cache;
    base.targetName = base.name = pluginName ~"_"~DefaultCompiler;
    base.versions~= "RedubPlugin";
    base.dFlags~= "-i";
    ///DO NOT SHARE D RUNTIME AS WE CAN'T GUARANTEE REDUB IS BEING BUILT TO SHARE IT.
    if(DefaultCompiler == "ldc2")
        base.dFlags~= "-link-defaultlib-shared=false";
    base.sourcePaths~= getPluginImportDir();
    base.importDirectories~= getPluginImportDir();
    base.targetType = TargetType.dynamicLibrary;

    return base;
}

void buildPlugin(string pluginName, string inputFile, CompilationInfo cInfo)
{
    import redub.command_generators.automatic;
    import redub.command_generators.commons;
    import redub.parsers.environment;
    import redub.building.utils;
    import redub.building.cache;
    import redub.tooling.compiler_identification;
    import redub.logging;
    import std.path;
    import std.file;
    writePluginImport();


    if(exists(inputFile) && isDir(inputFile))
    {
        buildPluginProject(inputFile, cInfo);
        return;
    }



    BuildConfiguration b = injectPluginCfg(BuildConfiguration.init, pluginName, cInfo);
    b.sourceFiles = [inputFile];


    CompilingSession s = CompilingSession(getCompiler(DefaultCompiler), os, instructionSetArchitecture);
    import std.stdio;
    writeln("Building Plugin with compiler ", s.compiler.d.bin, " ", s.compiler.d.version_);

    string buildCmds;
    string pluginHash = hashFrom(b, s, true);
    string inDir = getCacheOutputDir(pluginHash, b, s, true);

    errorTitle(pluginHash, " ", hashFrom(b, s, false));

    string cmdFile1, cmdFile2;

    string[string] env = getRedubEnv();

    errorTitle("", finishCompilerExec(b, s.compiler, inDir, b.outputDirectory, execCompiler(b, s.compiler, getCompilationFlags(b, s, pluginHash, true), buildCmds, true, cmdFile1, env)).output);
    errorTitle("Plugin Flags: ", buildCmds);
    ProcessExec2 linkProcess = linkBase(const ThreadBuildData(b, ExtraInformation()), s, pluginHash, buildCmds, cmdFile2);
    errorTitle("", waitProcessExec(linkProcess).output);
    errorTitle("Plugin Flags: ", buildCmds);
    scope(exit)
    {
        if(cmdFile1)
            std.file.remove(cmdFile1);
        if(cmdFile2)
            std.file.remove(cmdFile2);
    }
}


void buildPluginProject(string pluginDir, CompilationInfo cInfo)
{
    import redub.api;
    import redub.logging;
    writePluginImport();

    LogLevel level = getLogLevel();
    setLogLevel(LogLevel.error);

    version(LDC)
        enum preferredCompiler = "ldc2";
    else
        enum preferredCompiler = "dmd";

    ProjectDetails pluginDetails = resolveDependencies(false, os, CompilationDetails(preferredCompiler, includeEnvironmentVariables: false), ProjectToParse(null, pluginDir));
    if(!pluginDetails.tree)
        throw new Exception("Could not build plugin at path "~pluginDir);

    pluginDetails.bCreateSelections = false;
    pluginDetails.tree.requirements.cfg = injectPluginCfg(pluginDetails.tree.requirements.cfg, pluginDetails.tree.name, cInfo);
    pluginDetails = buildProject(pluginDetails);
    setLogLevel(level);
}