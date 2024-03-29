module redub.api;
import redub.logging;
import redub.tree_generators.dub;
import redub.parsers.automatic;
import redub.command_generators.automatic;
public import redub.parsers.environment;
public import std.system;
public import redub.buildapi;
public import redub.compiler_identification;

struct ProjectDetails
{
    ProjectNode tree;
    Compiler compiler;
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


ProjectDetails buildProject(ProjectDetails d)
{
    import redub.building.compile;
    import redub.command_generators.commons;

    if(!d.tree)
        return d;

    ProjectNode tree = d.tree;
    OS targetOS = osFromArch(tree.requirements.cfg.arch);

    auto result = timed(()
    {
        if(tree.isFullyParallelizable)
        {
            info("Project ", tree.name," is fully parallelizable! Will build everything at the same time");
            return buildProjectFullyParallelized(tree, d.compiler, targetOS); 
        }
        else
            return buildProjectParallelSimple(tree, d.compiler, targetOS); 
    });
    bool buildSucceeded = result.value;
    if(!buildSucceeded)
        throw new Error("Build failure");
    info("Built project in ", result.msecs, " ms.");

    return d;
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
    OS os = std.system.os,
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
    static import redub.parsers.environment;
    static import redub.parsers.build_type;

    StopWatch st = StopWatch(AutoStart.yes);
    Compiler compiler = getCompiler(cDetails.compilerOrPath, cDetails.assumption);

    with(dubVars)
    {
        DUB = either(DUB, "redub");
        DUB_CONFIG = either(DUB_CONFIG, proj.configuration);
        DC_BASE = either(DC_BASE, compiler.binOrPath);
        DUB_ARCH = either(DUB_ARCH, cDetails.arch);
        DUB_PLATFORM = either(DUB_PLATFORM, redub.parsers.environment.str(os));
        DUB_FORCE = either(DUB_FORCE, redub.parsers.environment.str(invalidateCache));
    }

    redub.parsers.environment.setupBuildEnvironmentVariables(dubVars);
    BuildRequirements req = parseProject(
        proj.workingDir, 
        compiler.getCompilerString,
        cDetails.arch, 
        BuildRequirements.Configuration(proj.configuration, false), 
        proj.subPackage,
        proj.recipe,
        osFromArch(cDetails.arch)
    );
    redub.parsers.environment.setupEnvironmentVariablesForRootPackage(cast(immutable)req);
    req.cfg = req.cfg.merge(redub.parsers.environment.parse());
    req.cfg = req.cfg.merge(redub.parsers.build_type.parse(buildType, compiler.compiler));

    ProjectNode tree = getProjectTree(req, CompilationInfo(compiler.getCompilerString, cDetails.arch, osFromArch(cDetails.arch)));
    redub.parsers.environment.setupEnvironmentVariablesForPackageTree(tree);

    if(invalidateCache)
        tree.invalidateCacheOnTree();
    else 
        invalidateCaches(tree, compiler, osFromArch(cDetails.arch));
    import redub.libs.colorize;
    
    infos("Dependencies resolved ", "in ", (st.peek.total!"msecs"), " ms for \"", color(buildType, fg.magenta),"\" using ", compiler.binOrPath);
    return ProjectDetails(tree, compiler);
}