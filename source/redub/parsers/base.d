module redub.parsers.base;
import std.system;
import redub.command_generators.commons;
import redub.logging;
import redub.buildapi;
import redub.package_searching.api;
import redub.parsers.json;
import redub.tree_generators.dub;


struct ParseConfig
{
    string workingDir;
    BuildRequirements.Configuration subConfiguration;
    ///Which subPackage to parse
    string subPackage;
    ///Which version this is
    string version_ = "~master";
    ///Creates a filter for Compiler-Arch-OS-ISA
    CompilationInfo cInfo;
    ///Who required that package.
    string requiredBy;
    ///If the current parse config is a sub package, it will have a parent
    string parentName;
    ///That information is important for assembling the name.
    bool isParsingSubpackage;
    ///When first run is equals false, it won't do anything at "configurations"
    bool firstRun = true;
    ///When preGenerateRun is true, it will run the preGenerateRun
    bool preGenerateRun = true;
    bool isRoot = false;
}


void setName(ref BuildRequirements req, string name, ParseConfig c)
{
    if(c.firstRun)
    {
        if(c.parentName.length)
            name = c.parentName~":"~name;
        req.cfg.name = name;
        // if(name == "default") asm { int 3; }
    }
}
void setTargetPath(ref BuildRequirements req, string path, ParseConfig c){req.cfg.outputDirectory = path;}
void setTargetType(ref BuildRequirements req, string targetType, ParseConfig c){req.cfg.targetType = targetFrom(targetType);}
void addImportPaths(ref BuildRequirements req, JSONStringArray paths, ParseConfig c)
{
    import std.array;
    if(c.firstRun) req.cfg.importDirectories = cast(string[])paths.array;
    else req.cfg.importDirectories.exclusiveMerge(paths);
}
void addStringImportPaths(ref BuildRequirements req, JSONStringArray paths, ParseConfig c){req.cfg.stringImportPaths.exclusiveMergePaths(paths);}
void addExtraDependencyFiles(ref BuildRequirements req, JSONStringArray files, ParseConfig c){req.cfg.extraDependencyFiles.exclusiveMerge(files);}
void addFilesToCopy(ref BuildRequirements req, JSONStringArray files, ParseConfig c){req.cfg.filesToCopy = req.cfg.filesToCopy.append(files);}
void addPreGenerateCommands(ref BuildRequirements req, JSONStringArray cmds, ParseConfig c)
{
    import hipjson;
    infos("Pre-gen ", "Running commands for ", c.requiredBy);
    foreach(JSONValue cmd; cmds.save)
    {
        import std.process;
        import std.stdio;
        import std.conv:to;

        if(hasLogLevel(LogLevel.verbose))
            vlog("Executing: ", executeShell("echo "~cmd.str, environment.toAA).output);

        auto status = wait(spawnShell(cmd.str, stdin, stdout, stderr, environment.toAA, Config.none, c.workingDir));
        if(status)
            throw new Exception("preGenerateCommand '"~cmd.str~"' exited with code "~status.to!string);
    }
    req.cfg.preGenerateCommands = req.cfg.preGenerateCommands.append(cmds);
}
void addPostGenerateCommands(ref BuildRequirements req, JSONStringArray cmds, ParseConfig c){req.cfg.postGenerateCommands = req.cfg.postGenerateCommands.append(cmds);}
void addPreBuildCommands(ref BuildRequirements req, JSONStringArray cmds, ParseConfig c){req.cfg.preBuildCommands = req.cfg.preBuildCommands.append(cmds);}
void addPostBuildCommands(ref BuildRequirements req, JSONStringArray cmds, ParseConfig c){req.cfg.postBuildCommands = req.cfg.postBuildCommands.append(cmds);}
void addSourcePaths(ref BuildRequirements req, JSONStringArray paths, ParseConfig c)
{
    import std.array;
    if(c.firstRun) req.cfg.sourcePaths = cast(string[])paths.array;
    else req.cfg.sourcePaths.exclusiveMergePaths(paths);
}
void addSourceFiles(ref BuildRequirements req, JSONStringArray files, ParseConfig c){req.cfg.sourceFiles.exclusiveMerge(files);}
void addExcludedSourceFiles(ref BuildRequirements req, JSONStringArray files, ParseConfig c){req.cfg.excludeSourceFiles.exclusiveMerge(files);}
void addLibPaths(ref BuildRequirements req, JSONStringArray paths, ParseConfig c){req.cfg.libraryPaths.exclusiveMerge(paths);}
void addLibs(ref BuildRequirements req, JSONStringArray libs, ParseConfig c){req.cfg.libraries.exclusiveMerge(libs);}
void addVersions(ref BuildRequirements req, JSONStringArray vers, ParseConfig c){req.cfg.versions.exclusiveMerge(vers);}
void addDebugVersions(ref BuildRequirements req, JSONStringArray vers, ParseConfig c){req.cfg.debugVersions.exclusiveMerge(vers);}
void addLinkFlags(ref BuildRequirements req, JSONStringArray lFlags, ParseConfig c){req.cfg.linkFlags.exclusiveMerge(lFlags);}
void addDflags(ref BuildRequirements req, JSONStringArray dFlags, ParseConfig c){req.cfg.dFlags.exclusiveMerge(dFlags);}
void addDependency(
    ref BuildRequirements req, 
    ParseConfig c,
    string name, string version_, 
    BuildRequirements.Configuration subConfiguration, 
    string path,
    string visibility,
    PackageInfo* info,
    bool isOptional
)
{
    import std.path;
    import std.algorithm.searching:countUntil;
    if(path.length && !isAbsolute(path)) 
        path = buildNormalizedPath(c.workingDir, path);
    Dependency dep = dependency(name, path, version_, req.name, c.workingDir, subConfiguration, visibility, info, isOptional);
    vvlog("Added dependency ", dep.name, ":", dep.subPackage, " [", dep.version_, "] ", "to ", req.name);
    //If dependency already exists, use the existing one
    ptrdiff_t depIndex = countUntil!((a) => a.isSameAs(dep))(req.dependencies);
    if(depIndex == -1)
        req.dependencies~= dep;
    else
    {
        dep.subConfiguration = req.dependencies[depIndex].subConfiguration;
        // if(!req.dependencies[depIndex].isOptional) dep.isOptional = false;
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
    string visibilityStr,
    PackageInfo* info,
    bool isOptional
)
{
    string out_mainPackageName;
    string subPackage = getSubPackageInfoRequiredBy(name, requirementName, out_mainPackageName);

    ///Inside this same package (requirementName:subPackage or :subPackage)
    if(subPackage && (out_mainPackageName == requirementName || out_mainPackageName.length == 0))
        path = workingDir;

    Visibility visibility = Visibility.public_;
    if(visibilityStr) visibility = VisibilityFrom(visibilityStr);
    
    return Dependency(name, path, version_, subConfiguration, subPackage, visibility, info, isOptional);
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
        req.dependencies~= dependency(dependencyName, null, null, req.name, c.workingDir, BuildRequirements.Configuration(subConfigurationName, false), null, null, false);
    else
        req.dependencies[depIndex].subConfiguration = BuildRequirements.Configuration(subConfigurationName, false);
}
