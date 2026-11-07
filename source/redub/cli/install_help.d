module redub.cli.install_help;

private string[] managedWorkspaceFolders(string workspaceFolder)
{
    import redub.api : getDubWorkspacePath;
    import redub.misc.path : buildNormalizedPath;
    import std.algorithm.sorting : sort;
    import std.file : exists, dirEntries, SpanMode;
    import std.path : baseName;

    string root = buildNormalizedPath(getDubWorkspacePath, workspaceFolder);
    string[] ret;
    if(exists(root))
        foreach(entry; dirEntries(root, SpanMode.shallow))
            if(entry.isDir)
                ret ~= baseName(entry.name);
    ret.sort;
    return ret;
}

private bool isManagedPath(string path, string managedRoot)
{
    import std.path : dirSeparator;
    import std.string : startsWith;

    return path == managedRoot || path.startsWith(managedRoot ~ dirSeparator);
}

private string externalMark(string path, string managedRoot)
{
    return isManagedPath(path, managedRoot) ? "" : "*";
}

private void sortVersionsDesc(string[] versions)
{
    import redub.libs.semver : SemVer;
    import std.algorithm.sorting : sort;

    versions.sort!((a, b) => SemVer(a) > SemVer(b));
}

private string folderVersion(string folderName, string prefix, const string[] suffixes = null)
{
    import std.algorithm.searching : endsWith;
    import std.string : chompPrefix;

    string ret = folderName.chompPrefix(prefix);
    if(suffixes !is null)
        foreach(suffix; suffixes)
            if(ret.endsWith(suffix))
                ret = ret[0 .. $ - suffix.length];
    return ret;
}

private string ldcAddonTags(string installRoot)
{
    import std.file : exists, dirEntries, SpanMode;
    import std.path : baseName;
    import std.string : startsWith;

    bool windows, android, wasi, emscripten;
    if(exists(installRoot))
        foreach(entry; dirEntries(installRoot, SpanMode.shallow))
        {
            string name = baseName(entry.name);
            if(name.startsWith("lib-android-"))
                android = true;
            else if(name.startsWith("lib-wasip"))
                wasi = true;
            else if(name == "lib-emscripten-wasm32")
                emscripten = true;
            else if(name == "lib-windows-i686" || name == "lib-windows-x86_64")
                windows = true;
        }

    string ret;
    if(android) ret ~= "+android";
    if(emscripten) ret ~= "+emscripten";
    if(wasi) ret ~= "+wasi";
    if(windows) ret ~= "+windows";
    return ret;
}

private string[] installedInstallTargets()
{
    import redub.api : getDubWorkspacePath;
    import redub.misc.android_install : findAndroidNdk, findAndroidSdk;
    import redub.misc.emscripten_install : findInstalledEmscriptenSdk;
    import redub.misc.path : buildNormalizedPath;
    import redub.misc.wasi_sdk_install : findInstalledWasiSdk;
    import redub.libs.semver : SemVer;
    import std.algorithm.sorting : sort;
    import std.array : join;
    import std.conv : to;
    import std.file : exists, dirEntries, SpanMode;
    import std.path : baseName;
    import std.string : startsWith;

    string workspace = getDubWorkspacePath();
    string androidWorkspace = buildNormalizedPath(workspace, "redub-android");

    string[] ret;
    string ndk = findAndroidNdk();
    if(ndk.length)
        ret ~= "android-ndk " ~ baseName(ndk) ~ externalMark(ndk, androidWorkspace);

    string sdk = findAndroidSdk();
    if(sdk.length)
    {
        string[] apis;
        string platforms = buildNormalizedPath(sdk, "platforms");
        if(exists(platforms))
            foreach(entry; dirEntries(platforms, SpanMode.shallow))
                if(entry.isDir && baseName(entry.name).startsWith("android-"))
                    apis ~= baseName(entry.name)["android-".length .. $];
        apis.sort!((a, b) => SemVer(a) > SemVer(b));
        ret ~= "android-sdk" ~ (apis.length ? " API " ~ apis.join(", ") : "")
            ~ externalMark(sdk, buildNormalizedPath(androidWorkspace, "android-sdk"));
    }

    string wasi = findInstalledWasiSdk();
    if(wasi.length)
        ret ~= "wasi-sdk " ~ baseName(wasi)
            ~ externalMark(wasi, buildNormalizedPath(workspace, "redub-wasi-sdk"));

    string em = findInstalledEmscriptenSdk();
    if(em.length)
        ret ~= "emsdk " ~ baseName(em)
            ~ externalMark(em, buildNormalizedPath(workspace, "redub-emsdk"));

    string[] ldcGroups;
    string[][string] ldcVersionsByAddons;
    foreach(name; managedWorkspaceFolders("redub-ldc"))
    {
        string addons = ldcAddonTags(buildNormalizedPath(workspace, "redub-ldc", name));
        if((addons in ldcVersionsByAddons) is null)
            ldcGroups ~= addons;
        ldcVersionsByAddons[addons] ~= folderVersion(name, "ldc2-",
            ["-windows-multilib", "-osx-universal", "-linux-x86_64",
            "-linux-aarch64", "-freebsd-x86_64"]);
    }
    ldcGroups.sort!((a, b) =>
        SemVer(ldcVersionsByAddons[a][0]) > SemVer(ldcVersionsByAddons[b][0]));
    foreach(addons; ldcGroups)
    {
        string[] versions = ldcVersionsByAddons[addons];
        sortVersionsDesc(versions);
        ret ~= "ldc " ~ versions.join(" ") ~ addons;
    }

    foreach(name; managedWorkspaceFolders("redub-opend"))
        ret ~= "opend " ~ name;

    string[] dmds = managedWorkspaceFolders("redub-dmd");
    if(dmds.length)
    {
        string[] versions;
        foreach(name; dmds)
            versions ~= folderVersion(name, "dmd-");
        sortVersionsDesc(versions);
        ret ~= "dmd " ~ versions.join(" ");
    }

    return ret;
}

void printInstallHelp()
{
    import redub.libs.colorize : color, cwrite, fg;
    import redub.misc.android_install : DefaultAndroidSdkApi;
    import redub.misc.dmd_install : DefaultDMDVersion;
    import std.format : format;

    string installed;
    auto targets = installedInstallTargets();
    if(targets.length)
    {
        installed = "Installed:\n";
        foreach(target; targets)
            installed ~= ("  -> " ~ target).color(fg.green) ~ "\n";
        installed ~= "\n";
    }

    enum helpText = q"EOS
Redub install

Usage:
  redub install <target> [<version>|help] [options]
  redub install --addon=<group> [<version>]
  redub install --help

Targets:
  ldc [<version>|help] [--addon=<group>]...
      Installs LDC (latest when <version> is omitted). Use 'help' to list
      available versions. Addons require LDC 1.43+ and accept:
      windows, android, wasi, emscripten (or a target triple).
      Examples:
        redub install ldc
        redub install ldc 1.43.0
        redub install ldc 1.43.0 --addon=wasi --addon=windows

  dmd [<version>]
      Installs DMD (default: %s). Use a release version
      from https://downloads.dlang.org/releases/2.x, e.g. 2.112.0.

  opend
      Installs the latest OpenD. OpenD has a single version.

  wasi-sdk [<version>|help]
      Installs a prebuilt WASI SDK (latest when omitted). Use 'help' to list
      versions. Redub exposes it automatically to wasip1/wasip2 targets.
      Accepts '25', 'v25' or 'wasi-sdk-25'.

  emsdk [<version>|help]
      Installs the Emscripten SDK (latest when omitted). Use 'help' to list
      versions. No system Python is required.

  android-ndk [<version>|help]
      Installs an official Android NDK (default: r27c, ~660 MB). Accepts
      r27c, 27c or android-ndk-r27c. Redub also finds NDKs installed by
      Android Studio/SDK.

  android-sdk [<api>|help]
      Installs the Android SDK (platform-tools, build-tools and platform)
      used to package APKs (default API: %s). A JDK 17 is installed too when
      none is found. Redub installs it in its workspace and finds it
      automatically.

Addon shortcut:
  redub install --addon=<group> [<version>]
      Installs LDC with the given addon group. '--addon=emsdk' is a
      shortcut for 'redub install emsdk'.

%sNotes:
  * Versions may be written with or without a leading 'v'.
  * LDC addons may be repeated or comma-separated via --addons.
  * Use 'redub use' to select an installed compiler.
  * A '*' marks an SDK found outside redub (system/Android Studio/env vars).
EOS";
    cwrite(format(helpText, DefaultDMDVersion, DefaultAndroidSdkApi, installed));
}
