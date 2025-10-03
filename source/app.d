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
            "build-universal": &buildUniversalMain,
            "update": &updateMain,
            "clean": &cleanMain,
            "describe": &describeMain,
            "deps": &depsMain,
            "test": &testMain,
            "init": &initMain,
            "watch": &watchMain,
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
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree || d.usesExternalErrorCode)
        return d.getReturnCode;
    d = buildProject(d);
    if(!d.tree || d.usesExternalErrorCode)
        return d.getReturnCode;
    if(d.tree.requirements.cfg.targetType != TargetType.executable)
        return 1;
    if(d.tree.name == "redub")
    {
        warnTitle("Attempt to build and run redub with redub: ", "For building redub with redub, use the command 'redub update' which already outputs an optimized build");
        return 0;
    }
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
    ProjectDetails d = resolveDependencies(args);
    return buildProject(d).getReturnCode;
}

int buildUniversalMain(string[] args)
{
    ArgsDetails argsDetails = resolveArguments(args);
    foreach(d; buildProjectUniversal(argsDetails))
        if(d.error)
            return d.getReturnCode;
    return 0;
}


int watchMain(string[] args)
{
    import fswatch;
    import std.path;
    import std.string;
    import arsd.terminal;

    static void clearDrawnChoices(ref Terminal t, ulong linesToClear, int startCursorY)
    {
        t.moveTo(0, cast(int)startCursorY, ForceOption.alwaysSend);
        //SelectionHint
        foreach(i; 0..linesToClear + 1)
            t.moveTo(0, cast(int)(startCursorY+i), ForceOption.alwaysSend), t.clearToEndOfLine();
        t.moveTo(0, cast(int)startCursorY, ForceOption.alwaysSend);
    }


    static void drawChoices(ref Terminal t, string[] choices, string next, int startCursorY)
    {
        enum SelectionHint = "--- Select an option by using Arrow Up/Down and choose it by pressing Enter. ---";
        t.flush();
        clearDrawnChoices(t, choices.length, startCursorY);
        t.color(arsd.terminal.Color.yellow | Bright, arsd.terminal.Color.DEFAULT);
        t.writeln(SelectionHint);
        t.color(arsd.terminal.Color.DEFAULT, arsd.terminal.Color.DEFAULT);
        foreach(i, c; choices)
        {
            if(c == next)
            {
                t.color(arsd.terminal.Color.green, arsd.terminal.Color.DEFAULT);
                t.writeln(">> ", c);
                t.color(arsd.terminal.Color.DEFAULT, arsd.terminal.Color.DEFAULT);
            }
            else t.writeln(c);
        }
        t.flush;
    }

    static bool selectChoiceBase(ref Terminal terminal, dchar key, string[] choices,
        ref ptrdiff_t selectedChoice, int startCursorY)
    {
        enum ESC = 983067;
        enum ArrowUp = 983078;
        enum ArrowDown = 983080;

        int startLine = startCursorY;

        switch(key)
        {
            case ArrowUp:
                selectedChoice = (selectedChoice + choices.length - 1) % choices.length;
                return false;
            case ArrowDown:
                selectedChoice = (selectedChoice+1) % choices.length;
                return false;
            case ESC:
                selectedChoice = choices.length - 1;
                break;
            case '\n':
                break;
            default: return false;
        }

        import std.algorithm.searching;
        clearDrawnChoices(terminal, choices.length, startCursorY);
        terminal.moveTo(0, cast(int)startLine+1); //Jump title
        terminal.color(arsd.terminal.Color.green, arsd.terminal.Color.DEFAULT);
        terminal.writeln(">> ", choices[selectedChoice]);
        terminal.color(arsd.terminal.Color.DEFAULT, arsd.terminal.Color.DEFAULT);
        terminal.flush;

        return true;
    }



    static void buildWatchers(ref FileWatch[] ret, ProjectDetails d)
    {
        ret.length = 0;
        string[] allDirs = d.tree.requirements.cfg.importDirectories ~ d.tree.requirements.cfg.stringImportPaths;
        foreach(ProjectNode node; d.tree.collapse)
        {
            foreach(source; node.requirements.cfg.sourceFiles)
                ret~= FileWatch(source, false);
        }
        foreach(dir; allDirs)
            ret~= FileWatch(dir, true);
    }

    ProjectDetails d = resolveDependencies(args.dup);
    FileWatch[] watchers;
    buildWatchers(watchers, d);
    auto terminal = Terminal(ConsoleOutputType.linear);
    auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw);

    ptrdiff_t choice = 0;
    int buildCount = 0;
    int successCount = 0;
    long timeSpentBuilding = 0;
    long minTime = long.max;
    long maxTime = long.min;
    bool drawnBuildStats = false;


    string[] choices = [
        "Run Blocking",
        "Force Rebuild",
        "Exit"
    ];

    scope(exit)
    {
        destroy(input);
        destroy(terminal);
    }

    bool hasShownLastLineMessage = false;
    terminal.updateCursorPosition();
    int cursorY = terminal.cursorY + 1;
    int firstCursorY = cursorY;
    int failureCursorYOffset = 0;

    while(true)
    {
        import core.thread;
        if(!drawnBuildStats)
        {
            terminal.moveTo(0, cursorY - 1, ForceOption.alwaysSend);
            terminal.clearToEndOfLine();
            terminal.write("|Build ", buildCount, " | ");
            long min = minTime, max = maxTime;
            long avgTime = 0;
            if(buildCount != 0)
                avgTime = timeSpentBuilding / buildCount;
            if(min == long.max) min = 0;
            if(max == long.min) max = 0;

            if(buildCount <= 1)
                terminal.write("Time(ms): ", avgTime, " | ");
            else
                terminal.write("Time(ms): Avg ", avgTime, " Total ", timeSpentBuilding, " Min ", min, " Max ", max, " | ");

            float successRatio = 0;
            if(buildCount != 0)
                successRatio = cast(float)successCount / buildCount;

            arsd.terminal.Color c;
            if(successRatio < 0.35)
                c = arsd.terminal.Color.red;
            else if(successRatio < 0.7)
                c = arsd.terminal.Color.yellow;
            else
                c = arsd.terminal.Color.green;

            terminal.color(c | Bright, arsd.terminal.Color.DEFAULT);
            int successPercentage = cast(int)(successRatio * 100);
            terminal.writeln(successPercentage, "% success");
            terminal.color(arsd.terminal.Color.DEFAULT, arsd.terminal.Color.DEFAULT);
            drawnBuildStats = true;
        }

        ProjectDetails doProjectBuild(ProjectDetails d)
        {
            ulong clearCount = choices.length + 1 + failureCursorYOffset;
            clearDrawnChoices(terminal, clearCount, cursorY - 1);
            if(cursorY != firstCursorY)
            {
                int realCursorY = cursorY - 1;
                clearDrawnChoices(terminal, (realCursorY - firstCursorY), firstCursorY - 1);
                // terminal.moveTo(0, firstCursorY)
            }
            failureCursorYOffset = 0;

            static bool firstBuild = true;
            import std.datetime.stopwatch;
            StopWatch sw = StopWatch(AutoStart.yes);
            try
            {
                d = buildProject(d);
                successCount++;
                long buildTime = sw.peek.total!"msecs";
                timeSpentBuilding+= buildTime;

                if(firstBuild)
                {
                    terminal.updateCursorPosition();
                    cursorY = terminal.cursorY + 1;
                    firstBuild = false;
                }

                if(buildTime > maxTime) maxTime = buildTime;
                if(buildTime < minTime) minTime = buildTime;

            }
            catch(BuildException be)
            {
                terminal.updateCursorPosition();
                failureCursorYOffset = terminal.cursorY - cursorY;
            }
            buildCount++;
            hasShownLastLineMessage = false;
            drawnBuildStats = false;
            return d;
        }
        WATCHERS_LOOP: foreach(ref watch; watchers)
        {
            foreach(event; watch.getEvents())
            {
                if(event.type == FileChangeEventType.modify)
                {
                    //Unimplemented, might be more complex than I want to deal with
                    // if(event.path.endsWith("dub.json") || event.path.endsWith("dub.sdl"))
                    // {
                    //     clearDrawnChoices(terminal, choices.length+1, cursorY - 1);
                    //     d = resolveDependencies(args.dup);
                    //     buildWatchers(watchers, d);
                    //     hasShownLastLineMessage = false;
                    //     drawnBuildStats = false;
                    //     break WATCHERS_LOOP;
                    // }
                    // else
                    if(event.path.endsWith(".d") || event.path.endsWith(".di"))
                    {
                        d = doProjectBuild(d);
                        break WATCHERS_LOOP;
                    }
                }
            }
        }
        dchar k = input.getch(true);
        if(k != dchar.init || !hasShownLastLineMessage)
        {
            auto selected = selectChoiceBase(terminal, k, choices, choice, cursorY+failureCursorYOffset);
            if(!selected)
            {
                drawChoices(terminal, choices, choices[choice], cursorY+failureCursorYOffset);
                hasShownLastLineMessage = true;
            }
            else
            {
                final switch(choices[choice])
                {
                    case "Run Blocking":
                        executeProgram(d.tree, null);
                        terminal.writeln("Press any button to continue.");
                        input.getch();
                        terminal.updateCursorPosition();
                        int newOffset = terminal.cursorY - cursorY;
                        clearDrawnChoices(terminal, newOffset, cursorY);
                        hasShownLastLineMessage = false;
                        drawnBuildStats = false;
                        break;
                    case "Force Rebuild":
                        d.forceRebuild = true;
                        d = doProjectBuild(d);
                        d.forceRebuild = false;
                        break;
                    case "Exit":
                        return 0;
                }
            }
        }
        Thread.sleep(dur!"msecs"(33));
    }

    return 0;

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
            bt = BuildType.debug_;
        
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
    import redub.api;

    ArgsDetails argsD = resolveArguments(args, isDescribeOnly);
   

    ProjectDetails ret =  redub.api.resolveDependencies(
        argsD.args.build.force,
        os,
        argsD.cDetails,
        argsD.proj,
        argsD.dubVars,
        argsD.buildType
    );

    if(argsD.args.targetPath)
        ret.tree.requirements.cfg.outputDirectory = argsD.args.targetPath;
    if(argsD.args.targetName)
        ret.tree.requirements.cfg.targetName = argsD.args.targetName;

    if(argsD.args.build.printBuilds)
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
