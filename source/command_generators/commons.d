module command_generators.commons;
public import std.system;


//Import the commonly shared buildapi
import buildapi;
import std.process;
import std.stdio;
import std.datetime.stopwatch;

string getExecutableExtension(OS os)
{
    if(os == OS.win32 || os == OS.win64)
        return ".exe";
    return null;
}


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

string getExtension(TargetType t, OS target)
{
    final switch(t)
    {
        case TargetType.autodetect: return null;
        case TargetType.executable: return target.getExecutableExtension;
        case TargetType.library: return target.getLibraryExtension;
        case TargetType.sharedLibrary: return target.getSharedLibraryExtension;
    }
}

string getOutputName(TargetType t, string name, OS os)
{
    string outputName;
    if(t == TargetType.library) outputName = "lib";
    outputName~= name~t.getExtension(os);
    return outputName;
}



string[] getSourceFiles(string path)
{
    import std.file;
    import std.string:endsWith;
    import std.array;
    import std.algorithm.iteration;
    return dirEntries(path, SpanMode.depth)
        .filter!((entry) => entry.name.endsWith(".d"))
        .map!((entry => entry.name)).array;
}