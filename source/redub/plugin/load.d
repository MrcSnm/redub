module redub.plugin.load;
import redub.plugin.api;
import redub.buildapi;
import redub.tree_generators.dub;


private struct RegisteredPlugin
{
    RedubPlugin plugin;
    string path;
}

__gshared RegisteredPlugin[string] registeredPlugins;

private struct BuiltinPlugin
{
    string name;
    string description;
    RedubPlugin function() factory;
}

private RedubPlugin createCmakePlugin()
{
    import redub.plugins.cmake : CmakePlugin;
    return new CmakePlugin();
}

private RedubPlugin createFetchlibPlugin()
{
    import redub.plugins.fetchlib : FetchLibPlugin;
    return new FetchLibPlugin();
}

private immutable BuiltinPlugin[] builtinPlugins = [
    BuiltinPlugin("cmake", "Fetches a source tree and builds/installs it through CMake", &createCmakePlugin),
    BuiltinPlugin("fetchlib", "Fetches a git source tree and injects its sources into the build", &createFetchlibPlugin),
];

string[] getBuiltinPluginNames()
{
    string[] names;
    foreach(ref plugin; builtinPlugins)
        names ~= plugin.name;
    return names;
}

string getBuiltinPluginDescription(string name)
{
    foreach(ref plugin; builtinPlugins)
        if(plugin.name == name)
            return plugin.description;
    return null;
}

private RedubPlugin createBuiltinPlugin(string name)
{
    foreach(ref plugin; builtinPlugins)
        if(plugin.name == name)
            return plugin.factory();
    import std.array : join;
    throw new Exception("Unknown built-in plugin '"~name~"'. Available built-in plugins: "~getBuiltinPluginNames.join(", "));
}

void loadBuiltinPlugin(string pluginName, string builtinName)
{
    import redub.logging : infos;
    string displayPath = "redub:"~builtinName;
    synchronized
    {
        if(auto reg = pluginName in registeredPlugins)
        {
            if(reg.path != displayPath)
                throw new Exception("Attempt to register plugin with same name '"~pluginName~"' with different paths: '"~reg.path~"' vs '"~displayPath~"'");
            return;
        }
        registeredPlugins[pluginName] = RegisteredPlugin(createBuiltinPlugin(builtinName), displayPath);
    }
    infos("Plugin Loaded: ", pluginName, " [builtin:", builtinName, "]");
}

void loadPlugin(string pluginName, string pluginPath, CompilationInfo cInfo)
{
    import redub.plugin.build;
    import std.file;
    import redub.misc.path;

    RegisteredPlugin* reg;
    synchronized
    {
        reg = pluginName in registeredPlugins;
        if(reg)
        {
            if(reg.path != pluginPath)
                throw new Exception("Attempt to register plugin with same name '"~pluginName~"' with different paths: '"~reg.path~"' vs '"~pluginPath~"'");
            return;
        }
    }



    import std.path : dirName;
    buildPlugin(pluginName, pluginPath, cInfo);
    string pluginBaseDir = isDir(pluginPath) ? pluginPath : dirName(pluginPath);
    string fullPluginPath = getDynamicLibraryName(buildNormalizedPath(pluginBaseDir, pluginName)~"_"~DefaultCompiler);
    if(!std.file.exists(fullPluginPath))
        throw new Exception("File "~fullPluginPath~" does not exists for being loaded.");
    void* pluginDll = loadLib((fullPluginPath~"\0").ptr);
    if(!pluginDll)
        throw new Exception("Plugin "~pluginName~" could not be loaded. Tried with path '"~fullPluginPath~"'. Error '"~sysError~"'");
    void* pluginFunc = loadSymbol(pluginDll, ("plugin_"~pluginName~"\0").ptr);
    if(!pluginFunc)
        throw new Exception("Plugin function 'plugin_"~pluginName~"' not found. Maybe you forgot to `import redub.plugin.api; mixin PluginEntrypoint!(YourPluginClassName)?`");

    import redub.logging;

    infos("Plugin Loaded: ", pluginName, " [", pluginPath, "]");

    synchronized
    {
        registeredPlugins[pluginName] = RegisteredPlugin((cast(RedubPlugin function())pluginFunc)(), pluginPath);
    }
}

enum PluginPhase : ubyte
{
    preGenerate,
    postGenerate,
}

BuildConfiguration executePlugin(PluginPhase phase, string pluginName, BuildConfiguration cfg, string[] args)
{
    import redub.logging;
    RegisteredPlugin* reg;
    synchronized
    {
        reg = pluginName in registeredPlugins;
        if(!reg)
        {
            import std.conv:to;
            throw new Exception("Could not find registered plugin named '"~pluginName~"'. Registered Plugins: "~registeredPlugins.to!string);
        }
    }

    RedubPlugin plugin = reg.plugin;
    RedubPluginData pluginResult;
    RedubPluginStatus status;
    try
    {
        final switch(phase)
        {
            case PluginPhase.preGenerate:
                status = plugin.preGenerate(cfg.toRedubPluginData, pluginResult, args, status);
                break;
            case PluginPhase.postGenerate:
                status = plugin.postGenerate(cfg.toRedubPluginData, pluginResult, args, status);
                break;
        }
        if(status.message)
        {
            if(status.code == RedubPluginExitCode.success)
                infos("Plugin '"~pluginName~"': ", status.message);
            else
                errorTitle("Plugin '"~pluginName~"': ", status.message);
        }
    }
    catch (Exception e)
    {
        status = RedubPluginStatus(RedubPluginExitCode.error, e.msg);
        errorTitle("Plugin '"~pluginName~"' failed with an exception: ", e.msg);
    }
    if(status.code != RedubPluginExitCode.success)
        throw new Exception("Execute Plugin process Failed for "~cfg.name);
    if(pluginResult != RedubPluginData.init)
        return cfg.mergeRedubPlugin(pluginResult);

    return cfg;
}

BuildConfiguration executePlugins(PluginPhase phase, BuildConfiguration cfg, PluginExecution[] plugins)
{
    foreach(plugin; plugins)
        cfg = executePlugin(phase, plugin.name, cfg, plugin.args);
    return cfg;
}


private {
    version(Windows)
    {
        import core.sys.windows.winbase;
        import core.sys.windows.windef;
        HMODULE loadLib(const(char)* name){
            return LoadLibraryA(name);
        }

        void unloadLib(void* lib){
            FreeLibrary(lib);
        }

        void* loadSymbol(void* lib, const(char)* symbolName){
            return GetProcAddress(lib, symbolName);
        }
        string sysError(){
            import std.conv:to;
            wchar* msgBuf;
            enum uint langID = MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT);

            FormatMessageW(
                FORMAT_MESSAGE_ALLOCATE_BUFFER |
                FORMAT_MESSAGE_FROM_SYSTEM |
                FORMAT_MESSAGE_IGNORE_INSERTS,
                null,
                GetLastError(),
                langID,
                cast(wchar*)&msgBuf,
                0,
                null,
            );
            string ret;
            if(msgBuf)
            {
                ret = to!string(msgBuf);
                LocalFree(msgBuf);
            }
            else
                return "Unknown Error";
            return ret;
        }
    }
    else version(Posix)
    {
        import core.sys.posix.dlfcn;

        void* loadLib(const(char)* name)
        {
            return dlopen(name, RTLD_NOW);
        }

        void unloadLib(void* lib){
            dlclose(lib);
        }

        void* loadSymbol(void* lib, const(char)* symbolName){
            return dlsym(lib, symbolName);
        }

        string sysError(){
            import core.stdc.string;
            char* msg = dlerror();
            return cast(string)(msg ? msg[0..strlen(msg)] : "Unknown Error");
        }

    }
    else static assert(false, "No dll loading support for this platform");
}

string getDynamicLibraryName(string dynamicLibPath)
{
    import std.path;
    string dir = dirName(dynamicLibPath);
    string name = baseName(dynamicLibPath);
    version(Windows)
        return buildNormalizedPath(dir, name~".dll");
    else version(linux)
        return buildNormalizedPath(dir, "lib"~name~".so");
    else version(FreeBSD)
        return buildNormalizedPath(dir, "lib"~name~".so");
    else version(Apple)
        return buildNormalizedPath(dir, "lib"~name~".dylib");
    else static assert(false, "No support for dynamic libraries on that OS.");
}
