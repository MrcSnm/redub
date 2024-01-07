module parsers.automatic;
public import buildapi;
static import parsers.json;

BuildRequirements parseProject(string projectWorkingDir, string subConfiguration="")
{
    import std.path;
    import package_searching.entry;
    string projectFile = findEntryProjectFile(projectWorkingDir);
    BuildRequirements req = BuildRequirements.init;
    switch(extension(projectFile))
    {
        case ".json":  req = parsers.json.parse(projectFile, subConfiguration); break;
        case null: break;
        default: throw new Error("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }
    finishBuildRequirements(req);
    return req;
}

private void finishBuildRequirements(ref BuildRequirements req)
{
    import std.path;
    if(!isAbsolute(req.cfg.outputDirectory))
        req.cfg.outputDirectory = buildNormalizedPath(req.cfg.workingDir, req.cfg.outputDirectory);

    foreach(ref string importDir; req.cfg.importDirectories)
        if(!isAbsolute(importDir)) importDir = buildNormalizedPath(req.cfg.workingDir, importDir);
    
    foreach(ref string libDir; req.cfg.libraryPaths)
        if(!isAbsolute(libDir)) libDir = buildNormalizedPath(req.cfg.workingDir, libDir);
        
    if(!isAbsolute(req.cfg.sourceEntryPoint)) 
        req.cfg.sourceEntryPoint = buildNormalizedPath(req.cfg.workingDir, req.cfg.sourceEntryPoint);

    
}