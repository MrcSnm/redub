module redub.misc.android_install;

enum DefaultAndroidNdkVersion = "r27c";

private string[] androidNdkCandidatesFrom(string sdk)
{
    import redub.misc.path : buildNormalizedPath;
    import std.algorithm.sorting : sort;
    import std.file : exists, isDir, dirEntries, SpanMode;

    string[] ret;
    string bundle = buildNormalizedPath(sdk, "ndk-bundle");
    if(exists(buildNormalizedPath(bundle, "toolchains")))
        ret ~= bundle;

    string ndkDir = buildNormalizedPath(sdk, "ndk");
    if(exists(ndkDir))
    {
        string[] versions;
        foreach(entry; dirEntries(ndkDir, SpanMode.shallow))
            if(entry.isDir)
                versions ~= entry.name;
        versions.sort;
        foreach(i; 0 .. versions.length)
            ret ~= versions[$ - 1 - i];
    }
    return ret;
}

private string findManagedNdk()
{
    import redub.api : getDubWorkspacePath;
    import redub.misc.path : buildNormalizedPath;
    import std.algorithm.sorting : sort;
    import std.file : exists, isDir, dirEntries, SpanMode;
    import std.path : baseName;
    import std.string : startsWith;

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-android");
    if(!exists(workspace))
        return null;

    string[] roots;
    foreach(entry; dirEntries(workspace, SpanMode.shallow))
        if(entry.isDir && baseName(entry.name).startsWith("android-ndk-")
            && exists(buildNormalizedPath(entry.name, "toolchains")))
            roots ~= entry.name;
    roots.sort;
    return roots.length ? roots[$ - 1] : null;
}

private string[] androidSdkRoots()
{
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable;

    string[] sdks;
    foreach(var; ["ANDROID_HOME", "ANDROID_SDK_ROOT"])
    {
        string sdk = getEnvVariable(var);
        if(sdk.length)
            sdks ~= sdk;
    }
    version(Windows)
    {
        string local = getEnvVariable("LOCALAPPDATA");
        if(local.length)
            sdks ~= buildNormalizedPath(local, "Android", "Sdk");
        string profile = getEnvVariable("USERPROFILE");
        if(profile.length)
            sdks ~= buildNormalizedPath(profile, "AppData", "Local", "Android", "Sdk");
    }
    else version(OSX)
    {
        string home = getEnvVariable("HOME");
        if(home.length)
            sdks ~= buildNormalizedPath(home, "Library", "Android", "sdk");
    }
    else
    {
        string home = getEnvVariable("HOME");
        if(home.length)
        {
            sdks ~= buildNormalizedPath(home, "Android", "Sdk");
            sdks ~= buildNormalizedPath(home, "Android", "sdk");
        }
    }
    return sdks;
}

string findAndroidSdk()
{
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;
    import std.path : baseName, dirName;

    string ndk = findAndroidNdk();
    if(ndk.length)
    {
        string ndkDir = dirName(ndk);
        if(baseName(ndkDir) == "ndk")
            return dirName(ndkDir);
    }
    foreach(sdk; androidSdkRoots())
        if(exists(sdk))
            return sdk;
    return null;
}

string findAndroidNdk()
{
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable;
    import std.file : exists;

    foreach(var; ["ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK"])
    {
        string p = getEnvVariable(var);
        if(p.length && exists(buildNormalizedPath(p, "toolchains")))
            return p;
    }

    string managed = findManagedNdk();
    if(managed.length)
        return managed;

    foreach(sdk; androidSdkRoots())
        foreach(candidate; androidNdkCandidatesFrom(sdk))
            if(exists(buildNormalizedPath(candidate, "toolchains")))
                return candidate;
    return null;
}

string findAndroidNdkBin(string ndk)
{
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists, isDir, dirEntries, SpanMode;

    if(!ndk.length)
        return null;
    string prebuilt = buildNormalizedPath(ndk, "toolchains", "llvm", "prebuilt");
    if(!exists(prebuilt))
        return null;
    foreach(entry; dirEntries(prebuilt, SpanMode.shallow))
        if(entry.isDir && exists(buildNormalizedPath(entry.name, "bin")))
            return buildNormalizedPath(entry.name, "bin");
    return null;
}

private string findAndroidClang(string bin)
{
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;

    version(Windows)
        string name = "clang.exe";
    else
        string name = "clang";
    string clang = buildNormalizedPath(bin, name);
    return exists(clang) ? clang : null;
}

///Sets up the Android NDK C compiler and linker for Android targets.
void setupAndroidEnvironment(string arch)
{
    import redub.logging : vlog, warn;
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable, setEnvVariable;
    import std.file : exists, isDir, dirEntries, SpanMode;
    import std.path : pathSeparator;
    import std.string : indexOf, toLower;

    if(arch.length == 0)
        return;
    string lower = arch.toLower;
    if(lower.indexOf("android") == -1)
        return;

    string ndk = findAndroidNdk();
    if(!ndk.length)
    {
        warn("Android target selected but no NDK was found. Set ANDROID_NDK_HOME, "
            ~ "install it under Android Studio's SDK, or run 'redub install android-ndk'.");
        return;
    }

    string bin;
    string prebuilt = buildNormalizedPath(ndk, "toolchains", "llvm", "prebuilt");
    if(exists(prebuilt))
        foreach(entry; dirEntries(prebuilt, SpanMode.shallow))
            if(entry.isDir && exists(buildNormalizedPath(entry.name, "bin")))
            {
                bin = buildNormalizedPath(entry.name, "bin");
                break;
            }
    if(!bin.length)
    {
        warn("Android NDK at '", ndk, "' has no LLVM prebuilt toolchain.");
        return;
    }

    string compiler = findAndroidClang(bin);
    if(!compiler.length)
    {
        warn("Could not find clang under '", bin, "'.");
        return;
    }

    if(!getEnvVariable("ANDROID_NDK_HOME").length)
        setEnvVariable("ANDROID_NDK_HOME", ndk);
    if(!getEnvVariable("CC").length)
        setEnvVariable("CC", compiler);

    string path = getEnvVariable("PATH");
    if(path.indexOf(bin) == -1)
        setEnvVariable("PATH", bin ~ pathSeparator ~ path);
    vlog("Android NDK: ", ndk, " (CC=", compiler, ")");
}

private void makeToolchainExecutable(string installRoot)
{
    version(Posix)
    {
        import redub.misc.make_file_executable : makeFileExecutable;
        import redub.misc.path : buildNormalizedPath;
        import std.file : exists, dirEntries, SpanMode;

        string prebuilt = buildNormalizedPath(installRoot, "toolchains", "llvm", "prebuilt");
        if(!exists(prebuilt))
            return;
        foreach(host; dirEntries(prebuilt, SpanMode.shallow))
        {
            string bin = buildNormalizedPath(host.name, "bin");
            if(!exists(bin))
                continue;
            foreach(entry; dirEntries(bin, SpanMode.shallow))
                if(entry.isFile)
                    makeFileExecutable(entry.name);
        }
    }
}

///Installs an official Android NDK into the redub workspace.
bool installAndroidNdk(string ndkVersion = DefaultAndroidNdkVersion)
{
    import d_downloader : downloadToFile;
    import redub.api : getDubWorkspacePath;
    import redub.logging : error, info, infos;
    import redub.misc.find_executable : findExecutable;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists, mkdirRecurse, remove, tempDir;
    import std.process : execute;
    import std.string : startsWith;

    version(Windows)
        string osSuffix = "windows";
    else version(OSX)
        string osSuffix = "darwin";
    else version(linux)
        string osSuffix = "linux";
    else
    {
        error("Android NDK automatic install is not supported on this OS.");
        return false;
    }

    string v = ndkVersion;
    if(v.startsWith("android-ndk-"))
        v = v["android-ndk-".length .. $];
    if(!v.startsWith("r"))
        v = "r" ~ v;

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-android");
    string installRoot = buildNormalizedPath(workspace, "android-ndk-" ~ v);
    if(exists(buildNormalizedPath(installRoot, "toolchains")))
    {
        infos("Android NDK ", v, " is already installed at ", installRoot);
        return true;
    }

    string url = "https://dl.google.com/android/repository/android-ndk-" ~ v
        ~ "-" ~ osSuffix ~ ".zip";
    string archive = buildNormalizedPath(tempDir, "android-ndk-" ~ v ~ ".zip");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    info("Downloading Android NDK ", v, " from ", url);
    try
        downloadToFile(url, archive);
    catch(Exception e)
    {
        error("Could not download Android NDK: ", e.msg);
        return false;
    }

    bool extracted;
    version(Windows)
    {
        import redub.misc._7zip : extract7ZipToFolder;
        extracted = extract7ZipToFolder(archive, workspace);
    }
    else
    {
        string unzip = findExecutable("unzip");
        if(unzip.length)
        {
            auto res = execute([unzip, "-q", "-o", archive, "-d", workspace]);
            if(res.status != 0)
                error("Could not extract ", archive, ": ", res.output);
            extracted = res.status == 0;
        }
        else
        {
            import redub.libs.package_suppliers.utils : extractZipToFolder;
            extracted = extractZipToFolder(archive, workspace);
            if(extracted)
                info("Note: extracted without system 'unzip'; file permissions may need attention.");
        }
    }
    if(exists(archive))
        remove(archive);
    if(!extracted || !exists(buildNormalizedPath(installRoot, "toolchains")))
    {
        error("Android NDK was not extracted to ", installRoot);
        return false;
    }

    makeToolchainExecutable(installRoot);
    infos("Installed Android NDK at ", installRoot);
    return true;
}

///Lists NDK release names advertised by Google's SDK repository.
void listAndroidNdkVersions()
{
    import d_downloader : downloadToBuffer;
    import redub.logging : error, info;
    import std.algorithm.sorting : sort;
    import std.string : indexOf;

    try
    {
        auto raw = downloadToBuffer(
            "https://dl.google.com/android/repository/repository2-3.xml");
        string text = cast(string) raw;
        bool[string] seen;
        string[] versions;
        enum prefix = "android-ndk-";
        size_t pos;
        while((pos = text.indexOf(prefix, pos)) != -1)
        {
            size_t end = text.indexOf(".zip", pos);
            if(end == -1)
                break;
            string name = text[pos .. end];
            size_t dash = name.indexOf('-', prefix.length);
            string v = name[prefix.length .. dash == -1 ? name.length : dash];
            if(v.length && (v in seen) is null)
            {
                seen[v] = true;
                versions ~= v;
            }
            pos = end + 4;
        }
        if(!versions.length)
        {
            error("Could not parse Android NDK versions. See https://developer.android.com/ndk/downloads");
            return;
        }
        versions.sort;
        info("Listing available Android NDK versions:");
        size_t limit = versions.length < 25 ? versions.length : 25;
        foreach(i; 0 .. limit)
            info("\t", versions[$ - 1 - i]);
        info("Install with 'redub install android-ndk <version>' (e.g. r27c).");
    }
    catch(Exception)
    {
        error("Could not fetch Android NDK versions. See https://developer.android.com/ndk/downloads");
    }
}
