module redub.compiler_identification;
public import redub.libs.semver;
import hipjson;


enum AcceptedCompiler
{
    invalid,
    dmd,
    ldc2,
    gcc,
    gxx
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


/** 
 * Using this structure, it is possible to use any compiler with any version as long
 * they are the valid AcceptedCompiler list.
 */
struct Compiler
{
    ///Accepted compiler is used for getting the commands
    AcceptedCompiler compiler;
    ///Version of the compiler used.
    SemVer version_;
    ///D Only - Which frontend was based 
    SemVer frontendVersion;

    ///Contents of executing binOrPath --version
    string versionString;

    ///Accepts both a complete path to an executable or a global environment search path name
    string binOrPath;

    ///Librarian tool
    string archiver = "llvm-ar";

    bool usesIncremental = false;


    string getCompilerString() const
    {
        final switch(compiler) with(AcceptedCompiler)
        {
            case dmd: return "dmd";
            case ldc2: return "ldc";
            case gcc: return "gcc";
            case gxx: return "g++";
            case invalid: throw new Exception("Invalid compiler.");
        }
    }

    string getCompilerWithVersion() const
    {
        return getCompilerString()~" "~version_.toString;
    }
}


bool isDCompiler(immutable Compiler comp)
{
    return comp.compiler == AcceptedCompiler.dmd || comp.compiler == AcceptedCompiler.ldc2;
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
    import std.path;
    if(!isAbsolute(compilerOrPath))
    {
        import std.file;
        string tempPath = buildNormalizedPath(getcwd(), compilerOrPath);
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
        {
            searchable = tryGetCompilerOnCwd(searchable);
        }
        else
            preferredTested = true;
        compVersionRes = executeShell(searchable ~ " --version");
        if(compVersionRes.status == 0)
        {
            actualCompiler = searchable;
            break;
        }
    }
    enforce(compVersionRes.status == 0, preferredCompiler~ " --version returned a non zero code. "~
        "In Addition, dmd and ldc2 were also tested and were not found. You may need to download or specify them before using redub."
    );

    if(actualCompiler != preferredCompiler)
        warn("The compiler '"~preferredCompiler~"' that was specified in your system wasn't found. Redub found "~actualCompiler~" and it will use for this compilation.");

    return compVersionRes.output;
}


/** 
 * Use this function to get extensive information about the Compiler to use.
 * Params:
 *   compilerOrPath = Can be used both as a global, such as `dmd` or a complete path to a compiler
 *   compilerAssumption = Optinal version string, such as `dmd v[2.105.0] f[2.106.0]`, v being its version, f being frontend version
 * Returns: The Compiler information that was found, or inferred if compilerAssumption was used.
 */
Compiler getCompiler(string compilerOrPath, string compilerAssumption)
{
    import std.process;
    import std.algorithm.comparison:either;
    import redub.misc.find_executable;
    import redub.meta;
    import std.exception;

    JSONValue compilersInfo = getRedubMeta();
    bool isDefault;
    if(compilerOrPath == null) 
    {
        if("defaultCompiler" in compilersInfo)
            compilerOrPath = compilersInfo["defaultCompiler"].str;
        isDefault = true;
    }
    if(compilerOrPath == null)
        compilerOrPath = "dmd";

    string locCompiler = tryGetCompilerOnCwd(compilerOrPath);
    bool isGlobal = locCompiler == compilerOrPath;
    if(!isGlobal)
        compilerOrPath = locCompiler;
    else
    {
        if(JSONValue* globalPaths = "globalPaths" in compilersInfo)
        {
            if(JSONValue* cachedPath = compilerOrPath in *globalPaths)
            {
                Compiler ret = getCompilerFromCache(compilersInfo, cachedPath.str);
                if(ret != Compiler.init)
                    return ret;
            }
        }
        compilerOrPath = findExecutable(compilerOrPath);
    }

    Compiler ret = getCompilerFromCache(compilersInfo, compilerOrPath);
    if(ret != Compiler.init)
        return ret;


    immutable inference = [
        &tryInferDmd,
        &tryInferLdc,
        &tryInferGcc,
        &tryInferGxx
    ];

    if(compilerAssumption == null)
    {
        string actualCompiler;
        string versionString = getActualCompilerToUse(compilerOrPath, actualCompiler);
        foreach(inf; inference)
        {
            if(inf(actualCompiler, versionString, ret))
            {
                saveCompilerInfo(compilersInfo, ret, isDefault, isGlobal);
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


Compiler getCompilerFromCache(JSONValue allCompilersInfo, string compiler)
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
            if(value.type != JSONType.array)
                enforce(false, "Expected that the value from object "~key~" were an array.");
            if(key == compiler)
            {
                JSONValue[] arr = value.array;
                if(arr[TIMESTAMP].get!long != timeLastModified(key).stdTime)
                    return Compiler.init;

                return Compiler(
                    acceptedCompilerfromString(arr[ACCEPTED_COMPILER].str),
                    SemVer(arr[VERSION_].str),
                    SemVer(arr[FRONTEND_VERSION].str),
                    arr[VERSION_STRING].str,
                    key
                );
            }
        }
    }

    return Compiler.init;
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
 *   compiler = The new compiler to add
 */
private void saveCompilerInfo(JSONValue allCompilersInfo, Compiler compiler, bool isDefault, bool isGlobal)
{
    import redub.meta;
    import std.conv:to;
    import redub.buildapi;
    import std.file;

    if(isDefault)
    {
        allCompilersInfo["defaultCompiler"] = JSONValue(compiler.compiler.to!string);
    }
    if(isGlobal)
    {
        if(!("globalPaths" in allCompilersInfo))
            allCompilersInfo["globalPaths"] = JSONValue.emptyObject;
        allCompilersInfo["globalPaths"][compiler.compiler.to!string] = JSONValue(compiler.binOrPath);
    }
    if(!("version" in allCompilersInfo))
        allCompilersInfo["version"] = JSONValue(RedubVersionOnly);

    if(!("compilers" in allCompilersInfo))
        allCompilersInfo["compilers"] = JSONValue.emptyObject;


    allCompilersInfo["compilers"][compiler.binOrPath] = JSONValue([
        JSONValue(compiler.compiler.to!string),
        JSONValue(compiler.version_.toString),
        JSONValue(compiler.frontendVersion.toString),
        JSONValue(compiler.versionString),
        JSONValue(timeLastModified(compiler.binOrPath).stdTime)
    ]);
    saveRedubMeta(allCompilersInfo.toString);
}

private Compiler assumeCompiler(string compilerOrPath, string compilerAssumption)
{
    import std.string;
    import std.exception;
    Compiler ret;
    ret.binOrPath = compilerOrPath;
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


private bool tryInferLdc(string compilerOrPath, string vString, out Compiler comp)
{
    import std.exception;
    import std.string;

    ptrdiff_t indexRight = 0;
    string ldcVerStr = inBetween(vString, "LDC - the LLVM D compiler (", ")", indexRight);
    ///Identify LDC and its version
    if(indexRight == -1) return false;
    ///Find DMD ver
    string frontEndVer = inBetweenAny(vString, "based on DMD v", [' ', '\t', '\n', '\r'], indexRight);
    enforce(indexRight != -1, "Found LDC but coult not find DMD Frontend version");

    comp = Compiler(AcceptedCompiler.ldc2, SemVer(ldcVerStr), SemVer(frontEndVer), vString, compilerOrPath);
    return true;
}


private bool tryInferDmd(string compilerOrPath, string vString, out Compiler comp)
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
    comp = Compiler(AcceptedCompiler.dmd, dmdVer, dmdVer, vString, compilerOrPath);
    return true;
}

private bool tryInferGcc(string compilerOrPath, string _vString, out Compiler comp)
{
    import std.path;
    import redub.logging;
    string type = compilerOrPath.baseName.stripExtension;
    switch(type)
    {
        case "gcc", "tcc":
            comp = Compiler(AcceptedCompiler.gcc, SemVer.init, SemVer.init, _vString, compilerOrPath); 
            error("GCC Compiler detected. Beware that it is still very untested.");
            return true;
        default: return false;
    }
}
private bool tryInferGxx(string compilerOrPath, string _vString, out Compiler comp)
{
    import std.path;
    import redub.logging;
    string type = compilerOrPath.baseName.stripExtension;
    if(type != "g++") return false;
    comp = Compiler(AcceptedCompiler.gxx, SemVer.init, SemVer.init, _vString, compilerOrPath);
    error("G++ Compiler detected. Beware that it is still very untested.");
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
Compiler comp;
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
Compiler comp;
assert(tryInferLdc(null, ldcVerString, comp));
assert(SemVer("1.36.0").satisfies(comp.version_));
assert(SemVer("2.106.1").satisfies(comp.frontendVersion));
}

@"Test Compiler Inference" unittest
{
    assert(getCompiler("ldc2", null).compiler == AcceptedCompiler.ldc2);
    assert(getCompiler("dmd", null).compiler == AcceptedCompiler.dmd);
    // assert(getCompiler("tcc", null).compiler == AcceptedCompiler.gcc);
}