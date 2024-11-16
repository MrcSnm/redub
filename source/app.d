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
    try
    {
        if(args.length == 1)
            return runMain(args, []);

        import std.algorithm:countUntil;
        ptrdiff_t execArgsInit = countUntil(args, "--");

        string[] runArgs;
        if(execArgsInit != -1)
        {
            runArgs = args[execArgsInit+1..$];
            args = args[0..execArgsInit];
        }


        int function(string[])[string] entryPoints = [
            "build": &buildMain,
            "clean": &cleanMain,
            "describe": &describeMain,
            "deps": &depsMain,
            "test": &testMain,
            "run": cast(int function(string[]))null
        ];


        foreach(cmd; entryPoints.byKey)
        {
            ptrdiff_t cmdPos = countUntil(args, cmd);
            if(cmdPos != -1)
            {
                args = args[0..cmdPos] ~ args[cmdPos+1..$];
                if(cmd == "run")
                    return runMain(args, runArgs);
                return entryPoints[cmd](args);
            }
        }
        return runMain(args, runArgs);
    }
    catch(RedubException e)
    {
        errorTitle("Redub Error: ", e.msg);
        return 1;
    }
    catch(BuildException e)
    {
        errorTitle("Build Failure");
        return 1;
    }
}


int runMain(string[] args, string[] runArgs)
{
    ProjectDetails d = buildProject(resolveDependencies(args));
    if(!d.tree || d.usesExternalErrorCode)
        return d.getReturnCode;
    if(d.tree.requirements.cfg.targetType != TargetType.executable)
        return 1;
    return executeProgram(d.tree, runArgs);
}

int executeProgram(ProjectNode tree, string[] args)
{
    import std.path;
    import std.array:join;
    import std.process;
    import redub.command_generators.commons;
    return wait(spawnShell(
        escapeShellCommand(getOutputPath(tree.requirements.cfg, os)) ~ " "~ join(args, " ")
        )
    );
}

int describeMain(string[] args)
{
    import std.getopt;
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
        import std.process;
        import std.stdio;
        writeln(escapeShellCommand(data));
    }
    return 0;
}


int depsMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(d.error)
        return 1;
    printProjectTree(d.tree);
    return 0;
}

int testMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(d.error)
        return d.getReturnCode();
    import redub.parsers.build_type;
    d.tree.requirements.cfg = d.tree.requirements.cfg.merge(parse(BuildType.unittest_, d.compiler.compiler));
    d.tree.requirements.cfg.dFlags~= "-main";
    d.tree.requirements.cfg.targetType = TargetType.executable;
    d.tree.requirements.cfg.targetName~= "-test-";

    if(d.tree.requirements.configuration.name)
        d.tree.requirements.cfg.targetName~= d.tree.requirements.configuration.name;
    else
        d.tree.requirements.cfg.targetName~= "library";

    d = buildProject(d);
    if(d.error)
        return d.getReturnCode();

    return executeProgram(d.tree, args);
}


int cleanMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return d.getReturnCode;
    return cleanProject(d, true);
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
    import std.file;
    import std.algorithm.comparison:either;
    import std.getopt;
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
        defaultGetoptPrinter(RedubVersionShort~" build information: \n\t", res.options);
        return ProjectDetails.init;
    }
    if(bArgs.version_)
    {
        import std.stdio;
        writeln(RedubVersion);
        return ProjectDetails(null, Compiler.init, ParallelType.auto_, CompilationDetails.init, false, true);
    }
    if(bArgs.single)
    {
        import std.process;
        import std.stdio;
        import std.array;
        string dubCommand = "dub "~join(unmodArgs[1..$], " ");
        environment["DUB_EXE"] = environment["DUB"] = "dub";
        string cwd = getcwd;
        warn(RedubVersionShort~ " does not handle --single. Forwarding '"~dubCommand~"' to dub with working dir "~cwd);

        int status = wait(spawnShell(dubCommand, stdin, stdout, stderr, environment.toAA, Config.none, cwd));
        return ProjectDetails(null, Compiler.init, ParallelType.auto_, CompilationDetails.init, false, true, status);
    }

    if(bArgs.arch && !bArgs.compiler) bArgs.compiler = "ldc2";
    DubCommonArguments cArgs = bArgs.cArgs;
    if(cArgs.root)
        workingDir = cArgs.getRoot(workingDir);
    if(cArgs.recipe)
        recipe = cArgs.getRecipe(workingDir);


    BuildType bt = BuildType.debug_;
    if(bArgs.buildType) bt = buildTypeFromString(bArgs.buildType);

    ProjectDetails ret =  redub.api.resolveDependencies(
        bArgs.build.force,
        os,
        CompilationDetails(bArgs.compiler, bArgs.arch, bArgs.compilerAssumption, bArgs.build.incremental, bArgs.build.useExistingObj, bArgs.build.combined, bArgs.build.parallel),
        ProjectToParse(bArgs.config, workingDir, subPackage, recipe),
        getInitialDubVariablesFromArguments(bArgs, DubBuildArguments.init, os, args),
        bt
    );

    if(bArgs.targetPath)
        ret.tree.requirements.cfg.outputDirectory = bArgs.targetPath;
    if(bArgs.targetName)
        ret.tree.requirements.cfg.targetName = bArgs.targetName;

    return ret;
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