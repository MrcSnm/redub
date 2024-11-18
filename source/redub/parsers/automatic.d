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
 *   compiler = Which compiler to use
 *   subConfiguration = Sub configuration to use
 *   subPackage = Optional sub package
 *   recipe = Optional recipe to read. It's path is not used as root.
 *   targetOS = Will be used to filter out some commands
 *   isa = Instruction Set Architexture to use for filtering commands
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
    bool isRoot = false,
    string version_ = null,
    bool useExistingObj = false,
    bool isDescribeOnly = false
)
{
    import std.path;
    import std.file;
    import redub.package_searching.entry;
    if(!std.file.exists(projectWorkingDir))
        throw new Exception("Directory '"~projectWorkingDir~"' does not exists.");
    string projectFile = findEntryProjectFile(projectWorkingDir, recipe);
    BuildRequirements req;

    vlog("Parsing ", projectFile, " at ", projectWorkingDir, " with :",  subPackage, " -c ", subConfiguration.name);

    switch(extension(projectFile))
    {
        case ".sdl":   req = redub.parsers.sdl.parse(projectFile, projectWorkingDir, cInfo, null, version_, subConfiguration, subPackage, isDescribeOnly, isRoot); break;
        case ".json":  req = redub.parsers.json.parse(projectFile, projectWorkingDir, cInfo, null, version_, subConfiguration, subPackage, "", isDescribeOnly, isRoot); break;
        default: throw new Exception("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }
    return postProcessBuildRequirements(req, cInfo, isRoot, useExistingObj);
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
BuildRequirements postProcessBuildRequirements(BuildRequirements req, CompilationInfo cInfo, bool isRoot, bool useExistingObj)
{
    redub.parsers.environment.setupEnvironmentVariablesForPackage(req.cfg);
    req.cfg.arch = cInfo.arch;
    if(isRoot && useExistingObj)
        req.cfg.outputsDeps = true;

    partiallyFinishBuildRequirements(req);
    ///Merge need to happen after partial finish, since other configuration will be merged
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
private void partiallyFinishBuildRequirements(ref BuildRequirements req)
{
    import std.path;
    req = req.mergePending();
    if(!isAbsolute(req.cfg.outputDirectory))
        req.cfg.outputDirectory = buildNormalizedPath(req.cfg.workingDir, req.cfg.outputDirectory);

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
                dir = buildNormalizedPath(req.cfg.workingDir, dir);
        }
    }


    import std.algorithm.iteration;
    auto libraries = req.cfg.sourceFiles.filter!((name) => name.extension.isLibraryExtension);
    req.cfg.libraries.exclusiveMergePaths(libraries);

    ///Remove libraries from the sourceFiles.
    req.cfg.sourceFiles = inPlaceFilter(req.cfg.sourceFiles, (string file) => !file.extension.isLibraryExtension);


    //Unused
    // if(!isAbsolute(req.cfg.sourceEntryPoint))
        // req.cfg.sourceEntryPoint = buildNormalizedPath(req.cfg.workingDir, req.cfg.sourceEntryPoint);


    import std.algorithm.sorting;
    ///Sort dependencies for predictability
    sort!((Dependency a, Dependency b) => a.name < b.name)(req.dependencies);
    sort!((Dependency a, Dependency b) => !a.subConfiguration.isDefault && b.subConfiguration.isDefault)(req.dependencies);

}