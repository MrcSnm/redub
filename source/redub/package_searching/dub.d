module redub.package_searching.dub;
import redub.package_searching.api;
import redub.logging;
import redub.api;
import hipjson;
import core.sync.mutex;



struct FetchedPackage
{
    string name;
    string reqBy;
    string version_;
}

__gshared FetchedPackage[] fetchedPackages;
/**
 *
 * Params:
 *   packageName = The package in which will be looked for
 *   repo = Optional repository, used when an invalid version is sent.
 *   packageVersion = Package version my be both a branch or a valid semver
 *   requiredBy = Metadata info
 * Returns: Package information
 */
ReducedPackageInfo redubDownloadPackage(string packageName, string repo, string packageVersion, string requiredBy = "")
{
    import redub.package_searching.downloader;
    import core.sync.mutex;
    import redub.misc.path;
    SemVer out_bestVersion;
    string downloadedPackagePath = downloadPackageTo(
        redub.misc.path.buildNormalizedPath(getDefaultLookupPathForPackages(), packageName),
        packageName,
        repo,
        SemVer(packageVersion),
        out_bestVersion
    );

    synchronized
    {
        import std.algorithm.searching;
        if(!canFind!("a.name == b.name")(fetchedPackages, FetchedPackage(packageName)))
            fetchedPackages~= FetchedPackage(packageName, requiredBy, out_bestVersion.toString);
    }

    return ReducedPackageInfo(
        out_bestVersion.toString,
        downloadedPackagePath,
        [out_bestVersion]
    );
}

/** 
 * Gets the best matching version on the specified folder
 * Params:
 *   folder = The folder containing the packageName versionentrie   s
 *   packageName = Used to build the path
 *   subPackage = Currently used only for warning
 *   packageVersion = The version required (SemVer)
 * Returns: 
 */
private ReducedPackageInfo getPackageInFolder(string folder, string packageName, string subPackage, string packageVersion)
{
    import std.path;
    import redub.misc.path;
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
                    return ReducedPackageInfo(fileName, redub.misc.path.buildNormalizedPath(folder, requirement.toString, packageName));
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
                return ReducedPackageInfo(v.toString, redub.misc.path.buildNormalizedPath(folder, v.toString, packageName), semVers);
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
PackageInfo getPackage(string packageName, string repo, string packageVersion, string requiredBy)
{
    import std.file;
    import std.path;
    import redub.misc.path;
    import std.algorithm;
    import std.array;

    PackageInfo pack = basePackage(packageName, packageVersion , requiredBy);
    packageName = pack.packageName;
    vlog("Getting package ", packageName, ":", pack.subPackage, "@", packageVersion);
    ReducedPackageInfo localPackage = getPackageInLocalPackages(packageName, packageVersion);
    if (localPackage != ReducedPackageInfo.init)
    {
        pack.bestVersion = SemVer(localPackage.bestVersion);
        pack.path = localPackage.bestVersionPath;
        return pack;
    }
    
    ///If no version was downloaded yet, download before looking
    string downloadedPackagePath = redub.misc.path.buildNormalizedPath(getDefaultLookupPathForPackages(), packageName);
    ReducedPackageInfo info;
    if (!std.file.exists(downloadedPackagePath))
        info = redubDownloadPackage(packageName, repo, packageVersion, requiredBy);
    else
        info = getPackageInFolder(downloadedPackagePath, packageName, pack.subPackage, packageVersion);

    if(info != ReducedPackageInfo.init)
    {
        pack.bestVersion = SemVer(info.bestVersion);
        pack.path = info.bestVersionPath;
        return pack;
    }

    ///If no matching version was found, try downloading it.
    info = redubDownloadPackage(packageName, repo, packageVersion, requiredBy);
    return getPackage(packageName, repo, packageVersion, requiredBy);

    throw new Exception(
        "Could not find any package named " ~
            packageName ~ " with version " ~ packageVersion ~
            " required by " ~ requiredBy ~ "\nFound versions:\n\t" ~
            info.foundVersions.map!(
                (sv) => sv.toString).join("\n\t")
    );
}

string getPackagePath(string packageName, string repo, string packageVersion, string requiredBy)
{
    return getPackage(packageName, repo, packageVersion, requiredBy).path;
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
            vlog("Using local package found at ", v["path"].str, " with version ", ver.str);
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
    import redub.misc.path;
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
    import redub.misc.path;
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
