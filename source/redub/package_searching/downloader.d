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
    import std.path;
    import std.file;
    //Supplier will download packageName-version. While dub actually creates packagename/version/
    string toPlace = supplier.downloadPackageTo(path, packageName, requirement, actualVersion);
    string installPath = buildNormalizedPath(toPlace, packageName~"-"~actualVersion.toString);
    toPlace = buildNormalizedPath(toPlace, actualVersion.toString);
    mkdirRecurse(toPlace);
    toPlace = buildNormalizedPath(toPlace, packageName);
    rename(installPath, toPlace);


    string sdlPath = buildNormalizedPath(toPlace, "dub.sdl");
    string jsonPath = buildNormalizedPath(toPlace, "dub.json");
    if(std.file.exists(sdlPath))
    {
        import dub_sdl_to_json;
        JSONValue json = sdlToJSON(parseSDL(sdlPath));
        json["version"] = actualVersion.toString;
        std.file.write(
            jsonPath,
            json.toString,
        );
        std.file.remove(sdlPath);
    }
    else
    {
        if(!std.file.exists(jsonPath))
            throw new Exception("Downloaded a dub package which has no dub configuration?");
        std.file.write(
            jsonPath,
            injectJSONVersion(std.file.readText(jsonPath), actualVersion.toString)
        );
    }

    return toPlace;
}


string injectJSONVersion(string jsonData, string version_)
{
    return jsonData[0..$-2] ~ `,"version": "`~version_~"\"\n}";
}

static this()
{
    supplier = new RegistryPackageSupplier();
}
