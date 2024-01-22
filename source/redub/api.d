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

struct CompilationDetails
{
    string compilerOrPath;
    string arch;
    string assumption;
}

struct ProjectToParse
{
    string configuration;
    string workingDir;
    string subPackage;
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
    import std.system;

    if(!d.tree)
        return d;

    ProjectNode tree = d.tree;

    auto result = timed(()
    {
        if(tree.isFullyParallelizable)
        {
            info("Project ", tree.name," is fully parallelizable! Will build everything at the same time");
            return buildProjectFullyParallelized(tree, d.compiler, os); 
        }
        else
            return buildProjectParallelSimple(tree, d.compiler, os); 
    });
    bool buildSucceeded = result.value;
    if(!buildSucceeded)
        throw new Error("Build failure");
    info("Built project in ", result.msecs, " ms.");

    return d;
}


ProjectDetails resolveDependencies(
    bool invalidateCache,
    OS os = std.system.os,
    CompilationDetails cDetails = CompilationDetails.init,
    ProjectToParse proj = ProjectToParse.init,
    InitialDubVariables dubVars = InitialDubVariables.init
)
{
    import std.datetime.stopwatch;
    import redub.building.cache;
    static import redub.parsers.environment;

    StopWatch st = StopWatch(AutoStart.yes);
    Compiler compiler = getCompiler(cDetails.compilerOrPath, cDetails.assumption);

    if(dubVars == InitialDubVariables.init)
    {
        with(dubVars)
        {
            DUB_CONFIG = proj.configuration;
            DC_BASE = compiler.binOrPath;
            DUB_ARCH = cDetails.arch;
            DUB_PLATFORM = redub.parsers.environment.str(os);
            DUB_FORCE = redub.parsers.environment.str(invalidateCache);
        }
    }
    redub.parsers.environment.setupBuildEnvironmentVariables(dubVars);
    BuildRequirements req = parseProject(
        proj.workingDir, 
        compiler.getCompilerString, 
        BuildRequirements.Configuration(proj.configuration, false), 
        proj.subPackage, 
        proj.recipe
    );
    redub.parsers.environment.setupEnvironmentVariablesForRootPackage(cast(immutable)req);
    req.cfg = req.cfg.merge(redub.parsers.environment.parse());

    ProjectNode tree = getProjectTree(req, compiler.getCompilerString);
    redub.parsers.environment.setupEnvironmentVariablesForPackageTree(tree);

    if(invalidateCache)
        tree.invalidateCacheOnTree();
    else 
        invalidateCaches(tree, compiler);
    
    info("Dependencies resolved in ", (st.peek.total!"msecs"), " ms.") ;
    return ProjectDetails(tree, compiler);
}