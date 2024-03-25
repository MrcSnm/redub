module redub.package_searching.dub;
import redub.logging;
import hipjson;
// import std.json;
import redub.libs.semver;

bool dubHook_PackageManagerDownloadPackage(string packageName, string packageVersion, string requiredBy= "")
{
    import std.process;
    SemVer sv = SemVer(packageVersion);
    info("Fetching ", packageName,"@",sv.toString, ", required by ", requiredBy);
    string dubFetchVersion = sv.toString;
    if(SemVer(0,0,0).satisfies(sv)) packageVersion = null;
    else if(!sv.ver.major.isNull) dubFetchVersion = sv.ver.toString;
    string cmd = "dub fetch "~packageName;
    if(packageVersion) cmd~= "@"~dubFetchVersion;

    // writeln("dubHook_PackageManagerDownloadPackage with arguments (", packageName, ", ", packageVersion,") " ~
    // "required by '", requiredBy, "' is not implemented yet.");
    return wait(spawnShell(cmd)) == 0;
    // return false;
}

/** 
 * Lookups inside 
 * - $HOME/.dub/packages/local-packages.json
 * - $HOME/.dub/packages/**
 *
 * Params:
 *   packageName = "name" inside dub.json
 *   packageVersion = "version" inside dub.json. Only full matches are accepted at the moment
 * Returns: The package path when found. null when not.
 */
string getPackagePath(string packageName, string packageVersion, string requiredBy)
{
    import std.file;
    import std.path;
    string lookupPath = getDefaultLookupPathForPackages();
    string locPackages = buildNormalizedPath(lookupPath, "local-packages.json");
    string mainPackageName;
    string subPackage = getSubPackageInfo(packageName, mainPackageName);
    if(mainPackageName) packageName = mainPackageName;

    vlog("Getting package ", packageName, ":", subPackage, "@",packageVersion);

    string packagePath;
    if(std.file.exists(locPackages))
    {
        JSONValue localPackagesJSON = parseJSON(std.file.readText(locPackages));
        packagePath = getPackageInJSON(localPackagesJSON, packageName, packageVersion);
        if(packagePath) return packagePath;
    }
    string downloadedPackagePath = buildNormalizedPath(lookupPath, packageName);
    if(!std.file.exists(downloadedPackagePath))
    {
        if(!dubHook_PackageManagerDownloadPackage(packageName, packageVersion, requiredBy))
            return null;
    }

    import std.algorithm.sorting;
    import std.algorithm.iteration;
    import std.array;

    SemVer[] semVers = dirEntries(downloadedPackagePath, SpanMode.shallow)
        .map!((DirEntry e) => e.name.baseName)
        .filter!((string name) => name.length && name[0] != '.') //Remove invisible files
        .map!((string name ) => SemVer(name)).array;
    SemVer requirement = SemVer(packageVersion);

    if(requirement.isInvalid)
    {
        if(isGitStyle(requirement.toString))
        {
            warn("Using git package version requirement ", requirement, " for ", packageName ~ (subPackage ? (":"~subPackage) : ""));
            foreach(DirEntry e; dirEntries(downloadedPackagePath, SpanMode.shallow))
            {
                if(e.name.baseName == requirement.toString)
                    return buildNormalizedPath(downloadedPackagePath, requirement.toString, packageName);
            }
        }
        error("Invalid package version requirement ", requirement);
        return null;
    }
    foreach_reverse(SemVer v; sort(semVers))
    {
        if(v.satisfies(requirement))
            return buildNormalizedPath(downloadedPackagePath, v.toString, packageName);
    }
    if(dubHook_PackageManagerDownloadPackage(packageName, packageVersion, requiredBy))
        return getPackagePath(packageName, packageVersion, requiredBy);
    throw new Error(
        "Could not find any package named "~ 
        packageName ~ " with version " ~ requirement.toString ~ 
        " required by "~requiredBy ~ "\nFound versions:\n\t" ~
        semVers.map!((sv) => sv.toString).join("\n\t")
        );
}

string getSubPackageInfo(string packageName, out string mainPackageName)
{
    import std.string:indexOf;
    ptrdiff_t ind = packageName.indexOf(":");
    if(ind == -1) return null;
    mainPackageName = packageName[0..ind];
    return packageName[ind+1..$];
}

string getDubWorkspacePath()
{
    import std.path;
    import std.process;
    version(Windows) return buildNormalizedPath(environment["LOCALAPPDATA"],  "dub");
    else return buildNormalizedPath(environment["HOME"], ".dub");
}



private string getPackageInJSON(JSONValue json, string packageName, string packageVersion)
{
    foreach(v; json.array)
    {
        const(JSONValue)* nameJson = "name" in v;
        //TODO: Check packageVersion
        if(nameJson && nameJson.str == packageName)
            return v["path"].str;
    }
    return null;
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
    import std.ascii:isAlphaNum;
    import std.algorithm.searching:canFind;
    // Must start with ~ and Can't find a non alpha numeric version 
    return str.length > 1 && str[0] == '~' && 
            !str[1..$].canFind!((ch) => !ch.isAlphaNum);
}

private bool isGitHashStyle(string str)
{
    import std.ascii:isHexDigit;
    import std.algorithm.searching:canFind;
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