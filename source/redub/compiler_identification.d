module redub.compiler_identification;
public import redub.libs.semver;


enum AcceptedCompiler
{
    invalid,
    dmd,
    ldc2,
    gcc,
    gxx
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


    string getCompilerString() const
    {
        final switch(compiler) with(AcceptedCompiler)
        {
            case dmd: return "dmd";
            case ldc2: return "ldc";
            case gcc: return "gcc";
            case gxx: return "g++";
            case invalid: throw new Error("Invalid compiler.");
        }
    }
}


bool isDCompiler(immutable Compiler comp)
{
    return comp.compiler == AcceptedCompiler.dmd || comp.compiler == AcceptedCompiler.ldc2;
}

Compiler getCompiler(string compilerOrPath, string compilerAssumption)
{
    import std.process;
    import std.exception;
    import std.path;
    if(compilerOrPath == null) compilerOrPath = "dmd";
    //Tries to find in the local folder for an executable file with the name of compilerOrPath
    if(!isAbsolute(compilerOrPath))
    {
        import std.file;
        string tempPath = buildNormalizedPath(getcwd(), compilerOrPath);
        version(Windows) enum targetExtension = ".exe";
        else enum targetExtension = cast(string)null;
        //If it does not, simply assume global
        if(exists(tempPath) && !isDir(tempPath) && tempPath.extension == targetExtension)
            compilerOrPath = tempPath;
    }

    immutable inference = [
        &tryInferDmd,
        &tryInferLdc,
        &tryInferGcc,
        &tryInferGxx
    ];

    Compiler ret;
    if(compilerAssumption == null)
    {
        auto compVersionRes = executeShell(compilerOrPath ~ " --version");
        enforce(compVersionRes.status == 0, compilerOrPath~" --version returned a non zero code.");
        string versionString = compVersionRes.output;
        foreach(inf; inference)
        {
            if(inf(compilerOrPath, versionString, ret))
                return ret;
        }
    }
    else
    {
        return assumeCompiler(compilerOrPath, compilerAssumption);
    }
    throw new Error("Could not infer which compiler you're using from "~compilerOrPath);
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
        default: throw new Error("Can only assume dmd, ldc and ldc2 at this moment, received "~compilerAssumption);
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
    assert(getCompiler("ldc2").compiler == AcceptedCompiler.ldc2);
    assert(getCompiler("dmd").compiler == AcceptedCompiler.dmd);
    assert(getCompiler("tcc").compiler == AcceptedCompiler.gcc);
}