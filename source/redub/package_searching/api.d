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