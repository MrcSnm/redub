module redub.extensions.android_bundle;

import redub.api;
import std.string : indexOf;

private immutable string redubAppIcon = import("redub_program.png");

private enum androidBridgeSource = q"EOS
struct android_app;

extern int rt_init(void);
extern int rt_term(void);
extern void android_main(void* app);

void redub_android_main(struct android_app* app)
{
    rt_init();
    android_main(app);
    rt_term();
}
EOS";
import redub.buildapi : TargetType;

private string androidExeSuffix()
{
    version(Windows) return ".exe";
    else return "";
}

private string androidAbi(string arch)
{
    import redub.logging : error;

    if(arch.indexOf("aarch64") != -1)
        return "arm64-v8a";
    if(arch.indexOf("armv7") != -1)
        return "armeabi-v7a";
    if(arch.indexOf("x86_64") != -1)
        return "x86_64";
    if(arch.indexOf("i686") != -1)
        return "x86";
    throw new RedubException("Unsupported Android ABI for arch '"~arch~"'.");
}

private int androidApi(string arch)
{
    size_t start = arch.length;
    while(start > 0 && arch[start - 1] >= '0' && arch[start - 1] <= '9')
        start--;
    if(start == arch.length)
        return 30;
    int api;
    foreach(c; arch[start .. $])
        api = api * 10 + (c - '0');
    return api ? api : 30;
}

private string androidPackageName(string name)
{
    import std.ascii : isAlphaNum, toLower;

    string sanitized;
    foreach(c; name)
    {
        char lower = toLower(c);
        sanitized ~= isAlphaNum(lower) ? lower : '_';
    }
    if(sanitized.length == 0 || (sanitized[0] >= '0' && sanitized[0] <= '9'))
        sanitized = "_" ~ sanitized;
    return "com.redub." ~ sanitized;
}

private string xmlEscape(string value)
{
    import std.string : replace;

    return value.replace("&", "&amp;").replace("\"", "&quot;")
        .replace("<", "&lt;").replace(">", "&gt;");
}

private string androidPermissionName(string permission)
{
    import std.ascii : isAlphaNum;

    string name = permission.indexOf('.') == -1
        ? "android.permission." ~ permission : permission;
    foreach(c; name)
        if(!isAlphaNum(c) && c != '.' && c != '_')
            throw new RedubException("Invalid Android permission '"~permission~"'.");
    return name;
}

private string androidManifest(string packageName, string label, int api,
    const string[] permissions)
{
    import std.conv : text;

    string usesPermissions;
    bool[string] seen;
    foreach(permission; permissions)
    {
        string name = androidPermissionName(permission);
        if(name in seen)
            continue;
        seen[name] = true;
        usesPermissions ~= text("    <uses-permission android:name=\"",
            xmlEscape(name), "\" />\n");
    }

    return text(
`<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="`, packageName, `">
    <uses-sdk android:minSdkVersion="`, api, `" android:targetSdkVersion="`, api, `" />
`, usesPermissions, `    <application android:icon="@mipmap/ic_launcher" android:label="`, xmlEscape(label), `"
        android:hasCode="false" android:extractNativeLibs="true">
        <activity android:name="android.app.NativeActivity"
            android:exported="true"
            android:label="`, xmlEscape(label), `">
            <meta-data android:name="android.app.lib_name" android:value="main" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
`);
}

private string[] childNames(string folder)
{
    import std.algorithm.sorting : sort;
    import std.file : exists, isDir, dirEntries, SpanMode;

    string[] names;
    if(exists(folder))
        foreach(entry; dirEntries(folder, SpanMode.shallow))
            if(entry.isDir)
                names ~= entry.name;
    names.sort;
    return names;
}

private string findBuildTools(string sdk)
{
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;

    foreach(name; childNames(buildNormalizedPath(sdk, "build-tools")))
        if(exists(name))
            return name;
    return null;
}

private string findAndroidJar(string sdk)
{
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;

    foreach(name; childNames(buildNormalizedPath(sdk, "platforms")))
        if(exists(buildNormalizedPath(name, "android.jar")))
            return buildNormalizedPath(name, "android.jar");
    return null;
}

private string toolPath(string buildTools, string name)
{
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;

    version(Windows)
        string exe = name == "apksigner" ? ".bat" : ".exe";
    else
        string exe = "";
    string path = buildNormalizedPath(buildTools, name ~ exe);
    return exists(path) ? path : null;
}

private string debugKeystore()
{
    import redub.misc.path : buildNormalizedPath;
    import redub.parsers.environment : getEnvVariable;
    import std.file : exists;

    version(Windows)
        string home = getEnvVariable("USERPROFILE");
    else
        string home = getEnvVariable("HOME");
    if(!home.length)
        return null;
    string path = buildNormalizedPath(home, ".android", "debug.keystore");
    return exists(path) ? path : null;
}

private int runTool(string[] args, string what)
{
    import redub.logging : error;
    import std.process : execute;

    auto res = execute(args);
    if(res.status != 0)
    {
        error(what, " failed:\n", res.output);
        return res.status;
    }
    return 0;
}

private int runBat(string bat, string[] args, string what)
{
    version(Windows)
    {
        import redub.logging : error;
        import std.process : escapeShellCommand, executeShell;

        auto res = executeShell(escapeShellCommand([bat] ~ args));
        if(res.status != 0)
        {
            error(what, " failed:\n", res.output);
            return res.status;
        }
        return 0;
    }
    else
        return runTool([bat] ~ args, what);
}

private int createDebugKeystore(string keystore)
{
    import redub.logging : error;
    import redub.misc.find_executable : findExecutable;
    import redub.parsers.environment : getEnvVariable;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;

    string keytool = findExecutable("keytool");
    if(!keytool.length)
    {
        string javaHome = getEnvVariable("JAVA_HOME");
        if(javaHome.length)
        {
            version(Windows)
                keytool = buildNormalizedPath(javaHome, "bin", "keytool.exe");
            else
                keytool = buildNormalizedPath(javaHome, "bin", "keytool");
        }
    }
    if(!keytool.length || !exists(keytool))
    {
        error("Could not find keytool to create a debug keystore. Set JAVA_HOME or install a JDK.");
        return 1;
    }
    return runTool([
        keytool, "-genkeypair", "-v", "-keystore", keystore,
        "-storepass", "android", "-alias", "androiddebugkey",
        "-keypass", "android", "-keyalg", "RSA", "-keysize", "2048",
        "-validity", "10000", "-dname", "CN=Android Debug,O=Android,C=US",
    ], "keytool");
}

string prepareForAndroidBundleGen(ref ProjectDetails d)
{
    import redub.logging : error, info, vlog;
    import redub.misc.android_install : findAndroidNdk, findAndroidNdkBin;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists, getSize, mkdirRecurse, remove, write;
    import std.process : execute;
    import std.string : indexOf;

    ref cfg = d.tree.requirements.cfg;
    string arch = cfg.arch;
    if(arch.indexOf("android") == -1)
        throw new RedubException("--bundle=android requires an Android target (e.g. --target=android).");

    string ndk = findAndroidNdk();
    if(!ndk.length)
        throw new RedubException("Android NDK not found. Set ANDROID_NDK_HOME or run 'redub install android-ndk'.");
    string bin = findAndroidNdkBin(ndk);
    if(!bin.length)
        throw new RedubException("Could not find the LLVM toolchain inside the Android NDK at '"~ndk~"'.");
    string glueDir = buildNormalizedPath(ndk, "sources", "android", "native_app_glue");
    string glueC = buildNormalizedPath(glueDir, "android_native_app_glue.c");
    if(!exists(glueC))
        throw new RedubException("Could not find android_native_app_glue.c in '"~glueDir~"'.");

    string originalOutput = d.tree.getOutputPath();
    string staging = buildNormalizedPath(originalOutput, "android");
    string abi = androidAbi(arch);
    string soDir = buildNormalizedPath(staging, "lib", abi);
    if(!exists(staging))
        mkdirRecurse(staging);
    if(!exists(soDir))
        mkdirRecurse(soDir);

    import redub.building.cache : getCacheFolder;
    import std.file : readText, timeLastModified;
    import std.path : baseName;

    string clang = buildNormalizedPath(bin, "clang" ~ androidExeSuffix);
    string ar = buildNormalizedPath(bin, "llvm-ar" ~ androidExeSuffix);
    string glueCache = buildNormalizedPath(getCacheFolder(), "android-glue",
        baseName(ndk) ~ "-" ~ arch ~ "-v1");
    if(!exists(glueCache))
        mkdirRecurse(glueCache);
    string obj = buildNormalizedPath(glueCache, "android_native_app_glue.o");
    string bridgeC = buildNormalizedPath(glueCache, "redub_android_bridge.c");
    string bridgeObj = buildNormalizedPath(glueCache, "redub_android_bridge.o");
    string glueLib = buildNormalizedPath(glueCache, "libredub_android_glue.a");

    bool bridgeChanged = true;
    if(exists(bridgeC))
        try
            bridgeChanged = readText(bridgeC) != androidBridgeSource;
        catch(Exception) {}
    if(bridgeChanged)
        write(bridgeC, androidBridgeSource);

    bool upToDate = exists(glueLib)
        && timeLastModified(glueLib) >= timeLastModified(glueC)
        && timeLastModified(glueLib) >= timeLastModified(bridgeC);
    if(upToDate)
        vlog("Android glue is up to date.");
    else
    {
        info("Compiling android_native_app_glue.c...");
        auto compile = execute([clang, "--target=" ~ arch, "-fPIC", "-c",
            "-Dandroid_main=redub_android_main",
            "-I" ~ glueDir, "-o", obj, glueC]);
        if(compile.status != 0)
            throw new RedubException("Could not compile android_native_app_glue.c:\n" ~ compile.output);
        if(!exists(obj) || getSize(obj) == 0)
            throw new RedubException("android_native_app_glue.c did not produce an object file.");
        auto bridgeCompile = execute([clang, "--target=" ~ arch, "-fPIC", "-c",
            "-o", bridgeObj, bridgeC]);
        if(bridgeCompile.status != 0)
            throw new RedubException("Could not compile the Android runtime bridge:\n" ~ bridgeCompile.output);
        if(!exists(bridgeObj) || getSize(bridgeObj) == 0)
            throw new RedubException("The Android runtime bridge did not produce an object file.");
        if(exists(glueLib))
            remove(glueLib);
        if(runTool([ar, "rcs", glueLib, obj, bridgeObj], "llvm-ar") != 0)
            throw new RedubException("Could not create the Android glue static library.");
        if(!exists(glueLib) || getSize(glueLib) == 0)
            throw new RedubException("The Android glue static library was not created.");
    }

    cfg.targetType = TargetType.dynamicLibrary;
    cfg.targetName = "main";
    cfg.outputDirectory = soDir;
    // Package the D runtime inside libmain.so; the APK does not ship the
    // phobos/druntime shared objects.
    cfg.dFlags ~= "-link-defaultlib-shared=false";
    cfg.libraryPaths ~= glueCache;
    cfg.libraries ~= ["redub_android_glue", "android", "log"];
    // The glue object is only pulled from the static archive when its entry
    // point is explicitly requested by the linker.
    cfg.linkFlags ~= "--undefined=ANativeActivity_onCreate";
    return originalOutput;
}

private void setAndroidRunEnvironment(ref ProjectDetails d, string apk)
{
    import redub.parsers.environment : setEnvVariable;

    d.androidApk = apk;
    string packageName = androidPackageName(d.tree.name);
    setEnvVariable("REDUB_ANDROID_PACKAGE", packageName);
    setEnvVariable("REDUB_ANDROID_ACTIVITY", packageName ~ "/android.app.NativeActivity");
}

void generateAndroidBundle(string outputFolder, ref ProjectDetails d)
{
    import redub.command_generators.commons : isaFromArch, osFromArch;
    import redub.logging : error, info, infos;
    import redub.misc.android_install : findAndroidSdk;
    import redub.misc.path : buildNormalizedPath;
    import std.datetime : Clock;
    import std.file : copy, exists, mkdirRecurse, read, remove, write;
    import std.path : baseName;
    import std.zip : ArchiveMember, CompressionMethod, ZipArchive;
    import std.string : indexOf;

    ref cfg = d.tree.requirements.cfg;
    string arch = cfg.arch;
    string abi = androidAbi(arch);
    string soName = d.tree.getOutputName(cfg.targetType, osFromArch(arch), isaFromArch(arch));
    string so = buildNormalizedPath(cfg.outputDirectory, soName);
    string finalApk = buildNormalizedPath(outputFolder, d.tree.name ~ ".apk");
    import redub.logging : vlog;
    vlog("Android bundle cache check: isUpToDate=", d.tree.isUpToDate,
        " apkExists=", exists(finalApk), " so=", so);
    if(d.tree.isUpToDate && exists(finalApk))
    {
        info("Android APK is up to date: ", finalApk);
        setAndroidRunEnvironment(d, finalApk);
        return;
    }
    if(!exists(so))
    {
        error("Android shared library was not generated at ", so);
        return;
    }

    string sdk = findAndroidSdk();
    if(!sdk.length)
    {
        error("Android SDK not found; cannot package the APK. Set ANDROID_HOME/ANDROID_SDK_ROOT.");
        return;
    }
    string buildTools = findBuildTools(sdk);
    string androidJar = findAndroidJar(sdk);
    if(!buildTools.length || !androidJar.length)
    {
        error("Android SDK build-tools or platform android.jar not found under '", sdk, "'.");
        return;
    }
    string aapt2 = toolPath(buildTools, "aapt2");
    string zipalign = toolPath(buildTools, "zipalign");
    string apksigner = toolPath(buildTools, "apksigner");
    if(!aapt2.length || !zipalign.length || !apksigner.length)
    {
        error("aapt2, zipalign or apksigner not found in '", buildTools, "'.");
        return;
    }

    string staging = buildNormalizedPath(outputFolder, "android");
    string resDir = buildNormalizedPath(staging, "res");
    string iconDir = buildNormalizedPath(resDir, "mipmap");
    string iconPath = buildNormalizedPath(iconDir, "ic_launcher.png");
    string resZip = buildNormalizedPath(staging, "res.zip");
    string manifest = buildNormalizedPath(staging, "AndroidManifest.xml");
    string unsignedApk = buildNormalizedPath(staging, "app-unsigned.apk");
    string withLibApk = buildNormalizedPath(staging, "app-with-lib.apk");
    string alignedApk = buildNormalizedPath(staging, "app-aligned.apk");
    string signedApk = buildNormalizedPath(staging, "app-signed.apk");
    if(exists(finalApk))
        remove(finalApk);
    mkdirRecurse(staging);
    mkdirRecurse(iconDir);
    write(iconPath, cast(const(ubyte)[]) redubAppIcon);

    write(manifest, androidManifest(androidPackageName(d.tree.name), d.tree.name,
        androidApi(arch), cfg.bundleConfig.permissions));
    if(runTool([aapt2, "compile", "--dir", resDir, "-o", resZip], "aapt2 compile") != 0)
        return;
    if(runTool([aapt2, "link", "--manifest", manifest, "-I", androidJar,
        "-R", resZip, "-o", unsignedApk], "aapt2 link") != 0)
        return;

    auto apkData = cast(ubyte[]) read(unsignedApk);
    auto archive = new ZipArchive(apkData);
    auto member = new ArchiveMember();
    member.name = "lib/" ~ abi ~ "/libmain.so";
    member.expandedData = cast(ubyte[]) read(so);
    member.compressionMethod = CompressionMethod.deflate;
    member.time = Clock.currTime();
    archive.addMember(member);
    write(withLibApk, cast(ubyte[]) archive.build());
    remove(unsignedApk);

    if(runTool([zipalign, "-f", "4", withLibApk, alignedApk], "zipalign") != 0)
        return;
    remove(withLibApk);

    string keystore = debugKeystore();
    if(!keystore.length)
    {
        keystore = buildNormalizedPath(outputFolder, "debug.keystore");
        if(createDebugKeystore(keystore) != 0)
            return;
    }
    if(runBat(apksigner, ["sign", "--ks", keystore,
        "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android",
        "--key-pass", "pass:android", "--out", signedApk, alignedApk],
        "apksigner") != 0)
        return;
    remove(alignedApk);
    if(runBat(apksigner, ["verify", signedApk], "apksigner verify") != 0)
        return;

    if(exists(finalApk))
        remove(finalApk);
    copy(signedApk, finalApk);
    remove(signedApk);
    infos("Generated Android APK ", finalApk);
    setAndroidRunEnvironment(d, finalApk);
    d.bundleGenerated = true;
}

unittest
{
    assert(androidAbi("aarch64-linux-android30") == "arm64-v8a");
    assert(androidAbi("armv7a-linux-androideabi29") == "armeabi-v7a");
    assert(androidAbi("x86_64-linux-android29") == "x86_64");
    assert(androidAbi("i686-linux-android29") == "x86");
    assert(androidApi("aarch64-linux-android30") == 30);
    assert(androidApi("armv7a-linux-androideabi29") == 29);
}
