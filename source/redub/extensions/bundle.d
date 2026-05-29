module redub.extensions.bundle;
import redub.api;
enum defaultIconNameNoExt = "redub_program";
enum defaultIconName = "redub_program.png";
enum programIcon = import(defaultIconName);

/** 
 * 
 * Params:
 *   d = The project details.
 * Returns: The old output path for building the path inside generateMacOSBundle.
 */
string prepareForMacOSBundleGen(ref ProjectDetails d)
{
    import redub.misc.path;
    string folder = d.tree.getOutputPath();
    d.tree.requirements.cfg.outputDirectory = buildNormalizedPath(folder, d.tree.name~".app", "Contents", "MacOS");
    return folder;
}

/** 
 * Generates a bundle for macOS.
 * Params:
 *   outputFolder = The folder which came from executing prepareForMacOSBundleGen
 *   d = The project details to identifying the other files.
 */
void generateMacOSBundle(string outputFolder, ref ProjectDetails d)
{
    import std.array;
    import std.file;
    import redub.misc.path;
    string baseDir = buildNormalizedPath(outputFolder, d.tree.name~".app", "Contents");
    

    string macOS = buildNormalizedPath(baseDir, "MacOS");
    string resources = buildNormalizedPath(baseDir, "Resources");
    mkdirRecurse(macOS);
    mkdirRecurse(resources);

    std.file.write(buildNormalizedPath(baseDir, "Info.plist"), getInfoPlist(d));
    if(d.tree.requirements.cfg.targetIcon.length)
    {
        import redub.misc.apple_icon;
        string iconPath = buildNormalizedPath(resources, d.tree.name~".icns");
        string error;
        ubyte[] data = getAppleICNSData(d.tree.requirements.cfg.targetIcon, error);
        if(!data.length)
            throw new RedubException(error);
        std.file.write(iconPath, data);
    }
    d.bundleGenerated = true;
}


/** 
 * Params:
 *   d = The project details.
 * Returns: The old output path for building the path inside generateMacOSBundle.
 */
string prepareForAppImageBundle(ref ProjectDetails d)
{
    import redub.misc.path;
    string folder = d.tree.getOutputPath();
    d.tree.requirements.cfg.outputDirectory = buildNormalizedPath(folder, d.tree.name~".AppDir", "usr", "bin");
    return folder;
}

void generateAppImageBundle(string outputFolder, ref ProjectDetails d)
{
    import redub.misc.make_file_executable;
    import redub.misc.path;
    import redub.misc.app_image;
    import std.process;
    import std.file;
    import std.path:baseName;

    string projectName = d.tree.name;

    string appImageExecutable = getAppImageExecutablePath();
    if(!exists(appImageExecutable))
    {
        if(!installAppImage())
            throw new RedubException("Could not install AppImage for generating linux bundle.");
    }
    string folder = buildNormalizedPath(outputFolder, projectName~".AppDir");
    string dotDesktopFile = buildNormalizedPath(folder, projectName~".desktop");
    string appRunFile = buildNormalizedPath(folder, "AppRun");

    mkdirRecurse(folder);



    std.file.write(dotDesktopFile, getDotDesktopContent(d));
    std.file.write(appRunFile, 
`#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
cd "$HERE"
exec "./usr/bin/`~projectName~`" "$@"`);
    if(!makeFileExecutable(appRunFile))
        throw new Exception("Could not make file "~appRunFile~" executable.");

    if(d.tree.requirements.cfg.targetIcon.length)
        copy(d.tree.requirements.cfg.targetIcon[0], buildNormalizedPath(folder, d.tree.requirements.cfg.targetIcon[0].baseName));
    else
        std.file.write(buildNormalizedPath(folder, defaultIconName), programIcon);


    string[string] env;
    env["ARCH"] = getAppImageArch();
    auto appImageRes = execute([appImageExecutable, folder], env, Config.none, size_t.max, outputFolder);
    if(appImageRes.status)
        throw new Exception("AppImage Error: "~appImageRes.output);
    

    string appImage = buildNormalizedPath(outputFolder, projectName~"-"~getAppImageArch~".AppImage");
    if(!makeFileExecutable(appImage))
        throw new Exception("Could not make file "~appImage~" executable.");
}

private string getDotDesktopContent(const ProjectDetails d)
{
    import core.interpolation;
    import std.algorithm.searching:canFind;
    import std.path: baseName;
    import std.string:join;
    import std.conv:text;
    string projectName = d.tree.name;
    string categories = "Development";
    string icon = defaultIconNameNoExt;

    if(d.tree.requirements.cfg.bundleConfig.categories.length)
        categories = (cast(string[])d.tree.requirements.cfg.bundleConfig.categories).join(";");

    if(d.tree.requirements.cfg.targetIcon.length)
        icon = d.tree.requirements.cfg.targetIcon[0].baseName;
    bool usesTerminal = d.tree.requirements.cfg.bundleConfig.usesTerminal;
    

return i"[Desktop Entry]
Type=Application
Name=$(projectName)
Exec=$(projectName)
Icon=$(icon)
Terminal=$(usesTerminal)
Categories=$(categories);
".text;
}

private string getInfoPlist(const ProjectDetails d)
{
    import std.conv:text;
    import std.process:environment;
    import std.algorithm.comparison:either;
    import std.string:toLowerInPlace, join;
    import core.interpolation;


    string appName = d.tree.name;
    string appVersion = either(d.tree.requirements.version_, "1.0");
    char[] host, user, executableLower = appName.dup;

    version(Windows)
    {
        user = environment["USERNAME"].dup;
        host = environment["COMPUTERNAME"].dup;
    }
    else version(Posix)
        user = environment["USER"].dup;
    version(linux)
    {
        foreach(v; ["HOSTNAME", "HOST"])
        {
            if(v in environment)
            {
                host = environment[v].dup;
                if(host.length) break;
            }
        }
    }
    else version(OSX)
    {
        import std.process:execute;
        import std.string:chomp;
        import std.array:join;
        auto result = execute(["hostname", "-s"]);
        if(result.status)
            throw new Exception(`Could not get hostname with "hostname -s"`);
        host = result.output.chomp.dup;
    }

    toLowerInPlace(host);
    toLowerInPlace(user);
    toLowerInPlace(executableLower);
    
    string appBundleIdentifier = join(["com", host, user, executableLower], ".").idup;



return i`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$(appName)</string>

    <key>CFBundleExecutable</key>
    <string>$(appName)</string>

    <key>CFBundleIdentifier</key>
    <string>$(appBundleIdentifier)</string>

    <key>CFBundleVersion</key>
    <string>$(appVersion)</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleIconFile</key>
    <string>$(appName).icns</string>
</dict>
</plist>`.text;
}
