module redub.tooling.compiler_identification;
public import redub.libs.semver;
public import redub.tooling.archiver_identification;
public import redub.tooling.linker_identification;
public import redub.tooling.compiler_inference : saveGlobalCompiler, tryGetCompilerOnCwd;
import hip.data.json;
import std.algorithm.setops;


enum AcceptedCompiler : ubyte
{
    invalid,
    dmd,
    ldc2,
    nmc,
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

    void setBinary(AcceptedCompiler type, string binPath)
    {
        this.compiler = type;
        this.bin = binPath;
    }



    string getCompilerString() const
    {
        final switch(compiler) with(AcceptedCompiler)
        {
            case dmd: return "dmd";
            case ldc2: return "ldc";
            case nmc: return "nmc";
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
    ///C compiler that will be used when finding C projects
    CompilerBinary c;

    /**
     * Allows the MSVC linker to do incremental linking. Only affects Windows and is unrelated to the build strategy.
     * Off by default since it is usually slower.
     */
    bool linkIncremental = false;

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
    return c == AcceptedCompiler.dmd || c.isLDCBased;
}
bool isLDCBased(AcceptedCompiler c)
{
    return c == AcceptedCompiler.ldc2 || c == AcceptedCompiler.nmc;
}


/**
 * Redub will try to search compilers in that order if the D compiler in getCompiler is not found.
 */
immutable string[] supportedDCompilers = [
    "dmd",
    "ldc2",
    "nmc"
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
 *   cCompilerOrPath = Optional path to a C compiler. If null, uses the default C compiler
 *   compilerAssumption = Optional version string, such as `dmd v[2.105.0] f[2.106.0]`, v being its version, f being frontend version
 *   arch = [UNUSED] Used mainly for identifying which ldc.conf to take, and by using it, it is possible to detect the default linker for the specific arch
 * Returns: The Compiler information that was found, or inferred if compilerAssumption was used.
 */
Compiler getCompiler(string compilerOrPath = "dmd", string cCompilerOrPath = null, string compilerAssumption = null, string arch = null)
{
    import redub.parsers.environment;
    import redub.misc.either;
    import redub.meta;
    import redub.misc.path;

    JSONValue compilersInfo = getRedubMeta();
    bool isDefault = compilerOrPath.length == 0;
    compilerOrPath = either(compilerOrPath, tryGetStr(compilersInfo, "defaultCompiler"), "dmd");
    cCompilerOrPath = either(cCompilerOrPath, tryGetStr(compilersInfo, "defaultCCompiler"), defaultCCompiler);

    Compiler ret;

    ret.d = searchCompiler(compilerOrPath, compilersInfo, isDefault, false, compilerAssumption);
    addToEnvPATH(buildNormalizedPath(ret.d.bin, ".."));
    if(cCompilerOrPath)
    {
        import redub.tooling.msvc_getter;
        version(Windows)
            setupMsvc(compilersInfo);
        ret.c = searchCompiler(cCompilerOrPath, compilersInfo, true, true);
        addToEnvPATH(buildNormalizedPath(ret.c.bin, ".."));
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

private string getCompilerVersion(ref string compiler)
{
    import std.string:indexOf;
    import std.path;
    if(!isAbsolute(compiler))
    {
        auto verPart = compiler.indexOf('@');
        if(verPart != -1)
        {
            string ret = compiler[verPart+1..$];
            compiler = compiler[0..verPart];
            return ret;
        }
    }
    return null;
}

/**
 * Utility to get compiler info given the arguments. Used with useMain to verify for existing compilers.
 * Params:
 *   compilerOrPath = The compiler identifier (such as dmd|ldc etc) to find
 *   isC = Are you looking for C compilers?
 * Returns: Extensive information about the compiler
 */
CompilerBinary searchCompiler(string compilerOrPath, bool isC)
{
    import redub.meta;
    JSONValue compilersInfo = getRedubMeta();
    bool isDefault = compilerOrPath.length == 0;
    return searchCompiler(compilerOrPath, compilersInfo, isDefault, isC, null, false);
}

private CompilerBinary searchCompiler(string compilerOrPath, JSONValue compilersInfo, bool isDefault, bool isC, string compilerAssumption = null, bool useGlobalPath = true)
{
    import redub.misc.find_executable;
    import redub.tooling.compiler_inference;
    import std.path;
    import std.file;
    bool isGlobal = false;
    bool forceAssumption = compilerAssumption !is null;

    CompilerBinary ret;
    string compilerVersion = getCompilerVersion(compilerOrPath);
    string compilerPath = compilerOrPath;
    //Try get compiler on global cache with global cached paths
    if(!isAbsolute(compilerOrPath))
    {
        string locCompiler = tryGetCompilerOnCwd(compilerOrPath);
        if(locCompiler != compilerOrPath)
            compilerOrPath = locCompiler;
        else if(!forceAssumption)
        {
            if(useGlobalPath)
                ret = getCompilerFromGlobalPath(compilerOrPath, compilersInfo, compilerVersion);
            isGlobal = true;
        }
    }

    if(forceAssumption)
    {
        compilerPath = findExecutable(compilerOrPath);
        if(compilerPath is null)
            compilerPath = compilerOrPath;
        ret = inferCompiler(compilerOrPath, compilerPath, compilerAssumption, compilersInfo, isDefault, isGlobal, isC);
    }
    else
    {
        //Try finding the compiler globally and getting it from cache
        if(ret == CompilerBinary.init)
        {
            compilerPath = findExecutable(compilerOrPath);
            ret = getCompilerFromCache(compilersInfo, compilerOrPath, compilerPath, compilerVersion);
        }
        //Try inferring the compiler and saving its infos
        if(ret == CompilerBinary.init)
            ret = inferCompiler(compilerOrPath, compilerPath, compilerAssumption, compilersInfo, isDefault, isGlobal, isC);
    }
    if(compilerVersion.length)
    {
        import redub.libs.semver;
        import redub.api;
        SemVer requirement = SemVer(compilerVersion);
        if(requirement.isInvalid || !ret.version_.satisfies(requirement))
            throw new BuildException("Specified " ~ compilerPath ~ " " ~ compilerVersion ~
                " but found compiler version " ~ ret.version_.toString);
    }
    return ret;
}



private bool satisfiesVersion(string ver, string requirement)
{
    SemVer req = SemVer(requirement);
    return !req.isInvalid && SemVer(ver).satisfies(req);
}

private struct ToolchainConstraints
{
    bool hasDmd;
    bool hasLdc;
    string dmd;
    string ldc;

    bool positiveDmd() const { return hasDmd && dmd != "no"; }
    bool positiveLdc() const { return hasLdc && ldc != "no"; }
    bool restricted() const { return positiveDmd || positiveLdc; }

    bool allows(AcceptedCompiler c) const
    {
        if(c == AcceptedCompiler.dmd)
            return (!hasDmd || positiveDmd) && (!restricted || positiveDmd);
        if(c == AcceptedCompiler.ldc2)
            return (!hasLdc || positiveLdc) && (!restricted || positiveLdc);
        return !restricted;
    }
}

private bool parseToolchainConstraints(JSONValue requirements, out ToolchainConstraints constraints, out string failure)
{
    import std.string : strip;
    if(requirements.type != JSONType.object)
    {
        failure = "'toolchainRequirements' must be an object.";
        return false;
    }
    foreach(key, value; requirements.object)
    {
        if(value.type != JSONType.string)
        {
            failure = "'toolchainRequirements."~key~"' must be a string.";
            return false;
        }
        string requirement = value.str.strip;
        switch(key)
        {
            case "dmd":
                constraints.hasDmd = true;
                constraints.dmd = requirement;
                break;
            case "ldc":
                constraints.hasLdc = true;
                constraints.ldc = requirement;
                break;
            default: break;
        }
    }
    return true;
}

private string allowedCompilerNames(const ref ToolchainConstraints constraints)
{
    import std.array : join;
    string[] names;
    if(constraints.allows(AcceptedCompiler.dmd))
        names ~= "dmd";
    if(constraints.allows(AcceptedCompiler.ldc2))
        names ~= "ldc";
    if(constraints.allows(AcceptedCompiler.nmc))
        names ~= "nmc";
    return names.join(", ");
}

/**
 * Checks a package's `toolchainRequirements` object against a D compiler.
 * A positive `dmd`/`ldc` requirement restricts the build to those compilers;
 * `frontend` alone accepts any D compiler that matches it.
 * Params:
 *   requirements = The `toolchainRequirements` object from the recipe.
 *   d = The D compiler being considered.
 *   failure = Human readable description of the first unsatisfied requirement.
 * Returns: Whether the compiler satisfies every requirement.
 */
bool satisfiesToolchainRequirements(JSONValue requirements, const ref CompilerBinary d, out string failure)
{
    import redub.buildapi : RedubVersionOnly;
    ToolchainConstraints constraints;
    if(!parseToolchainConstraints(requirements, constraints, failure))
        return false;
    if(!constraints.allows(d.compiler))
    {
        failure = "The recipe only allows "~allowedCompilerNames(constraints)~".";
        return false;
    }
    foreach(key, value; requirements.object)
    {
        string requirement = value.str;
        bool disallowed = requirement == "no";
        switch(key)
        {
            case "dub":
                if(disallowed)
                {
                    failure = "The recipe disallows using dub.";
                    return false;
                }
                if(!satisfiesVersion(RedubVersionOnly[1..$], requirement))
                {
                    failure = "Requires dub "~requirement~", but redub is "~RedubVersionOnly[1..$]~".";
                    return false;
                }
                break;
            case "frontend":
                if(disallowed)
                {
                    failure = "The recipe disallows the D frontend.";
                    return false;
                }
                if(!isDCompiler(d.compiler))
                {
                    failure = "Requires D frontend "~requirement~", but the selected compiler is not a D compiler.";
                    return false;
                }
                if(!satisfiesVersion(d.frontendVersion.toString, requirement))
                {
                    failure = "Requires D frontend "~requirement~", but "~d.getCompilerString~" provides "~d.frontendVersion.toString~".";
                    return false;
                }
                break;
            case "dmd":
                if(d.compiler == AcceptedCompiler.dmd && !satisfiesVersion(d.version_.toString, requirement))
                {
                    failure = "Requires DMD "~requirement~", but the selected DMD is "~d.version_.toString~".";
                    return false;
                }
                break;
            case "ldc":
                if(d.compiler == AcceptedCompiler.ldc2 && !satisfiesVersion(d.version_.toString, requirement))
                {
                    failure = "Requires LDC "~requirement~", but the selected LDC is "~d.version_.toString~".";
                    return false;
                }
                break;
            case "gdc":
                if(!disallowed)
                {
                    failure = "Requires GDC "~requirement~", which redub does not support.";
                    return false;
                }
                break;
            default: break;
        }
    }
    return true;
}

private CompilerBinary findInstalledCompiler(JSONValue requirements, const ref ToolchainConstraints constraints, out string failure)
{
    foreach(name; supportedDCompilers)
    {
        AcceptedCompiler c = name == "dmd" ? AcceptedCompiler.dmd
            : name == "ldc2" ? AcceptedCompiler.ldc2
            : AcceptedCompiler.nmc;
        if(!constraints.allows(c))
            continue;
        string requirement = c == AcceptedCompiler.dmd ? constraints.dmd
            : c == AcceptedCompiler.ldc2 ? constraints.ldc
            : null;
        string compilerId = requirement.length && requirement != "no" ? name~"@"~requirement : name;
        CompilerBinary candidate;
        try
            candidate = getCompiler(compilerId).d;
        catch(Exception)
            continue;
        if(candidate.compiler == AcceptedCompiler.invalid)
            continue;
        if(satisfiesToolchainRequirements(requirements, candidate, failure))
            return candidate;
    }
    return CompilerBinary.init;
}

/**
 * Replaces `compiler.d` with an installed compiler that satisfies the recipe's
 * `toolchainRequirements`, when the current one does not.
 * Params:
 *   recipe = The parsed recipe JSON.
 *   compiler = The compiler to update.
 */
void applyToolchainRequirements(JSONValue recipe, ref Compiler compiler)
{
    import redub.api : BuildException;
    import redub.logging : warn;

    JSONValue* requirements = "toolchainRequirements" in recipe;
    if(requirements is null)
        return;
    string failure;
    if(satisfiesToolchainRequirements(*requirements, compiler.d, failure))
        return;

    ToolchainConstraints constraints;
    if(!parseToolchainConstraints(*requirements, constraints, failure))
        throw new BuildException("Invalid toolchain requirements: "~failure);
    CompilerBinary found = findInstalledCompiler(*requirements, constraints, failure);
    if(found == CompilerBinary.init)
        throw new BuildException("Toolchain requirements are not satisfied: "~failure~
            "\nInstall a matching compiler (for example with 'redub install ldc <version>') and try again.");
    warn("Switching compiler to ", found.getCompilerWithVersion, " to satisfy toolchain requirements.");
    compiler.d = found;
}

private CompilerBinary getCompilerFromGlobalPath(string compilerIdentifier, JSONValue compilersInfo, string compilerVersion)
{
    if(!compilerVersion.length)
    if(JSONValue* globalPaths = "globalPaths" in compilersInfo)
    {
        if(JSONValue* cachedPath = compilerIdentifier in *globalPaths)
            return getCompilerFromCache(compilersInfo, compilerIdentifier, cachedPath.str, null);
    }
    return CompilerBinary.init;
}


private enum ACCEPTED_COMPILER = 0;
private enum VERSION_ = 1;
private enum FRONTEND_VERSION = 2;
private enum VERSION_STRING = 3;
private enum TIMESTAMP = 4;


/**
 *
 * Params:
 *   allCompilersInfo = All the compilers info to check
 *   compiler = The actual compiler (for example: ldc2 || dmd || cl || gcc)
 *   compilerPath = The actual executable path. Only used if compilerVersion is not specified
 *   compilerVersion = The compiler version requirement. SemVer is supported
 * Returns: The compiler that fits the version and compiler requirement
 */
private CompilerBinary getCompilerFromCache(JSONValue allCompilersInfo, string compiler, string compilerPath, string compilerVersion)
{
    import std.exception;
    import std.file;
    if(!compiler.length)
    {
        JSONValue* def = "defaultCompiler" in allCompilersInfo;
        if(def != null)
            compiler = def.str;
    }
    if(compilerVersion.length)
        return getCompilerFromCacheByVersion(allCompilersInfo, compiler, compilerVersion);
    JSONValue* comps = "compilers" in allCompilersInfo;
    CompilerBinary ret;
    if(comps)
    {
        foreach(key, value; comps.object)
        {
            enforce(value.type == JSONType.array, "Expected that the value from object "~key~" were an array.");
            if(key != compilerPath || !std.file.exists(key))
                continue;

            JSONValue[] arr = value.array;

            if(arr[TIMESTAMP].get!long == timeLastModified(key).stdTime)
            {
                ret = CompilerBinary(
                    acceptedCompilerfromString(arr[ACCEPTED_COMPILER].str),
                    key,
                    SemVer(arr[VERSION_].str),
                    SemVer(arr[FRONTEND_VERSION].str),
                    arr[VERSION_STRING].str,
                );
            }

            break;
        }
    }
    return ret;
}
private CompilerBinary getCompilerFromCacheByVersion(JSONValue allCompilersInfo, string compiler, string compilerVersion)
{
    import std.exception;
    import std.file;

    JSONValue* comps = "compilers" in allCompilersInfo;
    SemVer requirement = SemVer(compilerVersion);
    CompilerBinary ret;
    if(comps)
    {
        foreach(key, value; comps.object)
        {
            enforce(value.type == JSONType.array, "Expected that the value from object "~key~" were an array.");
            JSONValue[] arr = value.array;

            if(arr[ACCEPTED_COMPILER].str != compiler || !SemVer(arr[VERSION_].str).satisfies(requirement) || !std.file.exists(key))
                continue;
            if(arr[TIMESTAMP].get!long == timeLastModified(key).stdTime)
            {
                ret = CompilerBinary(
                    acceptedCompilerfromString(arr[ACCEPTED_COMPILER].str),
                    key,
                    SemVer(arr[VERSION_].str),
                    SemVer(arr[FRONTEND_VERSION].str),
                    arr[VERSION_STRING].str,
                );
            }
            break;
        }
    }
    ///Compilers installed by `redub install` may not be present in the meta cache yet.
    if(ret == CompilerBinary.init)
        ret = getManagedCompilerByVersion(compiler, compilerVersion, allCompilersInfo);
    return ret;
}

private CompilerBinary getManagedCompilerByVersion(string compiler, string requirement, JSONValue allCompilersInfo)
{
    import redub.api : getDubWorkspacePath;
    import redub.misc.path : buildNormalizedPath;
    import std.file : exists, dirEntries, SpanMode;
    import std.path : baseName;
    import std.string : startsWith, endsWith, chompPrefix;
    import std.algorithm.sorting : sort;

    string root;
    string[] versions;
    if(compiler == "dmd")
    {
        root = buildNormalizedPath(getDubWorkspacePath, "redub-dmd");
        if(!exists(root))
            return CompilerBinary.init;
        foreach(entry; dirEntries(root, SpanMode.shallow))
        {
            if(!entry.isDir)
                continue;
            string folder = baseName(entry.name);
            if(!folder.startsWith("dmd-"))
                continue;
            string name = folder["dmd-".length .. $];
            if(SemVer(name).satisfies(SemVer(requirement)))
                versions ~= name;
        }
    }
    else if(compiler == "ldc2" || compiler == "ldc")
    {
        root = buildNormalizedPath(getDubWorkspacePath, "redub-ldc");
        if(!exists(root))
            return CompilerBinary.init;
        static immutable ldcSuffixes = [
            "-windows-multilib", "-osx-universal", "-linux-x86_64",
            "-linux-aarch64", "-freebsd-x86_64",
        ];
        foreach(entry; dirEntries(root, SpanMode.shallow))
        {
            if(!entry.isDir)
                continue;
            string name = baseName(entry.name).chompPrefix("ldc2-");
            if(name == baseName(entry.name))
                continue;
            foreach(suffix; ldcSuffixes)
            {
                if(name.endsWith(suffix))
                {
                    name = name[0 .. $ - suffix.length];
                    break;
                }
            }
            if(SemVer(name).satisfies(SemVer(requirement)))
                versions ~= name;
        }
    }
    else
        return CompilerBinary.init;

    versions.sort!((a, b) => SemVer(a) > SemVer(b));
    foreach(ver; versions)
    {
        string bin;
        if(compiler == "dmd")
        {
            import redub.misc.dmd_install : getDmdFolder;
            version(Windows) enum dmdName = "dmd.exe";
            else enum dmdName = "dmd";
            bin = buildNormalizedPath(getDmdFolder(ver), dmdName);
        }
        else
        {
            import redub.misc.ldc_install : getLdcFolder;
            version(Windows) enum ldcName = "ldc2.exe";
            else enum ldcName = "ldc2";
            bin = buildNormalizedPath(getLdcFolder(ver), ldcName);
        }
        if(!exists(bin))
            continue;
        try
        {
            CompilerBinary ret = getCompiler(bin).d;
            if(ret.compiler != AcceptedCompiler.invalid)
                return ret;
        }
        catch(Exception) {}
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
 *   compiler = The new compiler to add
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

unittest
{
    JSONValue reqs = JSONValue.emptyObject;
    reqs["frontend"] = JSONValue(">=2.106");
    string failure;
    CompilerBinary ldc = CompilerBinary(AcceptedCompiler.ldc2, "ldc2", SemVer("1.43.0"), SemVer("2.113.0"), null);
    CompilerBinary oldLdc = CompilerBinary(AcceptedCompiler.ldc2, "ldc2", SemVer("1.30.0"), SemVer("2.100.0"), null);
    CompilerBinary dmd = CompilerBinary(AcceptedCompiler.dmd, "dmd", SemVer("2.113.0"), SemVer("2.113.0"), null);
    assert(satisfiesToolchainRequirements(reqs, ldc, failure));
    assert(satisfiesToolchainRequirements(reqs, dmd, failure));
    assert(!satisfiesToolchainRequirements(reqs, oldLdc, failure));

    reqs["dmd"] = JSONValue("no");
    assert(satisfiesToolchainRequirements(reqs, ldc, failure));
    assert(!satisfiesToolchainRequirements(reqs, dmd, failure));

    reqs = JSONValue.emptyObject;
    reqs["ldc"] = JSONValue(">=1.40.0");
    assert(satisfiesToolchainRequirements(reqs, ldc, failure));
    assert(!satisfiesToolchainRequirements(reqs, oldLdc, failure));
    assert(!satisfiesToolchainRequirements(reqs, dmd, failure));

    reqs = JSONValue.emptyObject;
    reqs["dmd"] = JSONValue(">=2.106");
    assert(satisfiesToolchainRequirements(reqs, dmd, failure));
    assert(!satisfiesToolchainRequirements(reqs, ldc, failure));

    reqs = JSONValue.emptyObject;
    reqs["gdc"] = JSONValue(">=9.0.0");
    assert(!satisfiesToolchainRequirements(reqs, ldc, failure));
    reqs["gdc"] = JSONValue("no");
    assert(satisfiesToolchainRequirements(reqs, ldc, failure));
}

