module redub.parsers.automatic;
import redub.logging;
public import redub.buildapi;
public import std.system;
static import redub.parsers.json;
static import redub.parsers.sdl;
static import redub.parsers.environment;
import redub.command_generators.commons;

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
 * Returns: The build requirements to the project. Not recursive.
 */
BuildRequirements parseProject(
    string projectWorkingDir, 
    string compiler, 
    string arch,
    BuildRequirements.Configuration subConfiguration, 
    string subPackage, 
    string recipe,
    OS targetOS,
    ISA isa,
    bool isRoot = false,
    string version_ = null
)
{
    import std.path;
    import std.file;
    import redub.package_searching.entry;
    if(!std.file.exists(projectWorkingDir))
        throw new Exception("Directory "~projectWorkingDir~"' does not exists.");
    string projectFile = findEntryProjectFile(projectWorkingDir, recipe);
    BuildRequirements req;

    vlog("Parsing ", projectFile, " at ", projectWorkingDir, " with :",  subPackage, " -c ", subConfiguration.name);

    switch(extension(projectFile))
    {
        case ".sdl":   req = redub.parsers.sdl.parse(projectFile, projectWorkingDir, compiler, arch, version_, subConfiguration, subPackage, targetOS, isa, isRoot); break;
        case ".json":  req = redub.parsers.json.parse(projectFile, projectWorkingDir, compiler, arch, version_, subConfiguration, subPackage, targetOS, isa, isRoot); break;
        default: throw new Exception("Unsupported project type "~projectFile~" at dir "~projectWorkingDir);
    }

    redub.parsers.environment.setupEnvironmentVariablesForPackage(req.cfg);
    req.cfg = redub.parsers.environment.parseEnvironment(req.cfg);
    req.cfg.arch = arch;
    if(isRoot)
        req.cfg.outputsDeps = true;

    partiallyFinishBuildRequirements(req);
    
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