import std.algorithm:countUntil;
import std.conv:to;
import std.array;
import std.path;
import std.file;
import std.process;
import redub_api;

import compiler_identification;
import logging;
import buildapi;
import parsers.automatic;
import tree_generators.dub;
import cli.dub;
import command_generators.commons;

enum RedubVersion = "Redub - A reimagined DUB: v1.1.0";


string formatError(string err)
{
    import std.algorithm.searching:countUntil;
    if(err.countUntil("which cannot be read") != -1)
    {
        ptrdiff_t moduleNameStart = err.countUntil("`") + 1;
        ptrdiff_t moduleNameEnd = err[moduleNameStart..$].countUntil("`") + moduleNameStart;
        string moduleName = err[moduleNameStart..moduleNameEnd];

        return err~"\nMaybe you forgot to add the module '"~moduleName~"' source root to import paths?
        Redub Failed!";
    }
    return err~"\nRedub Failed!";
}
/**
* Redub work with input -> output on each step. It must be almost stateless.
* ** CLI will be optionally implemented later. 
* ** Cache will be optionally implemented later
* 
* FindProject -> ParseProject -> MergeWithEnvironment -> ConvertToBuildFlags ->
* Build
*/
int main(string[] args)
{
    if(args.length == 1)
        return runMain(args);

    string action = args[1];
    switch(action)
    {
        case "build":
            args = args[0] ~ args[2..$];
            return buildMain(args);
        case "clean":
            args = args[0] ~ args[2..$];
            return cleanMain(args);
        case "describe":
            args = args[0] ~ args[2..$];
            return describeMain(args);
        case "run":
            args = args[0] ~ args[2..$];
            goto default;
        default:
            return runMain(args);
    }
}


int runMain(string[] args)
{
    ProjectDetails d = buildProject(resolveDependencies(args));
    if(!d.tree) return 1;
    if(d.tree.requirements.cfg.targetType != TargetType.executable)
        return 1;

    ptrdiff_t execArgsInit = countUntil(args, "--");
    string execArgs;
    if(execArgsInit != -1) execArgs = " " ~ escapeShellCommand(args[execArgsInit+1..$]);


    import command_generators.commons;
    
    return wait(spawnShell(
        buildNormalizedPath(d.tree.requirements.cfg.outputDirectory, 
        d.tree.requirements.cfg.name~getExecutableExtension(os)) ~  execArgs
    ));
}

int describeMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return 1;

    return 0;
}

int cleanMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return 1;
    
    auto res = timed(()
    {
        info("Cleaning project ", d.tree.name);
        import std.file;
        foreach(ProjectNode node; d.tree.collapse)
        {
            string output = buildNormalizedPath(
                node.requirements.cfg.outputDirectory, 
                getOutputName(node.requirements.cfg.targetType, node.name, os)
            );
            if(std.file.exists(output))
            {
                vlog("Removing ", output);
                remove(output);
            }
        }
        return true;
    });

    info("Finished cleaning project in ", res.msecs, "ms");

    return res.value ? 0 : 1;
}

int buildMain(string[] args)
{
    if(!buildProject(resolveDependencies(args)).tree)
        return 1;
    return 0;
}


ProjectDetails resolveDependencies(string[] args)
{
    import std.algorithm.comparison:either;
    static import parsers.environment;
    import redub_api;
    string subPackage = parseSubpackageFromCli(args);
    string workingDir = std.file.getcwd();
    string recipe;

    DubArguments bArgs;
    GetoptResult res = betterGetopt(args, bArgs);
    if(res.helpWanted)
    {
        import std.getopt;
        defaultGetoptPrinter("redub build information\n\t", res.options);
        return ProjectDetails.init;
    }
    updateVerbosity(bArgs.cArgs);
    if(bArgs.arch) bArgs.compiler = "ldc2";
    DubCommonArguments cArgs = bArgs.cArgs;
    if(cArgs.root)
        workingDir = cArgs.getRoot(workingDir);
    if(cArgs.recipe)
        recipe = cArgs.getRecipe(workingDir);

    return redub_api.resolveDependencies(
        bArgs.build.force,
        os,
        CompilationDetails(either(bArgs.compiler, "dmd"), bArgs.arch, bArgs.compilerAssumption),
        ProjectToParse(bArgs.config, workingDir, subPackage, recipe),
        getInitialDubVariablesFromArguments(bArgs, DubBuildArguments.init, os, args)
    );

}

void updateVerbosity(DubCommonArguments a)
{
    import logging;
    if(a.vquiet) return setLogLevel(LogLevel.none);
    if(a.verror) return setLogLevel(LogLevel.error);
    if(a.quiet) return setLogLevel(LogLevel.warn);
    if(a.verbose) return setLogLevel(LogLevel.verbose);
    if(a.vverbose) return setLogLevel(LogLevel.vverbose);
    return setLogLevel(LogLevel.info);
}

private string parseSubpackageFromCli(ref string[] args)
{
    import std.string:startsWith;
    import std.algorithm.searching;
    ptrdiff_t subPackIndex = countUntil!((a => a.startsWith(':')))(args);
    if(subPackIndex == -1) return null;

    string ret;
    ret = args[subPackIndex][1..$];
    args = args[0..subPackIndex] ~ args[subPackIndex+1..$];
    return ret;
}