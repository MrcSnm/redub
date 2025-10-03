module redub.extensions.watcher;

version(RedubCLI):
import redub.extensions.cli;

int watchMain(string[] args)
{
    import redub.api;
    import redub.buildapi;
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

    bool autoRunScheduled = false;

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
        if(watchArgs.run)
        {
            if(autoRunScheduled)
            {
                executeProgram(d.tree, null);
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
        }
        Thread.sleep(dur!"msecs"(33));
    }

    return 0;

}
