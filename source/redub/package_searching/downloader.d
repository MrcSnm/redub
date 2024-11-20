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
    import hipjson;
    import redub.libs.package_suppliers.utils;
    import std.path;
    import std.file;
    import redub.logging;
    //Supplier will download packageName-version. While dub actually creates packagename/version/
    string url;
    string toPlace = supplier.downloadPackageTo(path, packageName, requirement, actualVersion, url);

    string installPath = getFirstFileInDirectory(toPlace);
    if(!installPath)
        throw new Exception("No file was extracted to directory "~toPlace);
    toPlace = buildNormalizedPath(toPlace, actualVersion.toString);
    mkdirRecurse(toPlace);
    toPlace = buildNormalizedPath(toPlace, packageName);

    string toPlaceDir = dirName(toPlace);
    if(!std.file.exists(toPlaceDir))
        mkdirRecurse(toPlaceDir);


    rename(installPath, toPlace);

    string sdlPath = buildNormalizedPath(toPlace, "dub.sdl");
    string jsonPath = buildNormalizedPath(toPlace, "dub.json");
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
            throw new Exception("Downloaded a dub package which has no dub configuration?");
        json = parseJSON(std.file.readText(jsonPath));
    }

    //Inject version as `dub` itself requires that
    json["version"] = actualVersion.toString;
    std.file.write(
        jsonPath,
        json.toString,
    );
    return toPlace;
}

static this()
{
    supplier = new RegistryPackageSupplier();
}
