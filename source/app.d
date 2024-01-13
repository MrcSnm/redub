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
    //TEST -> Take from args[1] the workingDir.
    string workingDir = std.file.getcwd();
    if(args.length > 1)
    {
        if(!isAbsolute(args[1])) 
            workingDir = buildNormalizedPath(workingDir, args[1]);
        else workingDir = args[1];
        if(args.length > 2)
            args = args[0..1] ~ args[2..$];
        else
            args = args[0..1];
    }

    return buildMain(args, workingDir);
}


int buildMain(string[] args, string workingDir)
{
    import std.getopt;
    import std.datetime.stopwatch;
    import std.system;
    import building.compile;
    import building.cache;
    import package_searching.entry;
    static import parsers.environment;
    static import command_generators.dmd;

    DubArguments bArgs;
    GetoptResult res = betterGetopt(args, bArgs);
    if(res.helpWanted)
    {
        defaultGetoptPrinter("dubv2 build information\n\t", res.options);
        return 1;
    }
    parsers.environment.setupBuildEnvironmentVariables(bArgs, DubBuildArguments.init, os, args);

    StopWatch st = StopWatch(AutoStart.yes);
    BuildRequirements req = parseProject(workingDir, bArgs.compiler, bArgs.config, null);
    parsers.environment.setupEnvironmentVariablesForRootPackage(cast(immutable)req);
    req.cfg = req.cfg.merge(parsers.environment.parse());

    ProjectNode tree = getProjectTree(req, bArgs.compiler);
    parsers.environment.setupEnvironmentVariablesForPackageTree(tree);
    invalidateCaches(tree, cacheStatusForProject(tree));
    

    // ProjectNode[][] expandedDependencyMatrix = fromTree(tree);
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

    /// This might get removed.
    // buldSucceeded = buildProject(expandedDependencyMatrix, bArgs.compiler))

    

    writeln("Built project in ", (st.peek.total!"msecs"), " ms.") ;
    return 0;
}