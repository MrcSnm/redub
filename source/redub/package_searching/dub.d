module redub.package_searching.dub;
import redub.package_searching.api;
import redub.logging;
import hipjson;

bool dubHook_PackageManagerDownloadPackage(string packageName, string packageVersion, string requiredBy = "")
{
    import std.process;

    SemVer sv = SemVer(packageVersion);
    string dubFetchVersion = sv.toString;
    if (SemVer(0, 0, 0).satisfies(sv))
        packageVersion = null;
    else if (!sv.ver.major.isNull)
        dubFetchVersion = sv.toString;
    string cmd = "dub fetch " ~ packageName;
    if (packageVersion)
        cmd ~= "@\"" ~ dubFetchVersion ~ "\"";

    info("Fetching ", packageName, " with command ", cmd, ". This was required by ", requiredBy);

    // writeln("dubHook_PackageManagerDownloadPackage with arguments (", packageName, ", ", packageVersion,") " ~
    // "required by '", requiredBy, "' is not implemented yet.");
    return wait(spawnShell(cmd)) == 0;
    // return false;
}

/** 
 * Gets the best matching version on the specified folder
 * Params:
 *   folder = The folder containing the packageName versionentries
 *   packageName = Used to build the path
 *   subPackage = Currently used only for warning
 *   packageVersion = The version required (SemVer)
 * Returns: 
 */
private ReducedPackageInfo getPackageInFolder(string folder, string packageName, string subPackage, string packageVersion)
{
    import std.path;
    import std.file;
    import std.algorithm.sorting;
    import std.algorithm.iteration;
    import std.array;
    SemVer requirement = SemVer(packageVersion);
    if (requirement.isInvalid)
    {
        if (isGitStyle(requirement.toString))
        {
            warn("Using git package version requirement ", requirement, " for ", packageName ~ (subPackage ? (
                    ":" ~ subPackage) : ""));
            foreach (DirEntry e; dirEntries(folder, SpanMode.shallow))
            {
                string fileName = e.name.baseName;
                if (fileName == requirement.toString)
                    return ReducedPackageInfo(fileName, buildNormalizedPath(folder, requirement.toString, packageName));
            }
        }
        error("Invalid package version requirement ", requirement);
    }
    else
    {
        SemVer[] semVers = dirEntries(folder, SpanMode.shallow)
            .map!((DirEntry e) => e.name.baseName)
            .filter!((string name) => name.length && name[0] != '.') //Remove invisible files
            .map!((string name) => SemVer(name))
            .array;
        foreach_reverse (SemVer v; sort(semVers)) ///Sorts version from the highest to lowest
        {
            if (v.satisfies(requirement))
                return ReducedPackageInfo(v.toString, buildNormalizedPath(folder, v.toString, packageName), semVers);
        }
    }
    return ReducedPackageInfo.init;
}

/** 
 * Lookups inside 
 * - $HOME/.dub/packages/local-packages.json
 * - $HOME/.dub/packages/**
 *
 * Params:
 *   packageName = "name" inside dub.json
 *   packageVersion = "version" inside dub.json. SemVer matches are also accepted
 * Returns: The package path when found. null when not.
 */
PackageInfo getPackage(string packageName, string packageVersion, string requiredBy)
{
    import std.file;
    import std.path;
    import std.algorithm;
    import std.array;

    string mainPackageName;
    string subPackage = getSubPackageInfo(packageName, mainPackageName);

    PackageInfo pack;
    pack.packageName = packageName;
    pack.requiredBy = requiredBy;
    pack.subPackage = subPackage;
    pack.requiredVersion = SemVer(packageVersion);
    if (subPackage)
    {
        if(mainPackageName.length)
            packageName = mainPackageName;
        else
            packageName = requiredBy;
    } 
    vlog("Getting package ", packageName, ":", subPackage, "@", packageVersion);

    ReducedPackageInfo localPackage = getPackageInLocalPackages(packageName, packageVersion);
    if (localPackage != ReducedPackageInfo.init)
    {
        pack.bestVersion = SemVer(localPackage.bestVersion);
        pack.path = localPackage.bestVersionPath;
        return pack;
    }
    
    ///If no version was downloaded yet, download before looking
    string downloadedPackagePath = buildNormalizedPath(getDefaultLookupPathForPackages(), packageName);
    if (!std.file.exists(downloadedPackagePath))
    {
        if (!dubHook_PackageManagerDownloadPackage(packageName, packageVersion, requiredBy))
        {
            errorTitle("Dub Fetch Error: ", "Could not fetch ", packageName, "@\"", packageVersion, "\" required by ", requiredBy);
            return PackageInfo.init;
        }
    }
    ReducedPackageInfo info = getPackageInFolder(downloadedPackagePath, packageName, subPackage, packageVersion);
    if(info != ReducedPackageInfo.init)
    {
        pack.bestVersion = SemVer(info.bestVersion);
        pack.path = info.bestVersionPath;
        return pack;
    }

    ///If no matching version was found, try downloading it.
    if (dubHook_PackageManagerDownloadPackage(packageName, packageVersion, requiredBy))
        return getPackage(packageName, packageVersion, requiredBy);
    throw new Exception(
        "Could not find any package named " ~
            packageName ~ " with version " ~ packageVersion ~
            " required by " ~ requiredBy ~ "\nFound versions:\n\t" ~
            info.foundVersions.map!(
                (sv) => sv.toString).join("\n\t")
    );
}




string getPackagePath(string packageName, string packageVersion, string requiredBy)
{
    return getPackage(packageName, packageVersion, requiredBy).path;
}




/** 
 * Separates the subpackage name from the entire dependency name.
 * Params:
 *   packageName = A package name format, such as redub:adv_diff
 *   mainPackageName = In the case of redub:adv_diff, it will return redub
 * Returns: The subpackage name. In case of redub:adv_diff, returns adv_diff.
 */
string getSubPackageInfo(string packageName, out string mainPackageName)
{
    import std.string : indexOf;

    ptrdiff_t ind = packageName.indexOf(":");
    if (ind == -1)
        return null;
    mainPackageName = packageName[0 .. ind];
    return packageName[ind + 1 .. $];
}

/** 
 * Same as getSubPackageInfo, but infer mainPackageName in case of sending a subPackage only, such as :adv_diff
 * Params:
 *   packageName = The package dependency specification
 *   requiredBy = The requiredBy may be used in case of internal dependency specification, such as :adv_diff
 *   mainPackageName = The separated main package name from the sub package
 * Returns: The subpackage
 */
string getSubPackageInfoRequiredBy(string packageName, string requiredBy, out string mainPackageName)
{
    string sub = getSubPackageInfo(packageName, mainPackageName);
    if(sub.length && mainPackageName.length == 0)
        mainPackageName = requiredBy;
    return sub;
}

string getDubWorkspacePath()
{
    import std.path;
    import std.process;

    version (Windows)
        return buildNormalizedPath(environment["LOCALAPPDATA"], "dub");
    else
        return buildNormalizedPath(environment["HOME"], ".dub");
}

private ReducedPackageInfo getPackageInJSON(JSONValue json, string packageName, string packageVersion)
{
    SemVer requirement = SemVer(packageVersion);
    foreach (v; json.array)
    {
        const(JSONValue)* nameJson = "name" in v;
        const(JSONValue)* ver = "version" in v;
        SemVer packageVer = SemVer(ver.str);
        if (nameJson && nameJson.str == packageName && packageVer.satisfies(requirement))
        {
            info("Using local package found at ", v["path"].str, " with version ", ver.str);
            return ReducedPackageInfo(ver.str, v["path"].str);
        }
    }
    return ReducedPackageInfo.init;
}

/** 
 * Use this version instead of getPackageInJSON since this one will cache the local packages instead.
 * Params:
 *   packageName = The package name to get
 *   packageVersion = The package version to get
 * Returns: Best version with its path
 */
private ReducedPackageInfo getPackageInLocalPackages(string packageName, string packageVersion)
{
    import std.path;
    static import std.file;

    static JSONValue localCache;
    static bool isCached = false;

    if(isCached)
    {
        if(localCache == JSONValue.init)
            return ReducedPackageInfo.init;
        return getPackageInJSON(localCache, packageName, packageVersion);
    }
    isCached = true;
    string locPackages = buildNormalizedPath(getDefaultLookupPathForPackages(), "local-packages.json");
    if(std.file.exists(locPackages))
        localCache = parseJSON(std.file.readText(locPackages));
    return getPackageInLocalPackages(packageName, packageVersion);
}

private string getDefaultLookupPathForPackages()
{
    import std.path;
    return buildNormalizedPath(getDubWorkspacePath, "packages");
}

/** 
 * Git style (~master)
 * Params:
 *   str = ~branchName
 * Returns: 
 */
private bool isGitBranchStyle(string str)
{
    import std.ascii : isAlphaNum;
    import std.algorithm.searching : canFind;

    // Must start with ~ and Can't find a non alpha numeric version 
    return str.length > 1 && str[0] == '~' &&
        !str[1 .. $].canFind!((ch) => !ch.isAlphaNum);
}

private bool isGitHashStyle(string str)
{
    import std.ascii : isHexDigit;
    import std.algorithm.searching : canFind;

    // Can't find a non hex digit version 
    return str.length > 0 && !str.canFind!((ch) => !ch.isHexDigit);
}

/**
*   Checks for both git branches and git hashes
*/
private bool isGitStyle(string str)
{
    return isGitBranchStyle(str) || isGitHashStyle(str);
}

/**
Dub's add-local outputs to
$HOME/.dub/packages/local-packages.json
[
    {
        "name": "dorado",
        "path": "/home/artha/git/misc/dorado/",
        "version": "~main"
    },
    {
        "name": "samerion-api",
        "path": "/home/artha/git/samerion/api/",
        "version": "~main"
    },
    {
        "name": "steam-gns-d",
        "path": "/home/artha/git/samerion/steam-gns-d/",
        "version": "~main"
    },
    {
        "name": "isodi",
        "path": "/home/artha/git/samerion/isodi/",
        "version": "~main"
    },
    {
        "name": "rcdata",
        "path": "/home/artha/git/misc/rcdata/",
        "version": "~main"
    },
    {
        "name": "smaugvm",
        "path": "/home/artha/git/samerion/smaug-vm/",
        "version": "~main"
    }
]
**/
