import std.algorithm:countUntil;
import std.conv:to;
import std.array;
import std.path;
import std.file;
import std.process;
import redub.api;

import redub.compiler_identification;
import redub.logging;
import redub.buildapi;
import redub.parsers.automatic;
import redub.tree_generators.dub;
import redub.cli.dub;
import redub.command_generators.commons;


extern(C) __gshared string[] rt_options = [ "gcopt=initReserve:200" ];




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
        case "deps":
            args = args[0] ~ args[2..$];
            return depsMain(args);
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
    if(!d.tree || d.usesExternalErrorCode)
        return d.getReturnCode;
    if(d.tree.requirements.cfg.targetType != TargetType.executable)
        return 1;

    ptrdiff_t execArgsInit = countUntil(args, "--");
    string execArgs;
    if(execArgsInit != -1) execArgs = " " ~ escapeShellCommand(args[execArgsInit+1..$]);


    import redub.command_generators.commons;
    
    return wait(spawnShell(
        buildNormalizedPath(d.tree.requirements.cfg.outputDirectory, 
        d.tree.requirements.cfg.name~getExecutableExtension(os)) ~  execArgs
    ));
}

int describeMain(string[] args)
{
    DubDescribeArguments desc;
    try 
    {
        GetoptResult res = betterGetopt(args, desc);
        if(res.helpWanted)
        {
            defaultGetoptPrinter("redub describe help info ", res.options);
            return 1;
        }
    }
    catch(GetOptException e){}
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return 1;
    
    alias OutputData = string[];

    static immutable outputs =[
        "main-source-file": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.sourceEntryPoint;},
        "dflags": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.dFlags;},
        "lflags": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.linkFlags;},
        "libs": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.libraries;},
        "linker-files": (ref string[] dataContainer, const ProjectNode root)
        {
            root.putLinkerFiles(dataContainer);
        },
        "source-files": (ref string[] dataContainer, const ProjectNode root)
        {
            root.putSourceFiles(dataContainer);
        },
        "versions": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.versions;},
        // "debug-versions": (){},
        "import-paths": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.importDirectories;},
        "string-import-paths": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.stringImportPaths;}, 
        "import-files": (ref string[] dataContainer, const ProjectNode root){}, 
        "options": (ref string[] dataContainer, const ProjectNode root){}
    ];
    OutputData[] outputContainer = new OutputData[](desc.data.length);
    foreach(i, data; desc.data)
    {
        auto handler = data in outputs;
        if(handler)
            (*handler)(outputContainer[i], d.tree);
    }

    foreach(data; outputContainer)
    {
        import std.stdio;
        writeln(escapeShellCommand(data));
    }
    return 0;
}


int depsMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return 1;
    printProjectTree(d.tree);
    return 0;
}

int cleanMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return d.getReturnCode;
    
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
    return buildProject(resolveDependencies(args)).getReturnCode;
}

string findProgramPath(string program)
{
	import std.algorithm:countUntil;
	import std.process;
	string searcher;
	version(Windows) searcher = "where";
	else version(Posix) searcher = "which";
	else static assert(false, "No searcher program found in this OS.");
	auto shellRes = executeShell(searcher ~" " ~ program,
	[
		"PATH": environment["PATH"]
	]);
    if(shellRes.status == 0)
		return shellRes.output[0..shellRes.output.countUntil("\n")];
   	return null;
}


ProjectDetails resolveDependencies(string[] args)
{
    import std.algorithm.comparison:either;
    import redub.api;
    string subPackage = parseSubpackageFromCli(args);
    string workingDir = std.file.getcwd();
    string recipe;

    DubArguments bArgs;
    string[] unmodArgs = args.dup;
    GetoptResult res = betterGetopt(args, bArgs);
    updateVerbosity(bArgs.cArgs);
    if(res.helpWanted)
    {
        import std.getopt;
        defaultGetoptPrinter("redub build information\n\t", res.options);
        return ProjectDetails.init;
    }
    if(bArgs.version_)
    {
        import std.stdio;
        writeln(RedubVersion);
        return ProjectDetails(null, Compiler.init, ParallelType.auto_,  true);
    }
    if(bArgs.single)
    {
        import std.process;
        import std.stdio;
        string dubCommand = "dub "~join(unmodArgs[1..$], " ");
        environment["DUB_EXE"] = environment["DUB"] = "dub";
        string cwd = getcwd;
        warn(RedubVersionShort~ " does not handle --single. Forwarding '"~dubCommand~"' to dub with working dir "~cwd);

        int status = wait(spawnShell(dubCommand, stdin, stdout, stderr, environment.toAA, Config.none, cwd));
        return ProjectDetails(null, Compiler.init, ParallelType.auto_, true, status);
    }

    if(bArgs.arch) bArgs.compiler = "ldc2";
    DubCommonArguments cArgs = bArgs.cArgs;
    if(cArgs.root)
        workingDir = cArgs.getRoot(workingDir);
    if(cArgs.recipe)
        recipe = cArgs.getRecipe(workingDir);


    BuildType bt = BuildType.debug_;
    if(bArgs.buildType) bt = buildTypeFromString(bArgs.buildType);

    return redub.api.resolveDependencies(
        bArgs.build.force,
        os,
        CompilationDetails(bArgs.compiler, bArgs.arch, bArgs.compilerAssumption, bArgs.build.incremental, bArgs.build.combined, bArgs.build.parallel),
        ProjectToParse(bArgs.config, workingDir, subPackage, recipe),
        getInitialDubVariablesFromArguments(bArgs, DubBuildArguments.init, os, args),
        bt
    );
}

void updateVerbosity(DubCommonArguments a)
{
    import redub.logging;
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