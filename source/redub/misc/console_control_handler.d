module redub.misc.console_control_handler;

private void printPendingProjects() nothrow
{
    try
    {
        import std.stdio;
       // writeln("Executed CTRL+C");
    }
    catch(Exception e){}
}

void startHandlingConsoleControl()
{
    static bool hasStarted = false;
    if(!hasStarted)
    {
        hasStarted = true;
        // handleConsoleControl();
    }
}

version(Windows)
{
    import core.sys.windows.windef;
    private extern(Windows) BOOL handleConsoleControlWindows(DWORD ctrlType) nothrow
    {
        import core.sys.windows.wincon;
        switch ( ctrlType )
        {
            case CTRL_C_EVENT:
                printPendingProjects();
                return FALSE;
            default:
                return FALSE;
        }
    }
    private void handleConsoleControl()
    {
        import core.sys.windows.wincon;
        SetConsoleCtrlHandler(&handleConsoleControlWindows, 1);
    }
}
else version(Posix)
{
    private extern(C) void handleConsoleControlPosix(int sig)
    {
        printPendingProjects();
    }
    
    private void handleConsoleControl()
    {
        import core.sys.posix.signal;
        sigaction_t action;
        action.sa_handler = &handleConsoleControlPosix;
        sigaction(SIGINT, &action, null);
    }
}
