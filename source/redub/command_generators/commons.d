module redub.command_generators.commons;
public import redub.libs.semver;
public import std.system;
public import redub.compiler_identification;

//Import the commonly shared buildapi
import redub.buildapi;
import std.process;
import std.datetime.stopwatch;


OS osFromArch(string arch)
{
    import std.string;
    static bool contains(string a, string b){return a.indexOf(b) != -1;}
    if(contains(arch, "x86_64-windows")) return OS.win64;
    else if(contains(arch, "i686-windows")) return OS.win32;
    else if(contains(arch, "android")) return OS.android;
    else if(contains(arch, "linux")) return OS.linux;
    else if(contains(arch, "macos")) return OS.osx;
    else if(contains(arch, "ios")) return OS.iOS;
    else if(contains(arch, "wasm32")) return OS.otherPosix;
    else return std.system.os;
}

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


string getLibraryPath(string libName, string outputDir, OS os)
{
    import std.path;
    if(!isAbsolute(libName))
    {
        if(libName.length > 3 && libName[0..3] == "lib") libName = libName[3..$];
        if(extension(libName)) libName = stripExtension(libName);
        return buildNormalizedPath(outputDir, getOutputName(TargetType.staticLibrary, libName, os));
    }
    else
    {
        string name = baseName(libName);
        if(extension(name)) name = stripExtension(name);
        if(name.length > 3 && name[0..3] == "lib") name = name[3..$];
        if(name == libName) return libName;
        string dir = dirName(libName);

        return buildNormalizedPath(dir, getOutputName(TargetType.staticLibrary, name, os));
    }
    
}

string getConfigurationOutputPath(const BuildConfiguration conf, OS os)
{
    import std.path;
    with(conf)
    {
        if(targetType.isStaticLibrary)
            return buildNormalizedPath(outputDirectory, getOutputName(targetType, name, os));
        return buildNormalizedPath(outputDirectory, name~getObjectExtension(os));
    }
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
    return ext == ".a" || ext == ".lib";
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
    if(os.isPosix && t.isAnyLibrary)
        outputName = "lib";
    outputName~= name~t.getExtension(os);
    return outputName;
}

string getOutputName(const BuildConfiguration cfg, OS os)
{
    import std.string;
    if(cfg.arch.indexOf("wasm") != -1)
        return cfg.name~".wasm";
    return getOutputName(cfg.targetType, cfg.name, os);
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
    import std.exception;

    size_t length = output.length;
    output.length+= files.length;
    output[length..length+files.length] = files[];

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

/** 
 * This function is a lot more efficient than map!.array, since it won't need to 
 * allocate intermediary memory and won't use range interface
 * Params:
 *   appendTarget = The target in which will have the mapInput appended
 *   mapInput = Array which is going to be mapped
 *   mapFn = Map conversion function
 * Returns: appendTarget with the mapped elements from mapInput appended
 */
ref string[] mapAppend(Q, T)(return ref string[] appendTarget, const scope Q[] mapInput, scope T delegate(Q) mapFn)
{
    if(mapInput.length == 0) return appendTarget;
    size_t length = appendTarget.length;
    appendTarget.length+= mapInput.length;

    foreach(i; 0..mapInput.length)
        appendTarget[length++] = mapFn(mapInput[i]);
    return appendTarget;
}
/** 
 * This function is a is a less generic mapAppend. It constructs the array with more efficiency
 * Params:
 *   appendTarget = The target in which will have the mapInput appended
 *   mapInput = Array which is going to be mapped
 *   prefix = Prefix before appending
 * Returns: appendTarget with the mapped elements from mapInput appended
 */
ref string[] mapAppendPrefix(return ref string[] appendTarget, const scope string[] mapInput, string prefix)
{
    if(mapInput.length == 0) return appendTarget;
    size_t length = appendTarget.length;
    appendTarget.length+= mapInput.length;

    foreach(i; 0..mapInput.length)
    {
        char[] newStr = new char[](mapInput[i].length+prefix.length);
        newStr[0..prefix.length] = prefix[];
        newStr[prefix.length..$] = mapInput[i][];
        appendTarget[length++] = cast(string)newStr;
    }
    return appendTarget;
}

ref string[] mapAppendReverse(Q, T)(return ref string[] appendTarget, const scope Q[] mapInput, scope T delegate(Q) mapFn)
{
    if(mapInput.length == 0) return appendTarget;
    size_t length = appendTarget.length;
    appendTarget.length+= mapInput.length;

    foreach(i; 0..mapInput.length)
        appendTarget[length++] = mapFn(mapInput[$-(i+1)]);
    return appendTarget;
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