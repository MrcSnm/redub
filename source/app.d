import std.algorithm:countUntil;
import std.conv:to;
import std.array;
import std.path;
import std.file;
import std.process;
import std.stdio;

import buildapi;



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
/**
* DubV2 work with input -> output on each step. It must be almost stateless.
* ** CLI will be optionally implemented later. 
* ** Cache will be optionally implemented later
* 
* FindProject -> ParseProject -> MergeWithEnvironment -> ConvertToBuildFlags ->
* Build
*/
int main(string[] args)
{
    import building.cache;
    import package_searching.entry;
    import package_searching.dub;
    static import parsers.json;
    static import parsers.environment;
    static import command_generators.dmd;

    //TEST -> Take from args[1] the workingDir.
    string workingDir = std.file.getcwd();
    if(args.length > 1)
        workingDir = args[1];

    if(isUpToDate(workingDir))
    {

    }
    else
    {
        import std.datetime.stopwatch;
        import std.system;
        StopWatch st = StopWatch(AutoStart.yes);
        
        string projectFile = findEntryProjectFile(workingDir);

        BuildRequirements req;
        switch(extension(projectFile))
        {
            case ".json":  req = parsers.json.parse(projectFile); break;
            default: throw new Error("Unsupported project type "~projectFile);
        }
        req.cfg = req.cfg.merge(parsers.environment.parse());
        writeln = command_generators.dmd.parseBuildConfiguration(req.cfg, os);
        writeln = req.dependencies;

        writeln("Built project in ", (st.peek.total!"msecs"), " ms.") ;
    }

    return 0;
}