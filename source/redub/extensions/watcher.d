module redub.extensions.watcher;

version(RedubCLI):
version(RedubWatcher):

import redub.extensions.cli;

int watchMain(string[] args)
{
    import redub.api;
    import redub.buildapi;
    import fswatch;
    import std.path;
    import std.string;
    import redub.extensions.helper.terminal;

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

    struct WatchArgs
    {
        @("Runs automatically every time a build happens. Best when used for iteratively building displays")
        bool run;
    }
    import redub.cli.dub;
    import std.getopt;

    WatchArgs watchArgs;
    GetoptResult res = betterGetopt(args, watchArgs);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" watch information: \n", res.options);
        return 0;
    }

    ProjectDetails d = redub.extensions.cli.resolveDependencies(args.dup);
    FileWatch[] watchers;
    buildWatchers(watchers, d);

    auto terminal = getTerminal();
    auto input = getInput(terminal);

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
    terminal.hideCursor();
    int cursorY = terminal.cursorY;
    int buildLinesCount = 0;
    int runLinesCount = 0;
    int firstCursorY = cursorY;
    int failureCursorYOffset = 0;

    bool autoRunScheduled = false;

    bool bRunning = true;

    while(bRunning)
    {
        import core.thread;
        if(!drawnBuildStats)
        {
            terminal.moveTo(0, cursorY, ForceOption.alwaysSend);
            terminal.updateCursorPosition();
            terminal.clearToEndOfLine();
            terminal.write("| Build ", buildCount, " | ");
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
            terminal.flush;
            drawnBuildStats = true;
        }

        ProjectDetails doProjectBuild(ProjectDetails d)
        {
            if(isProjectUpToDate(d))
                return d;
            ulong clearCount = 1 + failureCursorYOffset; //The build stats at leat.
            if(!watchArgs.run) clearCount+= choices.length + 1; //Selection hint

            clearLines(terminal, clearCount + buildLinesCount + runLinesCount, firstCursorY);
            failureCursorYOffset = 0;

            import std.datetime.stopwatch;
            StopWatch sw = StopWatch(AutoStart.yes);
            try
            {
                d = buildProject(d);
                d = redub.extensions.cli.resolveDependencies(args.dup);
                successCount++;
                long buildTime = sw.peek.total!"msecs";
                timeSpentBuilding+= buildTime;

                terminal.updateCursorPosition();

                buildLinesCount = (terminal.cursorY - 1) - firstCursorY; //-1 because of the | Build | stats
                cursorY = terminal.cursorY;


                if(buildTime > maxTime) maxTime = buildTime;
                if(buildTime < minTime) minTime = buildTime;

                if(watchArgs.run)
                    autoRunScheduled = true;

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
                    //     clearLines(terminal, choices.length+1, cursorY - 1);
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
        if(watchArgs.run)
        {
            if(autoRunScheduled)
            {
                terminal.moveTo(0, cursorY + 1, ForceOption.alwaysSend);
                terminal.updateCursorPosition();
                executeProgram(d.tree, null);
                terminal.updateCursorPosition();
                runLinesCount = (terminal.cursorY - cursorY);
                autoRunScheduled = false;
            }
        }
        else
        {
            dchar k = input.getch(true);
            if(k != dchar.init || !hasShownLastLineMessage)
            {
                auto selected = selectChoiceBase(terminal, k, choices, choice, cursorY+failureCursorYOffset);
                if(!selected)
                {
                    drawChoices(terminal, choices, choices[choice], cursorY+1+failureCursorYOffset);
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
                            runLinesCount = terminal.cursorY - cursorY;
                            clearLines(terminal, runLinesCount, cursorY);
                            hasShownLastLineMessage = false;
                            drawnBuildStats = false;
                            break;
                        case "Force Rebuild":
                            d.forceRebuild = true;
                            d = doProjectBuild(d);
                            d.forceRebuild = false;
                            break;
                        case "Exit":
                            bRunning = false;
                            break;
                    }
                }
            }
        }
        Thread.sleep(dur!"msecs"(33));
    }

    clearLines(terminal, buildLinesCount+runLinesCount+choices.length+2, cursorY); //Selection hint + Build Stats

    terminal.showCursor();

    return 0;

}
