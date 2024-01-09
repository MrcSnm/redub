module parsers.automatic;
public import buildapi;
static import parsers.json;

BuildRequirements parseProject(string projectWorkingDir, string subConfiguration="", string subPackage="")
{
    import std.stdio;
    import std.path;
    import package_searching.entry;
    string projectFile = findEntryProjectFile(projectWorkingDir);
    BuildRequirements req = BuildRequirements.defaultInit;

    switch(extension(projectFile))
    {
        case ".json":  req = parsers.json.parse(projectFile, subConfiguration, subPackage); break;
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
        {
            import std.string:replace;
            string ver = "Have_"~dep.name.replace("-", "_");
            if(dep.subPackage) ver~= "_"~dep.subPackage;
            toMerge.versions~= ver;

        }
        req.cfg = req.cfg.mergeVersions(toMerge);
    }
        

    if(!isAbsolute(req.cfg.outputDirectory))
        req.cfg.outputDirectory = buildNormalizedPath(req.cfg.workingDir, req.cfg.outputDirectory);

    alias StringArrayRef = string[]*;
    StringArrayRef[] toAbsolutize = [
        &req.cfg.importDirectories,
        &req.cfg.libraryPaths,
        &req.cfg.stringImportPaths
    ];

    foreach(arr; toAbsolutize)
        foreach(ref string dir; *arr)
            if(!isAbsolute(dir)) dir = buildNormalizedPath(req.cfg.workingDir, dir);
        
    if(!isAbsolute(req.cfg.sourceEntryPoint)) 
        req.cfg.sourceEntryPoint = buildNormalizedPath(req.cfg.workingDir, req.cfg.sourceEntryPoint);

}