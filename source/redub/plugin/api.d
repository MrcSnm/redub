module redub.plugin.api;

enum RedubPluginExitCode : ubyte
{
    ///Indicates that the build may continue
    success = 0,
    ///The build should not continue
    error = 1,
}
extern(C) struct RedubPluginStatus
{
    RedubPluginExitCode code;
    ///If there is some message that Redub should print, just assign it here.
    string message;

    static RedubPluginStatus success() { return RedubPluginStatus(RedubPluginExitCode.success);}
}


/**
 * Due to bugs regarding DMD and LDC bridging on shared libraries, functions that returns a value must use a return ref argument, this ensures
 * compatibility between both compilers
 */
interface RedubPlugin
{
    void preGenerate();
    void postGenerate();

    /**
     *
     * Params:
     *   input = Receives the build information on the input
     *   out = The modified input. If RedubPluginData is the same as the .init value, it will be completely ignored in the modification process
     *   args = Arguments that may be sent or not from the redub configuration file.
     *   status = The return value
     * Returns: The status for managing redub state.
     */
    extern(C) ref RedubPluginStatus preBuild(RedubPluginData input, out RedubPluginData output, const ref string[] args, return ref RedubPluginStatus status);
    void postBuild();
}

/**
 * Representation of what may be changed by a redub plugin.
 * All member names are kept the same as redub internal representation.
 */
struct RedubPluginData
{
    string[] versions;
    string[] debugVersions;
    string[] importDirectories;
    string[] libraryPaths;
    string[] stringImportPaths;
    string[] libraries;
    string[] linkFlags;
    string[] dFlags;
    string[] sourcePaths;
    string[] sourceFiles;
    string[] excludeSourceFiles;
    string[] extraDependencyFiles;
    string[] filesToCopy;
    string[] changedBuildFiles;
    string outputDirectory;
    string targetName;
}

version(RedubPlugin):
mixin template PluginEntrypoint(cls) if(is(cls : RedubPlugin))
{
    version(Windows)
    {
        import core.sys.windows.dll;
        mixin SimpleDllMain;
    }

    pragma(mangle, "plugin_"~__MODULE__)
    export extern(C) RedubPlugin pluginEntrypoint()
    {
        return new cls();
    }
}