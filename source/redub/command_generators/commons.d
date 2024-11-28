module redub.command_generators.commons;
public import redub.libs.semver;
public import std.system;
public import redub.compiler_identification;

//Import the commonly shared buildapi
import redub.buildapi;
public import std.file:DirEntry;


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


string getObjectDir(string cacheDir)
{
    import std.path;
    import std.file;

    string objDir = buildNormalizedPath(cacheDir, "..", "obj/");
    if(!exists(objDir)) 
        mkdirRecurse(objDir);
    return objDir;
}

string stripLibraryExtension(string libpath)
{
    import std.path;
    switch(extension(libpath))
    {
        case ".a", ".lib", ".so", ".dll", ".dylib":
            return stripExtension(libpath);
        default:
            return libpath;
    }
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
/** 
 * 
 * Params:
 *   conf = The configuration
 *   os = OS in which is being built for
 * Returns: A name with an extension that should be used for compiling
 */
string getConfigurationOutputName(const BuildConfiguration conf, OS os)
{
    import redub.building.cache;
    with(conf)
    {
        if(targetType.isStaticLibrary)
            return getOutputName(targetType, targetName, os);
        return targetName~getObjectExtension(os);
    }
}

string getDepsFilePath(ProjectNode root, CompilingSession s)
{
    import redub.building.cache;
    string packHash = hashFrom(root.requirements, s);
    return getDepsFilePath(getCacheOutputDir(packHash, root.requirements.cfg, s, root.isRoot));
}

string getDepsFilePath(string cacheDir)
{
    return cacheDir~".deps";
}

/** 
 * 
 * Params:
 *   conf = The configuration
 *   os = OS in which is being built for
 * Returns: A path with an extension that should be used for compiling
 */
string getConfigurationOutputPath(const BuildConfiguration conf, OS os)
{
    import std.path;
    return buildNormalizedPath(conf.outputDirectory, getConfigurationOutputName(conf, os));
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
        case TargetType.invalid: throw new Exception("Can't use invalid targetType.");
        case TargetType.none: return null;
        case TargetType.autodetect, TargetType.sourceLibrary: return null;
        case TargetType.executable: return target.getExecutableExtension(isa);
        case TargetType.library, TargetType.staticLibrary: return target.getLibraryExtension;
        case TargetType.dynamicLibrary: return target.getDynamicLibraryExtension;
    }
}

void copyDir(string fromDir, string toDir, bool shallow = true)
{
    import std.file;
    import std.path;
    import std.exception;
    import redub.misc.hard_link;
    enforce(isDir(fromDir), "Input must be a directory");

    if(!exists(toDir))
        mkdirRecurse(toDir);
    else
        enforce(isDir(toDir), "Output must be a directory");

    foreach(DirEntry e; dirEntries(fromDir, shallow ? SpanMode.shallow : SpanMode.depth))
        hardLinkFile(e.name, buildNormalizedPath(toDir, baseName(e.name)), true);
}

/** 
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
        import std.string;
        string[] parts = split(name, dirSeparator);
        parts[$-1] = "lib"~parts[$-1];
        outputName = join(parts, dirSeparator);
    }
    outputName~= t.getExtension(os, isa);
    return outputName;
}

/** 
 * Params:
 *   cfg = The configuration to read target name and type
 *   os = Which OS is this running on   
 *   isa = ISA which it is being built for
 * Returns: For a given library path (e.g: /some/path/a), will make it /some/path/a.[lib|dll] on Windows and /some/path/liba.[a|so] on POSIX
 */
string getOutputName(const BuildConfiguration cfg, OS os, ISA isa = std.system.instructionSetArchitecture)
{
    import std.string;
    if(cfg.arch.indexOf("wasm") != -1)
        return cfg.targetName~".wasm";
    return getOutputName(cfg.targetType, cfg.targetName, os, isa);
}

/** 
 * 
 * Params:
 *   cfg = The configuration to get the output path
 *   type = Which is the target type. This gives more flexibility
 *   os = The OS in which it is being built for
 *   isa = The ISA it is being built for
 * Returns: The output path for the given arguments
 */
string getOutputPath(const BuildConfiguration cfg, TargetType type, OS os, ISA isa = std.system.instructionSetArchitecture)
{
    import std.path;
    return buildNormalizedPath(cfg.outputDirectory, getOutputName(type, cfg.targetName, os, isa));
}
/** 
 * 
 * Params:
 *   cfg = The configuration to get the output path
 *   os = The OS in which it is being built for
 *   isa = The ISA it is being built for
 * Returns: The output path for the given arguments
 */
string getOutputPath(const BuildConfiguration cfg, OS os, ISA isa = std.system.instructionSetArchitecture)
{
    return getOutputPath(cfg, cfg.targetType, os, isa);
}

string[] getExpectedArtifacts(const BuildRequirements req, OS targetOS, ISA isa)
{
    import redub.command_generators.commons;
    ///Adds the output to the expectedArtifact. Those files will be considered on the cache formula.
    string[] ret = [getOutputPath(req.cfg, targetOS, isa)];
    ///When windows builds shared libraries and they aren't root, it also generates a static library (import library)
    ///This library will enter on the cache formula
    if(targetOS.isWindows && req.cfg.targetType == TargetType.dynamicLibrary)
        ret ~= getOutputPath(req.cfg, TargetType.staticLibrary, targetOS, isa);
    return ret; 
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
bool isFileHidden(DirEntry e)
{
    version(Windows)
    {
        import core.sys.windows.winnt;
        return (e.attributes & FILE_ATTRIBUTE_HIDDEN) != 0;
    }
    else
    {
        return e.name.length == 0 || e.name[0] == '.';
    }
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
    
    foreach(path; paths)
    {
        DirEntryLoop: foreach(DirEntry e; dirEntries(unescapePath(path), SpanMode.depth))
        {
            foreach(exclusion; excludeFiles)
                if(e.name.globMatch(exclusion))
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
    if(files.length == 0)
        return;
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


///On Windows, when trying to rename in a different drive, it throws. Use copy instead
void renameOrCopy(string from, string to)
{
    import std.file;
    version(Windows)
    {
        import std.path;
        if(driveName(from) != driveName(to))
        {
            std.file.copy(from, to);
            std.file.remove(from);
        }
        else
            std.file.rename(from, to);
    }
    else return std.file.rename(from, to);
}

///DMD only when using -op
void moveGeneratedObjectFiles(
    const string[] paths, 
    const string[] files, 
    const string[] excludeFiles,
    string moveDir,
    string extension
)
{
    import std.file;
    import std.path;
    import std.string:endsWith;
    import std.algorithm.searching;
    import std.exception;
    foreach(path; paths)
    {
        string basePath = unescapePath(path);
        DirEntryLoop: foreach(DirEntry e; dirEntries(basePath, SpanMode.depth))
        {
            foreach(exclusion; excludeFiles)
                if(e.name.globMatch(exclusion))
                    continue DirEntryLoop;
            if(isFileHidden(e) || e.isDir)
                continue;
            if(e.name.endsWith(extension))
            {
                string targetPath = buildNormalizedPath(moveDir, e.name[basePath.length+1..$]);
                string targetDir = dirName(targetPath);
                if(!exists(targetDir))
                    mkdirRecurse(targetDir);
                renameOrCopy(e.name, targetPath);
            }
        }
    }
    foreach(i, file; files)
    {
        string targetPath = buildNormalizedPath(moveDir, baseName(setExtension(file, extension)));
        renameOrCopy(file, targetPath);
    }
}


string[] getLinkFiles(const string[] filesToLink)
{
    import std.path;
    import std.array;
    import std.algorithm.iteration;
    return cast(string[])filesToLink.filter!((string name) => extension(name).isLinkerValidExtension).array; //Array already guarantee nothing is modified.
}

string[] getLibFiles(const string[] filesToLink)
{
    import std.path;
    import std.array;
    import std.algorithm.iteration;
    return cast(string[])filesToLink.filter!((string name) => extension(name).isLibraryExtension).array; //Array already guarantee nothing is modified.
}

BuildConfiguration getConfigurationFromLibsWithPkgConfig(string[] libs, out string[] modifiedFlagsFromPkgConfig)
{
    import std.algorithm : startsWith, splitter;
    import std.string: strip;
    import std.array : split;
    import std.process;
    import std.parallelism;


    bool existsPkgConfig = true;

    static string[string] pkgConfigCache;

    static string[] pkgconfig_bin = ["pkg-config", "--libs"];

    struct LinkCommand
    {
        string flags;
        bool isLibrary;
    }

    LinkCommand[] commands = new LinkCommand[](libs.length);

    BuildConfiguration ret;
    foreach(i, l; parallel(libs))
    {
        commands[i] = LinkCommand(l, true);
        if(l in pkgConfigCache)
            commands[i] = LinkCommand(pkgConfigCache[l], false);
        else if(existsPkgConfig)
        {
            try
            {
                foreach(cmd; parallel([l, "lib"~l]))
                {
                    auto flags = execute(pkgconfig_bin~cmd);
                    if(flags.status == 0 && flags.output.strip.length != 0)
                    {
                        pkgConfigCache[cmd] = flags.output;
                        commands[i] = LinkCommand(flags.output, false);
                    }
                }
            }
            catch(ProcessException e)
                existsPkgConfig = false;
        }
    }
    foreach(cmd; commands)
    {
        if(cmd.isLibrary)
            ret.libraries~= cmd.flags;
        else if(cmd.flags.length)        
        {
            modifiedFlagsFromPkgConfig~= cmd.flags;
            foreach (string f; splitter(cmd.flags))
            {
                if (f.startsWith("-L-L"))
                    ret.linkFlags ~= f[2 .. $];
                else if (f.startsWith("-defaultlib"))
                    ret.dFlags~= f;
                else if (f.startsWith("-L-defaultlib"))
                    ret.dFlags~= f[2 .. $];
                else if (f.startsWith("-pthread"))
                    ret.linkFlags~= "-lpthread";
                else if (f.startsWith("-L-l"))
                    ret.linkFlags~= f[2 .. $].split(",");
                else if (f.startsWith("-Wl,"))
                    ret.linkFlags~= f[4 .. $].split(",");
                else
                    ret.linkFlags~= f;
            }
        }
    }
    return ret;
}

ref T[] append(T, TRange)(ref T[] theArray, TRange theRange)
{
    static if(__traits(hasMember, theRange, "length"))
    {
        size_t curr = theArray.length;
        theArray.length+= theRange.length;
        foreach(elem; theRange)
            theArray[curr++] = elem;
    }
    else
    {
        foreach(elem; theRange)
            theArray~= elem;
    }
    return theArray;
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

void createOutputDirFolder(const BuildConfiguration cfg)
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

string createCommandFile(const BuildConfiguration cfg, string[] flags, out string joinedFlags)
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