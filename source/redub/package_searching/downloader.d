module redub.package_searching.downloader;
import redub.libs.package_suppliers.dub_registry;
import redub.libs.semver;
RegistryPackageSupplier supplier;


/**
*   Dub downloads to a path, usually packagename-version
*   After that, it replaces it to packagename/version
*   Then, it will load the .sdl or .json file
*   If it uses .sdl, convert it to .json and add a version to it
*   If it uses .json, append a "version" to it
*/
string downloadPackageTo(return string path, string packageName, SemVer requirement, out SemVer actualVersion)
{
    import core.thread;
    import hipjson;
    import redub.libs.package_suppliers.utils;
    import std.path;
    import std.file;
    import redub.logging;
    //Supplier will download packageName-version. While dub actually creates packagename/version/
    string url;

    ///Create a temporary directory for outputting downloaded version. This will ensure a single version is found on getFirstFile
    string tempPath = buildNormalizedPath(path, "temp");
    size_t timeout = 10_0000;
    while(std.file.exists(tempPath))
    {
        ///If exists a temporary path at that same directory, simply wait until it is removed
        import core.time;
        Thread.sleep(dur!"msecs"(50));
        timeout-= 50;
        if(timeout == 0)
        {
            errorTitle("Redub Fetch Timeout: ", "Wait time of 10 seconds for package "~packageName~" temp folder to be removed has been exceeded");
            throw new NetworkException("Timeout while waiting for removing "~tempPath);
        }
    }
    scope(exit)
        rmdirRecurse(tempPath);

    warnTitle("Fetching Package: ", packageName, " version ", requirement.toString);
    string toPlace = supplier.downloadPackageTo(tempPath, packageName, requirement, actualVersion, url);
    if(!url)
    {
        import redub.libs.semver;
        string existing = "'. Existing Versions: ";
        SemVer[] vers = supplier.getExistingVersions(packageName);
        if(vers is null) existing = "'. This package does not exists in the registry.";
        else
            foreach(v; vers) existing~= "\n\t"~v.toString;


        throw new NetworkException("No version with requirement '"~requirement.toString~"' was found when looking for package "~packageName~existing);
    }

    string installPath = getFirstFileInDirectory(toPlace);
    if(!installPath)
        throw new Exception("No file was extracted to directory "~toPlace~" while extracting package "~packageName);

    path = getOutputDirectoryForPackage(path, packageName, actualVersion.toString);

    ///The download might have happen while downloading ourselves
    if(std.file.exists(path))
        return path;

    rename(installPath, path);

    string sdlPath = buildNormalizedPath(path, "dub.sdl");
    string jsonPath = buildNormalizedPath(path, "dub.json");
    JSONValue json;
    if(std.file.exists(sdlPath))
    {
        import dub_sdl_to_json;
        try
        {
            json = sdlToJSON(parseSDL(sdlPath));
        }
        catch(Exception e)
        {
            errorTitle("Could not convert SDL->JSON The package '"~packageName~"'. Exception\n"~e.msg);
            throw e;
        }
        std.file.remove(sdlPath);
    }
    else
    {
        if(!std.file.exists(jsonPath))
            throw new NetworkException("Downloaded a dub package which has no dub configuration?");
        json = parseJSON(std.file.readText(jsonPath));
    }
    if(json.hasErrorOccurred)
        throw new Exception("Redub Json Parsing Error while reading json '"~jsonPath~"': "~json.error);

    //Inject version as `dub` itself requires that
    json["version"] = actualVersion.toString;
    std.file.write(
        jsonPath,
        json.toString,
    );
    return path;
}

string getOutputDirectoryForPackage(string baseDir, string packageName, string packageVersion)
{
    import std.path;
    import std.file;
    string output = buildNormalizedPath(baseDir, packageVersion, packageName);
    string outputDir = dirName(output);
    if(!std.file.exists(outputDir))
        mkdirRecurse(outputDir);

    return output;
}

static this()
{
    supplier = new RegistryPackageSupplier();
}
