module redub.misc.emscripten_install;

private immutable emsdkRepoArchive =
    "https://github.com/emscripten-core/emsdk/archive/refs/heads/main.tar.gz";
private immutable pythonStandaloneRepo = "astral-sh/python-build-standalone";

private string managedPythonPath()
{
    import redub.api : getDubWorkspacePath;
    import redub.misc.path : buildNormalizedPath;

    version(Windows)
        return buildNormalizedPath(getDubWorkspacePath, "redub-python", "python", "python.exe");
    else
        return buildNormalizedPath(getDubWorkspacePath, "redub-python", "python", "bin", "python3");
}

///Returns the redub-managed Python, downloading it on first use.
private string ensureManagedPython()
{
    import hip.data.json;
    import redub.api : getDubWorkspacePath;
    import redub.logging : error, info;
    import redub.misc.github_tag_check : getGithubReleaseAPI, getLatestGitRepositoryTag;
    import redub.misc.path : buildNormalizedPath;
    import redub.misc.unzip : downloadAndExtract;
    import std.file : exists, mkdirRecurse;
    import std.string : endsWith, indexOf;

    string python = managedPythonPath();
    if(exists(python))
        return python;

    import std.system : ISA, instructionSetArchitecture;
    if(instructionSetArchitecture != ISA.x86_64 && instructionSetArchitecture != ISA.aarch64)
    {
        error("No prebuilt Python available for this architecture.");
        return null;
    }
    string arch = instructionSetArchitecture == ISA.aarch64 ? "aarch64" : "x86_64";
    string triple;
    version(Windows)
        triple = arch ~ "-pc-windows-msvc";
    else version(OSX)
        triple = arch ~ "-apple-darwin";
    else version(linux)
        triple = arch ~ "-unknown-linux-gnu";
    else
    {
        error("No prebuilt Python available for this OS.");
        return null;
    }
    string suffix = "-" ~ triple ~ "-install_only_stripped.tar.gz";

    string tag = getLatestGitRepositoryTag(pythonStandaloneRepo);
    JSONValue release = tag ? getGithubReleaseAPI(pythonStandaloneRepo, tag) : JSONValue(null);
    string url;
    if(!release.isNull)
        if(auto assets = "assets" in release)
            foreach(asset; (*assets).array)
            {
                auto name = "name" in asset;
                if(name is null || name.type != JSONType.string_
                    || !name.str.endsWith(suffix) || name.str.indexOf("freethreaded") != -1)
                    continue;
                if(auto dl = "browser_download_url" in asset)
                    url = dl.str;
                break;
            }
    if(!url.length)
    {
        error("Could not find a prebuilt Python package for this OS/ISA.");
        return null;
    }

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-python");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    info("Downloading a minimal Python from ", url);
    if(!downloadAndExtract(url, workspace) || !exists(python))
    {
        error("Could not set up a minimal Python for emsdk.");
        return null;
    }
    return python;
}

///Returns the redub-managed Python if it is already installed.
private string findManagedPython()
{
    import std.file : exists;

    string python = managedPythonPath();
    return exists(python) ? python : null;
}

private bool runEmsdk(string python, string root, string[] args)
{
    import redub.logging : error, info;
    import redub.misc.path : buildNormalizedPath;
    import std.process : execute;

    string script = buildNormalizedPath(root, "emsdk.py");
    auto result = execute([python, script] ~ args);
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
    string python = ensureManagedPython();
    if(!python.length)
        return false;
    if(!runEmsdk(python, root, ["install", sdkVersion]))
        return false;
    if(!runEmsdk(python, root, ["activate", sdkVersion]))
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
    import std.path : dirName, pathSeparator;
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
    string managedPython = findManagedPython();
    if(managedPython.length)
    {
        dirs ~= dirName(managedPython);
        if(!getEnvVariable("EMSDK_PYTHON").length)
            setEnvVariable("EMSDK_PYTHON", managedPython);
    }
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
