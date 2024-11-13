module redub.plugin.load;
import redub.plugin.api;
import redub.buildapi;


private struct RegisteredPlugin
{
    RedubPlugin plugin;
    string path;
}

__gshared RegisteredPlugin[string] registeredPlugins;
void loadPlugin(string pluginName, string pluginPath)
{
    import redub.plugin.build;
    import std.file;
    import std.path;

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



    buildPlugin(pluginName, pluginPath);

    string fullPluginPath = buildNormalizedPath(pluginPath, pluginName);

    void* pluginDll = loadLib((getDynamicLibraryName(fullPluginPath)~"\0").ptr);
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

BuildConfiguration executePlugin(string pluginName, BuildConfiguration cfg, string[] args)
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
    RedubPluginData preBuildResult;
    RedubPluginStatus status;
    try
    {
        status = plugin.preBuild(cfg.toRedubPluginData, preBuildResult, args, status);
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
        errorTitle("Plugin '"~pluginName~"' failed with an exception: ", e.msg);
    }
    if(status.code != RedubPluginExitCode.success)
        throw new Exception("Execute Plugin process Failed for "~cfg.name);
    if(preBuildResult != RedubPluginData.init)
        return cfg.mergeRedubPlugin(preBuildResult);


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
        return buildNormalizedPath(dir, name~".so");
    else version(OSX)
        return buildNormalizedPath(dir, name~".dynlib");
    else static assert(false, "No support for dynamic libraries on that OS.");
}