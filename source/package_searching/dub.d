module package_searching.dub;
import std.json;
import dubv2.libs.semver;

bool dubHook_PackageManagerDownloadPackage(string packageName, string packageVersion, string requiredBy= "")
{
    import std.stdio;
    import std.process;
    string cmd = "dub fetch "~packageName;
    if(packageVersion) cmd~= "@"~packageVersion;
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
        if(!dubHook_PackageManagerDownloadPackage(packageName, packagePath, requiredBy))
            return null;
    }

    import std.algorithm.sorting;
    import std.algorithm.iteration;
    import std.stdio;
    import std.array;

    SemVer[] semVers = dirEntries(downloadedPackagePath, SpanMode.shallow)
        .map!((DirEntry e) => e.name.baseName)
        .filter!((string name) => name.length && name[0] != '.') //Remove invisible files
        .map!((string name ) => SemVer(name)).array;
    SemVer requirement = SemVer(packageVersion);

    if(requirement.isInvalid)
    {
        import std.ascii:isAlphaNum;
        import std.algorithm.searching:canFind;
        if(requirement.toString.length > 1 && requirement.toString[0] == '~' && 
            !requirement.toString[1..$].canFind!((ch) => !ch.isAlphaNum)) //Can't find a non alpha numeric version
        {
            writeln("Warning: using git package version requirement ", requirement, " for ", packageName ~ (subPackage ? (":"~subPackage) : ""));
            foreach(DirEntry e; dirEntries(downloadedPackagePath, SpanMode.shallow))
            {
                if(e.name.baseName == requirement.toString)
                    return buildNormalizedPath(downloadedPackagePath, requirement.toString, packageName);
            }
        }
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
            return buildNormalizedPath(downloadedPackagePath, v.toString, packageName);
    }
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