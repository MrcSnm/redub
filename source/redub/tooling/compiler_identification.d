module redub.tooling.compiler_identification;
public import redub.libs.semver;
public import redub.tooling.archiver_identification;
public import redub.tooling.linker_identification;
public import redub.tooling.compilers_inference : saveGlobalCompiler, tryGetCompilerOnCwd;
import hip.data.json;
import std.algorithm.setops;


enum AcceptedCompiler : ubyte
{
    invalid,
    dmd,
    ldc2,
    gcc,
    gxx,
    clang,
    ///Microsoft MSVC compiler
    cl
}


AcceptedCompiler acceptedCompilerfromString(string str)
{
    switch(str)
    {
        static foreach(mem; __traits(allMembers, AcceptedCompiler))
        {
            case mem:
                return __traits(getMember, AcceptedCompiler, mem);
        }
        default:
            throw new Exception("Invalid AcceptedCompiler string received: "~str);
    }
}



struct CompilerBinary
{
    AcceptedCompiler compiler;
    string bin;
    ///Version of the compiler used.
    SemVer version_;
    ///D Only - Which frontend was based
    SemVer frontendVersion;
    ///Contents of executing binOrPath --version
    string versionString;



    string getCompilerString() const
    {
        final switch(compiler) with(AcceptedCompiler)
        {
            case dmd: return "dmd";
            case ldc2: return "ldc";
            case gcc: return "gcc";
            case gxx: return "g++";
            case clang: return "clang";
            case cl: return "cl";
            case invalid: return null;
        }
    }

    string getCompilerWithVersion() const
    {
        return getCompilerString()~" "~version_.toString;
    }
}


/**
 * Using this structure, it is possible to use any compiler with any version as long
 * they are the valid AcceptedCompiler list.
 */
struct Compiler
{
    ///Accepted compiler is used for getting the commands
    CompilerBinary d;
    ///C compiiler that will be used when finding C proejcts
    CompilerBinary c;

    /**
     * Currently a flag that only affects Windows. Usually it is turned off since depending on the case, it might
     * make compilation slower
     */
    bool usesIncremental = false;

    ///Currently unused. Was used before for checking whether --start-group should be emitted or not. Since it is emitted
    ///by default, only on webAssembly which is not, it lost its usage for now.
    AcceptedLinker linker = AcceptedLinker.unknown;
}

bool isDCompiler(const CompilerBinary comp)
{
    return isDCompiler(comp.compiler);
}
bool isDCompiler(AcceptedCompiler c)
{
    return c == AcceptedCompiler.dmd || c == AcceptedCompiler.ldc2;
}


/**
 * Redub will try to search compilers in that order if the D compiler on getCompiler is not found.
 */
immutable string[] supportedDCompilers = [
    "dmd",
    "ldc2"
];

immutable string[] supportedCCompilers = [
    "cl",
    "clang",
    "g++",
    "gcc",
];

version(Windows)
    private string defaultCCompiler = "cl";
else version(OSX)
    private string defaultCCompiler = "clang";
else
    private string defaultCCompiler = "gcc";


string tryGetStr(JSONValue v, string key)
{
    JSONValue* ret = key in v;
    return ret ? ret.str : null;
}

/**
 * Use this function to get extensive information about the Compiler to use.
 * Params:
 *   compilerOrPath = Can be used both as a global, such as `dmd` or a complete path to a compiler. If null, defaults to DMD
 *   compilerAssumption = Optinal version string, such as `dmd v[2.105.0] f[2.106.0]`, v being its version, f being frontend version
 *   arch = Used mainly for identifying which ldc.conf to take, and by using it, it is possible to detect the default linker for the specific arch
 * Returns: The Compiler information that was found, or inferred if compilerAssumption was used.
 */
Compiler getCompiler(string compilerOrPath = "dmd", string cCompilerOrPath = null, string compilerAssumption = null, string arch = null)
{
    import std.algorithm.comparison:either;
    import redub.meta;

    JSONValue compilersInfo = getRedubMeta();
    bool isDefault = compilerOrPath == null;
    compilerOrPath = either(compilerOrPath, tryGetStr(compilersInfo, "defaultCompiler"), "dmd");
    cCompilerOrPath = either(cCompilerOrPath, tryGetStr(compilersInfo, "defaultCCompiler"), defaultCCompiler);

    Compiler ret;

    ret.d = searchCompiler(compilerOrPath, compilersInfo, isDefault, false, compilerAssumption);
    if(cCompilerOrPath)
    {
        import redub.tooling.msvc_getter;
        version(Windows)
            setupMsvc(compilersInfo);
        ret.c = searchCompiler(cCompilerOrPath, compilersInfo, true, true);
        version(Windows)
        {
            if(ret.c.compiler == AcceptedCompiler.cl)
            {
                if(!setupMsvc(compilersInfo))
                    throw new Exception("Defectable Environment: Could not setup MSVC");
            }
        }

    }

    ret.linker = acceptedLinkerfromString(compilersInfo["defaultLinker"].str);

    //Checks for ldc.conf switches to see if it is using gnu linker by default
    ///TODO: Might be reactivated if that issue shows again.
    // if(ret.compiler == AcceptedCompiler.ldc2)
    // {
    //     int res = isUsingGnuLinker(ret.binOrPath, arch);
    //     if(res != UsesGnuLinker.unknown)
    //         ret.usesGnuLinker = res == UsesGnuLinker.yes ? true : false;
    // }


    return ret;
}
private CompilerBinary searchCompiler(string compilerOrPath, JSONValue compilersInfo, bool isDefault, bool isC, string compilerAssumption = null)
{
    import redub.misc.find_executable;
    import redub.tooling.compilers_inference;
    import std.path;
    import std.file;
    bool isGlobal = false;

    CompilerBinary ret;
    //Try get compiler on global cache with global cached paths
    if(!isAbsolute(compilerOrPath))
    {
        string locCompiler = tryGetCompilerOnCwd(compilerOrPath);
        if(locCompiler != compilerOrPath)
            compilerOrPath = locCompiler;
        else
        {
            ret = getCompilerFromGlobalPath(compilerOrPath, compilersInfo);
            isGlobal = true;
        }
    }
    //Try finding the compiler globally and getting it from cache
    if(ret == CompilerBinary.init)
    {
        compilerOrPath = findExecutable(compilerOrPath);
        ret = getCompilerFromCache(compilersInfo, compilerOrPath);
    }
    //Try inferring the compiler and saving its infos
    if(ret == CompilerBinary.init)
        ret = inferCompiler(compilerOrPath, compilerAssumption, compilersInfo, isDefault, isGlobal, isC);
    return ret;
}



private CompilerBinary getCompilerFromGlobalPath(string compilerOrPath, JSONValue compilersInfo)
{
    if(JSONValue* globalPaths = "globalPaths" in compilersInfo)
    {
        if(JSONValue* cachedPath = compilerOrPath in *globalPaths)
            return getCompilerFromCache(compilersInfo, cachedPath.str);
    }
    return CompilerBinary.init;
}




private CompilerBinary getCompilerFromCache(JSONValue allCompilersInfo, string compiler)
{
    import std.exception;
    import std.file;

    enum ACCEPTED_COMPILER = 0;
    enum VERSION_ = 1;
    enum FRONTEND_VERSION = 2;
    enum VERSION_STRING = 3;
    enum TIMESTAMP = 4;

    if(!compiler.length)
    {
        JSONValue* def = "defaultCompiler" in allCompilersInfo;
        if(def != null)
            compiler = def.str;
    }
    JSONValue* comps = "compilers" in allCompilersInfo;
    if(comps)
    {
        foreach(key, value; comps.object)
        {
            enforce(value.type == JSONType.array, "Expected that the value from object "~key~" were an array.");
            if(key == compiler && std.file.exists(key))
            {
                JSONValue[] arr = value.array;

                if(arr[TIMESTAMP].get!long != timeLastModified(key).stdTime)
                    return CompilerBinary.init;

                return CompilerBinary(
                    acceptedCompilerfromString(arr[ACCEPTED_COMPILER].str),
                    key,
                    SemVer(arr[VERSION_].str),
                    SemVer(arr[FRONTEND_VERSION].str),
                    arr[VERSION_STRING].str,
                );
            }
        }
    }

    return CompilerBinary.init;
}

/**
* The file format is as specified:
```json
{
    "C:\\D\\dmd\\dmd2\\windows\\bin64\\dmd.exe": ["dmd", "version_.toString", "frontendVersion.toString", "versionString"]
}
```
 * Params:
 *   allCompilersInfo = The JSON value of the current redub compilers info
 *   compiler = The new compiler to add. It will also save usesGnuLinker inside compiler
 *   isDefault = saves the compiler as the default compiler
 *   isGlobal = Saves the compiler as a globalPath. For example, it will use the path whenever expected to find in global path when "dmd" is sent or "ldc2" (i.e: no real path)
 *   isC = If is a C compiler
 */
void saveCompilerInfo(JSONValue allCompilersInfo, ref CompilerBinary compiler, bool isDefault, bool isGlobal, bool isC)
{
    import redub.meta;
    import std.conv:to;
    import redub.buildapi;
    import std.file;

    string compilerStr = compiler.compiler.to!string;

    if(isDefault)
    {
        allCompilersInfo[isC ? "defaultCCompiler" : "defaultCompiler"] = JSONValue(compilerStr);
    }


    if(isGlobal)
    {
        if(!("globalPaths" in allCompilersInfo))
            allCompilersInfo["globalPaths"] = JSONValue.emptyObject;
        allCompilersInfo["globalPaths"][compilerStr] = JSONValue(compiler.bin);
    }

    if(!("defaultLinker" in allCompilersInfo))
        allCompilersInfo["defaultLinker"] = getDefaultLinker.to!string;

    if(!("compilers" in allCompilersInfo))
        allCompilersInfo["compilers"] = JSONValue.emptyObject;


    allCompilersInfo["compilers"][compiler.bin] = JSONValue([
        JSONValue(compilerStr),
        JSONValue(compiler.version_.toString),
        JSONValue(compiler.frontendVersion.toString),
        JSONValue(compiler.versionString),
        JSONValue(timeLastModified(compiler.bin).stdTime)
    ]);

    saveRedubMeta(allCompilersInfo);
}

