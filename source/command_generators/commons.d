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

string getExtension(OutputType t, OS target)
{
    final switch(t)
    {
        case OutputType.executable: return target.getExecutableExtension;
        case OutputType.library: return target.getLibraryExtension;
        case OutputType.sharedLibrary: return target.getSharedLibraryExtension;
    }
}