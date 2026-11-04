module redub.misc.emscripten_install;

private immutable emsdkRepoArchive =
    "https://github.com/emscripten-core/emsdk/archive/refs/heads/main.tar.gz";

private bool runEmsdk(string root, string[] args)
{
    import redub.logging : error, info;
    import redub.misc.path : buildNormalizedPath;
    import std.process : execute;

    string script = buildNormalizedPath(root, "emsdk.py");
    version(Windows)
        string[] command = ["cmd", "/c", buildNormalizedPath(root, "emsdk.bat")] ~ args;
    else
        string[] command = ["python3", script] ~ args;

    auto result = execute(command);
    if(result.status != 0)
    {
        error("emsdk ", args.length ? args[0] : "", " failed:\n", result.output);
        return false;
    }
    if(result.output.length)
        info(result.output);
    return true;
}

///Installs an Emscripten SDK and records it for the `emscripten` target.
bool installEmscriptenSdk(string sdkVersion = "latest")
{
    import hip.data.json;
    import redub.api : getDubWorkspacePath;
    import redub.logging : error, info, infos;
    import redub.meta : getRedubMeta, saveRedubMeta;
    import redub.misc.path : buildNormalizedPath;
    import redub.misc.unzip : downloadAndExtract;
    import std.file : exists, mkdirRecurse;

    if(sdkVersion.length == 0)
        sdkVersion = "latest";

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-emsdk");
    string root = buildNormalizedPath(workspace, "emsdk-main");
    if(!exists(buildNormalizedPath(root, "emsdk.py")))
    {
        if(!exists(workspace))
            mkdirRecurse(workspace);
        info("Downloading emsdk from ", emsdkRepoArchive);
        if(!downloadAndExtract(emsdkRepoArchive, workspace))
            return false;
    }
    if(!exists(buildNormalizedPath(root, "emsdk.py")))
    {
        error("emsdk was not extracted to ", root);
        return false;
    }
    if(!runEmsdk(root, ["install", sdkVersion]))
        return false;
    if(!runEmsdk(root, ["activate", sdkVersion]))
        return false;

    JSONValue meta = getRedubMeta();
    meta["emscriptenSdkPath"] = JSONValue(root);
    saveRedubMeta(meta);
    infos("Installed Emscripten SDK at ", root);
    return true;
}

string findInstalledEmscriptenSdk()
{
    import hip.data.json;
    import redub.api : getDubWorkspacePath;
    import redub.meta : getRedubMeta;
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable;
    import std.file : exists, isDir;

    JSONValue meta = getRedubMeta();
    if(auto p = "emscriptenSdkPath" in meta)
        if(p.type == JSONType.string_ && p.str.length
            && exists(buildNormalizedPath(p.str, "upstream", "emscripten")))
            return p.str;

    string env = getEnvVariable("EMSDK");
    if(env.length && exists(buildNormalizedPath(env, "upstream", "emscripten")))
        return env;

    string root = buildNormalizedPath(getDubWorkspacePath, "redub-emsdk", "emsdk-main");
    if(exists(buildNormalizedPath(root, "upstream", "emscripten")))
        return root;
    return null;
}

///Exposes a redub-managed Emscripten SDK to LDC for emscripten targets.
void setupEmscriptenEnvironment(string arch)
{
    import redub.logging : warn;
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable, setEnvVariable;
    import std.file : exists, isDir, dirEntries, SpanMode;
    import std.path : pathSeparator;
    import std.string : indexOf, toLower;

    if(arch.length == 0)
        return;
    string lower = arch.toLower;
    if(lower.indexOf("emscripten") == -1)
        return;

    string root = findInstalledEmscriptenSdk();
    if(!root.length)
    {
        warn("Emscripten target selected but no Emscripten SDK is installed. "
            ~ "Run 'redub install emsdk'.");
        return;
    }

    if(!getEnvVariable("EMSDK").length)
        setEnvVariable("EMSDK", root);

    string[] dirs = [root, buildNormalizedPath(root, "upstream", "emscripten")];
    string nodeRoot = buildNormalizedPath(root, "node");
    if(exists(nodeRoot))
        foreach(entry; dirEntries(nodeRoot, SpanMode.shallow))
            if(entry.isDir)
            {
                dirs ~= entry.name;
                dirs ~= buildNormalizedPath(entry.name, "bin");
            }

    string path = getEnvVariable("PATH");
    foreach(dir; dirs)
        if(path.indexOf(dir) == -1)
            path = dir ~ pathSeparator ~ path;
    setEnvVariable("PATH", path);

    if(!getEnvVariable("EMSDK_NODE").length)
        foreach(dir; dirs)
        {
            string node = buildNormalizedPath(dir, "node.exe");
            version(Posix)
                node = buildNormalizedPath(dir, "node");
            if(exists(node))
            {
                setEnvVariable("EMSDK_NODE", node);
                break;
            }
        }
}

///Warns when the selected LDC lacks the Emscripten platform libraries addon.
void checkLdcEmscriptenAddon(string arch, string ldcBinary)
{
    import redub.logging : warn;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;
    import std.path : dirName;
    import std.string : indexOf, toLower;

    if(arch.length == 0 || ldcBinary.length == 0)
        return;
    if(arch.toLower.indexOf("emscripten") == -1)
        return;
    string root = dirName(dirName(ldcBinary));
    if(!exists(buildNormalizedPath(root, "lib-emscripten-wasm32")))
        warn("LDC Emscripten addon not found under '", root,
            "'. Run 'redub install ldc --addon=emscripten' for this LDC installation.");
}
