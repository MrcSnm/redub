module redub.extensions.bundle;
import redub.api;

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
    {
        user = environment["USER"].dup;
        host = environment["HOSTNAME"].dup;
    }
    version(OSX)
        host = environment["HOST"].dup;

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
