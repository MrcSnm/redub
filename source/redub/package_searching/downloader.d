module redub.package_searching.downloader;
import redub.libs.package_suppliers.dub_registry;
import redub.libs.semver;
import core.sync.mutex;
RegistryPackageSupplier supplier;

void prefetchPackagesMetadata(string[] packages)
{
    if(packages.length)
        supplier.loadPackagesMetadata(packages);
}

string getGitDownloadLink(string packageName, string repo, string branch)
{
    import std.algorithm.searching;
    import std.uri;
    if(repo.startsWith("git+"))
        repo = repo[4..$];
    string downloadLink;
    if(repo[$-1] == '/')
        repo = repo[0..$-1];

    if(repo.canFind("gitlab.com"))
        downloadLink = repo~"/-/archive/"~branch~"/"~encodeComponent(packageName)~"-"~branch~".zip";
    else if(repo.canFind("bitbucket.com"))
        downloadLink = repo~"/get/"~encodeComponent(packageName)~"-"~branch~".zip";
    else if(repo.canFind("github.com"))
    {
        //Github has changed recently to other format.
        if(branch.length)
        {
            if(branch[0] == '~')
                downloadLink = repo~"/archive/refs/heads/"~branch[1..$]~".zip";
            else
                downloadLink = repo~"/archive/refs/tags/"~branch~".zip";
        }
        else
            throw new Exception("Unexpected Empty Branch.");
    }
    else 
    {
        ///Gitea and GitBucket all use the same style
        downloadLink = repo~"/archive/"~branch~".zip";
    }
    return downloadLink;
}

string getDownloadLink(string packageName, string repo, SemVer requirement, out SemVer actualVer)
{
    if(repo.length)
    {
        if(!requirement.isInvalid)
            throw new Exception("Package '"~packageName~"' should specify a repository branch, not semver: ["~requirement.toString ~
            "]\n\tExample of repository with branch usage: \"redub\": {\"version\": \"~master\", \"repository\": \"git+https://github.com/MrcSnm/redub.git\"}"~
            "\n\tBranches should start with '~' otherwise, in github, it will be treated as a tag.");
        actualVer = requirement;
        return getGitDownloadLink(packageName, repo, requirement.toString);
    }
    else if(requirement.isInvalid)
        throw new Exception("version for package '"~packageName~"' is invalid ["~requirement.toString~"]. verion may only be used as a git branch if a \"repository\" is specified.");
    return supplier.getBestPackageDownloadUrl(packageName, requirement, actualVer);
}

/**
 * Downloads a .zip containing a package with the specified requirement
 *
 * Params:
 *   packageName = The package name to find
 *   repo = Null whenever a valid requirement exists. An invalid SemVer is used for git branches
 *   requirement = Required. When valid, uses dub registry, when invalid, uses git repo
 *   out_actualVersion = Actual version is for the best package found. Only relevant when a valid SemVer is in place
 *   url = Actual URL from which the download was made
 * Returns: The downloaded content
 */
ubyte[] fetchPackage(string packageName, string repo, SemVer requirement, out SemVer out_actualVersion, out string url)
{
    import d_downloader;
    url = getDownloadLink(packageName, repo, requirement, out_actualVersion);
    if(!url)
        return null;
    return downloadToBuffer(url);
}

/**
 * Downloads the package to a specific folder and extracts it.
 * If no version actually matched existing versions, both out_actualVersionRequirement and url will be empty.
 *
 * Params:
 *   path = The path expected to extract the package to
 *   packageName = Package name for assembling the link
 *   repo = Required when an invalid SemVer is sent
 *   requirement = The requirement that it must satisfy
 *   out_actualVersion = The version that matched the requirement
 *   url = The URL that was built for downloading the package
 * Returns: The path after extraction
 */
string downloadPackageTo(return string path, string packageName, string repo,  SemVer requirement, out SemVer out_actualVersion, out string url)
{
    import redub.libs.package_suppliers.utils;
    import redub.logging;
    import std.zip;
    ubyte[] zipContent = fetchPackage(packageName, repo, requirement, out_actualVersion, url);
    if(!zipContent)
        return null;
    
    if(hasLogLevel(LogLevel.verbose))
        vlog("Extracting package ",packageName, " from repository ", repo, " with branch ", requirement.toString, " to path ", path, " [",url,"]");

    bool extracted = false;
    try
    {
        extracted = extractZipToFolder(zipContent, path);
    }
    catch(ZipException e) {}
    finally
    {
        if(!extracted)
            throw new Exception("Error while trying to extract zip to path "~path~
            "\nPackage "~packageName~ " repository "~ repo~ " with branch "~ requirement.toString~ " download link [" ~ url~"]"
        );

    }
    return path;
}


///Uses that mutex for printing and managing downloader cache, thus, avoiding also more than a single package to be downloaded twice
private __gshared Mutex downloaderMutex;

/**
 * Dub downloads to a path, usually packagename-version.
 * After that, it replaces it with packagename/version.
 * Then, it will load the .sdl or .json file
 * If it uses .sdl, convert it to .json and add a version to it.
 * If it uses .json, append a "version" to it
 */
string downloadPackageTo(return string path, string packageName, string repo, SemVer requirement, out SemVer actualVersion)
{
    import core.thread;
    import core.sync.mutex;
    import core.sync.condition;
    import hip.data.json;
    import redub.libs.package_suppliers.utils;
    import std.path;
    import std.file;
    import redub.logging;
    //Supplier will download packageName-version. While dub actually creates packagename/version/
    string url;

    struct DownloadData
    {
        Mutex mtx;
        string ver;
    }


    ///Create a temporary directory for outputting downloaded version. This will ensure a single version is found on getFirstFile
    string tempPath = buildNormalizedPath(path, "temp");
    size_t timeout = 10_000;
    __gshared DownloadData[string] downloadedPackages;


    bool willDownload;

    synchronized(downloaderMutex)
    {
        if((packageName in downloadedPackages) is null)
        {
            downloadedPackages[packageName] = DownloadData(new Mutex, null);
            willDownload = true;
        }
    }
    downloadedPackages[packageName].mtx.lock;

    scope(exit)
    {
        if(std.file.exists(tempPath))
            std.file.rmdirRecurse((tempPath));
        downloadedPackages[packageName].mtx.unlock;
    }


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



    if(!willDownload)
    {
        return getOutputDirectoryForPackage(path, packageName, downloadedPackages[packageName].ver);
    }
    else
    {
        synchronized(downloaderMutex)
        {
            warnTitle("Fetching Package: ", packageName, " ", repo, " version ", requirement.toString);
            import std.stdio;
            stdout.flush;
        }
        tempPath = downloadPackageTo(tempPath, packageName, repo, requirement, actualVersion, url);
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
        synchronized(downloaderMutex)
        {
            downloadedPackages[packageName].ver = actualVersion.toString;
        }
        path = getOutputDirectoryForPackage(path, packageName, actualVersion.toString);
        string installPath = getFirstFileInDirectory(tempPath);
        if(!installPath)
            throw new Exception("No file was extracted to directory "~tempPath~" while extracting package "~packageName);
        ///The download might have happen while downloading ourselves


        if(std.file.exists(path))
            return path;

        string outputDir = dirName(path);
        if(!std.file.exists(outputDir))
            mkdirRecurse(outputDir);
        rename(installPath, path);
        rmdirRecurse(tempPath);
    }




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
        json = parseJSON(std.file.readText(jsonPath), true);
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
    if(packageVersion is null)
        throw new Exception("Can't create output directory for package "~ packageName~" because its version is null.");
    return buildNormalizedPath(baseDir, packageVersion, packageName);
}

static this()
{
    supplier = new RegistryPackageSupplier();
}

shared static this()
{
    downloaderMutex = new Mutex;
}
