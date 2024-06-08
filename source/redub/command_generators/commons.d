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

ISA isaFromArch(string arch)
{
    import std.string;
    static bool contains(string a, string b){return a.indexOf(b) != -1;}

    with(ISA)
    {
        if(contains(arch, "x86_64"))       return x86_64;
        else if(contains(arch, "aarch64")) return aarch64;
        else if(contains(arch, "wasm"))    return webAssembly;
        else if(contains(arch, "arm"))     return arm;
        else if(contains(arch, "x86"))     return x86;
    }
    return std.system.instructionSetArchitecture;
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

string getExecutableExtension(OS os, ISA isa = std.system.instructionSetArchitecture)
{
    if(isa == ISA.webAssembly)
        return ".wasm";
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

string getExtension(TargetType t, OS target, ISA isa)
{
    final switch(t)
    {
        case TargetType.none: return null;
        case TargetType.autodetect, TargetType.sourceLibrary: return null;
        case TargetType.executable: return target.getExecutableExtension(isa);
        case TargetType.library, TargetType.staticLibrary: return target.getLibraryExtension;
        case TargetType.dynamicLibrary: return target.getDynamicLibraryExtension;
    }
}

/** 
 * 
 * Params:
 *   t = The target type
 *   name = Base library name or path
 *   os = Which OS is this running on   
 * Returns: For a given library path (e.g: /some/path/a), will make it /some/path/a.[lib|dll] on Windows and /some/path/liba.[a|so] on POSIX
 */
string getOutputName(TargetType t, string name, OS os, ISA isa = std.system.instructionSetArchitecture)
{
    string outputName = name;
    if(os.isPosix && t.isAnyLibrary)
    {
        import std.path;
        import std.array;
        string[] paths = name.pathSplitter.array;
        paths[$-1] = "lib"~paths[$-1];
        outputName = buildPath(paths);
    }
    outputName~= t.getExtension(os, isa);
    return outputName;
}

string getOutputName(const BuildConfiguration cfg, OS os)
{
    import std.string;
    if(cfg.arch.indexOf("wasm") != -1)
        return cfg.name~".wasm";
    return getOutputName(cfg.targetType, cfg.name, os);
}

string escapePath(string sourceFile)
{
    import std.string;
    if(indexOf(sourceFile, ' ') != -1)
        return '"'~sourceFile~'"';
    return sourceFile;
}

string unescapePath(string targetPath)
{
    if(targetPath.length >= 2 && ((targetPath[0] == '"' && targetPath[$-1] == '"') || (targetPath[0] == '\'' && targetPath[$-1] == '\'')))
        return targetPath[1..$-1];
    return targetPath;
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
    

    static bool isFileHidden(DirEntry e)
    {
        version(Windows)
        {
            import core.sys.windows.winnt;
            return (e.attributes & FILE_ATTRIBUTE_HIDDEN) != 0;
        }
        else
        {
            return e.name.length >= 0 && e.name[0] == '.';
        }
    }



    foreach(path; paths)
    {
        DirEntryLoop: foreach(DirEntry e; dirEntries(unescapePath(path), SpanMode.depth))
        {
            import redub.misc.match_glob;
            foreach(exclusion; excludeFiles)
                if(e.name.matchesGlob(exclusion))
                    continue DirEntryLoop;
            if(isFileHidden(e) || e.isDir)
                continue;
            foreach(ext; extensions) 
            {
                if(e.name.endsWith(ext))
                {
                    output~= escapePath(e.name);
                    break;
                }
            }
        }
    }
    size_t length = output.length;
    output.length+= files.length;
    foreach(i, file; files)
    {
        if(output.countUntil(file) != -1)
        {
            import std.conv:to;
            throw new Exception("\n\tFile was specified twice: "~ "File '"~file~
                "' was specified in sourceFiles at directory '" ~ workingDir~"'. But it can already be found based on the current sourcePaths: "~
                paths.to!string ~ ".  Either add this file to excludeSourceFiles or remove it from sourceFiles."
            );
        }
        output[length+i] = escapePath(file);
    }
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
ref string[] mapAppendPrefix(return ref string[] appendTarget, const scope string[] mapInput, string prefix, bool shouldEscapeInput)
{
    if(mapInput.length == 0) return appendTarget;
    size_t length = appendTarget.length;
    appendTarget.length+= mapInput.length;

    foreach(i; 0..mapInput.length)
    {
        string input = shouldEscapeInput ? escapePath(mapInput[i]) : mapInput[i];
        char[] newStr = new char[](input.length+prefix.length);
        newStr[0..prefix.length] = prefix[];
        newStr[prefix.length..$] = input[];
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