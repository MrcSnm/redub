module parsers.automatic;
import logging;
public import buildapi;
static import parsers.json;
static import parsers.sdl;
static import parsers.environment;

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
    import package_searching.entry;
    if(!std.file.exists(projectWorkingDir))
        throw new Error("Directory "~projectWorkingDir~"' does not exists.");
    string projectFile = findEntryProjectFile(projectWorkingDir, recipe);
    BuildRequirements req;

    vlog("Parsing ", projectFile, " at ", projectWorkingDir, " with :",  subPackage, " -c ", subConfiguration.name);

    switch(extension(projectFile))
    {
        case ".sdl":   req = parsers.sdl.parse(projectFile, projectWorkingDir, compiler, null, subConfiguration, subPackage); break;
        case ".json":  req = parsers.json.parse(projectFile, projectWorkingDir, compiler, null, subConfiguration, subPackage); break;
        default: throw new Error("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }
    parsers.environment.setupEnvironmentVariablesForPackage(cast(immutable)req);
    req.cfg = parsers.environment.parseEnvironment(req.cfg);

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