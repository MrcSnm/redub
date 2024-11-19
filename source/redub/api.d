module redub.api;
import redub.cli.dub;
import redub.logging;
import redub.tree_generators.dub;
import redub.command_generators.automatic;
public import redub.cli.dub: ParallelType, Inference;
public import redub.parsers.environment;
public import std.system;
public import redub.buildapi;
public import redub.compiler_identification;

struct ProjectDetails
{
    ProjectNode tree;
    Compiler compiler;
    ParallelType parallelType;
    CompilationDetails cDetails;
    bool useExistingObjFiles;
    ///Makes the return code 0 for when using print commands.
    bool printOnly;
    int externalErrorCode = int.min;
    bool forceRebuild;

    bool error() const {return this == ProjectDetails.init; }

    bool usesExternalErrorCode() const { return this.printOnly && externalErrorCode != int.min; }

    int getReturnCode()
    {
        if(error) return 1;
        else if(usesExternalErrorCode) return externalErrorCode;
        return 0;
    }

    void getLinkerFiles(out string[] output) const {putLinkerFiles(tree, output);}
    void getSourceFiles(out string[] output) const {putSourceFiles(tree, output);}

    string getCacheOutputDir(CompilingSession s) const
    {
        import redub.building.cache;
        import std.path;
        string hash = hashFrom(tree.requirements, s);
        return buildNormalizedPath(getCacheFolder, hash);
    }

    /**
    *   Returns whatever this project is supposed to produce [.wasm, .exe, .dll, .lib, .so, ]
    */
    string getOutputFile()
    {
        import std.path;
        import redub.command_generators.commons;

        return buildNormalizedPath(
            tree.requirements.cfg.outputDirectory,
            getOutputName(tree.requirements.cfg.targetType, tree.targetName, osFromArch(cDetails.arch), isaFromArch(cDetails.arch))
        );
    }
}

/** 
 * CompilationDetails are required for making proper compilation.
 */
struct CompilationDetails
{
    ///This is the only required member of this struct. Must be a path to compiler or a compiler in the global context, i.e: `dmd`
    string compilerOrPath;
    ///Arch is only being used for LDC2 compilers. If arch is used, ldc2 is automatically inferred
    string arch;
    ///Assumption to make dependency resolution slightly faster
    string assumption;
    ///Makes the build incremental or not
    Inference incremental;
    ///Makes the build use existing files
    bool useExistingObj;
    ///Whether the build should force single project
    bool combinedBuild;
    ///Whether the build should be fully parallel, simple, no or inferred
    ParallelType parallelType;
    /**
    *  Whenever true, it will parse the environment and merge with the configurations with the project.
    *  Details on that can be found on redub.parsers.environment.parse()
    *  This flag is currently used only for plugin building.
    */
    bool includeEnvironmentVariables = true;
}
/** 
 * Project in which should be parsed.
 */
struct ProjectToParse
{
    ///Optinal configuration to build
    string configuration;
    ///If working directory is null, std.file.getcwd() is used
    string workingDir;
    ///Optional subpackage to build
    string subPackage;
    ///Optinal recipe to use instead of workingDir's dub.json
    string recipe;
    ///Optional single argument. Used for parsing D files
    bool isSingle;
    ///Optional single argument. Used for not running preGenerate commands
    bool isDescribeOnly;
}



auto timed(T)(scope T delegate() action)
{
    import std.datetime.stopwatch;
    StopWatch sw = StopWatch(AutoStart.yes);
    static struct Value
    {
        T value;
        long msecs;
    }
    Value ret = Value(action());
    ret.msecs = sw.peek.total!"msecs";
    return ret;
}

ParallelType inferParallel(ProjectDetails d)
{
    if(d.parallelType == ParallelType.auto_)
    {
        if(d.tree.collapse.length == 1)
            return ParallelType.no;
        if(d.tree.isFullyParallelizable)
            return ParallelType.full;
        return ParallelType.leaves;
    }
    return d.parallelType;
}

class RedubException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }
}
class BuildException : Exception
{
    this(string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(null, file, line, nextInChain );
    }
}

/** 
 * Unchanged Files can't deal with directories at that moment.
 * Params:
 *   root = The root of the project
 */
string[] getChangedBuildFiles(ProjectNode root, CompilingSession s)
{
    import std.file;
    import std.path;
    import std.algorithm.iteration;
    import std.array : array;
    import redub.command_generators.commons;
    if(!root.isRoot)
        throw new RedubException("Can only exclude unchanged files from root at this moment.");

    string depsPath = getDepsFilePath(root, s);
    if(!exists(depsPath))
        return null;
    const string[] dirtyFiles = filter!((string f) => !f.isDir)(root.getDirtyFiles()).array;
    if(dirtyFiles.length == 0)
        return null;

    import d_depedencies;

    //TODO: Improve that
    ModuleParsing moduleParse = parseDependencies(std.file.readText(depsPath), 
        buildNormalizedPath("/Library/D/dmd")
    );

    string[] buildFiles = map!((ModuleDef def) => def.modPath)(moduleParse.findDependees(dirtyFiles)).array;
    if(hasLogLevel(LogLevel.verbose))
        warnTitle("Project files to rebuild: ", buildFiles);
    return buildFiles;
}


ProjectDetails buildProject(ProjectDetails d)
{
    import redub.building.compile;
    import redub.building.cache;
    import redub.command_generators.commons;
    import redub.misc.console_control_handler;

    if(!d.tree)
        return d;

    CompilingSession session = CompilingSession(d.compiler, osFromArch(d.cDetails.arch), isaFromArch(d.tree.requirements.cfg.arch));

    if(d.forceRebuild)
    {
        if(!cleanProject(d, false))
            throw new RedubException("Could not clean project ", d.tree.name);
        d.tree.invalidateCacheOnTree();
    }
    else
        invalidateCaches(d.tree,session);
    ProjectNode tree = d.tree;
    if(d.useExistingObjFiles)
        tree.requirements.cfg.changedBuildFiles = getChangedBuildFiles(tree, session);
    startHandlingConsoleControl();

    auto result = timed(()
    {
        switch(inferParallel(d))
        {
            case ParallelType.full:
                return buildProjectFullyParallelized(tree, session);
            case ParallelType.leaves:
                return buildProjectParallelSimple(tree, session);
            case ParallelType.no:
                return buildProjectSingleThread(tree, session);
            default: 
                throw new RedubException(`Unsupported parallel type in this step.`);
        }
    });
    bool buildSucceeded = result.value;
    if(!buildSucceeded)
        throw new BuildException();
    infos("Finished ", d.tree.name, " - ", result.msecs, "ms - To force a rebuild of up-to-date targets, run again with --force");

    return d;
}



bool cleanProject(ProjectDetails d, bool showMessages)
{
    import std.file;
    import std.path;
    import redub.command_generators.commons;

    static void removeFile(string filePath, bool show,  string message = null)
    {
        if(std.file.exists(filePath))
        {
            if(show)
            {
                if(message)
                    vlog(message);
                else
                    vlog("Removing ", filePath);
            }
            if(std.file.isFile(filePath))
                std.file.remove(filePath);
            else
                std.file.rmdirRecurse(filePath);
        }
    }
    
    auto res = timed(()
    {
        import std.typecons;
        if(showMessages)
            info("Cleaning project ", d.tree.name);
        foreach(ProjectNode node; d.tree.collapse)
        {

            foreach(type; [tuple("", node.requirements.cfg.targetType), tuple("-test-library", TargetType.executable)])
            {
                string output = node.getOutputName(type[1], os);
                {
                    string ext = extension(output);
                    string base = baseName(output, ext);
                    output = buildNormalizedPath(dirName(output), base~type[0]~ext);
                }
                foreach(ext; ["", getObjectExtension(os)])
                {
                    if(ext.length)
                        output = output.setExtension(ext);
                    removeFile(output, showMessages);
                }

                version(Windows)
                {
                    if(type[1].isLinkedSeparately)
                    {
                        foreach(ext; [".ilk", ".pdb"])
                        {
                            removeFile(output.setExtension(ext), showMessages);
                        }
                    }
                }
            }

            removeFile(buildNormalizedPath(node.requirements.cfg.workingDir, "dub.sdl.redub_cache_json"), showMessages, "Removing redub json cache file");
            removeFile(buildNormalizedPath(node.requirements.cfg.workingDir, ".ldc2_cache"), showMessages, "Removing ldc2 cache");
            foreach(copiedFile; node.requirements.cfg.filesToCopy)
            {
                string outFile = buildNormalizedPath(d.tree.requirements.cfg.outputDirectory, isAbsolute(copiedFile) ? baseName(copiedFile) : copiedFile);
                removeFile(outFile, showMessages);
            }
        }
        

        import redub.building.cache;
        
        string hash = hashFrom(d.tree.requirements, CompilingSession(d.compiler, osFromArch(d.cDetails.arch), isaFromArch(d.cDetails.arch)));
        string cacheOutput = buildNormalizedPath(getCacheFolder, hash);
        string cacheFile = getCacheFilePath(hash);

        removeFile(cacheOutput, showMessages, "Removing cache output dir "~cacheOutput);
        removeFile(cacheFile, showMessages, "Removing cache reference file" ~ cacheFile);

        return true;
    });

    if(showMessages)
        info("Finished cleaning project in ", res.msecs, "ms");
    return res.value;
}
/** 
 * Use this function to get a project information.
 * Params:
 *   invalidateCache = Should invalidate cache or should auto check
 *   os = Target operating system
 *   cDetails = CompilationDetails, receives, the compiler to be inferred, architecture and assumptions
 *   proj = Detailed information in which project to parse. Most of the time, workingDir is the most important part.
 *   dubVars = InitialDubVariables to setup on the project
 * Returns: Completely resolved project, with all its necessary flags and and paths, but still, the directory will be iterated on compilation searching for source files.
 */
ProjectDetails resolveDependencies(
    bool invalidateCache,
    const OS os = std.system.os,
    CompilationDetails cDetails = CompilationDetails.init,
    ProjectToParse proj = ProjectToParse.init,
    InitialDubVariables dubVars = InitialDubVariables.init,
    BuildType buildType = BuildType.debug_
)
{
    import std.datetime.stopwatch;
    import redub.building.cache;
    import std.algorithm.comparison;
    import redub.command_generators.commons;
    static import redub.parsers.single;
    static import redub.parsers.automatic;
    static import redub.parsers.environment;
    static import redub.parsers.build_type;

    StopWatch st = StopWatch(AutoStart.yes);
    Compiler compiler = getCompiler(cDetails.compilerOrPath, cDetails.assumption);

    with(dubVars)
    {
        import std.conv:to;
        DUB = either(DUB, "redub");
        DUB_EXE = DUB;
        DUB_CONFIG = either(DUB_CONFIG, proj.configuration);
        DUB_BUILD_TYPE = buildType;

        DUB_COMBINED = redub.parsers.environment.str(cDetails.combinedBuild);
        DC = either(DC, compiler.binOrPath);
        DC_BASE = either(DC_BASE, compiler.binOrPath);
        DUB_ARCH = either(DUB_ARCH, cDetails.arch, isaFromArch(cDetails.arch).to!string);
        DUB_PLATFORM = either(DUB_PLATFORM, redub.parsers.environment.str(os));
        DUB_FORCE = either(DUB_FORCE, redub.parsers.environment.str(invalidateCache));
    }
    redub.parsers.environment.setupBuildEnvironmentVariables(dubVars);
    CompilationInfo cInfo = CompilationInfo(compiler.getCompilerString, cDetails.arch, osFromArch(cDetails.arch), isaFromArch(cDetails.arch), compiler.binOrPath);
    if(proj.workingDir == null)
    {
        import std.file;
        proj.workingDir = std.file.getcwd;
    }


    BuildRequirements req;
    if(proj.isSingle)
        req = redub.parsers.single.parseProject(
            proj.workingDir,
            cInfo,
            BuildRequirements.Configuration(proj.configuration, false),
            proj.subPackage,
            proj.recipe,
            true,
            null,
            cDetails.useExistingObj
        );
    else
        req = redub.parsers.automatic.parseProject(
            proj.workingDir,
            cInfo,
            BuildRequirements.Configuration(proj.configuration, false),
            proj.subPackage,
            proj.recipe,
            true,
            null,
            cDetails.useExistingObj,
            proj.isDescribeOnly
        );
    redub.parsers.environment.setupEnvironmentVariablesForRootPackage(cast(immutable)req);
    if(cDetails.includeEnvironmentVariables)
        req.cfg = req.cfg.merge(redub.parsers.environment.parse());

    req.cfg = req.cfg.merge(redub.parsers.build_type.parse(buildType, compiler.compiler));

    ProjectNode tree = getProjectTree(req, cInfo);

    if(cDetails.combinedBuild)
        tree.combine();
    compiler.usesIncremental = isIncremental(cDetails.incremental, tree);
    redub.parsers.environment.setupEnvironmentVariablesForPackageTree(tree);


    import redub.libs.colorize;
    import redub.package_searching.dub;
    import std.conv:to;
    ProjectDetails ret = ProjectDetails(tree, compiler, cDetails.parallelType, cDetails, cDetails.useExistingObj, false, 0, invalidateCache);

    foreach(pkg; fetchedPackages)
    {
        infos("Fetch Success: ", pkg.name, " v",pkg.version_, " required by ", pkg.reqBy);
    }


    infos(
        "Dependencies resolved", " - ", (st.peek.total!"msecs"), " ms \"",
        color(buildType, fg.magenta),"\" using ", compiler.binOrPath," v", compiler.version_,
        color(" ["~ cInfo.targetOS.to!string~ "-"~cInfo.isa.to!string~ "]", fg.light_cyan),
        " - ", color(inferParallel(ret).to!string~" parallel", fg.light_green)
    );
    return ret;
}


/** 
 * 
 * Params:
 *   incremental = If auto, it will disable incremental when having more than 3 compilation units
 *   tree = The tree to find compilation units 
 * Returns: 
 */
bool isIncremental(Inference incremental, ProjectNode tree)
{
    final switch(incremental)
    {
        case Inference.auto_: return tree.collapse.length < 3;
        case Inference.on: return true;
        case Inference.off: return false;
    }
}

string getDubWorkspacePath()
{
    import std.path;
    import std.process;

    version (Windows)
        return buildNormalizedPath(environment["LOCALAPPDATA"], "dub");
    else
        return buildNormalizedPath(environment["HOME"], ".dub");
}