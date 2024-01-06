import std.algorithm:countUntil;
import std.conv:to;
import std.array;
import std.path;
import std.file;
import std.process;
import std.stdio;

import buildapi;




void createHipmakeFolder(string workingDir)
{
    std.file.mkdirRecurse(buildPath(workingDir, ".hipmake"));
}

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

bool willGetCommand = false;
string hipMakePath;

/**
*
*   All this file does is:
*   1. Search in the current directory for project.d
*   2. Use that directory as an import place for the project generator
*   3. Build the command generator together with the project.d (as it is being blindly imported )
*   4. Run the command generator using the project gotten from getProject function
*   5. Caches the command generated from the generator until project.d is modified.
*   6. If it is cached, it will only run the command
*/
int main(string[] args)
{
    import building.cache;
    import package_searching.entry;
    static import parsers.json;
    static import parsers.environment;

    string workingDir = std.file.getcwd();
    if(isUpToDate(workingDir))
    {

    }
    else
    {
        import std.datetime.stopwatch;
        StopWatch st = StopWatch(AutoStart.yes);
        string projectFile = findEntryProjectFile(workingDir);

        BuildConfiguration base;
        switch(extension(projectFile))
        {
            case ".json":  base = parsers.json.parse(projectFile).cfg; break;
            default: throw new Error("Unsupported project type "~projectFile);
        }
        base = parsers.environment.parse().merge(base);

        writeln("Built project in ", (st.peek.total!"msecs"), " ms.") ;
    }

    return 0;
}