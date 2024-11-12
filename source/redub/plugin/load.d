module redub.plugin.load;
import redub.plugin.api;
import redub.buildapi;


RedubPlugin [string] registeredPlugins;
void loadPlugin(string pluginName, string pluginPath)
{
    import redub.plugin.build;
    import std.file;
    import std.path;

    buildPlugin(pluginName, pluginPath);

    string fullPluginPath = buildNormalizedPath(pluginPath, pluginName);

    void* pluginDll = loadLib((fullPluginPath~"\0").ptr);
    if(!pluginDll)
        throw new Exception("Plugin "~pluginName~" could not be loaded. Tried with path '"~fullPluginPath~"'. Error '"~sysError~"'");
    void* pluginFunc = loadSymbol(pluginDll, ("plugin_"~pluginName~"\0").ptr);
    if(!pluginFunc)
        throw new Exception("Plugin function 'plugin_"~pluginName~"' not found. Maybe you forgot to `import redub.plugin.api; mixin PluginEntrypoint!(YourPluginClassName)?`");
    registeredPlugins[pluginName] = (cast(RedubPlugin function())pluginFunc)();
}

BuildConfiguration executePlugin(string pluginName, BuildConfiguration cfg, string[] args)
{
    import redub.logging;
    RedubPlugin plugin = registeredPlugins[pluginName];
    RedubPluginData preBuildResult;
    RedubPluginStatus status = plugin.preBuild(cfg.toRedubPluginData, preBuildResult, args);
    if(status.message)
    {
        if(status.code == RedubPluginExitCode.success)
            infos("Plugin '"~pluginName~"': ", status.message);
        else
            errorTitle("Plugin '"~pluginName~"': ", status.message);
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

        void* loadLib(const(char)* name){
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
            return msg ? msg[0..strlen(msg)] : "Unknown Error";
        }
    }
    else static assert(false, "No dll loading support for this platform");
}