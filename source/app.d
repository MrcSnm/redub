import redub.api;

import redub.compiler_identification;
import redub.logging;
import redub.buildapi;
import redub.parsers.automatic;
import redub.tree_generators.dub;
import redub.cli.dub;
import redub.command_generators.commons;
import redub.libs.package_suppliers.utils;


extern(C) __gshared string[] rt_options = [ "gcopt=initReserve:200 cleanup:none"];

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
            "update": &updateMain,
            "clean": &cleanMain,
            "describe": &describeMain,
            "deps": &depsMain,
            "test": &testMain,
            "init": &initMain,
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
        version(Developer) throw e;
        return 1;
    }
    catch(BuildException e)
    {
        errorTitle("Build Failure: ", e.msg);
        version(Developer) throw e;
        return 1;
    }
    catch(NetworkException e)
    {
        errorTitle("Network Error: ", e.msg);
        version(Developer) throw e;
        return 1;
    }
    catch(Exception e)
    {
        errorTitle("Internal Error: ", e.msg);
        version(Developer) throw e;
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
    ProjectDetails d = resolveDependencies(args, true);
    if(!d.tree)
        return 1;
    
    alias OutputData = string[];

    static immutable outputs =[
        "dflags": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.dFlags;},
        "lflags": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.linkFlags;},
        "libs": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.libraries;},
        "linker-files": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d)
        {
            root.putLinkerFiles(dataContainer, osFromArch(d.cDetails.arch), isaFromArch(d.cDetails.arch));
        },
        "source-files": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d)
        {
            root.putSourceFiles(dataContainer);
        },
        "versions": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.versions;},
        // "debug-versions": (){},
        "import-paths": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.importDirectories;},
        "string-import-paths": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.stringImportPaths;},
        "import-files": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){},
        "options": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){}
    ];
    OutputData[] outputContainer = new OutputData[](desc.data.length);
    foreach(i, data; desc.data)
    {
        auto handler = data in outputs;
        if(handler)
            (*handler)(outputContainer[i], d.tree, d);
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
    d.tree.requirements.cfg = d.tree.requirements.cfg.merge(parse(BuildType.unittest_, d.tree.requirements.cfg.getCompiler(d.compiler).compiler));
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

int initMain(string[] args)
{
    import std.getopt;
    struct InitArgs
    {
        @("Creates a project of the specified type")
        @("t")
        string type;
    }
    InitArgs initArgs;
    GetoptResult res = betterGetopt(args, initArgs);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" init information:\n ", res.options);
        return 0;
    }
    setLogLevel(LogLevel.info);
    return createNewProject(initArgs.type, args.length > 1 ? args[1] : null);
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

int updateMain(string[] args)
{
    import core.runtime;
    import std.stdio;
    import std.process;
    import std.file;
    import std.path;
    import redub.misc.github_tag_check;
    import redub.libs.package_suppliers.utils;
    string redubExePath = thisExePath;
    string currentRedubDir = dirName(redubExePath);
    string redubPath = buildNormalizedPath(currentRedubDir, "..");
    string latest;

    struct UpdateArgs
    {
        @("Builds redub using dmd -b debug for faster iteration on redub")
        bool fast;

        @("Throws stack instead of simply pretty-printing the message")
        bool dev;

        @("Sets the compiler to build redub")
        string compiler = "ldc2";

        @("Does not execute git pull")
        @("no-pull")
        bool noPull;

        @("Makes the update very verbose")
        bool vverbose;
    }
    import std.getopt;
    UpdateArgs update;
    GetoptResult res = betterGetopt(args, update);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" update information: \n", res.options);
        return 0;
    }

    setLogLevel(update.vverbose ? LogLevel.vverbose : LogLevel.info);

    int gitCode = executeShell("git --help").status;
    enum isNotGitRepo = 128;
    enum hasNoGitWindows = 9009;
    enum hasNoGitPosix = 127;

    bool replaceRedub = false || update.noPull;
    if(gitCode == 0 && !update.noPull)
    {
        auto ret = executeShell("git pull", null, Config.none, size_t.max, redubPath);
        gitCode = ret.status;
        if(gitCode != 0 && gitCode != isNotGitRepo)
        {
            errorTitle("Git Pull Error: \n", ret.output);
            return 1;
        }
        else if(gitCode == 0)
        {
            info("Redub will be rebuilt using git repo found at ", redubPath);
            replaceRedub = true;
        }
    }

    if(gitCode == isNotGitRepo || gitCode == hasNoGitWindows || gitCode == hasNoGitPosix)
    {
        latest = getLatestVersion();
        if(SemVer(latest[1..$]) > SemVer(RedubVersionOnly[1..$]))
        {
            replaceRedub = true;
            string redubLink = getRedubDownloadLink(latest);
            info("Downloading redub from '", redubLink, "'");
            ubyte[] redubZip = downloadFile(redubLink);
            redubPath = tempDir;
            mkdirRecurse(redubPath);
            extractZipToFolder(redubZip, redubPath);
            redubPath = buildNormalizedPath(redubPath, "redub-"~latest[1..$]);
        }
    }


    if(replaceRedub)
    {
        import redub.api;
        import std.exception;
        info("Preparing to build redub at ", redubPath);
        BuildType bt = BuildType.release_debug;
        if(update.fast)
        {
            update.compiler = "dmd";
        }
        
        ProjectDetails d = redub.api.resolveDependencies(false, os, CompilationDetails(update.compiler), ProjectToParse(update.dev ? "cli-dev" : null, redubPath), InitialDubVariables.init, bt);
        enforce(d.tree.name == "redub", "Redub update should only be used to update redub.");
        d.tree.requirements.cfg.outputDirectory = buildNormalizedPath(tempDir, "redub_build");
        d = buildProject(d);
        if(d.error)
            return 1;
        info("Replacing current redub at path ", currentRedubDir, " with the built file: ", d.getOutputFile);

        string redubScriptPath;
        version(Windows)
            redubScriptPath = buildNormalizedPath(redubPath, "replace_redub.bat");
        else
            redubScriptPath = buildNormalizedPath(redubPath, "replace_redub.sh");

        if(!exists(redubScriptPath))
        {
            error("Redub Script not found at path ", redubScriptPath);
            return 1;
        }

        version(Windows)
        {
            spawnShell(`start cmd /c "`~redubScriptPath~" "~d.getOutputFile~" "~redubExePath~'"');
        }
        else version(Posix)
        {
            import core.sys.posix.unistd;
            import std.conv:to;
            string pid = getpid().to!string;
            string exec = `chmod +x `~redubScriptPath~` && nohup bash `~redubScriptPath~" "~pid~" "~d.getOutputFile~" "~redubExePath~" > /dev/null 2>&1";
            spawnShell(exec);
        }
        else assert(false, "Your system does not have any command right now for auto copying the new content.");
        return 0;
    }
    warn("Your redub version '", RedubVersionOnly, "' is already greater or equal than the latest redub version '", latest);
    return 0;
}

string findProgramPath(string program)
{
    import redub.parsers.environment;
	import std.algorithm:countUntil;
	import std.process;
	string searcher;
	version(Windows) searcher = "where";
	else version(Posix) searcher = "which";
	else static assert(false, "No searcher program found in this OS.");
	auto shellRes = executeShell(searcher ~" " ~ program,
	[
		"PATH": redubEnv["PATH"]
	]);
    if(shellRes.status == 0)
		return shellRes.output[0..shellRes.output.countUntil("\n")];
   	return null;
}


/**
 *
 * Params:
 *   args = All the arguments to parse
 *   isDescribeOnly = Used to not run the preGenerate commands
 * Returns:
 */
ProjectDetails resolveDependencies(string[] args, bool isDescribeOnly = false)
{
    import std.file;
    import std.algorithm.comparison:either;
    import std.getopt;
    import redub.api;
    string subPackage = parseSubpackageFromCli(args);
    string workingDir = std.file.getcwd();
    string recipe;

    DubArguments bArgs;
    GetoptResult res = betterGetopt(args, bArgs);
    updateVerbosity(bArgs.cArgs);
    if(res.helpWanted)
    {
        import std.getopt;
        string newCommands =
`

Additions to redub commands --

update
    Usage: redub update
    Description: Updates with 'git pull' redub if the current redub is a git repository. If it is not, it will download the newest git tag from redub
        repository. After updating the source, it will also optimally rebuild redub and replace the current one with the new build.
`;
        defaultGetoptPrinter(RedubVersionShort~" build information: \n\t"~newCommands, res.options);
        return ProjectDetails.init;
    }
    if(bArgs.version_)
    {
        import std.stdio;
        writeln(RedubVersion);
        return ProjectDetails(null, Compiler.init, ParallelType.auto_, CompilationDetails.init, false, true);
    }

    if(bArgs.arch && !bArgs.compiler) bArgs.compiler = "ldc2";
    DubCommonArguments cArgs = bArgs.cArgs;
    if(cArgs.root)
        workingDir = cArgs.getRoot(workingDir);

    if(bArgs.single && cArgs.recipe)
        throw new RedubException("Can't set both --single and --recipe");
    if(cArgs.recipe)
        recipe = cArgs.getRecipe(workingDir);

    if(bArgs.build.breadth)
    {
        import redub.command_generators.commons;
        setSpanModeAsBreadth(bArgs.build.breadth);
    }

    if(bArgs.single)
    {
        import std.path;
        if(!isAbsolute(bArgs.single))
            recipe = buildNormalizedPath(workingDir, bArgs.single);
        else
            recipe = bArgs.single;
    }

    if(bArgs.prefetch)
    {
        import redub.misc.path;
        import redub.package_searching.dub;
        string selections = redub.misc.path.buildNormalizedPath(workingDir, "dub.selections.json");
        auto timing = timed((){prefetchPackages(selections); return true;});
        infos("Prefetchi Finished: ", timing.msecs,"ms");
    }


    string bt = either(bArgs.buildType, BuildType.debug_);

    ProjectDetails ret =  redub.api.resolveDependencies(
        bArgs.build.force,
        os,
        CompilationDetails(bArgs.compiler, bArgs.cCompiler, bArgs.arch, bArgs.compilerAssumption, bArgs.build.incremental, bArgs.build.useExistingObj, bArgs.build.combined, bArgs.build.parallel),
        ProjectToParse(bArgs.config, workingDir, subPackage, recipe, bArgs.single.length != 0, isDescribeOnly),
        getInitialDubVariablesFromArguments(bArgs, DubBuildArguments.init, os, args),
        bt
    );

    if(bArgs.targetPath)
        ret.tree.requirements.cfg.outputDirectory = bArgs.targetPath;
    if(bArgs.targetName)
        ret.tree.requirements.cfg.targetName = bArgs.targetName;

    if(bArgs.build.printBuilds)
    {
        import redub.parsers.build_type;
        info("\tAvailable build types:");
        foreach(string buildType, value; registeredBuildTypes)
            info("\t ", buildType);
        foreach(mem; __traits(allMembers, BuildType))
        {
            if(__traits(getMember, BuildType, mem) !in registeredBuildTypes)
                info("\t ", __traits(getMember, BuildType, mem));
        }
    }

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