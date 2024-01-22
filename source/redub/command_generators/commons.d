module redub.command_generators.commons;
public import redub.libs.semver;
public import std.system;
public import redub.compiler_identification;

//Import the commonly shared buildapi
import redub.buildapi;
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

void putSourceFiles(
    ref string[] output,
    const string workingDir,
    const string[] paths, 
    const string[] files, 
    const string[] excludeFiles,
    scope const string[] extensions...
)
{
    import std.file;
    import std.path;
    import std.string:endsWith;
    import std.algorithm.searching;

    size_t length = output.length;
    output.length+= files.length;

    foreach(i, f; files)
    {
        if(!isAbsolute(f)) output[length+i] = buildNormalizedPath(workingDir, f);
        else output[length+i] = f;
    }

    foreach(path; paths)
    {
        foreach(DirEntry e; dirEntries(path, SpanMode.depth))
        {
            if(countUntil(excludeFiles, e.name) != -1)
                continue;
            foreach(ext; extensions) 
            {
                if(e.name.endsWith(ext))
                {
                    output~= e.name;
                    break;
                }
            }
        }
    }
}

string[] getDSourceFiles(string path)
{
    import std.file;
    import std.string:endsWith;
    import std.array;
    import std.algorithm.iteration;
    return dirEntries(path, SpanMode.depth)
        .filter!((entry) => entry.name.endsWith(".d")).map!((entry => entry.name)).array;
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


bool isWindows(OS os){return os == OS.win32 || os == OS.win64;}

void createOutputDirFolder(immutable BuildConfiguration cfg)
{
    import std.file;
    if(cfg.outputDirectory)
        mkdirRecurse(cfg.outputDirectory);
}

string createCommandFile(immutable BuildConfiguration cfg, OS os, Compiler compiler, string[] flags, out string joinedFlags)
{
    import std.random;
    import std.string;
    import std.file;
    import std.conv;
    import std.path;
    Random seed = Random(unpredictableSeed);
    uint num = uniform(0, int.max, seed);
    joinedFlags = join(flags, " ");
    string fileName = buildNormalizedPath(tempDir, cfg.name~num.to!string);
    std.file.write(fileName, joinedFlags);
    return fileName;
}