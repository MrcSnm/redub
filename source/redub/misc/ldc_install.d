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