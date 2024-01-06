module package_searching.dub;
import std.json;

bool dubHook_PackageManagerDownloadPackage(string packageName, string packageVersion)
{
    import std.stdio;
    writeln("dubHook_PackageManagerDownloadPackage with arguments (", packageName, ", ", packageVersion,") is not implemented yet.");
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
string getPackagePath(string packageName, string packageVersion)
{
    import std.file;
    import std.path;
    import std.json;
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
        if(!dubHook_PackageManagerDownloadPackage(packageName, packagePath))
            return null;
    }
    
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
    string base;
    version(Windows) base = environment["LOCALAPPDATA"];
    else base = environment["HOME"];
    return buildNormalizedPath(base, ".dub", "packages");
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