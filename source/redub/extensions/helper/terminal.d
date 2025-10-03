module redub.extensions.helper.terminal;

version(RedubCLI): version(RedubWatcher):
public import arsd.terminal;
void clearLines(ref Terminal t, ulong linesToClear, int startCursorY)
{
    t.moveTo(0, cast(int)startCursorY, ForceOption.alwaysSend);
    //SelectionHint
    foreach(i; 0..linesToClear)
        t.moveTo(0, cast(int)(startCursorY+i), ForceOption.alwaysSend), t.clearToEndOfLine();
    t.moveTo(0, cast(int)startCursorY, ForceOption.alwaysSend);
}

void drawChoices(ref Terminal t, string[] choices, string next, int startCursorY)
{
    enum SelectionHint = "--- Select an option by using Arrow Up/Down and choose it by pressing Enter. ---";
    t.flush();
    clearLines(t, choices.length+1, startCursorY);
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


bool selectChoiceBase(ref Terminal terminal, dchar key, string[] choices,
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
    clearLines(terminal, choices.length+1, startCursorY);
    terminal.moveTo(0, cast(int)startLine+1); //Jump title
    terminal.color(arsd.terminal.Color.green, arsd.terminal.Color.DEFAULT);
    terminal.writeln(">> ", choices[selectedChoice]);
    terminal.color(arsd.terminal.Color.DEFAULT, arsd.terminal.Color.DEFAULT);
    terminal.flush;

    return true;
}

auto getTerminal() { return Terminal(ConsoleOutputType.linear); }
auto getInput(ref Terminal t) { return RealTimeConsoleInput(&t, ConsoleInputFlags.raw); }
