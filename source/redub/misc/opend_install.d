module redub.misc.opend_install;
import std.system;

bool installOpend(OS os = std.system.os, ISA isa = instructionSetArchitecture)
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
    string downloadLink = getOpendDownloadLink(os, isa);

    string workspace = buildNormalizedPath(getDubWorkspacePath, "redub-opend");
    string binPath = buildNormalizedPath(workspace, getOpendFolderName(os, isa), "bin");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    if(exists(binPath))
    {
        infos("OpenD", " is already installed at path ", binPath);
        return true;
    }

    if(!downloadAndExtract(downloadLink, workspace))
        return false;
    foreach(executable; ["ldc2", "dmd", "opend"].staticArray)
        if(!makeFileExecutable(buildNormalizedPath(binPath, executable)))
            return false;
	return true;
}

string getOpendFolderName(OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import redub.command_generators.commons;
    import redub.api;
    import core.interpolation;
    import std.conv:to,text;
    string sys;

    if(os.isWindows)
        sys = "windows-x64";
    else if(os.isApple)
        sys = "osx-universal";
    else if(os.isPosix)
        sys = "linux-x86_64";
    else
        throw new RedubException("Redub has no support to OpenD for the OS '"~os.to!string~"'");
    return i"opend-latest-$(sys)".text;
}

string getOpendDownloadLink(OS os = std.system.os, ISA isa = instructionSetArchitecture)
{
    import redub.command_generators.commons;
    import redub.api;
    import core.interpolation;
    import std.conv:to,text;
    string sys;

    if(os.isWindows)
        sys = "windows-x64.7z";
    else if(os.isApple)
        sys = "osx-universal.tar.xz";
    else if(os.isPosix)
        sys = "linux-x86_64.tar.xz";
    else
        throw new RedubException("Redub has no support to Open D for the OS '"~os.to!string~"'");
    return i"https://github.com/opendlang/opend/releases/download/CI/opend-latest-$(sys)".text;
}