module redub.package_searching.cache;
public import redub.package_searching.api;


/** 
 * The packages cache is a package list indexed by their name.
 * This list contains different versions of the package inside it.
 * Those different versions are used to identify the best compatible version among them.
 */
private __gshared PackageInfo[string] packagesCache;


PackageInfo* findPackage(string packageName, string packageVersion, string requiredBy, string path)
{
    PackageInfo* pkg = packageName in packagesCache;
    if(pkg) return pkg;
    if(path.length == 0) return findPackage(packageName, packageVersion, requiredBy);

    PackageInfo localPackage = basePackage(packageName, packageVersion, requiredBy);
    localPackage.path = path;
    packagesCache[packageName] = localPackage;
    return packageName in packagesCache;
}

private string getBetterPackageInfo(PackageInfo* input, string packageName)
{
    string ret = packageName;
    while(input != null)
    {
        if(input.requiredBy == null)
            break;
        ret = input.requiredBy~"->"~ret;
        input = input.requiredBy in packagesCache;
    }
    return ret;
}

PackageInfo* findPackage(string packageName, string packageVersion, string requiredBy)
{
    import redub.package_searching.dub;
    if(packageName.length > 0 && packageName[0] == ':') packageName = packageName~":"~requiredBy;
    PackageInfo* pkg = packageName in packagesCache;
    if(!pkg)
    {
        PackageInfo info = getPackage(packageName, packageVersion, requiredBy);
        packagesCache[packageName] = info;
    }
    else
    {
        import redub.logging;
        SemVer newPkg = SemVer(packageVersion);
        if(!pkg.bestVersion.satisfies(newPkg))
        {
            if(newPkg.satisfies(pkg.requiredVersion))
            {
                PackageInfo newPkgInfo = getPackage(packageName, packageVersion, requiredBy);
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
    packagesCache[packageName] = PackageInfo(packageName, null, SemVer(0,0,0), SemVer(0,0,0), path, null);
}

void putPackageInCache(string packageName, string version_, string path)
{
    packagesCache[packageName] = PackageInfo(packageName, null, SemVer(version_), SemVer(version_), path, null);
}

string getPackagePath(string packageName, string packageVersion, string requiredBy)
{
    return findPackage(packageName, packageVersion, requiredBy).path;
}
