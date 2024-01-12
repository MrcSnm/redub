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

string getObjectExtension(OS os)
{
    switch(os)
    {
        case OS.win32, OS.win64: return ".obj";
        default: return ".o";
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

bool isLibraryExtension(string ext)
{
    switch(ext)
    {
        case ".a", ".lib": return true;
        default: return false;
    }
}
bool isObjectExtension(string ext)
{
    switch(ext)
    {
        case ".o", ".obj": return true;
        default: return false;
    }
}

bool isLinkerValidExtension(string ext)
{
    return isObjectExtension(ext) || isLibraryExtension(ext);
}

string getExtension(TargetType t, OS target)
{
    final switch(t)
    {
        case TargetType.autodetect, TargetType.sourceLibrary: return null;
        case TargetType.executable: return target.getExecutableExtension;
        case TargetType.library, TargetType.staticLibrary: return target.getLibraryExtension;
        case TargetType.sharedLibrary: return target.getSharedLibraryExtension;
    }
}

string getOutputName(TargetType t, string name, OS os)
{
    string outputName;
    if(t == TargetType.library || t == TargetType.staticLibrary) outputName = "lib";
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

string[] getLinkFiles(const string[] filesToLink)
{
    import std.path;
    import std.array;
    import std.algorithm.iteration;
    return filesToLink.filter!((name) => name.extension.isLinkerValidExtension).array.dup;
}