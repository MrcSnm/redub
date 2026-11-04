module redub.extensions.android_run;

version(RedubCLI):

private string findAdb()
{
    import redub.misc.find_executable : findExecutable;
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable;
    import std.file : exists;

    string adb = findExecutable("adb");
    if(adb.length)
        return adb;

    string[] sdks;
    foreach(root; ["ANDROID_HOME", "ANDROID_SDK_ROOT"])
    {
        string base = getEnvVariable(root);
        if(base.length)
            sdks ~= base;
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

    version(Windows)
        enum adbName = "adb.exe";
    else
        enum adbName = "adb";
    foreach(base; sdks)
    {
        string candidate = buildNormalizedPath(base, "platform-tools", adbName);
        if(exists(candidate))
            return candidate;
    }
    return null;
}

private string managedAdbPath()
{
    import redub.api : getDubWorkspacePath;
    import redub.misc.path : buildNormalizedPath;

    version(Windows)
        return buildNormalizedPath(getDubWorkspacePath, "redub-android", "platform-tools", "adb.exe");
    else
        return buildNormalizedPath(getDubWorkspacePath, "redub-android", "platform-tools", "adb");
}

private string ensureAdb()
{
    import redub.api : getDubWorkspacePath;
    import redub.logging : error, info;
    import redub.misc.make_file_executable : makeFileExecutable;
    import redub.misc.path : buildNormalizedPath;
    import redub.misc.unzip : downloadAndExtract;
    import std.file : exists, mkdirRecurse;
    import std.system : ISA, instructionSetArchitecture;

    string adb = findAdb();
    if(adb.length)
        return adb;
    adb = managedAdbPath();
    if(exists(adb))
        return adb;

    string url;
    version(Windows)
        url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip";
    else version(OSX)
        url = "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip";
    else version(linux)
    {
        if(instructionSetArchitecture != ISA.x86_64)
        {
            error("Official Android platform-tools are x86_64 only. Install adb via your package manager.");
            return null;
        }
        url = "https://dl.google.com/android/repository/platform-tools-latest-linux.zip";
    }
    else
    {
        error("Automatic adb download is not supported on this OS.");
        return null;
    }

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-android");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    info("adb not found; downloading Android platform-tools...");
    if(!downloadAndExtract(url, workspace))
    {
        error("Could not download Android platform-tools.");
        return null;
    }
    adb = managedAdbPath();
    if(!exists(adb))
    {
        error("platform-tools was not extracted to ", adb);
        return null;
    }
    version(Posix)
        if(!makeFileExecutable(adb))
            return null;
    return adb;
}

private string selectDevice(string adb)
{
    import redub.logging : error;
    import redub.parsers.environment : getEnvVariable;
    import std.array : join;
    import std.process : execute;
    import std.string : indexOf, split, splitLines, startsWith, strip;

    string envSerial = getEnvVariable("ANDROID_SERIAL");
    if(envSerial.length)
        return envSerial;

    auto res = execute([adb, "devices", "-l"]);
    if(res.status != 0)
    {
        error("Could not list Android devices with '", adb, "':\n", res.output);
        return null;
    }

    string[] ready;
    string[] other;
    foreach(line; res.output.splitLines)
    {
        line = line.strip;
        if(line.length == 0 || line.startsWith("*") || line.indexOf("List of devices") != -1)
            continue;
        auto parts = line.split;
        if(parts.length < 2)
            continue;
        if(parts[1] == "device")
            ready ~= parts[0];
        else
            other ~= line;
    }

    if(ready.length == 1)
        return ready[0];
    if(ready.length == 0)
    {
        error("No Android device/emulator found with '", adb, "'.");
        error("Connect a device with USB debugging enabled, accept the authorization prompt "
            ~ "and, on Windows, install the OEM USB driver. Try 'adb kill-server' if the "
            ~ "device is visible to Android Studio but not here.");
        if(res.output.length)
            error("adb devices -l output:\n", res.output);
        if(other.length)
            error("Devices are not ready:\n\t", other.join("\n\t"));
        return null;
    }
    error("More than one Android device found. Set ANDROID_SERIAL to one of:\n\t",
        ready.join("\n\t"));
    return null;
}

int androidRunMain(string[] args)
{
    import redub.logging : error, info, LogLevel, setLogLevel;
    import std.file : exists;
    import std.path : baseName;
    import std.process : execute, spawnProcess, wait;
    import std.stdio : writeln;

    setLogLevel(LogLevel.info);
    if(args.length < 2 || args[1] == "--help" || args[1] == "-h")
    {
        writeln("redub android-run <artifact> [args...]");
        writeln("Pushes the artifact to the connected Android device via adb and runs it.");
        writeln("Set ANDROID_SERIAL to choose a device when several are connected.");
        return args.length < 2 ? 1 : 0;
    }

    string artifact = args[1];
    if(!exists(artifact))
    {
        error("Artifact not found: ", artifact);
        return 1;
    }

    string adb = ensureAdb();
    if(!adb.length)
    {
        error("Could not locate or install adb. Install Android platform-tools or put adb in PATH.");
        return 1;
    }

    string serial = selectDevice(adb);
    if(!serial.length)
        return 1;
    string[] adbCmd = [adb, "-s", serial];

    string remote = "/data/local/tmp/redub-" ~ baseName(artifact);
    auto push = execute(adbCmd ~ ["push", artifact, remote]);
    if(push.status != 0)
    {
        error("adb push failed (adb: ", adb, "):\n", push.output);
        return push.status;
    }

    auto chmod = execute(adbCmd ~ ["shell", "chmod", "+x", remote]);
    if(chmod.status != 0)
    {
        error("adb shell chmod failed:\n", chmod.output);
        return chmod.status;
    }

    info("Running ", remote, " on Android (", serial, ")...");
    return wait(spawnProcess(adbCmd ~ ["shell", remote] ~ args[2 .. $]));
}
