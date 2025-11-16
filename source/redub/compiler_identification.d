module redub.compiler_identification;
public import redub.libs.semver;
public import redub.archiver_identification;
public import redub.linker_identification;
import hip.data.json;
import std.algorithm.setops;


enum AcceptedCompiler : ubyte
{
    invalid,
    dmd,
    ldc2,
    gcc,
    gxx,
    clang
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
immutable string[] searchableCompilers = [
    "dmd",
    "ldc2"
];


/**
 * Tries to find in the local folder for an executable file with the name of compilerOrPath.
 * They are only searched if the path is not absolute
 * Params:
 *   compilerOrPath = The base compiler name to search on the current directory.
 * Returns:
 */
private string tryGetCompilerOnCwd(string compilerOrPath)
{
    import redub.misc.path;
    import std.path;
    if(!isAbsolute(compilerOrPath))
    {
        import std.file;
        string tempPath = redub.misc.path.buildNormalizedPath(getcwd(), compilerOrPath);
        version(Windows) enum targetExtension = ".exe";
        else enum targetExtension = string.init;
        //If it does not, simply assume global
        if(exists(tempPath) && !isDir(tempPath) && tempPath.extension == targetExtension)
        {
            import redub.logging;
            compilerOrPath = tempPath;
            warn("Using compiler found on current directory: "~tempPath);
        }
    }
    return compilerOrPath;
}

/**
 * Tries to find the compiler to use. If the preferred compiler is not on the user environment, it will
 * warn and use it instead.
 * Params:
 *   preferredCompiler = The compiler that the user may have specified.
 *   actualCompiler = Actual compiler. If no compiler is found on the searchable list, the program will exit.
 * Returns: The output from executeShell. This will be processed for getting version information on the compiler.
 */
private string getActualCompilerToUse(string preferredCompiler, ref string actualCompiler)
{
    import std.exception;
    import std.typecons;
    import std.process;
    import redub.logging;
    Tuple!(int, "status", string, "output") compVersionRes;

    bool preferredTested = false;
    foreach(string searchable; preferredCompiler~searchableCompilers)
    {
        if(preferredTested && searchable == preferredCompiler)
            continue;
        if(searchable != preferredCompiler)
            searchable = tryGetCompilerOnCwd(searchable);
        else
            preferredTested = true;
        compVersionRes = executeShell(searchable ~ " --version");
        if(compVersionRes.status == 0)
        {
            actualCompiler = searchable;
            break;
        }
    }

    if(compVersionRes.status != 0)
    {
        throw new Exception(preferredCompiler~ " --version returned a non zero code. "~
        "In Addition, dmd and ldc2 were also tested and were not found. You may need to download or specify them before using redub.\n" ~
        "If you don't have any compiler added in the PATH, you can install it by using 'redub install dmd' and then do 'redub use dmd'\n" ~
        "it will setup the compiler to use with redub. \n"~
        "Last Shell Output: "~ compVersionRes.output);
    }
    if(actualCompiler != preferredCompiler)
        warn("The compiler '"~preferredCompiler~"' that was specified in your system wasn't found. Redub found "~actualCompiler~" and it will use for this compilation.");

    return compVersionRes.output;
}

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
    cCompilerOrPath = either(cCompilerOrPath, tryGetStr(compilersInfo, "defaultCCompiler"), "clang");

    Compiler ret;

    ret.d = searchCompiler(compilerOrPath, compilersInfo, isDefault, false, compilerAssumption);
    if(cCompilerOrPath)
        ret.c = searchCompiler(cCompilerOrPath, compilersInfo, true, true);

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

private immutable bool function(string compilerOrPath, string vString, out CompilerBinary comp)[5] compilersInference = [
    &tryInferDmd,
    &tryInferLdc,
    &tryInferGcc,
    &tryInferGxx,
    &tryInferClang,
];

/**
 *
 * Params:
 *   compilerOrPath = The path where the compiler is
 *   compilerAssumption = Assumption that will make skip --version call
 *   compilersInfo = Used for saving metadata
 *   isDefault = Used for metadata
 *   isGlobal = Used for metadata
 *   isC = Used for metadata
 * Returns: The compiler that was inferrred from the given info
 */
private CompilerBinary inferCompiler(string compilerOrPath, string compilerAssumption, JSONValue compilersInfo, bool isDefault, bool isGlobal, bool isC)
{
    import redub.misc.find_executable;
    CompilerBinary ret;

    if(compilerAssumption == null)
    {
        string actualCompiler;
        string versionString = getActualCompilerToUse(compilerOrPath, actualCompiler);
        foreach(inf; compilersInference)
        {
            if(inf(actualCompiler, versionString, ret))
            {
                ret.bin = findExecutable(ret.bin);
                saveCompilerInfo(compilersInfo, ret, isDefault, isGlobal, isC);
                return ret;
            }
        }
    }
    else
    {
        return assumeCompiler(compilerOrPath, compilerAssumption);
    }
    throw new Exception("Could not infer which compiler you're using from "~compilerOrPath);
}

/**
 *
 * Params:
 *   compilerPath = The path where the compiler is
 *   compilerAssumption = Assumption that will make skip --version call
 *   compilersInfo = Used for saving metadata
 *   isDefault = Used for metadata
 *   isGlobal = Used for metadata
 *   isC = Used for metadata
 * Returns: The compiler that was inferrred from the given info
 */
public void saveGlobalCompiler(string compilerPath, JSONValue compilersInfo, bool isDefault, bool isC)
{
    import redub.misc.find_executable;
    import std.process;

    CompilerBinary ret;
    string actualCompiler;
    auto res = executeShell(compilerPath~" --version");
    if(res.status)
        throw new Exception("saveGlobalCompiler was called in an inexistent compiler.");
    foreach(inf; compilersInference)
    {
        if(inf(actualCompiler, res.output, ret))
        {
            ret.bin = compilerPath;
            saveCompilerInfo(compilersInfo, ret, isDefault, true, isC);
            return;
        }
    }
    throw new Exception("Could not infer which compiler you're using from "~compilerPath);
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

private CompilerBinary assumeCompiler(string compilerOrPath, string compilerAssumption)
{
    import std.string;
    import std.exception;
    CompilerBinary ret;
    ret.bin = compilerOrPath;
    ret.versionString = compilerAssumption;
    ptrdiff_t compEndIndex = indexOfAny(compilerAssumption, [' ']);
    enforce(compEndIndex != -1, "Expected 'compiler v[...] f[...]'. The compiler assumption must have a space between it and its version/frontend");
    string compiler = compilerAssumption[0..compEndIndex];

    switch(compiler)
    {
        case "dmd":
            ptrdiff_t _;
            string dmdVer = inBetween(compilerOrPath, "v[", "]", _);
            enforce(dmdVer is null, "Can only assume compiler with versions, received "~compilerAssumption);
            string feVer = inBetween(compilerOrPath, "f[", "]", _);
            ret.compiler = AcceptedCompiler.dmd;
            ret.version_ = SemVer(dmdVer);
            ret.frontendVersion = feVer is null ? ret.version_ : SemVer(feVer);
            break;
        case "ldc", "ldc2":
            ptrdiff_t _;
            string ldcVer = inBetween(compilerOrPath, "v[", "]", _);
            enforce(ldcVer is null, "Can only assume compiler with versions, received "~compilerAssumption);
            string feVer = inBetween(compilerOrPath, "f[", "]", _);
            enforce(feVer is null, "LDC2 must contain a frontend version, received "~compilerAssumption);
            ret.compiler = AcceptedCompiler.ldc2;
            ret.version_ = SemVer(ldcVer);
            ret.frontendVersion = SemVer(feVer);
            break;
        default: throw new Exception("Can only assume dmd, ldc and ldc2 at this moment, received "~compilerAssumption);
    }
    return ret;
}


private bool tryInferLdc(string compilerOrPath, string vString, out CompilerBinary comp)
{
    import std.exception;
    import std.string;

    ptrdiff_t indexRight = 0;
    string ldcVerStr = inBetween(vString, "LDC - the LLVM D compiler (", ")", indexRight);
    ///Identify LDC and its version
    if(indexRight == -1)
    {
        ldcVerStr = inBetween(vString, "LDC - the LLVM Open D compiler (", " ", indexRight);
        if(indexRight == -1)
            return false;
    }
    ///Find DMD ver
    string frontEndVer = inBetweenAny(vString, "based on DMD v", [' ', '\t', '\n', '\r'], indexRight);
    enforce(indexRight != -1, "Found LDC but coult not find DMD Frontend version");

    comp = CompilerBinary(AcceptedCompiler.ldc2, compilerOrPath, SemVer(ldcVerStr), SemVer(frontEndVer), vString);
    return true;
}


private bool tryInferDmd(string compilerOrPath, string vString, out CompilerBinary comp)
{
    import std.string;
    import std.exception;
    enum DMDCheck1 = "DMD";

    //Identify DMD
    ptrdiff_t dmdIndex = indexOf(vString, DMDCheck1);
    if(dmdIndex == -1) return false;

    //Identify its version
    string dmdVerString = inBetweenAny(vString, "D Compiler v", [' ', '\t', '\n', '\r'], dmdIndex, dmdIndex+DMDCheck1.length);
    if(dmdIndex == -1) return false;

    SemVer dmdVer = SemVer(dmdVerString);
    comp = CompilerBinary(AcceptedCompiler.dmd, compilerOrPath, dmdVer, dmdVer, vString);
    return true;
}

private bool tryInferGcc(string compilerOrPath, string _vString, out CompilerBinary comp)
{
    import std.path;
    import redub.logging;
    string type = compilerOrPath.baseName.stripExtension;
    switch(type)
    {
        case "gcc", "tcc":
            comp = CompilerBinary(AcceptedCompiler.gcc, compilerOrPath, SemVer.init, SemVer.init, _vString);
            warnTitle("GCC Compiler detected. ", "Beware that it is still very untested.");
            return true;
        default: return false;
    }
}
private bool tryInferGxx(string compilerOrPath, string _vString, out CompilerBinary comp)
{
    import std.path;
    import redub.logging;
    string type = compilerOrPath.baseName.stripExtension;
    if(type != "g++") return false;
    comp = CompilerBinary(AcceptedCompiler.gxx, compilerOrPath, SemVer.init, SemVer.init, _vString);
    warnTitle("G++ Compiler detected.", " Beware that it is still very untested.");
    return true;
}

private bool tryInferClang(string compilerOrPath, string vString, out CompilerBinary comp)
{
    import std.path;
    import redub.logging;
    string type = compilerOrPath.baseName.stripExtension;
    if(type != "clang") return false;
    ptrdiff_t indexRight;
    string clangVerStr = inBetween(vString, "clang version ", "\n", indexRight);
    comp = CompilerBinary(AcceptedCompiler.clang, compilerOrPath, SemVer(clangVerStr), SemVer(clangVerStr), vString);
    warnTitle("Clang Compiler detected.", " Beware that it is still very untested.");
    return true;
}



private string inBetween(string input, string left, string right, out ptrdiff_t indexOfRight, size_t startIndex = 0) @nogc nothrow
{
    import std.string;
    ptrdiff_t indexLeft = indexOf(input, left, startIndex);
    if(indexLeft == -1)
    {
        indexOfRight = -1;
        return null;
    }
    indexLeft+= left.length;
    indexOfRight = indexOf(input, right, indexLeft);
    if(indexOfRight == -1) return null;
    return input[indexLeft..indexOfRight];
}

private string inBetweenAny(string input, string left, scope const(char)[] anyRight, out ptrdiff_t indexOfRight, size_t startIndex = 0)
{
    import std.string;
    ptrdiff_t indexLeft = indexOf(input, left, startIndex);
    if(indexLeft == -1)
    {
        indexOfRight = -1;
        return null;
    }
    indexLeft+= left.length;
    indexOfRight = indexOfAny(input, anyRight, indexLeft);
    if(indexOfRight == -1) return null;
    return input[indexLeft..indexOfRight];
}




@"Test DMD Version" unittest
{
    string dmdVerString =
`
DMD64 D Compiler v2.106.0-dirty                                                                                                                                          Copyright (C) 1999-2023 by The D Language Foundation, All Rights Reserved written by Walter Bright
`;
CompilerBinary comp;
assert(tryInferDmd(null, dmdVerString, comp));
assert(SemVer("2.106.0").satisfies(comp.version_));
assert(SemVer("2.106.0").satisfies(comp.frontendVersion));

}

@"Test LDC Version" unittest
{
string ldcVerString =
`
LDC - the LLVM D compiler (1.36.0):                                                                                                                                        based on DMD v2.106.1 and LLVM 17.0.6                                                                                                                                    built with LDC - the LLVM D compiler (1.36.0)                                                                                                                            Default target: x86_64-pc-windows-msvc                                                                                                                                   Host CPU: znver1                                                                                                                                                         http://dlang.org - http://wiki.dlang.org/LDC
`;
CompilerBinary comp;
assert(tryInferLdc(null, ldcVerString, comp));
assert(SemVer("1.36.0").satisfies(comp.version_));
assert(SemVer("2.106.1").satisfies(comp.frontendVersion));
}

@"Test Compiler Inference" unittest
{
    assert(getCompiler("ldc2", null).d.compiler == AcceptedCompiler.ldc2);
    assert(getCompiler("dmd", null).d.compiler == AcceptedCompiler.dmd);
    // assert(getCompiler("tcc", null).compiler == AcceptedCompiler.gcc);
}