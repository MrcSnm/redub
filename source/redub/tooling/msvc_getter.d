module redub.tooling.msvc_getter;
version(Windows):
import redub.meta;
import hip.data.json;


bool setupMsvc(ref JSONValue compilersInfo)
{
    import redub.parsers.environment;
    import std.process;
    import std.system;
    import std.array:staticArray;
    import std.file;
    import std.path : pathSeparator;
    import redub.misc.path;
    string msvcPath = getCachedString(compilersInfo, "msvcPath", getMsvcPath());
    string sdk = getCachedString(compilersInfo, "winsdkPath", getWinsdkPath());
    string sdkVer = getCachedString(compilersInfo, "winsdkVersion", getWinsdkVersion(sdk));
    static bool hasInitialized = false;
    if(hasInitialized)
        return true;

    if(!msvcPath.length && !sdk.length && !sdkVer.length)
        return false;
    string host = instructionSetArchitecture == ISA.x86 ? "Hostx86" : "Hostx64";
    string target =  instructionSetArchitecture == ISA.x86 ? "x86" : "x64"; //Assume that target is same as host


    string oldLIB, oldINCLUDE, oldPATH;
    if("PATH" in redubEnv)
        oldPATH = pathSeparator ~ redubEnv["PATH"];
    if("LIB" in redubEnv)
        oldLIB = pathSeparator~redubEnv["LIB"];
    if("INCLUDE" in redubEnv)
        oldINCLUDE = pathSeparator~redubEnv["INCLUDE"];

    string libs, includes, paths;
    if(msvcPath.length)
    {
        paths~= buildNormalizedPath(msvcPath, "bin", host, target);
        includes~= buildNormalizedPath(msvcPath, "include");
        libs~= buildNormalizedPath(msvcPath, "lib", target);
    }


    if(sdk.length && sdkVer.length)
    {
        foreach(inc; ["ucrt", "um", "shared"].staticArray)
        {
            string nPath = buildNormalizedPath(sdk, "Include", sdkVer, inc);
            if(exists(nPath))
            {
                if(includes.length)
                    includes~= pathSeparator;
                includes~= nPath;
            }
        }
        foreach(libPath; ["ucrt", "um"].staticArray)
        {
            string nPath = buildNormalizedPath(sdk, "Lib", sdkVer, libPath, target);
            if(exists(nPath))
            {
                if(libs.length)
                    libs~= pathSeparator;
                libs~= nPath;
            }
        }
    }

    setEnvVariable("PATH", paths~oldPATH);
    setEnvVariable("LIB", libs~oldLIB);
    setEnvVariable("INCLUDE", includes~oldINCLUDE);
    hasInitialized = true;
    return true;
}

private string getMsvcPath()
{
    import std.process;
    import std.system;
    import std.algorithm.sorting;
    import std.string:strip;
    import std.file;
    import redub.misc.path;
    import redub.misc.semver_in_folder;
    string vswhere = getVswhere();
    if(!vswhere.length)
        return null;
    auto vsOutput = executeShell(
        escapeShellCommand(vswhere,
        "-latest",
        "-products", "*",
        "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "-property", "installationPath")
    );
    if(vsOutput.status || !vsOutput.output.length)
        return null;
    string vcDir = buildNormalizedPath(strip(vsOutput.output), "VC", "Tools", "MSVC");
    if(!exists(vcDir))
        return null;
    foreach_reverse(SemVer sv; sort(semverInFolder(vcDir))) ///Sorts version from the highest to lowest
        return buildNormalizedPath(vcDir, sv.toString);
    return null;
}

private string getWinsdkPath()
{
    import redub.misc.windows_registry;
    import std.array;
    import std.stdio;
    Key k = windowsGetKeyWithPath("SOFTWARE", "Microsoft", "Windows Kits", "Installed Roots");
    if(k is null)
        return null;
    foreach(kRoot; ["KitsRoot10", "KitsRoot81", "KitsRoot"].staticArray)
    {
        try
        {
            Value v = k.getValue(kRoot);
            if(v.type == REG_VALUE_TYPE.REG_SZ)
                return v.value_SZ();
            if(v.type == REG_VALUE_TYPE.REG_EXPAND_SZ)
                return v.value_EXPAND_SZ();
        }
        catch(Exception e){}
    }
    return null;
}

private string getWinsdkVersion(string sdkPath)
{
    import std.algorithm.sorting;
    import std.exception;
    import redub.misc.path;
    import redub.misc.semver_in_folder;
    if(!sdkPath.length)
        return null;
    string inc = buildNormalizedPath(sdkPath, "Include");
    foreach_reverse(SemVer ver; sort(semverInFolder(inc)))
        return ver.toString;
    enforce(false, sdkPath~" was sent but no SDK version was found at path "~inc);
    return null;
}

private string getVswhere()
{
    import redub.parsers.environment;
    import std.process;
    import std.file;
    import redub.misc.path;
    string vswhere = buildNormalizedPath(redubEnv["PROGRAMFILES(X86)"], "Microsoft Visual Studio", "Installer", "vswhere.exe");
    return exists(vswhere) ? vswhere : null;
}