module parsers.automatic;
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

    switch(extension(projectFile))
    {
        case ".json":  req = parsers.json.parse(projectFile, projectWorkingDir, compiler, null, subConfiguration, subPackage); break;
        case ".sdl":   req = parsers.sdl.parse(projectFile, projectWorkingDir, compiler, null, subConfiguration, subPackage); break;
        default: throw new Error("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }

    parsers.environment.setupEnvironmentVariablesForPackage(cast(immutable)req);
    req.cfg = parsers.environment.parseEnvironment(req.cfg);

    partiallyFinishBuildRequirements(req);
    
    return req;
}

/** 
 * This function finishes some parts of the build requirement:
 * - Transforms relative paths into absolute paths
 * After that, it makes possible to merge with other build requirements. But, it is not completely
 * finished. It still has to become a tree.
 * Params:
 *   req = Any build requirement
 */
private void partiallyFinishBuildRequirements(ref BuildRequirements req)
{
    import std.path;
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
        
    if(!isAbsolute(req.cfg.sourceEntryPoint)) 
        req.cfg.sourceEntryPoint = buildNormalizedPath(req.cfg.workingDir, req.cfg.sourceEntryPoint);

    import std.algorithm.sorting;
    sort!((Dependency a, Dependency b) => a.name < b.name)(req.dependencies);

}