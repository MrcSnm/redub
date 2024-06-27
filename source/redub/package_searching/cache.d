module redub.package_searching.cache;
import redub.package_searching.api;


/** 
 * The packages cache is a package list indexed by their name.
 * This list contains different versions of the package inside it.
 * Those different versions are used to identify the best compatible version among them.
 */
private __gshared PackageInfo[string] packagesCache;


PackageInfo findPackage(string packageName, string packageVersion, string requiredBy)
{
    PackageInfo* pkg = packageName in packagesCache;
    if(!pkg)
    {
        import redub.package_searching.dub;
        PackageInfo info = getPackage(packageName, packageVersion, requiredBy);
        packagesCache[packageName] = info;
    }
    else
    {
        if(!pkg.bestVersion.satisfies(SemVer(packageVersion)))
            throw new Exception("Package "~packageName~" with first version found '"~pkg.bestVersion.toString~"' is not compatible with the new requirement: "~packageVersion);

        import redub.logging;
        info("Using ", packageName, " with version: ", pkg.bestVersion, ". Initial requirement was '", pkg.requiredVersion, ". Current is ", packageVersion);
        return *pkg;
    }
    return packagesCache[packageName];
}

/** 
 * 
 * Params:
 *   packageName = What is the root package name
 *   path = Where the root package is located.
 */
void putRootPackageInCache(string packageName, string path)
{
    packagesCache[packageName] = PackageInfo(packageName, null, SemVer(0,0,0), SemVer(0,0,0), path, null);
}

string getPackagePath(string packageName, string packageVersion, string requiredBy)
{
    return findPackage(packageName, packageVersion, requiredBy).path;
}
