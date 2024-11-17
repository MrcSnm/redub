module redub.parsers.json;
import redub.logging;
import std.system;
import redub.buildapi;
import hipjson;
// import std.json;
import std.file;
import redub.parsers.base;
import redub.command_generators.commons;
import core.runtime;
import redub.tree_generators.dub;

/** 
 * Those commands are independent of the selected target OS.
 * It will use the host OS instead of targetOS since they depend on the machine running them
 */
immutable string[] commandsWithHostFilters = [
    "preBuildCommands",
    "postBuildCommands",
    "preGenerateCommands",
    "postGenerateCommands"
];

BuildRequirements parse(string filePath, 
    string projectWorkingDir, 
    CompilationInfo cInfo,
    string version_, 
    BuildRequirements.Configuration subConfiguration,
    string subPackage,
    string parentName,
    bool isRoot = false
)
{
    import std.path;
    ParseConfig c = ParseConfig(projectWorkingDir, subConfiguration, subPackage, version_, cInfo, null, parentName);
    return parse(parseJSONCached(filePath), c, isRoot);
}


private JSONValue[string] jsonCache;
///Optimization to be used when dealing with subPackages
private JSONValue parseJSONCached(string filePath)
{
    JSONValue* cached = filePath in jsonCache;
    if(cached) return *cached;
    jsonCache[filePath] = parseJSON(std.file.readText(filePath));
    if(jsonCache[filePath].hasErrorOccurred)
        throw new Exception(jsonCache[filePath].error);
    return jsonCache[filePath];
}

/** 
 * This function was created since on libraries, they may be reusing multiple times and thus
 * storing the cache between runs may trigger errors.
 */
public void clearJsonCache(){jsonCache = null;}



/** 
 * Params:
 *   json = A dub.json equivalent
 * Returns: 
 */
BuildRequirements parse(JSONValue json, ParseConfig cfg, bool isRoot = false)
{
    import std.exception;
    cfg.isRoot = isRoot;
    ///Setup base of configuration before finding anything
    if(!cfg.requiredBy)
    {
        enforce("name" in json, "Every package must contain a 'name'");
        cfg.requiredBy = json["name"].str;
        if("version" in json)
            cfg.version_ = json["version"].str;
    }
    if(isRoot)
    {
        import redub.package_searching.cache;
        putRootPackageInCache(cfg.requiredBy, cfg.workingDir);
        vlog("Added project ", cfg.requiredBy, " to memory cache.");
    }
    BuildRequirements buildRequirements = getDefaultBuildRequirement(cfg);

    immutable static requirementsRun = [
        "name": (ref BuildRequirements req, JSONValue v, ParseConfig c){},
        "plugins": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            enforce(v.type == JSONType.object, "\"plugins\" in json must be an object.");
            foreach(key, value; v.object)
            {
                enforce(value.type == JSONType.string, "\"plugins\" entry key '"~key~"' must be a string to a path being either a .d file or a dub project.");
                baseLoadPlugin(key, value.str, c.workingDir, c.cInfo);
            }
        },
        "preBuildPlugins": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            foreach(key, value; v.object)
                addPreBuildPlugins(req, key, value.strArr, c);
        },
        // "buildTypes": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        // {
        //     enforce(false, "Redub does not support buildTypes and has no plan to support it. Use \"configurations\" for achieving the same thing.");
        // },
        "targetName": (ref BuildRequirements req, JSONValue v, ParseConfig c){setTargetName(req, v.str, c);},
        "targetType": (ref BuildRequirements req, JSONValue v, ParseConfig c){setTargetType(req, v.str, c);},
        "targetPath": (ref BuildRequirements req, JSONValue v, ParseConfig c){setTargetPath(req, v.str, c);},
        "importPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){addImportPaths(req, v.strArr, c);},
        "stringImportPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){addStringImportPaths(req, v.strArr, c);},
        "preGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPreGenerateCommands(req, v.strArr, c);},
        "postGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPostGenerateCommands(req, v.strArr, c);},
        "preBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPreBuildCommands(req, v.strArr, c);},
        "postBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPostBuildCommands(req, v.strArr, c);},
        "copyFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c){addFilesToCopy(req, v.strArr, c);},
        "extraDependencyFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c){addExtraDependencyFiles(req, v.strArr, c);},
        "sourcePaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){addSourcePaths(req, v.strArr, c);},
        "sourceFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c){addSourceFiles(req, v.strArr, c);},
        "excludedSourceFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c){addExcludedSourceFiles(req, v.strArr, c);},
        "libPaths":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addLibPaths(req, v.strArr, c);},
        "libs":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addLibs(req, v.strArr, c);},
        "versions":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addVersions(req, v.strArr, c);},
        "debugVersions":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addDebugVersions(req, v.strArr, c);},
        "lflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addLinkFlags(req, v.strArr, c);},
        "dflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addDflags(req, v.strArr, c);},
        "configurations": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            ///If it is a recursive call (not firstRun), it won't care about configurations
            if(c.firstRun)
            {
                import std.conv:to;
                enforce(v.type == JSONType.array, "'configurations' must be an array.");
                enforce(v.array.length, "'configurations' must have at least one member.");
                ///Start looking for a configuration that matches the user preference if exists
                ///If "platform" didn't match, then it will skip it.
                int preferredConfiguration = -1;
                JSONValue configurationToUse;
                foreach(i, JSONValue projectConfiguration; v.array)
                {
                    JSONValue* name = "name" in projectConfiguration;
                    enforce(name, "'configurations' must have a 'name' on each");
                    JSONValue* platforms = "platforms" in projectConfiguration;
                    if(platforms)
                    {
                        enforce(platforms.type == JSONType.array, 
                            "'platforms' on configuration "~name.str~" at project "~req.name
                        );
                        if(!platformMatches(platforms.array, os, c.cInfo.isa))
                            continue;
                    }
                    if(name.str == c.subConfiguration.name)
                    {
                        preferredConfiguration = i.to!int;
                        break;
                    }
                    if(preferredConfiguration == -1)
                        preferredConfiguration = i.to!int;
                }
                if(c.subConfiguration.name && v.array[preferredConfiguration]["name"].str != c.subConfiguration.name)
                {
                    import std.algorithm:map;
                    import std.array:join;
                    throw new Exception("Configuration '"~c.subConfiguration.name~"' specified for dependency '"~req.name~"' but wasn't found. Avaiable Configurations:\n\t"~v.array.map!((JSONValue v) => v["name"].str).join("\n\t"));
                }
                if(preferredConfiguration != -1)
                {
                    configurationToUse = v.array[preferredConfiguration];
                    string cfgName = configurationToUse["name"].str;

                    c.subConfiguration = BuildRequirements.Configuration(cfgName, preferredConfiguration == 0);
                    c.firstRun = false;
                    BuildRequirements subCfgReq = parse(configurationToUse, c);
                    req.configuration = c.subConfiguration;
                    req = req.mergeDependencies(subCfgReq);
                    req = req.addPending(PendingMergeConfiguration(true, subCfgReq.cfg));
                }
            }
        },
        "dependencies": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            import std.path;
            import std.exception;
            import std.algorithm.comparison;
            import redub.package_searching.api;
            import redub.package_searching.cache;
            
            foreach(string depName, JSONValue value; v.object)
            {
                string version_, path, visibility;
                string out_mainPackage;
                string subPackage = getSubPackageInfoRequiredBy(depName, c.requiredBy, out_mainPackage);
                bool isOptional = false;
                bool isInSameFile = false;
                ///If the main package is the same as this dependency, then simply use the same json file.
                if(subPackage && out_mainPackage == c.requiredBy)
                {
                    path = req.cfg.workingDir;
                    isInSameFile = true;
                }
                if(value.type == JSONType.object) ///Uses path style
                {
                    const(JSONValue)* depPath = "path" in value;
                    const(JSONValue)* depVer = "version" in value;
                    const(JSONValue)* depRep = "repository" in value;
                    visibility = value.tryStr("visibility");
                    enforce(depPath || depVer, 
                        "Dependency named "~ depName ~ 
                        " must contain at least a \"path\" or \"version\" property."
                    );
                    if("optional" in value && value["optional"].boolean == true)
                    {
                        if(!("default" in value) || value["default"].boolean == false)
                            isOptional = true;
                    }
                    if(depPath)
                        path = isAbsolute(depPath.str) ? depPath.str : buildNormalizedPath(req.cfg.workingDir, depPath.str);
                    version_ = depVer ? depVer.str : null;
                }
                else if(value.type == JSONType.string) ///Version style
                    version_ = value.str;

                if(isInSameFile)
                {
                    ///Match all dependencies which are subpackages should have the same version as the parent project.
                    if(SemVer(version_).isMatchAll())
                        version_ = c.version_;
                }
                PackageInfo* info;

                string packageFullName = getPackageFullName(depName, c.requiredBy);
                if(!path)
                {
                    info = redub.package_searching.cache.findPackage(packageFullName, version_, c.requiredBy);
                    path = info.path;
                    version_ = info.bestVersion.toString;
                }
                else
                    info = findPackage(packageFullName, version_, c.requiredBy, path);
                
                addDependency(req, c, packageFullName, version_, BuildRequirements.Configuration.init, path, visibility, info, isOptional);

            }
        },
        "subConfigurations": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            enforce(v.type == JSONType.object, "subConfigurations must be an object conversible to string[string]");
            
            foreach(string key, JSONValue value; v)
                addSubConfiguration(req, c, key, value.str);
        },
        "subPackages": (ref BuildRequirements req, JSONValue v, ParseConfig c){}
    ];


    if(cfg.subPackage)
    {
        enforce("name" in json, 
            "dub.json at "~cfg.workingDir~
            " which contains subPackages, must contain a name"
        );
        JSONValue* subPackages = "subPackages" in json;
        enforce(subPackages,
            "dub.json at "~cfg.workingDir~
            " must contain a subPackages property since it has a subPackage named "~cfg.subPackage
        );
        enforce(subPackages.type == JSONType.array, "subPackages property must be an Array");

        setName(buildRequirements, json["name"].str, cfg);

        ///Iterate first all subpackages and add each of them inside the cache
        foreach(JSONValue p; subPackages.array)
        {
            import redub.package_searching.cache;
            enforce(p.type == JSONType.object || p.type == JSONType.string, "subPackages may only be either a string or an object");

            string subPackageName;
            if(p.type == JSONType.object)
            {
                const(JSONValue)* name = "name" in p;
                enforce(name, "All subPackages entries must contain a name.");
                subPackageName = name.str;
            }
            else
            {
                import std.path;
                string subPackagePath = p.str;
                if(!std.path.isAbsolute(subPackagePath))
                    subPackagePath = buildNormalizedPath(cfg.workingDir, subPackagePath);
                enforce(std.file.isDir(subPackagePath), "subPackage path '"~subPackagePath~"' must be a directory " );
                subPackageName = pathSplitter(subPackagePath).back;
            }
            redub.package_searching.cache.putPackageInCache(buildRequirements.name~":"~subPackageName, cfg.version_, cfg.workingDir);
        }

        foreach(JSONValue p; subPackages.array)
        {
            if(p.type == JSONType.object) //subPackage is at same file
            {
                const(JSONValue)* name = "name" in p;
                if(name.str == cfg.subPackage)
                    return parse(p, ParseConfig(cfg.workingDir, cfg.subConfiguration, null, cfg.version_, cfg.cInfo, cfg.requiredBy, buildRequirements.name, true, true, true));
            }
            else ///Subpackage is on other file
            {
                import std.path;
                import std.range:back;
                string subPackagePath = p.str;
                if(!std.path.isAbsolute(subPackagePath))
                    subPackagePath = buildNormalizedPath(cfg.workingDir, subPackagePath);
                string subPackageName = pathSplitter(subPackagePath).back;
                if(subPackageName == cfg.subPackage)
                {
                    import redub.parsers.automatic;
                    return parseProject(subPackagePath, cfg.cInfo, cfg.subConfiguration, null, null, false, cfg.version_);
                }
            } 
        }
        throw new Exception("subPackage named '"~cfg.subPackage~"' could not be found " ~
            "while looking inside the requested package '"~buildRequirements.name ~ "' in path "~ cfg.workingDir
        );
    }
    string[] unusedKeys;

    setName(buildRequirements, json["name"].str, cfg);
    runHandlers(requirementsRun, buildRequirements, cfg, json, false, unusedKeys);

    if(cfg.firstRun && unusedKeys.length) warn("Unused Keys -> ", unusedKeys);

    return buildRequirements;
}

private void runHandlers(
    immutable void function(ref BuildRequirements req, JSONValue v, ParseConfig c)[string] handler,
    ref BuildRequirements buildRequirements, ParseConfig cfg,
    JSONValue target, bool bGetUnusedKeys, out string[] unusedKeys)
{
    import std.algorithm.searching;
    foreach(string key, JSONValue v; target)
    {
        bool mustExecuteHandler = true;
        auto fn = key in handler;
        if(!fn)
        {
            CommandWithFilter filtered = CommandWithFilter.fromKey(key);
            fn = filtered.command in handler;
            
            OS osToMatch = cfg.cInfo.targetOS;
            ///If the command is inside the host filters, it will use host OS instead.
            if(commandsWithHostFilters.countUntil(filtered.command) != -1) osToMatch = std.system.os;

            mustExecuteHandler = filtered.matchesPlatform(osToMatch, cfg.cInfo.isa, cfg.cInfo.compiler) && fn;
        }
        if(mustExecuteHandler)
            (*fn)(buildRequirements, v, cfg);
        else if(bGetUnusedKeys)
            unusedKeys~= key;
    }
}

struct JSONStringArray
{
    JSONValue[] input;
    size_t i;

    const(string) front() const {return input[i].str;}
    void popFront(){i++;}
    bool empty(){ return i >= input.length; }
    size_t length() { return input.length; }

    JSONStringArray save() { return JSONStringArray(input, i); }

}

private JSONStringArray strArr(JSONValue target)
{
    return JSONStringArray(target.array);
}

private JSONStringArray strArr(JSONValue target, string prop)
{
    if(prop in target)
        return strArr(target[prop]);
    return JSONStringArray();
}

enum OSExtension
{
    webAssembly = OS.unknown + 1
}

private bool isOS(string osRep)
{
    switch(osRep)
    {
        case "posix", "linux", "osx", "darwin", "windows", "freebsd", "netbsd", "openbsd", "dragonflybsd", "solaris", "watchos", "tvos", "ios", "webassembly": return true;
        default: return false;
    }
}
private bool isArch(string archRep)
{
    switch(archRep)
    {
        case "x86", "x86_64", "amd64", "x86_mscoff", "arm", "aarch64": return true;
        default: return false;
    }
}
private bool matchesArch(string archRep, ISA isa)
{
    switch(archRep) with(ISA)
    {
        case "x86", "x86_mscoff":     return isa == x86;
        case "x86_64":  return isa == x86_64;
        case "arm":     return isa == arm;
        case "aarch64": return isa == aarch64;
        default:
            throw new Exception("No appropriate switch clause found for architecture '"~archRep~"'");
    }
}

private bool matchesOS(string osRep, OS os)
{
    switch(osRep) with(OS)
    {
        case "posix": return os == solaris || 
                             os == dragonFlyBSD || 
                             os == freeBSD || 
                             os ==  netBSD ||
                             os == openBSD || 
                             os == otherPosix || 
                             "linux".matchesOS(os) || 
                             "osx".matchesOS(os);
        case "freebsd": return os == freeBSD;
        case "netbsd": return os == netBSD;
        case "openbsd": return os == openBSD;
        case "dragonflybsd": return os == dragonFlyBSD;
        case "solaris": return os == solaris;
        case "linux": return os == linux || os == android;
        case "darwin", "osx": return os == osx || os == iOS || os == tvOS || os == watchOS;
        case "watchos": return os == watchOS;
        case "tvos": return os == tvOS;
        case "ios": return os == iOS;
        case "windows": return os == win32 || os == win64;
        case "webassembly", "wasm": return cast(OSExtension)os == OSExtension.webAssembly;
        default: throw new Exception("No appropriate switch clause found for the OS '"~osRep~"'");
    }
}

struct PlatformFilter
{
    string compiler;
    string targetOS;
    string targetArch;
    bool matchesArch(ISA isa){return this.targetArch is null || redub.parsers.json.matchesArch(targetArch, isa);}
    bool matchesOS(OS os){return this.targetOS is null || redub.parsers.json.matchesOS(targetOS, os);}
    bool matchesCompiler(string compiler)
    {
        import std.string:startsWith;
        if(compiler.length == 0 || this.compiler.length == 0) return true;
        if(this.compiler.startsWith("ldc")) return compiler.startsWith("ldc");
        return this.compiler == compiler;
    }

    bool matchesPlatform(OS os, ISA isa, string compiler = null){return matchesOS(os) && matchesArch(isa) && matchesCompiler(compiler);}


    /** 
     * Splits command-compiler-os-arch into a struct.
     * Input examples:
     * - dflags-osx
     * - dflags-ldc-osx
     * - dependencies-windows
     * Params:
     *   key = Any key matching input style
     * Returns: 
     */
    static PlatformFilter fromKeys(string[] keys)
    {
        import std.string;
        PlatformFilter ret;

        ret.compiler = keys[0];
        if(keys.length >= 2) ret.targetOS = keys[1];
        if(keys.length >= 3) ret.targetArch = keys[2];


        if(isOS(ret.compiler)) swap(ret.compiler, ret.targetOS);
        if(isArch(ret.compiler)) swap(ret.compiler, ret.targetArch);

        if(isArch(ret.targetOS)) swap(ret.targetOS, ret.targetArch);
        if(isOS(ret.targetArch)) swap(ret.targetArch, ret.targetOS);

        ///TODO: Remove 'darwin' support.
        if(ret.targetOS == "darwin")
            warn("'darwin' OS filter has been used but it is deprecated. Please use 'osx' instead.");

        return ret;
    }
}

struct CommandWithFilter
{
    string command;
    PlatformFilter filter;

    bool matchesArch(ISA isa){return filter.matchesArch(isa);}
    bool matchesOS(OS os){return filter.matchesOS(os);}
    bool matchesCompiler(string compiler){return filter.matchesCompiler(compiler);}
    bool matchesPlatform(OS os, ISA isa, string compiler = null){return filter.matchesPlatform(os, isa, compiler);}


    /** 
     * Splits command-compiler-os-arch into a struct.
     * Input examples:
     * - dflags-osx
     * - dflags-ldc-osx
     * - dependencies-windows
     * Params:
     *   key = Any key matching input style
     * Returns: 
     */
    static CommandWithFilter fromKey(string key)
    {
        import std.string;
        CommandWithFilter ret;

        string[] keys = key.split("-"); 
        if(keys.length == 1)
            return ret;
        ret.command = keys[0];
        ret.filter = PlatformFilter.fromKeys(keys[1..$]);
        return ret;
    }
}

private string tryStr(JSONValue input, string prop)
{
    const(JSONValue)* v = prop in input;
    if(v) return v.str;
    return null;
}

private void swap(T)(ref T a, ref T b)
{
    T temp = b;
    b = a;
    a = temp;
}

private bool platformMatches(JSONValue[] platforms, OS os, ISA isa)
{
    foreach(p; platforms)
    {
        import std.string;
        PlatformFilter filter = PlatformFilter.fromKeys(p.str.split("-"));

        if(filter.matchesPlatform(os, isa))
            return true;
    }
    return false;
}

BuildRequirements getDefaultBuildRequirement(ParseConfig cfg)
{
    BuildRequirements req;
    if(cfg.firstRun) req = BuildRequirements.defaultInit(cfg.workingDir);
    req.version_ = cfg.version_;
    req.configuration = cfg.subConfiguration;
    req.cfg.workingDir = cfg.workingDir;
    return req;
}