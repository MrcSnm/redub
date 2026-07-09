module redub.parsers.automatic;
import redub.logging;
public import redub.buildapi;
public import std.system;
static import redub.parsers.json;
static import redub.parsers.adapter.sdl;
static import redub.parsers.environment;
import redub.command_generators.commons;
import redub.tree_generators.dub;
import hip.data.json;

/**
 * Parses an initial directory, not recursively. Currently only .sdl and .json are parsed.
 * After the parse happens, it also partially finishes the requirements by using a generalized fix
 * for after the parsing stage.
 * Params:
 *   projectWorkingDir = Optional working dir. What is the root being considered for the recipe file
 *   cInfo = Important compilation info for that project
 *   subConfiguration = Sub configuration to use
 *   subPackage = Optional sub package
 *   recipe = Optional recipe to read. Its path is not used as root.
 *   version = The actual version of that project, may be null on root
 *   useExistingObj = Makes the project output dependencies if it is a root project. Disabled by default since compilation may be way slower
 *   isDescribeOnly = Do not execute preGenerate commands when true
 * Returns: The build requirements to the project. Not recursive.
 */
RootParseResult parseProject(
    string projectWorkingDir,
    ref CompilationInfo cInfo,
    BuildRequirements.Configuration subConfiguration,
    string subPackage,
    string recipe,
    string target,
    bool useExistingObj = false,
    bool isDescribeOnly = false
)
{
    import redub.parsers.base;
    import std.path;
    import std.file;
    import redub.package_searching.entry;
    string projectFile = findEntryProjectFile(projectWorkingDir, recipe);
    if(!projectFile)
        throw new Exception("Directory '"~projectWorkingDir~"' has no recipe or does not exists.");

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

    JSONValue projectJSON = getProjectJSON(projectFile, projectWorkingDir);
    return parseProject(projectJSON, projectWorkingDir, cInfo, subConfiguration, subPackage, target, useExistingObj, isDescribeOnly);
}

/**
 * Parses an initial directory, not recursively. Currently only .sdl and .json are parsed.
 * After the parse happens, it also partially finishes the requirements by using a generalized fix
 * for after the parsing stage.
 * Params:
 *   projectWorkingDir = Optional working dir. What is the root being considered for the recipe file
 *   cInfo = Important compilation info for that project
 *   subConfiguration = Sub configuration to use
 *   subPackage = Optional sub package
 *   version = The actual version of that project, may be null on root
 *   useExistingObj = Makes the project output dependencies if it is a root project. Disabled by default since compilation may be way slower
 *   isDescribeOnly = Do not execute preGenerate commands when true
 * Returns: The build requirements to the project. Not recursive.
 */
RootParseResult parseProject(
    JSONValue projectJSON,
    string projectWorkingDir,
    CompilationInfo cInfo,
    BuildRequirements.Configuration subConfiguration,
    string subPackage,
    string target,
    bool useExistingObj = false,
    bool isDescribeOnly = false
)
{
    import redub.parsers.base;

    RootParseResult result;

    ParseConfig cfg = getParseConfig(projectWorkingDir, cInfo, null, null, subConfiguration, subPackage, null, isDescribeOnly);

    if(target.length)
    {
        import redub.parsers.json;
        TargetInfo targetInfo = redub.parsers.json.getTarget(projectJSON, target, cfg);
        cfg = targetInfo.parseConfig;
        cInfo = cfg.cInfo;
        result.targetRequirement = postProcessBuildRequirements(targetInfo.targetRequirement, targetInfo.pending, cInfo, false, useExistingObj);
    }
    result.targetCompilationInfo = cInfo;
    BuildConfiguration pending;
    result.mainRequirement = redub.parsers.json.parse(projectJSON, cfg, pending, true);
    result.mainRequirement= postProcessBuildRequirements(result.mainRequirement, pending, cInfo, true, useExistingObj);

    return result;
}



/**
 * Parses an initial directory, not recursively. Currently only .sdl and .json are parsed.
 * After the parse happens, it also partially finishes the requirements by using a generalized fix
 * for after the parsing stage.
 * Params:
 *   projectWorkingDir = Optional working dir. What is the root being considered for the recipe file
 *   cInfo = Important compilation info for that project
 *   subConfiguration = Sub configuration to use
 *   subPackage = Optional sub package
 *   recipe = Optional recipe to read. Its path is not used as root.
 *   parentName = Used whenever parseProject is called for a sub package.
 *   isRoot = When the package is root, it is added to the package searching cache automatically with version 0.0.0
 *   isTarget = When the package is target, it propagates that isTarget flag for not merging the globals with themselves
 *   version = The actual version of that project, may be null on root
 *   useExistingObj = Makes the project output dependencies if it is a root project. Disabled by default since compilation may be way slower
 *   isDescribeOnly = Do not execute preGenerate commands when true
 * Returns: The build requirements to the project. Not recursive.
 */
BuildRequirements parseProjectCommon(
    string projectWorkingDir,
    const ref CompilationInfo cInfo,
    BuildRequirements.Configuration subConfiguration,
    string subPackage,
    string recipe,
    string parentName = "",
    bool isRoot = false,
    bool isTarget = false,
    string version_ = null,
    bool useExistingObj = false,
    bool isDescribeOnly = false
)
{
    import redub.parsers.base;
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
    ParseConfig cfg = getParseConfig(projectWorkingDir, cInfo, null, version_, subConfiguration, subPackage, parentName, isDescribeOnly);
    cfg.extra.isTarget = isTarget;

    JSONValue parseData = getProjectJSON(projectFile, projectWorkingDir);

    req = redub.parsers.json.parse(parseData, cfg, pending, false);
    return postProcessBuildRequirements(req, pending, cInfo, isRoot, useExistingObj);
}

JSONValue getProjectJSON(string projectFile, string projectWorkingDir)
{
    import std.path;
    switch(extension(projectFile))
    {
        case ".sdl":
            return redub.parsers.adapter.sdl.sdlToJSONCache(projectFile);
        case ".json":
            import redub.parsers.adapter.json_cache;
            return parseJSONCached(projectFile);
        default: throw new Exception("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }
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

    JSONValue parseData;
    bool hasInitData;

    switch(extension(projectFile))
    {
        case ".sdl":
            import redub.parsers.adapter.sdl;
            parseData = sdlToJSONCache(projectFile);
            hasInitData = true;
            goto case ".json";
        case ".json":  
            if(!hasInitData)
            {
                import redub.parsers.adapter.json_cache;
                parseData  = parseJSONCached(projectFile);
            }
            return redub.parsers.json.getPackageName(parseData);
        default: throw new Exception("Unsupported project type "~projectFile);
    }
}

/**
 * Post process for the parseProject operation.
 * Required to merge pending configuration, set up environment variables, parse environment variables inside its content,
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
    foreach(ref Dependency dep; req.dependencies)
    {
        dep.isTarget = req.extra.isTarget;
    }

    if(isRoot && useExistingObj)
        req.cfg.flags|= BuildConfigurationFlags.outputsDeps;

    req.cfg = redub.parsers.environment.parseEnvironment(req.cfg); //First pass in env parsing
    partiallyFinishBuildRequirements(req, pending);    ///Merge need to happen after partial finish, since other configuration will be merged

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
        &req.cfg.targetIcon
    ];

    foreach(arr; toAbsolutize)
    {
        foreach(ref string dir; *arr)
        {
            import redub.parsers.environment;
            dir = parseStringWithEnvironment(dir);
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
    req.cfg.libraries = req.cfg.libraries.exclusiveMergePaths(libraries);

    //importPaths will always contain sourcePath if it is using the default https://dub.pm/dub-reference/build_settings/#sourcepaths
    if(req.cfg.isUsingDefaultSourcePaths || req.cfg.importDirectories.length == 0)
        req.cfg.importDirectories.exclusiveMergePaths(req.cfg.sourcePaths);

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
    redub.parsers.adapter.sdl.clearSdlRecipeCache();
}