module redub.misc.dmd_install;
import std.system;

enum DefaultDMDVersion = "2.111.0";


string getDmdFolder(string ver, OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import redub.api;
    import redub.misc.path;
    return buildNormalizedPath(getDubWorkspacePath, "redub-dmd", getDmdFolderName(ver, os, isa));
}


bool installDmd(string dmdVersion, OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import std.string;
    import std.array;
    import std.file;
    import redub.api;
    import redub.meta;
    import redub.misc.path;
    import redub.misc.unzip;
    import redub.libs.package_suppliers.utils;
    import redub.misc.make_file_executable;
    import redub.logging;
    string downloadLink = getDmdDownloadLink(dmdVersion, os, isa);
    if(dmdVersion.startsWith("v"))
        dmdVersion = dmdVersion[1..$];

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-dmd");
    string binPath = buildNormalizedPath(workspace, getDmdFolderName(dmdVersion, os, isa), "bin");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    if(exists(binPath))
    {
        infos("LDC ",dmdVersion," is already installed at path ", binPath);
        return true;
    }

    if(!downloadAndExtract(downloadLink, workspace))
        return false;

    rename(buildNormalizedPath(workspace, "dmd2"), buildNormalizedPath(workspace, "dmd-"~dmdVersion));
    foreach(executable; ["ldc2", "ldmd2", "rdmd", "dub"].staticArray)
        if(!makeFileExecutable(buildNormalizedPath(binPath, executable)))
            return false;
	return true;
}

private string getDmdFolderName(string ver, OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import redub.misc.path;
    import redub.command_generators.commons;
    import redub.api;
    import core.interpolation;
    import std.conv:to,text;
    import std.string:startsWith;
    string sys;
    if(ver.startsWith("v"))
        ver = ver[1..$];

    if(os.isWindows)
        sys = isa == ISA.x86 ? "winndows\\bin" : "windows\\bin64";
    else if(os.isApple)
        sys = "osx/bin";
    else if(os.isPosix)
        sys = isa == ISA.x86 ? "linux/bin32" : "linux/bin64";
    else
        throw new RedubException("Redub has no support to DMD for the OS '"~os.to!string~"'");
    return buildNormalizedPath("dmd-"~ver, sys);
}
string getDmdDownloadLink(string ver, OS os = std.system.os, ISA isa = instructionSetArchitecture)
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
        sys = "windows.7z";
    else if(os.isApple)
    {
        if(isa == ISA.aarch64)
            throw new RedubException("Redub is not able to install dmd for MacOS ARM");
        sys = "osx.tar.xz";
    }
    else if(os.isPosix)
        sys = "linux.tar.xz";
    else
        throw new RedubException("Redub has no support to DMD for the OS '"~os.to!string~"'");
    return i"https://downloads.dlang.org/releases/2.x/$(ver)/dmd.$(ver).$(sys)".text;
}