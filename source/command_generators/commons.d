module command_generators.commons;

import std.string:join;
import std.array:join;

//Import the commonly shared buildapi
import buildapi;
//Blindly import project, app.d will handle that
import project;

import std.process;
import std.stdio;
import std.datetime.stopwatch;

string getExecutableExtension()
{
    version(Windows) return ".exe";
    else return null;
}

import std.system;

string getSharedLibraryExtension(OS os)
{
    switch(os)
    {
        case OS.win32, OS.win64: return ".dll";
        case OS.iOS, OS.osx, OS.tvOS, OS.watchOS: return ".dynlib";
        default: return ".so";
    }
}
string getLibraryExtension(OS os)
{
    switch(os)
    {
        case OS.win32, OS.win64: return ".lib";
        default: return ".a";
    }
}

string getExtension(OutputType t)
{
    final switch(t)
    {
        case OutputType.executable:
            return executableExt;
        case OutputType.library:
            return libExt;
        case OutputType.sharedLibrary:
            return sharedLibExt;
    }
}

string[] buildCommand(string[] extraImports = [], string[] extraVersions = [],
string[] extraLibs = [], string[] extraLibPaths = [])
{
    enum compiler = p.compiler.getCompiler;

    string[] cmd = [compiler];

    if(p.isDebug)
        cmd~= "-g";
    if(p.is64)
        cmd~= "-m64";
    
    final switch(p.outputType)
    {
        case OutputType.executable:
            break;
        case OutputType.library: 
            cmd~= "-lib";
            break;
        case OutputType.sharedLibrary:
            cmd~= "-shared";
            break;
    }

    foreach(i; p.importDirectories ~ extraImports)
        cmd~= "-I"~i;

    foreach(v; p.versions ~ extraVersions)
        cmd~= compiler.getVersion~v;


    foreach(l; p.libraries ~ extraLibs)
        cmd~= "-l"~l~libExt;
    foreach(lp; p.libraryPaths~extraLibPaths)
        cmd~= "-L-L"~lp;

    cmd~= "-i";
    cmd~= p.sourceEntryPoint;

    if(p.outputDirectory)
        cmd~= "-od"~p.outputDirectory;


    cmd~= "-of"~p.outputDirectory~pathSep~p.name ~ p.outputType.getExtension;

    return cmd;
}


/**
*   The command generator is a program which may receive the following arguments:
*   - getCommand : Executed automatically when hipmake runs hipmake command
*   - dependenciesResolved : That means this program is receiving the correct arguments
*   taking into account the dependencies
*/
int main(string[] args)
{ 

    string[] extraImports  = [];
    string[] extraVersions = [];
    string[] extraLibs     = [];
    string[] extraLibPaths = [];
    if(dependenciesResolved)
    {
        DependenciesPack p = packDependencies("", args[2]);
        extraImports = p.importPaths;
        extraVersions = p.versions;
        extraLibs = p.libs;
        extraLibPaths = p.libPaths;
    }

    if(getCommand)
        return returnCommandString(extraImports, extraVersions, extraLibs, extraLibPaths);

    StopWatch st = StopWatch(AutoStart.yes);
    auto ex = execute(buildCommand(extraImports, extraVersions, extraLibs, extraLibPaths));
    st.stop();
    if(ex.status)
    {
        return ex.status;
    }
    bool quiet = (args.length > 1) && args[1] == "quiet";
    

    if(!quiet)
        writeln("Built project '"~p.name~"' in ", (st.peek.total!"msecs"), " ms.") ;
    return 0;
}