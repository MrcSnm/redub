module redub.misc.wasi_sdk_install;

import std.system : OS, ISA, os, instructionSetArchitecture;

private enum wasiRepo = "WebAssembly/wasi-sdk";

private string wasiSdkTag(string wasiVersion)
{
    import redub.misc.github_tag_check : getLatestGitRepositoryTag;
    import std.string : indexOf, startsWith;

    if(wasiVersion.length == 0)
        return getLatestGitRepositoryTag(wasiRepo);

    string v = wasiVersion;
    if(v.startsWith("wasi-sdk-"))
        v = v["wasi-sdk-".length .. $];
    else if(v.startsWith("v"))
        v = v[1 .. $];
    auto dot = v.indexOf('.');
    string major = dot >= 0 ? v[0 .. dot] : v;
    return "wasi-sdk-" ~ major;
}

private string wasiSdkSuffix(OS targetOS, ISA targetISA)
{
    import redub.command_generators.commons : isApple, isPosix, isWindows;
    if(targetOS.isWindows)
        return targetISA == ISA.aarch64 ? "arm64-windows.tar.gz" : "x86_64-windows.tar.gz";
    if(targetOS.isApple)
        return targetISA == ISA.aarch64 ? "arm64-macos.tar.gz" : "x86_64-macos.tar.gz";
    if(targetOS.isPosix)
        return targetISA == ISA.aarch64 ? "arm64-linux.tar.gz" : "x86_64-linux.tar.gz";
    return null;
}

bool installWasiSdk(string wasiVersion = null, OS targetOS = os,
    ISA targetISA = instructionSetArchitecture)
{
    import hip.data.json;
    import redub.api : getDubWorkspacePath;
    import redub.logging : error, info, infos;
    import redub.meta : getRedubMeta, saveRedubMeta;
    import redub.misc.github_tag_check : getGithubReleaseAPI;
    import redub.misc.path : buildNormalizedPath;
    import redub.misc.unzip : downloadAndExtract;
    import std.file : exists, mkdirRecurse;
    import std.string : endsWith;

    string tag = wasiSdkTag(wasiVersion);
    if(!tag.length)
    {
        error("Could not resolve a WASI SDK version.");
        return false;
    }
    JSONValue release = getGithubReleaseAPI(wasiRepo, tag);
    if(release.isNull)
    {
        error("Could not fetch WASI SDK release ", tag);
        return false;
    }
    string suffix = wasiSdkSuffix(targetOS, targetISA);
    if(!suffix.length)
    {
        error("No prebuilt WASI SDK package for this OS/ISA.");
        return false;
    }

    string url, assetName;
    if(auto assets = "assets" in release)
        foreach(asset; (*assets).array)
        {
            auto name = "name" in asset;
            if(name is null || name.type != JSONType.string_ || !name.str.endsWith(suffix))
                continue;
            assetName = name.str;
            if(auto dl = "browser_download_url" in asset)
                url = dl.str;
            break;
        }
    if(!url.length)
    {
        error("WASI SDK asset not found for ", tag, " (", suffix, ")");
        return false;
    }

    string folderName = assetName[0 .. $ - ".tar.gz".length];
    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-wasi-sdk");
    string installRoot = buildNormalizedPath(workspace, folderName);
    if(!exists(workspace))
        mkdirRecurse(workspace);
    if(!exists(installRoot))
    {
        info("Downloading WASI SDK ", tag, " from ", url);
        if(!downloadAndExtract(url, workspace))
            return false;
    }
    if(!exists(installRoot))
    {
        error("WASI SDK was not extracted to ", installRoot);
        return false;
    }

    JSONValue meta = getRedubMeta();
    meta["wasiSdkPath"] = JSONValue(installRoot);
    saveRedubMeta(meta);
    infos("Installed WASI SDK at ", installRoot);
    return true;
}

string findInstalledWasiSdk()
{
    import hip.data.json;
    import redub.api : getDubWorkspacePath;
    import redub.meta : getRedubMeta;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists, isDir, dirEntries, SpanMode;

    JSONValue meta = getRedubMeta();
    if(auto p = "wasiSdkPath" in meta)
        if(p.type == JSONType.string_ && p.str.length && exists(p.str) && isDir(p.str))
            return p.str;

    string root = buildNormalizedPath(getDubWorkspacePath, "redub-wasi-sdk");
    if(exists(root))
        foreach(entry; dirEntries(root, SpanMode.shallow))
            if(entry.isDir)
                return entry.name;
    return null;
}

///Exposes a redub-managed WASI SDK to LDC for wasip* targets.
void setupWasiSdkEnvironment(string arch)
{
    import redub.logging : warn;
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable, setEnvVariable;
    import std.file : exists;
    import std.path : pathSeparator;
    import std.string : indexOf, toLower;

    if(arch.length == 0)
        return;
    string lower = arch.toLower;
    if(lower.indexOf("wasi") == -1)
        return;

    string root = findInstalledWasiSdk();
    if(!root.length)
    {
        warn("WASI target selected but no WASI SDK is installed. Run 'redub install wasi-sdk'.");
        return;
    }

    string bin = buildNormalizedPath(root, "bin");
    string ccName = lower.indexOf("wasip2") != -1 ? "wasm32-wasip2-clang"
        : lower.indexOf("wasip1") != -1 ? "wasm32-wasip1-clang"
        : "clang";
    version(Windows)
        ccName ~= ".exe";
    string cc = buildNormalizedPath(bin, ccName);
    if(!exists(cc))
    {
        version(Windows)
            cc = buildNormalizedPath(bin, "clang.exe");
        else
            cc = buildNormalizedPath(bin, "clang");
    }
    if(!exists(cc))
        return;

    if(!getEnvVariable("WASI_SDK_PATH").length)
        setEnvVariable("WASI_SDK_PATH", root);
    string path = getEnvVariable("PATH");
    if(path.indexOf(bin) == -1)
        setEnvVariable("PATH", bin ~ pathSeparator ~ path);
    if(!getEnvVariable("CC").length)
        setEnvVariable("CC", cc);
}

///Warns when the selected LDC lacks the WASI platform libraries addon.
void checkLdcWasiAddon(string arch, string ldcBinary)
{
    import redub.logging : warn;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;
    import std.path : dirName;
    import std.string : indexOf, toLower;

    if(arch.length == 0 || ldcBinary.length == 0)
        return;
    string lower = arch.toLower;
    if(lower.indexOf("wasi") == -1)
        return;
    string root = dirName(dirName(ldcBinary));
    string libName = lower.indexOf("wasip2") != -1
        ? "lib-wasip2-wasm32" : "lib-wasip1-wasm32";
    if(!exists(buildNormalizedPath(root, libName)))
        warn("LDC WASI addon not found under '", root,
            "'. Run 'redub install ldc --addon=wasi' for this LDC installation.");
}
