module redub.parsers.automatic;
import redub.logging;
public import redub.buildapi;
public import std.system;
static import redub.parsers.json;
static import redub.parsers.sdl;
static import redub.parsers.environment;
import redub.command_generators.commons;
import redub.tree_generators.dub;

/** 
 * Parses an initial directory, not recursively. Currently only .sdl and .json are parsed.
 * After the parse happens, it also partially finish the requirements by using a generalized fix
 * for after the parsing stage.
 * Params:
 *   projectWorkingDir = Optional working dir. What is the root being considered for the recipe file
 *   cInfo = Important compilation info for that project
 *   subConfiguration = Sub configuration to use
 *   subPackage = Optional sub package
 *   recipe = Optional recipe to read. It's path is not used as root.
 *   parentName = Used whenever parseProject is called for a sub package.
 *   isRoot = When the package is root, it is added to the package searching cache automatically with version 0.0.0
 *   version = The actual version of that project, may be null on root
 *   useExistingObj = Makes the project output dependencies if it is a root project. Disabled by default since compilation may be way slower
 *   isDescribeOnly = Do not execute preGenerate commands when true
 * Returns: The build requirements to the project. Not recursive.
 */
BuildRequirements parseProject(
    string projectWorkingDir, 
    CompilationInfo cInfo,
    BuildRequirements.Configuration subConfiguration,
    string subPackage, 
    string recipe,
    string parentName = "",
    bool isRoot = false,
    string version_ = null,
    bool useExistingObj = false,
    bool isDescribeOnly = false
)
{
    import std.path;
    import std.file;
    import redub.package_searching.entry;
    string projectFile = findEntryProjectFile(projectWorkingDir, recipe);
    if(!projectFile)
        throw new Exception("Directory '"~projectWorkingDir~"' has no recipe or does not exists.");
    BuildRequirements req;

    if(getLogLevel() >= LogLevel.verbose)
    {
        import std.string;
        if(projectFile.startsWith(projectWorkingDir))
            vlog("Parsing ", projectFile);
        else
            vlog("Parsing ", projectFile, " at ", projectWorkingDir);
        if(subPackage)
            vlog("\tSubPackage: ", subPackage);
        if(subConfiguration.name)
            vlog("\tConfiguration: ", subConfiguration.name);
    }

    BuildConfiguration pending;
    switch(extension(projectFile))
    {
        case ".sdl":   req = redub.parsers.sdl.parse(projectFile, projectWorkingDir, cInfo, null, version_, subConfiguration, subPackage, pending, parentName, isDescribeOnly, isRoot); break;
        case ".json":  req = redub.parsers.json.parse(projectFile, projectWorkingDir, cInfo, null, version_, subConfiguration, subPackage, pending, parentName, isDescribeOnly, isRoot); break;
        default: throw new Exception("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }
    return postProcessBuildRequirements(req, pending, cInfo, isRoot, useExistingObj);
}

/** 
 * Used mostly to check the name of a package in the local directory and decide what to build
 * Params:
 *   projectWorkingDir = The working dir on where to get the package name
 *   recipe = The actual recipe to read
 * Returns: The found package name
 */
string getPackageName(string projectWorkingDir, string recipe)
{
    import redub.package_searching.entry;
    import std.path;
    string projectFile = findEntryProjectFile(projectWorkingDir, recipe);
    if(!projectFile)
        throw new Exception("Directory '"~projectWorkingDir~"' has no recipe or does not exists.");
    switch(extension(projectFile))
    {
        case ".sdl":   return redub.parsers.sdl.getPackageName(projectFile); break;
        case ".json":  return redub.parsers.json.getPackageName(projectFile); break;
        default: throw new Exception("Unsupported project type "~projectFile);
    }
}

/**
 * Post process for the parseProject operation.
 * Required for merge pending configuration, setup environment variables, parse environment variables inside its content
 * and define its current arch
 * Params:
 *   req = Input requirement
 *   cInfo = Compilation Info for setting the configuration arch
 *   isRoot = Decides whether to output objects or not
 *   useExistingObj = Decides whether to output objects or not
 * Returns: Post processed build requirements and now ready to use
 */
BuildRequirements postProcessBuildRequirements(BuildRequirements req, BuildConfiguration pending, CompilationInfo cInfo, bool isRoot, bool useExistingObj)
{
    req.cfg.arch = cInfo.arch;
    req.extra.isRoot = isRoot;
    if(isRoot && useExistingObj)
        req.cfg.flags|= BuildConfigurationFlags.outputsDeps;

    partiallyFinishBuildRequirements(req, pending);    ///Merge need to happen after partial finish, since other configuration will be merged
    req.cfg = redub.parsers.environment.parseEnvironment(req.cfg);
    return req;
}

/** 
 * This function finishes some parts of the build requirement:
 * - Merge pending configuration (this guarantees the order is always correct.)
 * - Transforms relative paths into absolute paths
 * - Remove libraries from sourceFiles and put them onto libraries
 * - If no import directory exists, it will be reflected by source paths.
 * After that, it makes possible to merge with other build requirements. But, it is not completely
 * finished. It still has to become a tree.
 * Params:
 *   req = Any build requirement
 */
private void partiallyFinishBuildRequirements(ref BuildRequirements req, BuildConfiguration pending)
{
    import std.path;
    import std.algorithm.searching:startsWith;
    import redub.misc.path;
    req.cfg = req.cfg.merge(pending);
    if(!isAbsolute(req.cfg.outputDirectory))
        req.cfg.outputDirectory = redub.misc.path.buildNormalizedPath(req.cfg.workingDir, req.cfg.outputDirectory);

    alias StringArrayRef = string[]*;
    scope StringArrayRef[] toAbsolutize = [
        &req.cfg.importDirectories,
        &req.cfg.libraryPaths,
        &req.cfg.stringImportPaths,
        &req.cfg.sourcePaths,
        &req.cfg.excludeSourceFiles,
        &req.cfg.sourceFiles,
        &req.cfg.filesToCopy,
    ];

    foreach(arr; toAbsolutize)
    {
        foreach(ref string dir; *arr)
        {
            import redub.command_generators.commons : escapePath;
            if(!isAbsolute(dir)) 
                dir = redub.misc.path.buildNormalizedPath(req.cfg.workingDir, dir);
        }
    }

    for(int i = 1; i < req.cfg.sourcePaths.length; i++)
    {
        //[src, src/folder]
        //[src/folder, src]
        string pathRemoved;
        string specificPath;
        if(req.cfg.sourcePaths[i].length > req.cfg.sourcePaths[i-1].length &&
            req.cfg.sourcePaths[i].startsWith(req.cfg.sourcePaths[i-1]))
        {
            specificPath = req.cfg.sourcePaths[i];
            pathRemoved = req.cfg.sourcePaths[i-1];
            req.cfg.sourcePaths[i-1] = req.cfg.sourcePaths[$-1];
        }
        else if(req.cfg.sourcePaths[i-1].length > req.cfg.sourcePaths[i].length &&
                req.cfg.sourcePaths[i-1].startsWith(req.cfg.sourcePaths[i]))
        {
            specificPath = req.cfg.sourcePaths[i-1];
            pathRemoved = req.cfg.sourcePaths[i];
            req.cfg.sourcePaths[i] = req.cfg.sourcePaths[$-1];
        }
        if(pathRemoved !is null)
        {
            warn("Path ",pathRemoved," was removed from sourcePaths since a more specific path was specified [", specificPath,"] . Please use \"sourcePaths\": [] instead for removing that warn and be clear about your intention");
            req.cfg.sourcePaths.length--;
            i--;
        }
    }


    import std.algorithm.iteration;
    auto libraries = req.cfg.sourceFiles.filter!((name) => name.extension.isLibraryExtension);
    req.cfg.libraries.exclusiveMergePaths(libraries);

    ///Remove libraries from the sourceFiles.
    req.cfg.sourceFiles = inPlaceFilter(req.cfg.sourceFiles, (string file) => !file.extension.isLibraryExtension);



    import std.algorithm.sorting;
    ///Sort dependencies for predictability
    sort!((Dependency a, Dependency b)
    {
        if(a.name != b.name) return a.name < b.name;
        return !a.subConfiguration.isDefault && b.subConfiguration.isDefault;
    })(req.dependencies);

}



void clearRecipeCaches()
{
    redub.parsers.json.clearJsonRecipeCache();
    redub.parsers.sdl.clearSdlRecipeCache();
}