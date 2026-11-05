module redub.misc.android_install;

enum DefaultAndroidNdkVersion = "r27c";
enum DefaultAndroidSdkApi = "35";

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

private string managedAndroidPath(string name)
{
    import redub.api : getDubWorkspacePath;
    import redub.misc.path : buildNormalizedPath;

    return buildNormalizedPath(getDubWorkspacePath, "redub-android", name);
}

private string managedAndroidSdkRoot()
{
    return managedAndroidPath("android-sdk");
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
    string managed = managedAndroidSdkRoot();
    if(exists(buildNormalizedPath(managed, "build-tools"))
        && exists(buildNormalizedPath(managed, "platforms")))
        return managed;
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
    import std.file : exists;
    import std.path : pathSeparator;
    import std.string : indexOf, toLower;

    if(arch.length == 0)
        return;
    string lower = arch.toLower;
    if(lower.indexOf("android") == -1)
        return;

    setupAndroidJdkEnvironment();

    string ndk = findAndroidNdk();
    if(!ndk.length)
    {
        warn("Android target selected but no NDK was found. Set ANDROID_NDK_HOME, "
            ~ "install it under Android Studio's SDK, or run 'redub install android-ndk'.");
        return;
    }

    string bin = findAndroidNdkBin(ndk);
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

    // Windows resolves executables from the process PATH, not from the
    // environment block passed to the child. Persist the absolute NDK
    // archiver so C builds work with or without an Android bundle.
    version(Windows)
        string arName = "llvm-ar.exe";
    else
        string arName = "llvm-ar";
    string ar = buildNormalizedPath(bin, arName);
    if(exists(ar))
    {
        import redub.meta : getRedubMeta;
        import redub.tooling.archiver_identification : AcceptedArchiver, Archiver, saveArchiver;
        auto meta = getRedubMeta();
        saveArchiver(meta, Archiver(AcceptedArchiver.llvmAr, ar));
    }

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

private bool extractAndroidZip(string archive, string destination)
{
    import redub.logging : error, info;
    import redub.misc.find_executable : findExecutable;
    import std.process : execute;

    version(Windows)
    {
        import redub.misc._7zip : extract7ZipToFolder;
        return extract7ZipToFolder(archive, destination);
    }
    else
    {
        string unzip = findExecutable("unzip");
        if(unzip.length)
        {
            auto res = execute([unzip, "-q", "-o", archive, "-d", destination]);
            if(res.status != 0)
                error("Could not extract ", archive, ": ", res.output);
            return res.status == 0;
        }
        import redub.libs.package_suppliers.utils : extractZipToFolder;
        bool extracted = extractZipToFolder(archive, destination);
        if(extracted)
            info("Note: extracted without system 'unzip'; file permissions may need attention.");
        return extracted;
    }
}

private bool downloadArchive(string url, string archive, string what)
{
    import redub.logging : error, info;
    import redub.misc.download : downloadWithProgress;

    info("Downloading ", what, " from ", url);
    try
        downloadWithProgress(url, archive);
    catch(Exception e)
    {
        error("Could not download ", what, ": ", e.msg);
        return false;
    }
    return true;
}

///Installs an official Android NDK into the redub workspace.
bool installAndroidNdk(string ndkVersion = DefaultAndroidNdkVersion)
{
    import redub.api : getDubWorkspacePath;
    import redub.logging : error, infos;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists, mkdirRecurse, remove, tempDir;
    import std.string : chompPrefix, startsWith;

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

    string v = ndkVersion.chompPrefix("android-ndk-");
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
    if(!downloadArchive(url, archive, "Android NDK " ~ v))
        return false;

    bool extracted = extractAndroidZip(archive, workspace);
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

private string currentOsName()
{
    version(Windows)
        return "win";
    else version(OSX)
        return "mac";
    else version(linux)
        return "linux";
    else
        return null;
}

private string[] repositoryZipNames(string xml, string prefix)
{
    import std.string : indexOf;

    string[] ret;
    size_t pos;
    while((pos = xml.indexOf(prefix, pos)) != -1)
    {
        size_t end = xml.indexOf(".zip", pos);
        if(end == -1)
            break;
        ret ~= xml[pos .. end + 4];
        pos = end + 4;
    }
    return ret;
}

///Picks the newest command-line tools archive name for the given OS in the SDK repository XML.
private string latestCommandlineToolsName(string xml, string osName)
{
    import std.algorithm.searching : all, endsWith;
    import std.ascii : isDigit;
    import std.conv : to;

    string prefix = "commandlinetools-" ~ osName ~ "-";
    enum suffix = "_latest.zip";
    string best;
    uint bestBuild;
    foreach(name; repositoryZipNames(xml, prefix))
    {
        string rest = name[prefix.length .. $];
        if(!rest.endsWith(suffix))
            continue;
        string build = rest[0 .. $ - suffix.length];
        if(build.length == 0 || !build.all!isDigit)
            continue;
        uint n = to!uint(build);
        if(best.length == 0 || n >= bestBuild)
        {
            bestBuild = n;
            best = name;
        }
    }
    return best;
}

unittest
{
    enum sample = `<url>commandlinetools-linux-999_latest.zip</url>
        <url>commandlinetools-linux-1000_latest.zip</url>
        <url>commandlinetools-win-2000_latest.zip</url>
        <url>commandlinetools-linux-1000_latest.zip.bak</url>`;
    assert(latestCommandlineToolsName(sample, "linux") == "commandlinetools-linux-1000_latest.zip");
    assert(latestCommandlineToolsName(sample, "win") == "commandlinetools-win-2000_latest.zip");
    assert(latestCommandlineToolsName(sample, "mac").length == 0);
}

private string javaExecutableName()
{
    version(Windows)
        return "java.exe";
    else
        return "java";
}

private string managedAndroidJdkRoot()
{
    return managedAndroidPath("jdk-17");
}

string findAndroidJdk()
{
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable;
    import std.file : exists;

    string home = getEnvVariable("JAVA_HOME");
    if(home.length && exists(buildNormalizedPath(home, "bin", javaExecutableName())))
        return home;
    home = managedAndroidJdkRoot();
    if(exists(buildNormalizedPath(home, "bin", javaExecutableName())))
        return home;
    return null;
}

private string findJavaBinary()
{
    import redub.misc.find_executable : findExecutable;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;

    string java = findExecutable("java");
    if(java.length)
        return java;
    string home = findAndroidJdk();
    if(home.length)
    {
        java = buildNormalizedPath(home, "bin", javaExecutableName());
        if(exists(java))
            return java;
    }
    return null;
}

///Checks that a Java binary is at least Java 17, as required by the SDK tools.
private bool javaIsRecent(string java)
{
    import redub.libs.semver : SemVer;
    import redub.parsers.environment : getRedubEnv;
    import std.process : execute;
    import std.string : split;

    string output;
    try
        output = execute([java, "-version"], getRedubEnv).output;
    catch(Exception)
        return false;
    auto quoted = output.split(`"`);
    return quoted.length >= 2 && SemVer(quoted[1]).satisfies(SemVer(">=17.0.0"));
}

///Sets JAVA_HOME/PATH to the redub-managed JDK so apksigner and keytool can run.
void setupAndroidJdkEnvironment()
{
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable, setEnvVariable;
    import std.path : pathSeparator;
    import std.string : indexOf;

    string home = findAndroidJdk();
    if(!home.length)
        return;
    if(!getEnvVariable("JAVA_HOME").length)
        setEnvVariable("JAVA_HOME", home);
    string bin = buildNormalizedPath(home, "bin");
    string path = getEnvVariable("PATH");
    if(path.indexOf(bin) == -1)
        setEnvVariable("PATH", bin ~ pathSeparator ~ path);
}

///Installs an Eclipse Temurin JDK 17 into the redub workspace.
bool installAndroidJdk()
{
    import redub.api : getDubWorkspacePath;
    import redub.logging : error, infos;
    import redub.misc.make_file_executable : makeFileExecutable;
    import redub.misc.path : buildNormalizedPath;
    import redub.misc.unzip : extractToFolder;
    import std.file : exists, mkdirRecurse, remove, rename, rmdirRecurse, tempDir,
        dirEntries, SpanMode;

    version(Windows)
    {
        string osName = "windows";
        string archiveExt = ".zip";
        string arch = "x64";
    }
    else version(OSX)
    {
        import std.system : ISA, instructionSetArchitecture;
        string osName = "mac";
        string archiveExt = ".tar.gz";
        string arch = instructionSetArchitecture == ISA.aarch64 ? "aarch64" : "x64";
    }
    else version(linux)
    {
        import std.system : ISA, instructionSetArchitecture;
        string osName = "linux";
        string archiveExt = ".tar.gz";
        string arch = instructionSetArchitecture == ISA.aarch64 ? "aarch64" : "x64";
    }
    else
    {
        error("Automatic JDK install is not supported on this OS.");
        return false;
    }

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-android");
    string installRoot = managedAndroidJdkRoot();
    if(exists(buildNormalizedPath(installRoot, "bin", javaExecutableName())))
    {
        infos("JDK is already installed at ", installRoot);
        return true;
    }
    if(!exists(workspace))
        mkdirRecurse(workspace);

    string url = "https://api.adoptium.net/v3/binary/latest/17/ga/" ~ osName ~ "/"
        ~ arch ~ "/jdk/hotspot/normal/eclipse";
    string archive = buildNormalizedPath(tempDir, "redub-jdk-17" ~ archiveExt);
    if(!downloadArchive(url, archive, "JDK 17"))
        return false;

    string staging = buildNormalizedPath(workspace, "jdk-staging");
    if(exists(staging))
        rmdirRecurse(staging);
    mkdirRecurse(staging);
    bool extracted = extractToFolder(archive, staging);
    if(exists(archive))
        remove(archive);
    string root;
    if(extracted)
        foreach(entry; dirEntries(staging, SpanMode.shallow))
            if(entry.isDir)
            {
                root = entry.name;
                break;
            }
    if(!root.length || !exists(buildNormalizedPath(root, "bin", javaExecutableName())))
    {
        error("JDK was not extracted correctly.");
        if(exists(staging))
            rmdirRecurse(staging);
        return false;
    }
    if(exists(installRoot))
        rmdirRecurse(installRoot);
    rename(root, installRoot);
    if(exists(staging))
        rmdirRecurse(staging);

    version(Posix)
        foreach(entry; dirEntries(buildNormalizedPath(installRoot, "bin"), SpanMode.shallow))
            if(entry.isFile)
                makeFileExecutable(entry.name);

    infos("Installed JDK 17 at ", installRoot);
    return true;
}

private int runSdkManager(string sdkManager, string sdkRoot, string[] packages)
{
    import redub.logging : error, info;
    import redub.parsers.environment : getRedubEnv;
    import std.array : join;
    import std.file : exists, readText, remove, tempDir;
    import std.path : buildNormalizedPath;
    import std.process : Config, pipe, spawnProcess, wait;
    import std.stdio : File;

    string[] args;
    version(Windows)
        args = ["cmd", "/c", sdkManager, "--sdk_root=" ~ sdkRoot] ~ packages;
    else
        args = [sdkManager, "--sdk_root=" ~ sdkRoot] ~ packages;

    info("Running sdkmanager ", packages.join(" "));
    string logPath = buildNormalizedPath(tempDir, "redub-sdkmanager.log");
    auto stdinPipe = pipe();
    File log = File(logPath, "w");
    auto pid = spawnProcess(args, stdinPipe.readEnd, log, log, getRedubEnv(),
        Config.retainStdout | Config.retainStderr);
    try
        foreach(i; 0 .. 200)
            stdinPipe.writeEnd.write("y\n");
    catch(Exception) {}
    stdinPipe.writeEnd.close();
    int status = wait(pid);
    log.close();
    if(status != 0)
    {
        error("sdkmanager ", packages.join(" "), " failed with exit code ", status);
        if(exists(logPath))
            error(readText(logPath));
    }
    if(exists(logPath))
        remove(logPath);
    return status;
}

///Installs the official Android SDK (platform-tools, build-tools and a platform) into the redub workspace.
bool installAndroidSdk(string apiVersion = DefaultAndroidSdkApi)
{
    import d_downloader : downloadToBuffer;
    import redub.logging : error, info, infos;
    import redub.misc.make_file_executable : makeFileExecutable;
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable, setEnvVariable;
    import std.file : exists, mkdirRecurse, remove, rename, rmdirRecurse, tempDir;
    import std.path : dirName;
    import std.string : chompPrefix;

    string api = apiVersion.chompPrefix("android-");
    if(api.length == 0)
        api = DefaultAndroidSdkApi;

    string sdkRoot = managedAndroidSdkRoot();
    string platformDir = buildNormalizedPath(sdkRoot, "platforms", "android-" ~ api);
    // shortcut: assumes build-tools has an x.y.0 release matching the API (e.g. 35.0.0);
    // upgrade to resolve the exact version from the SDK repository if that stops holding.
    string buildToolsDir = buildNormalizedPath(sdkRoot, "build-tools", api ~ ".0.0");

    string java = findJavaBinary();
    if(!java.length || !javaIsRecent(java))
    {
        info("No recent JDK found; installing one for the Android SDK...");
        if(!installAndroidJdk())
            return false;
        java = buildNormalizedPath(managedAndroidJdkRoot(), "bin", javaExecutableName());
        setEnvVariable("JAVA_HOME", managedAndroidJdkRoot());
    }
    if(!getEnvVariable("JAVA_HOME").length)
    {
        string javaHome = dirName(dirName(java));
        if(exists(javaHome))
            setEnvVariable("JAVA_HOME", javaHome);
    }

    if(exists(platformDir) && exists(buildToolsDir)
        && exists(buildNormalizedPath(sdkRoot, "platform-tools")))
    {
        infos("Android SDK (API ", api, ") is already installed at ", sdkRoot);
        return true;
    }

    if(!exists(sdkRoot))
        mkdirRecurse(sdkRoot);

    version(Windows)
        string sdkManager = buildNormalizedPath(sdkRoot, "cmdline-tools", "latest", "bin", "sdkmanager.bat");
    else
        string sdkManager = buildNormalizedPath(sdkRoot, "cmdline-tools", "latest", "bin", "sdkmanager");
    if(!exists(sdkManager))
    {
        string osName = currentOsName();
        if(!osName.length)
        {
            error("Android SDK automatic install is not supported on this OS.");
            return false;
        }
        string fileName;
        try
            fileName = latestCommandlineToolsName(cast(string) downloadToBuffer(
                "https://dl.google.com/android/repository/repository2-3.xml"), osName);
        catch(Exception e)
        {
            error("Could not fetch the Android command-line tools: ", e.msg);
            return false;
        }
        if(!fileName.length)
        {
            error("Could not find Android command-line tools for this OS.");
            return false;
        }

        string url = "https://dl.google.com/android/repository/" ~ fileName;
        string archive = buildNormalizedPath(tempDir, fileName);
        if(!downloadArchive(url, archive, "Android command-line tools"))
            return false;

        string staging = buildNormalizedPath(sdkRoot, "cmdline-tools-staging");
        if(exists(staging))
            rmdirRecurse(staging);
        mkdirRecurse(staging);
        bool extracted = extractAndroidZip(archive, staging);
        if(exists(archive))
            remove(archive);
        string extractedRoot = buildNormalizedPath(staging, "cmdline-tools");
        if(!extracted || !exists(extractedRoot))
        {
            error("Android command-line tools were not extracted correctly.");
            if(exists(staging))
                rmdirRecurse(staging);
            return false;
        }
        string cmdlineTools = buildNormalizedPath(sdkRoot, "cmdline-tools");
        if(exists(cmdlineTools))
            rmdirRecurse(cmdlineTools);
        mkdirRecurse(cmdlineTools);
        rename(extractedRoot, buildNormalizedPath(cmdlineTools, "latest"));
        rmdirRecurse(staging);
    }

    version(Posix)
    {
        import std.file : dirEntries, SpanMode;
        foreach(entry; dirEntries(buildNormalizedPath(sdkRoot, "cmdline-tools", "latest", "bin"), SpanMode.shallow))
            if(entry.isFile)
                makeFileExecutable(entry.name);
    }

    if(runSdkManager(sdkManager, sdkRoot, ["--licenses"]) != 0)
        return false;
    if(runSdkManager(sdkManager, sdkRoot,
        ["platform-tools", "platforms;android-" ~ api, "build-tools;" ~ api ~ ".0.0"]) != 0)
        return false;

    if(!exists(platformDir) || !exists(buildToolsDir))
    {
        error("Android SDK install did not produce ", platformDir, " and ", buildToolsDir);
        return false;
    }
    infos("Installed Android SDK (API ", api, ") at ", sdkRoot);
    return true;
}

///Lists NDK release names advertised by Google's SDK repository.
void listAndroidNdkVersions()
{
    import d_downloader : downloadToBuffer;
    import redub.logging : error, info;
    import std.algorithm.searching : endsWith;
    import std.algorithm.sorting : sort;
    import std.string : chompPrefix, indexOf;

    try
    {
        auto raw = downloadToBuffer(
            "https://dl.google.com/android/repository/repository2-3.xml");
        string text = cast(string) raw;
        bool[string] seen;
        string[] versions;
        enum prefix = "android-ndk-";
        foreach(name; repositoryZipNames(text, prefix))
        {
            string rest = name.chompPrefix(prefix);
            if(!rest.endsWith(".zip"))
                continue;
            string v = rest[0 .. $ - ".zip".length];
            size_t dash = v.indexOf('-');
            if(dash != -1)
                v = v[0 .. dash];
            if(v.length && (v in seen) is null)
            {
                seen[v] = true;
                versions ~= v;
            }
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
