module redub.package_searching.api;
public import redub.libs.semver;


struct PackageInfo
{
    string packageName;
    string subPackage;
    SemVer requiredVersion;
    SemVer bestVersion;
    string path;
    string requiredBy;
}

struct ReducedPackageInfo
{
    string bestVersion;
    string bestVersionPath;
    SemVer[] foundVersions;
}



/**
 * Separates the subpackage name from the entire dependency name.
 * Params:
 *   packageName = A package name format, such as redub:adv_diff
 *   mainPackageName = In the case of redub:adv_diff, it will return redub
 * Returns: The subpackage name. In case of redub:adv_diff, returns adv_diff.
 */
private string getSubPackageInfo(string packageName, out string mainPackageName)
{
    import std.string : indexOf;

    ptrdiff_t ind = packageName.indexOf(":");
    if (ind == -1)
    {
        mainPackageName = packageName;
        return null;
    }
    mainPackageName = packageName[0 .. ind];
    return packageName[ind + 1 .. $];
}

/** 
 * Gets the full package name. Used for caching
 * Params:
 *   packageName = The package name specification
 *   requiredBy = Which is requesting it
 * Returns: The package full name. For example - (:gl, renderer) returns 'renderer:gl'
 */
string getPackageFullName(string packageName, string requiredBy)
{
    if(packageName.length && packageName[0] == ':')
        return requiredBy~packageName;
    return packageName;
}


/**
 * Same as getSubPackageInfo, but infer mainPackageName in case of sending a subPackage only, such as :adv_diff
 * Params:
 *   packageName = The package dependency specification
 *   requiredBy = The requiredBy may be used in case of internal dependency specification, such as :adv_diff
 *   mainPackageName = The separated main package name from the sub package
 * Returns: The subpackage
 */
string getSubPackageInfoRequiredBy(string packageName, string requiredBy, out string mainPackageName)
{
    string sub = getSubPackageInfo(packageName, mainPackageName);
    if(sub.length && mainPackageName.length == 0)
        mainPackageName = requiredBy;
    return sub;
}


PackageInfo basePackage(string packageName, string packageVersion, string requiredBy)
{
    PackageInfo pack;
    pack.subPackage =  getSubPackageInfoRequiredBy(packageName, requiredBy, pack.packageName);
    pack.requiredBy = requiredBy;
    pack.requiredVersion = SemVer(packageVersion);
    return pack;
}