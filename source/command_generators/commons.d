module command_generators.commons;
public import redub.libs.semver;
public import std.system;


//Import the commonly shared buildapi
import buildapi;
import std.process;
import std.datetime.stopwatch;


string getObjectDir(string projWorkingDir)
{
    import std.path;
    import std.file;

    static string objDir;
    if(objDir is null)
    {
        objDir = buildNormalizedPath(tempDir, ".redub");
        if(!exists(objDir)) mkdirRecurse(objDir);
    }
    return objDir;
}

string getExecutableExtension(OS os)
{
    if(os == OS.win32 || os == OS.win64)
        return ".exe";
    return null;
}


string getDynamicLibraryExtension(OS os)
{
    switch(os)
    {
        case OS.win32, OS.win64: return ".dll";
        case OS.iOS, OS.osx, OS.tvOS, OS.watchOS: return ".dylib";
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

bool isPosix(OS os)
{
    return !(os == OS.win32 || os == OS.win64);
}

string getExtension(TargetType t, OS target)
{
    final switch(t)
    {
        case TargetType.none: throw new Error("Invalid targetType: none");
        case TargetType.autodetect, TargetType.sourceLibrary: return null;
        case TargetType.executable: return target.getExecutableExtension;
        case TargetType.library, TargetType.staticLibrary: return target.getLibraryExtension;
        case TargetType.dynamicLibrary: return target.getDynamicLibraryExtension;
    }
}

string getOutputName(TargetType t, string name, OS os)
{
    string outputName;
    if(os.isPosix && t.isStaticLibrary)
        outputName = "lib";
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
        .filter!((entry) => { entry.name.endsWith(".d") || entry.name.endsWith(".c") || entry.name.endsWith(".cpp") ||
                              entry.name.endsWith(".cc") || entry.name.endsWith(".mm") || entry.name.endsWith(".cxx") ||
                            entry.name.endsWith(".c++"); })
        .map!((entry => entry.name)).array;
}

string[] getLinkFiles(const string[] filesToLink)
{
    import std.path;
    import std.array;
    import std.algorithm.iteration;
    return filesToLink.filter!((name) => name.extension.isLinkerValidExtension).array.dup;
}

T[] reverseArray(Q, T = typeof(Q.front))(Q range)
{
    T[] ret;
    static if(__traits(hasMember, Q, "length"))
    {
        ret = new T[](range.length);
        int i = 0;
        foreach_reverse(v; range)
            ret[i++] = v;
    }
    else foreach_reverse(v; range) ret~= v;
    return ret;
}

