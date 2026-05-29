module redub.misc.app_image;
import redub.libs.package_suppliers.utils;


string getAppImageArch()
{
    version(AArch64)
        return "aarch64";
    else version(X86_64)
        return "x86_64";
    else version(ARM_HardFloat)
        return "armhf";
    else
        return "x86";
}

string getAppImageDownloadLink()
{
    import core.interpolation;
    import std.conv:text;
    return i"https://github.com/AppImage/appimagetool/releases/latest/download/appimagetool-$(getAppImageArch()).AppImage".text;
}

string getAppImageExecutablePath()
{
    import redub.api;
    import redub.misc.path;
    return buildNormalizedPath(getDubWorkspacePath, "appimagetool-"~getAppImageArch()~".AppImage");
}


bool installAppImage()
{
    import redub.api;
    import redub.misc.path;
    import redub.misc.make_file_executable;
    import redub.logging;
    import d_downloader;
    import std.path:baseName;
    import std.file;
    string downloadLink = getAppImageDownloadLink();
    string execPath = getAppImageExecutablePath();
    
    try
    {
        info("Downloading ", downloadLink, " to ", execPath);
        downloadToFile(downloadLink, execPath);
        if(!makeFileExecutable(execPath))
        {
            error("Failed in making file ",execPath, " executable.");
            return false;
        }
    }
    catch(Exception e)
        throw new NetworkException("Could not download '"~downloadLink~"' to path '"~execPath~"': "~e.msg);
    return true;
}