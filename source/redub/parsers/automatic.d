module redub.parsers.automatic;
import redub.logging;
public import redub.buildapi;
static import redub.parsers.json;
static import redub.parsers.sdl;
static import redub.parsers.environment;

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
 * Returns: The build requirements to the project. Not recursive.
 */
BuildRequirements parseProject(
    string projectWorkingDir, 
    string compiler, 
    BuildRequirements.Configuration subConfiguration, 
    string subPackage, 
    string recipe
)
{
    import std.path;
    import std.file;
    import redub.package_searching.entry;
    if(!std.file.exists(projectWorkingDir))
        throw new Error("Directory "~projectWorkingDir~"' does not exists.");
    string projectFile = findEntryProjectFile(projectWorkingDir, recipe);
    BuildRequirements req;

    vlog("Parsing ", projectFile, " at ", projectWorkingDir, " with :",  subPackage, " -c ", subConfiguration.name);

    switch(extension(projectFile))
    {
        case ".sdl":   req = redub.parsers.sdl.parse(projectFile, projectWorkingDir, compiler, null, subConfiguration, subPackage); break;
        case ".json":  req = redub.parsers.json.parse(projectFile, projectWorkingDir, compiler, null, subConfiguration, subPackage); break;
        default: throw new Error("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }
    redub.parsers.environment.setupEnvironmentVariablesForPackage(cast(immutable)req);
    req.cfg = redub.parsers.environment.parseEnvironment(req.cfg);

    partiallyFinishBuildRequirements(req);
    
    return req;
}

/** 
 * This function finishes some parts of the build requirement:
 * - Merge pending configuration (this guarantees the order is always correct.)
 * - Transforms relative paths into absolute paths
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
    StringArrayRef[] toAbsolutize = [
        &req.cfg.importDirectories,
        &req.cfg.libraryPaths,
        &req.cfg.stringImportPaths,
        &req.cfg.sourcePaths,
        &req.cfg.excludeSourceFiles,
        &req.cfg.sourceFiles,
    ];

    foreach(arr; toAbsolutize)
        foreach(ref string dir; *arr)
            if(!isAbsolute(dir)) dir = buildNormalizedPath(req.cfg.workingDir, dir);

    if(req.cfg.importDirectories.length == 0)
        req.cfg.importDirectories = req.cfg.sourcePaths;
        
    if(!isAbsolute(req.cfg.sourceEntryPoint)) 
        req.cfg.sourceEntryPoint = buildNormalizedPath(req.cfg.workingDir, req.cfg.sourceEntryPoint);

    import std.algorithm.sorting;
    ///Sort dependencies for predictability
    sort!((Dependency a, Dependency b) => a.name < b.name)(req.dependencies);

}