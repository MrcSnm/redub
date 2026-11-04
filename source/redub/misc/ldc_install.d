module redub.misc.ldc_install;
import std.system;

string getLdcFolder(string ver, OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import redub.api;
    import redub.misc.path;
    return buildNormalizedPath(getDubWorkspacePath, "redub-ldc", getLdcFolderName(ver, os, isa), "bin");
}


bool installLdc(string ldcVersion, OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import std.array;
    import std.file;
    import redub.api;
    import redub.meta;
    import redub.misc.path;
    import redub.misc.unzip;
    import redub.libs.package_suppliers.utils;
    import redub.misc.make_file_executable;
    import redub.logging;
    string downloadLink = getLdcDownloadLink(ldcVersion, os, isa);

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-ldc");
    string binPath = buildNormalizedPath(workspace, getLdcFolderName(ldcVersion, os, isa), "bin");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    if(exists(binPath))
    {
        infos("LDC ",ldcVersion," is already installed at path ", binPath);
        return true;
    }

    if(!downloadAndExtract(downloadLink, workspace))
        return false;
    foreach(executable; ["ldc2", "ldmd2", "rdmd", "dub"].staticArray)
        if(!makeFileExecutable(buildNormalizedPath(binPath, executable)))
            return false;
	return true;
}

private string getLdcFolderName(string ver, OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import redub.command_generators.commons;
    import redub.api;
    import core.interpolation;
    import std.conv:to,text;
    import std.string:startsWith;
    string sys;
    if(ver.startsWith("v"))
        ver = ver[1..$];

    if(os.isWindows)
        sys = "windows-multilib";
    else if(os.isApple)
        sys = "osx-universal";
    else if(os == OS.freeBSD)
        sys = "freebsd-x86_64";
    else if(os.isPosix)
        sys = isa == ISA.aarch64 ? "linux-aarch64" : "linux-x86_64";
    else
        throw new RedubException("Redub has no support to LDC for the OS '"~os.to!string~"'");
    return i"ldc2-$(ver)-$(sys)".text;
}
string getLdcDownloadLink(string ver, OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import redub.command_generators.commons;
    import redub.api;
    import core.interpolation;
    import std.conv:to,text;
    import std.string:startsWith;
    string sys;
    if(ver.startsWith("v"))
        ver = ver[1..$];

    if(os.isWindows)
        sys = "windows-multilib.7z";
    else if(os.isApple)
        sys = "osx-universal.tar.xz";
    else if(os == OS.freeBSD)
        sys = "freebsd-x86_64.tar.xz";
    else if(os.isPosix)
        sys = isa == ISA.aarch64 ? "linux-aarch64.tar.xz" : "linux-x86_64.tar.xz";
    else
        throw new RedubException("Redub has no support to LDC for the OS '"~os.to!string~"'");
    return i"https://github.com/ldc-developers/ldc/releases/download/v$(ver)/ldc2-$(ver)-$(sys)".text;
}

///Maps an addon group or target triple to the LDC addon asset group.
private string getLdcAddonGroup(string target)
{
    import std.string : toLower, indexOf;
    string t = target.toLower;
    if(t == "windows" || t.indexOf("windows") != -1) return "windows";
    if(t == "android" || t.indexOf("android") != -1) return "android";
    if(t == "wasi" || t.indexOf("wasi") != -1) return "wasi";
    if(t == "emscripten" || t.indexOf("emscripten") != -1) return "emscripten";
    return null;
}

///URL of an LDC 1.43+ prebuilt cross-compilation addon.
private string getLdcAddonDownloadLink(string ver, string addon)
{
    import std.string : startsWith;
    import std.conv:to,text;
    if(ver.startsWith("v"))
        ver = ver[1 .. $];
    return i"https://github.com/ldc-developers/ldc/releases/download/v$(ver)/ldc2-$(ver)-addon-$(addon).tar.xz".text;
}

private bool validateLdcAddon(string ldcVersion, string target, out string addon)
{
    import redub.libs.semver : SemVer;
    import redub.logging : error;
    import std.string : startsWith;

    addon = getLdcAddonGroup(target);
    if(addon is null)
    {
        error("Unknown LDC addon '", target,
            "'. Use windows, android, wasi, emscripten or a target triple.");
        return false;
    }

    string ver = ldcVersion.startsWith("v") ? ldcVersion[1 .. $] : ldcVersion;
    if(SemVer(ver) < SemVer("1.43.0"))
    {
        error("LDC addons require LDC 1.43.0 or newer (requested ", ldcVersion,
            "). Omit the version to install the latest.");
        return false;
    }
    return true;
}

///Installs an addon into an explicitly selected LDC installation directory.
bool installLdcAddonTo(string ldcVersion, string installRoot, string target)
{
    import redub.logging : error, info;
    import redub.misc.unzip : downloadAndExtract;
    import std.file : exists;
    import std.string : startsWith;

    string addon;
    if(!validateLdcAddon(ldcVersion, target, addon))
        return false;
    if(!exists(installRoot))
    {
        error("LDC installation directory not found: ", installRoot);
        return false;
    }

    string ver = ldcVersion.startsWith("v") ? ldcVersion[1 .. $] : ldcVersion;
    string link = getLdcAddonDownloadLink(ver, addon);
    info("Installing LDC addon '", addon, "' for ", target, " into ",
        installRoot, " from ", link);
    return downloadAndExtract(link, installRoot);
}

///Installs a prebuilt LDC addon into the redub-managed LDC installation.
bool installLdcAddon(string ldcVersion, string target,
    OS os = std.system.os, ISA isa = std.system.instructionSetArchitecture)
{
    import std.file : exists;
    import std.path : dirName;

    string installRoot = dirName(getLdcFolder(ldcVersion, os, isa));
    if(!exists(installRoot) && !installLdc(ldcVersion, os, isa))
        return false;
    return installLdcAddonTo(ldcVersion, installRoot, target);
}

///Maps an Android target triple to its LDC addon library directory.
private string androidAddonLibName(string arch)
{
    import std.string : indexOf, toLower;
    string lower = arch.toLower;
    if(lower.indexOf("android") == -1)
        return null;
    if(lower.indexOf("aarch64") != -1) return "lib-android-aarch64";
    if(lower.indexOf("armv7a") != -1 || lower.indexOf("armv7") != -1) return "lib-android-armv7a";
    if(lower.indexOf("x86_64") != -1) return "lib-android-x86_64";
    if(lower.indexOf("i686") != -1) return "lib-android-i686";
    return null;
}

///Warns when the selected LDC lacks the Android platform libraries addon.
void checkLdcAndroidAddon(string arch, string ldcBinary)
{
    import redub.logging : warn;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists;
    import std.path : dirName;

    if(arch.length == 0 || ldcBinary.length == 0)
        return;
    string libName = androidAddonLibName(arch);
    if(libName is null)
        return;
    string root = dirName(dirName(ldcBinary));
    if(!exists(buildNormalizedPath(root, libName)))
        warn("LDC Android addon not found under '", root,
            "'. Run 'redub install ldc --addon=android' for this LDC installation.");
}

unittest
{
    assert(getLdcAddonGroup("windows") == "windows");
    assert(getLdcAddonGroup("x86_64-windows-msvc") == "windows");
    assert(getLdcAddonGroup("aarch64-linux-android30") == "android");
    assert(getLdcAddonGroup("wasm32-unknown-wasip1") == "wasi");
    assert(getLdcAddonGroup("wasm32-unknown-wasip2") == "wasi");
    assert(getLdcAddonGroup("wasm32-unknown-emscripten") == "emscripten");
    assert(getLdcAddonGroup("linux-x86_64") is null);
    assert(androidAddonLibName("aarch64-linux-android30") == "lib-android-aarch64");
    assert(androidAddonLibName("armv7a-linux-androideabi29") == "lib-android-armv7a");
    assert(androidAddonLibName("x86_64-linux-android29") == "lib-android-x86_64");
    assert(androidAddonLibName("i686-linux-android29") == "lib-android-i686");
    assert(androidAddonLibName("x86_64-linux-gnu") is null);
    assert(getLdcAddonDownloadLink("v1.43.0", "wasi") ==
        "https://github.com/ldc-developers/ldc/releases/download/v1.43.0/ldc2-1.43.0-addon-wasi.tar.xz");
}
