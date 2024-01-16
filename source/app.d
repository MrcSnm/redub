import std.algorithm:countUntil;
import std.conv:to;
import std.array;
import std.path;
import std.file;
import std.process;
import std.stdio;

import buildapi;
import parsers.automatic;
import tree_generators.dub;
import cli.dub;



string formatError(string err)
{
    import std.algorithm.searching:countUntil;
    if(err.countUntil("which cannot be read") != -1)
    {
        ptrdiff_t moduleNameStart = err.countUntil("`") + 1;
        ptrdiff_t moduleNameEnd = err[moduleNameStart..$].countUntil("`") + moduleNameStart;
        string moduleName = err[moduleNameStart..moduleNameEnd];

        return err~"\nMaybe you forgot to add the module '"~moduleName~"' source root to import paths?
        Dubv2 Failed!";
    }
    return err~"\nDubv2 Failed!";
}
/**
* DubV2 work with input -> output on each step. It must be almost stateless.
* ** CLI will be optionally implemented later. 
* ** Cache will be optionally implemented later
* 
* FindProject -> ParseProject -> MergeWithEnvironment -> ConvertToBuildFlags ->
* Build
*/
int main(string[] args)
{
    return buildMain(args);
}


int buildMain(string[] args)
{
    import std.getopt;
    import std.datetime.stopwatch;
    import std.system;
    import building.compile;
    import building.cache;
    import package_searching.entry;
    static import parsers.environment;
    static import command_generators.dmd;

    string workingDir = std.file.getcwd();
    string recipe;
    DubArguments bArgs;
    GetoptResult res = betterGetopt(args, bArgs);
    if(res.helpWanted)
    {
        defaultGetoptPrinter("dubv2 build information\n\t", res.options);
        return 1;
    }
    DubCommonArguments cArgs = bArgs.cArgs;
    if(cArgs.root)
        workingDir = cArgs.getRoot(workingDir);
    if(cArgs.recipe)
        recipe = cArgs.getRecipe(workingDir);
    parsers.environment.setupBuildEnvironmentVariables(bArgs, DubBuildArguments.init, os, args);
    StopWatch st = StopWatch(AutoStart.yes);


    BuildRequirements req = parseProject(workingDir, bArgs.compiler, BuildRequirements.Configuration(bArgs.config, false), null, recipe);
    parsers.environment.setupEnvironmentVariablesForRootPackage(cast(immutable)req);
    req.cfg = req.cfg.merge(parsers.environment.parse());

    ProjectNode tree = getProjectTree(req, bArgs.compiler);
    parsers.environment.setupEnvironmentVariablesForPackageTree(tree);

    invalidateCaches(tree, cacheStatusForProject(tree));
    if(bArgs.build.force) tree.invalidateCacheOnTree();
    
    writeln("Dependencies resolved in ", (st.peek.total!"msecs"), " ms.") ;

    bool buildSucceeded;
    if(tree.isFullyParallelizable)
    {
        writeln("Project ", req.name," is fully parallelizable! Will build everything at the same time");
        buildSucceeded = buildProjectFullyParallelized(tree, bArgs.compiler, os); 
    }
    else
        buildSucceeded = buildProjectParallelSimple(tree, bArgs.compiler, os); 
    if(!buildSucceeded)
        throw new Error("Build failure");

    // This might get removed.
    // buldSucceeded = buildProject(expandedDependencyMatrix, bArgs.compiler);

    

    writeln("Built project in ", (st.peek.total!"msecs"), " ms.") ;
    return 0;
}