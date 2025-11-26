module redub.tooling.compilers_inference;
import redub.libs.semver;
import redub.tooling.compiler_identification;
import hip.data.json;


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
    import redub.parsers.environment;
    import std.process;

    CompilerBinary ret;
    string actualCompiler;
    auto res = execute([compilerPath, "--version"], getRedubEnv());
    if(res.status)
        throw new Exception("saveGlobalCompiler was called in an inexistent compiler.");
    foreach(inf; isC ? cCompilersInference : dCompilersInference)
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

/**
 * Tries to find in the local folder for an executable file with the name of compilerOrPath.
 * They are only searched if the path is not absolute
 * Params:
 *   compilerOrPath = The base compiler name to search on the current directory.
 * Returns:
 */
string tryGetCompilerOnCwd(string compilerOrPath)
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
CompilerBinary inferCompiler(string compilerOrPath, string compilerAssumption, JSONValue compilersInfo, bool isDefault, bool isGlobal, bool isC)
{
    import redub.misc.find_executable;
    CompilerBinary ret;

    string versionString;
    if(compilerAssumption == null)
    {
        string actualCompiler;
        bool isError;
        versionString = getActualCompilerToUse(compilerOrPath, actualCompiler, isC ? supportedCCompilers : supportedDCompilers, isError);
        if(!isError)
        foreach(inf; isC ? cCompilersInference : dCompilersInference)
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
    return CompilerBinary(AcceptedCompiler.invalid, versionString);
}

/**
 * Tries to find the compiler to use. If the preferred compiler is not on the user environment, it will
 * warn and use it instead.
 * Params:
 *   preferredCompiler = The compiler that the user may have specified.
 *   actualCompiler = Actual compiler. If no compiler is found on the searchable list, the program will exit.
 * Returns: The output from executeProcess. This will be processed for getting version information on the compiler.
 */
private string getActualCompilerToUse(string preferredCompiler, ref string actualCompiler, const string[] searchableCompilers, out bool isError)
{
    import std.exception;
    import redub.parsers.environment;
    import std.typecons;
    import std.process;
    import redub.logging;
    import std.path: baseName, stripExtension;
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

        string[2] versionCommand = [searchable, "--version"];
        size_t args = searchable.baseName.stripExtension != "cl" ? 2 : 1;
        compVersionRes = execute(versionCommand[0..args], getRedubEnv());
        if(compVersionRes.status == 0)
        {
            actualCompiler = searchable;
            break;
        }
    }

    if(compVersionRes.status != 0)
    {
        isError = true;
        import std.string:join;
        string baseMessage;
        string testedCompilersMessage = "The compilers ["~searchableCompilers.join(", ")~ "] were tested and not found.";
        if(preferredCompiler.length != 0)
            baseMessage = "The specified compiler \""~preferredCompiler~"\" --version returned a non zero code.\nIn Addition:";

        return baseMessage~
        testedCompilersMessage~ " You may need to download or specify them before using redub.\n" ~
        "If you don't have any D compiler added in the PATH, you can install them by using 'redub install dmd' and then do 'redub use dmd'\n" ~
        "it will setup the compiler to use with redub. \n";
        // "Last Shell Output: "~ compVersionRes.output;
    }
    if(actualCompiler != preferredCompiler)
        warn("The compiler '"~preferredCompiler~"' that was specified in your system wasn't found. Redub found "~actualCompiler~" and it will use for this compilation.");

    isError = false;
    return compVersionRes.output;
}

private immutable bool function(string compilerOrPath, string vString, out CompilerBinary comp)[2] dCompilersInference = [
    &tryInferDmd,
    &tryInferLdc
];

private immutable bool function(string compilerOrPath, string vString, out CompilerBinary comp)[4] cCompilersInference = [
    &tryInferCl,
    &tryInferClang,
    &tryInferGcc,
    &tryInferGxx,
];



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

private bool tryInferCl(string compilerOrPath, string vString, out CompilerBinary comp)
{
    import std.path;
    import redub.logging;
    string type = compilerOrPath.baseName.stripExtension;
    if(type != "cl") return false;
    ptrdiff_t indexRight;
    string clVerStr = inBetween(vString, "Microsoft (R) C/C++ Optimizing Compiler Version ", " for ", indexRight);
    comp = CompilerBinary(AcceptedCompiler.cl, compilerOrPath, SemVer(clVerStr), SemVer(clVerStr), vString);
    warnTitle("CL Compiler detected.", " Beware that it is still very untested.");
    return true;
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