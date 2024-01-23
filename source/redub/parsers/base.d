module redub.parsers.base;
import redub.logging;
import redub.buildapi;
import redub.package_searching.dub;


struct ParseConfig
{
    string workingDir;
    BuildRequirements.Configuration subConfiguration;
    string subPackage;
    string version_ = "~master";
    string compiler;
    string arch;
    string requiredBy;
    bool firstRun = true;
    bool preGenerateRun = true;
}


void setName(ref BuildRequirements req, string name, ParseConfig c)
{
    if(c.firstRun)
        req.cfg.name = name;
}
void setTargetPath(ref BuildRequirements req, string path, ParseConfig c){req.cfg.outputDirectory = path;}
void setTargetType(ref BuildRequirements req, string targetType, ParseConfig c){req.cfg.targetType = targetFrom(targetType);}
void addImportPaths(ref BuildRequirements req, string[] paths, ParseConfig c)
{
    if(c.firstRun) req.cfg.importDirectories = paths;
    else req.cfg.importDirectories.exclusiveMerge(paths);
}
void addStringImportPaths(ref BuildRequirements req, string[] paths, ParseConfig c){req.cfg.stringImportPaths.exclusiveMergePaths(paths);}
void addPreGenerateCommands(ref BuildRequirements req, string[] cmds, ParseConfig c){req.cfg.preGenerateCommands~= cmds;}
void addPostGenerateCommands(ref BuildRequirements req, string[] cmds, ParseConfig c){req.cfg.postGenerateCommands~= cmds;}
void addPreBuildCommands(ref BuildRequirements req, string[] cmds, ParseConfig c){req.cfg.preBuildCommands~= cmds;}
void addPostBuildCommands(ref BuildRequirements req, string[] cmds, ParseConfig c){req.cfg.postBuildCommands~= cmds;}
void addSourcePaths(ref BuildRequirements req, string[] paths, ParseConfig c)
{
    if(c.firstRun) req.cfg.sourcePaths = paths;
    else req.cfg.sourcePaths.exclusiveMergePaths(paths);
}
void addSourceFiles(ref BuildRequirements req, string[] files, ParseConfig c){req.cfg.sourceFiles.exclusiveMerge(files);}
void addExcludedSourceFiles(ref BuildRequirements req, string[] files, ParseConfig c){req.cfg.excludeSourceFiles.exclusiveMerge(files);}
void addLibPaths(ref BuildRequirements req, string[] paths, ParseConfig c){req.cfg.libraryPaths.exclusiveMerge(paths);}
void addLibs(ref BuildRequirements req, string[] libs, ParseConfig c){req.cfg.libraries.exclusiveMerge(libs);}
void addVersions(ref BuildRequirements req, string[] vers, ParseConfig c){req.cfg.versions.exclusiveMerge(vers);}
void addLinkFlags(ref BuildRequirements req, string[] lFlags, ParseConfig c){req.cfg.linkFlags.exclusiveMerge(lFlags);}
void addDflags(ref BuildRequirements req, string[] dFlags, ParseConfig c){req.cfg.dFlags.exclusiveMerge(dFlags);}
void addDependency(
    ref BuildRequirements req, 
    ParseConfig c,
    string name, string version_, 
    BuildRequirements.Configuration subConfiguration, 
    string path,
    string visibility
)
{
    import std.path;
    import std.algorithm.searching:countUntil;
    if(path.length && !isAbsolute(path)) 
        path = buildNormalizedPath(c.workingDir, path);
    Dependency dep = dependency(name, path, version_, req.name, c.workingDir, subConfiguration, visibility);
    //If dependency already exists, use the existing one
    ptrdiff_t depIndex = countUntil!((a) => a.isSameAs(dep))(req.dependencies);
    if(depIndex == -1)
        req.dependencies~= dep;
    else
    {
        dep.subConfiguration = req.dependencies[depIndex].subConfiguration;
        req.dependencies[depIndex] = dep;
    }
}


/**
*   This function infers the subPackage name on the dependency.
*/
private Dependency dependency(
    string name,
    string path,
    string version_,
    string requirementName,
    string workingDir,
    BuildRequirements.Configuration subConfiguration,
    string visibilityStr
)
{
    string out_mainPackageName;
    string subPackage = getSubPackageInfo(name, out_mainPackageName);
    ///If subPackage was found, populate informations on it
    if(out_mainPackageName.length)
        name = out_mainPackageName;
    ///Inside this same package
    if(out_mainPackageName == requirementName && subPackage)
        path = workingDir;

    Visibility visibility = Visibility.public_;
    if(visibilityStr) visibility = VisibilityFrom(visibilityStr);
    
    return Dependency(name, path, version_, subConfiguration, subPackage, visibility);
}

void addSubConfiguration(
    ref BuildRequirements req, 
    ParseConfig c,
    string dependencyName,
    string subConfigurationName
)
{
    vlog("Using ", subConfigurationName, " subconfiguration for ", dependencyName, " in project ", c.requiredBy);
    import std.algorithm.searching:countUntil;
    ptrdiff_t depIndex = countUntil!((dep) => dep.name == dependencyName)(req.dependencies);
    if(depIndex == -1)
        req.dependencies~= Dependency(dependencyName, null, null, BuildRequirements.Configuration(subConfigurationName, false), null);
    else
        req.dependencies[depIndex].subConfiguration = BuildRequirements.Configuration(subConfigurationName, false);
    
    
}