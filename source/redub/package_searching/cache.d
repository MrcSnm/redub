module redub.package_searching.cache;
import core.sync.mutex;
import core.attribute;
public import redub.package_searching.api;


/** 
 * The packages cache is a package list indexed by their name.
 * This list contains different versions of the package inside it.
 * Those different versions are used to identify the best compatible version among them.
 */
private __gshared PackageInfo[string] packagesCache;
private __gshared Mutex cacheMtx;

@standalone @trusted
shared static this()
{
    cacheMtx = new Mutex;
}

/**
 *
 * Params:
 *   packageName = The package name to find
 *   repo = Repo information that is only ever used whenever the version is invalid
 *   packageVersion = The version of the package, may be both a SemVer or a branch
 *   requiredBy = Metadata information
 *   path = The path on which this package may be. Used whenever not in the cache
 * Returns: The package information
 */
PackageInfo* findPackage(string packageName, string repo, string packageVersion, string requiredBy, string path)
{
    PackageInfo* pkg;
    synchronized(cacheMtx)
    {
        pkg = packageName in packagesCache;
    }
    if(pkg) return pkg;
    if(path.length == 0) return findPackage(packageName, repo, packageVersion, requiredBy);

    PackageInfo localPackage = basePackage(packageName, packageVersion, requiredBy);
    localPackage.path = path;
    synchronized(cacheMtx)
    {
        packagesCache[packageName] = localPackage;
        return packageName in packagesCache;
    }
}

private string getBetterPackageInfo(PackageInfo* input, string packageName)
{
    string ret = packageName;
    synchronized(cacheMtx)
    {
        while(input != null)
        {
            if(input.requiredBy == null)
                break;
            ret = input.requiredBy~"->"~ret;
            input = input.requiredBy in packagesCache;
        }
    }
    return ret;
}

/**
 *
 * Params:
 *   packageName = The package name to find
 *   repo = The repo information. Used when the package version is invalid. Information only used to fetch
 *   packageVersion = The SemVer version to look for. Or a git branch
 *   requiredBy = Meta information on whom is requiring it.
 * Returns:
 */
PackageInfo* findPackage(string packageName, string repo, string packageVersion, string requiredBy)
{
    import redub.package_searching.dub;
    PackageInfo* pkg;
    synchronized(cacheMtx)
        pkg = packageName in packagesCache;
    if(!pkg)
    {
        PackageInfo info = getPackage(packageName, repo, packageVersion, requiredBy);
        synchronized(cacheMtx)
        {
            packagesCache[packageName] = info;
        }
    }
    else
    {
        import redub.logging;
        SemVer newPkg = SemVer(packageVersion);
        if(!pkg.bestVersion.satisfies(newPkg))
        {
            if(newPkg.satisfies(pkg.requiredVersion))
            {
                PackageInfo newPkgInfo = getPackage(packageName, repo, packageVersion, requiredBy);
                pkg.bestVersion = newPkgInfo.bestVersion;
                pkg.path = newPkgInfo.path;
                import redub.logging;
                error("Using ", pkg.path, " for package ", pkg.packageName);
            }
            else
                throw new Exception("Package "~packageName~" with first requirement found '"~pkg.requiredVersion.toString~"' from the dependency '" ~
                getBetterPackageInfo(pkg, packageName)~"' is not compatible with the new requirement: "~packageVersion ~ " required by "~requiredBy~ " ("~getBetterPackageInfo(requiredBy in packagesCache, requiredBy)~")");
        }
        vlog("Using ", packageName, " with version: ", pkg.bestVersion, ". Initial requirement was '", pkg.requiredVersion, ". Current is ", packageVersion);
        return pkg;
    }
    synchronized(cacheMtx)
        return packageName in packagesCache;
}


/** 
 * 
 * Params:
 *   packageName = What is the root package name
 *   path = Where the root package is located.
 */
void putRootPackageInCache(string packageName, string path)
{
    synchronized(cacheMtx)
    {
        packagesCache[packageName] = PackageInfo(packageName, null, SemVer(0,0,0), SemVer(0,0,0), path, null,);
    }
}

/**
 * Puts the package in cache. This is only called from subPackage, and, when this package is searched again, redub will know where to look at.
 * Params:
 *   packageName = The full package name
 *   version_ = Which version is it
 *   path = Where is it located
 *   requiredBy = Which package required that
 *   isInternalSubPackage = Information to tell whether this is a subPackage in a separate file or not
 */
void putPackageInCache(string packageName, string version_, string path, string requiredBy, bool isInternalSubPackage)
{
    synchronized(cacheMtx)
    {
        PackageInfo p = basePackage(packageName, version_, requiredBy, isInternalSubPackage);
        p.path = path;
        packagesCache[packageName] = p;
    }
}
void clearPackageCache()
{
    synchronized(cacheMtx)
        packagesCache = null;
}

string getPackagePath(string packageName, string repo, string packageVersion, string requiredBy)
{
    return findPackage(packageName, repo ,packageVersion, requiredBy).path;
}
