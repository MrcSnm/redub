module parsers.automatic;
public import buildapi;
static import parsers.json;

BuildRequirements parseProject(string projectWorkingDir, string subConfiguration="")
{
    import std.path;
    import package_searching.entry;
    string projectFile = findEntryProjectFile(projectWorkingDir);
    BuildRequirements req = BuildRequirements.defaultInit;
    switch(extension(projectFile))
    {
        case ".json":  req = parsers.json.parse(projectFile, subConfiguration); break;
        case null: break;
        default: throw new Error("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }
    partiallyFinishBuildRequirements(req);
    return req;
}

/** 
 * This function finishes some parts of the build requirement:
 * - Adds Have_ versions
 * - Transforms relative paths into absolute paths
 * After that, it makes possible to merge with other build requirements. But, it is not completely
 * finished. It still has to become a tree.
 * Params:
 *   req = Any build requirement
 */
private void partiallyFinishBuildRequirements(ref BuildRequirements req)
{
    import std.path;
    {
        BuildConfiguration toMerge = BuildConfiguration.defaultInit;
        foreach(dep; req.dependencies)
            toMerge.versions~= "Have_"~dep.name;
        req.cfg = req.cfg.mergeVersions(toMerge);
    }
        

    if(!isAbsolute(req.cfg.outputDirectory))
        req.cfg.outputDirectory = buildNormalizedPath(req.cfg.workingDir, req.cfg.outputDirectory);

    foreach(ref string importDir; req.cfg.importDirectories)
        if(!isAbsolute(importDir)) importDir = buildNormalizedPath(req.cfg.workingDir, importDir);
    
    foreach(ref string libDir; req.cfg.libraryPaths)
        if(!isAbsolute(libDir)) libDir = buildNormalizedPath(req.cfg.workingDir, libDir);
        
    if(!isAbsolute(req.cfg.sourceEntryPoint)) 
        req.cfg.sourceEntryPoint = buildNormalizedPath(req.cfg.workingDir, req.cfg.sourceEntryPoint);

}