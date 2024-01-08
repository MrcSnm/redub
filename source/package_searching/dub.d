module package_searching.dub;
import std.json;
import dubv2.libs.semver;

bool dubHook_PackageManagerDownloadPackage(string packageName, string packageVersion, string requiredBy= "")
{
    import std.stdio;
    writeln("dubHook_PackageManagerDownloadPackage with arguments (", packageName, ", ", packageVersion,") " ~
    "required by '", requiredBy, "' is not implemented yet.");
    return false;
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
string getPackagePath(string packageName, string packageVersion, string requiredBy="")
{
    import std.file;
    import std.path;
    string lookupPath = getDefaultLookupPathForPackages();
    string locPackages = buildNormalizedPath(lookupPath, "local-packages.json");
    string packagePath;
    if(std.file.exists(locPackages))
    {
        JSONValue localPackagesJSON = parseJSON(locPackages);
        packagePath = getPackageInJSON(localPackagesJSON, packageName, packageVersion);
        if(packagePath) return packagePath;
    }
    string downloadedPackagePath = buildNormalizedPath(lookupPath, packageName);
    if(!std.file.exists(downloadedPackagePath))
    {
        if(!dubHook_PackageManagerDownloadPackage(packageName, packagePath, requiredBy))
            return null;
    }

    import std.algorithm.sorting;
    import std.algorithm.iteration;
    import std.stdio;
    import std.array;

    SemVer[] semVers = dirEntries(downloadedPackagePath, SpanMode.shallow).map!((DirEntry e ) => SemVer(e.name.baseName)).array;
    SemVer requirement = SemVer(packageVersion);

    if(requirement.isInvalid)
    {
        writeln("Invalid package version requirement ", requirement);
        return null;
    }

    foreach_reverse(SemVer v; sort(semVers))
    {
        if(v.isInvalid)
        {
            writeln("Invalid semver '", v, "' found in folder '", downloadedPackagePath, "'");
            return null;
        }
        if(v.satisfies(requirement))
            return buildNormalizedPath(downloadedPackagePath, v.toString);
    }
    return null;
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
    import std.process;
    version(Windows) return buildNormalizedPath(environment["LOCALAPPDATA"],  "dub", "packages");
    else return buildNormalizedPath(environment["HOME"], ".dub", "packages");
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