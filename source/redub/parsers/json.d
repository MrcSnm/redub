module redub.parsers.json;
import redub.logging;
import std.system;
import redub.buildapi;
import hipjson;
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

/**
 * Parses a .json file into a BuildRequirements
 * Params:
 *   filePath = The JSON file path
 *   projectWorkingDir = Working directory to parse with it
 *   cInfo = Compilation Info for being used as filters while parsing
 *   defaultPackageName = Package name to use if no name is found inside the recipe.
 *   version_ = Version of the current one being parsed. May be used to decide which version to use
 *   subConfiguration = The configuration that were specified in the parsing process
 *   subPackage = The subpackage that is actually being used
 *   parentName = Used as metadata
 *   isRoot = Used as metadata
 * Returns:
 */
BuildRequirements parse(string filePath, 
    string projectWorkingDir, 
    CompilationInfo cInfo,
    string defaultPackageName,
    string version_, 
    BuildRequirements.Configuration subConfiguration,
    string subPackage,
    out BuildConfiguration pending,
    string parentName,
    bool isDescribeOnly = false,
    bool isRoot = false
)
{
    import std.path;
    ParseConfig c = ParseConfig(projectWorkingDir, subConfiguration, subPackage, version_, cInfo, defaultPackageName, ParseSubConfig(null,parentName), preGenerateRun: !isDescribeOnly);
    return parse(parseJSONCached(filePath), c, pending, isRoot);
}

string getPackageName(string filePath)
{
    JSONValue v = parseJSONCached(filePath);
    return v["name"].str;
}

/**
 *
 * Params:
 *   filePath = The JSON file path
 *   fileData = The actual data to use as JSON. This were created for --single builds
 *   projectWorkingDir = Working directory to parse with it
 *   cInfo = Compilation Info for being used as filters while parsing
 *   defaultPackageName = Package name to use if no name is found inside the recipe
 *   version_ = Version of the current one being parsed. May be used to decide which version to use
 *   subConfiguration = The configuration that were specified in the parsing process
 *   subPackage = The subpackage that is actually being used
 *   parentName = Used as metadata
 *   isRoot = Used as metadata
 * Returns:
 */
BuildRequirements parseWithData(string filePath,
    string fileData,
    string projectWorkingDir,
    CompilationInfo cInfo,
    string defaultPackageName,
    string version_,
    BuildRequirements.Configuration subConfiguration,
    string subPackage,
    out BuildConfiguration pending,
    string parentName,
    bool isDescribeOnly = false,
    bool isRoot = false
)
{
    import std.path;
    ParseConfig c = ParseConfig(projectWorkingDir, subConfiguration, subPackage, version_, cInfo, defaultPackageName, ParseSubConfig(null, parentName), preGenerateRun: !isDescribeOnly);
    return parse(parseJSONCached(filePath, fileData), c, pending, isRoot);
}


private __gshared JSONValue[string] jsonCache;
///Saves information about which JSONValues has already registered subPackages for.
private __gshared bool[JSONValue] registeredSubpackages;
/**
 *
 * Params:
 *   filePath = Uses filePath as the file data for parsing. Better API
 * Returns: Same as parseJSONCache
 */
private JSONValue parseJSONCached(string filePath)
{
    return parseJSONCached(filePath, std.file.readText(filePath));
}

/**
* Optimization to be used when dealing with subPackages.
* Params:
*   filePath = The path to use for getting it from cache, used simply as a key to the jsonCache
*   fileData = The actual content to be used for parsing.
*/
private JSONValue parseJSONCached(string filePath, string fileData)
{
    synchronized
    {
        JSONValue* cached = filePath in jsonCache;
        if(cached) return *cached;
        jsonCache[filePath] = parseJSON(fileData);
        if(jsonCache[filePath].hasErrorOccurred)
            throw new Exception(jsonCache[filePath].error);
        return jsonCache[filePath];
    }
}

/** 
 * This function was created since on libraries, they may be reusing multiple times and thus
 * storing the cache between runs may trigger errors.
 */
public void clearJsonRecipeCache()
{
    jsonCache = null;
    registeredSubpackages = null;
}



/** 
 * Params:
 *   json = A dub.json equivalent
 * Returns: 
 */
BuildRequirements parse(JSONValue json, ParseConfig cfg, out BuildConfiguration pending, bool isRoot = false)
{
    import std.exception;
    cfg.isRoot = isRoot;

    ///Setup base of configuration before finding anything
    if(!cfg.extra.requiredBy)
    {
        string name = tryStr(json, "name", cfg.defaultPackageName);
        enforce(name.length, "Every package must contain a 'name' or have a defaultPackageName");
        cfg.extra.requiredBy = name;
        cfg.version_ = tryStr(json, "version", cfg.version_);
    }
    if(isRoot)
    {
        import redub.package_searching.cache;
        putRootPackageInCache(cfg.extra.requiredBy, cfg.workingDir);
        vlog("Added project ", cfg.extra.requiredBy, " to memory cache.");
    }
    BuildRequirements buildRequirements = getDefaultBuildRequirement(cfg, json);

    immutable static requirementsRun = [
        "name": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){},
        "plugins": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _)
        {
            enforce(v.type == JSONType.object, "\"plugins\" in json must be an object.");
            foreach(key, value; v.object)
            {
                enforce(value.type == JSONType.string, "\"plugins\" entry key '"~key~"' must be a string to a path being either a .d file or a dub project.");
                baseLoadPlugin(key, value.str, c.workingDir, c.cInfo);
            }
        },
        "preBuildPlugins": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _)
        {
            foreach(key, value; v.object)
                addPreBuildPlugins(req, key, value.strArr, c);
        },
        "buildTypes": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _)
        {
            static import redub.parsers.build_type;
            if(c.isRoot)
            {
                BuildConfiguration ignored = void;
                c.extra.requiredBy = req.name;
                c.firstRun = false;
                foreach(buildTypeName, value; v.object)
                    redub.parsers.build_type.registeredBuildTypes[buildTypeName] = parse(value, c, ignored).cfg;
            }

        },
        "environments": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _)
        {
            enforce(v.type == JSONType.object, "`environments` must be an object.");
            foreach(key, value; v.object)
            {
                import redub.parsers.environment;
                enforce(value.type == JSONType.string, "Environments value can only be a string.");
                redubEnv[key] = value.str;
            }
        },
        "workingDirectory": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){setTargetRuntimeWorkingDir(req, v.str, c);},
        "targetName": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){setTargetName(req, v.str, c);},
        "targetType": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){setTargetType(req, v.str, c);},
        "targetPath": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){setTargetPath(req, v.str, c);},
        "importPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addImportPaths(req, v.strArr, c);},
        "stringImportPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addStringImportPaths(req, v.strArr, c);},
        "preGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addPreGenerateCommands(req, v.strArr, c);},
        "postGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addPostGenerateCommands(req, v.strArr, c);},
        "preBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addPreBuildCommands(req, v.strArr, c);},
        "postBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addPostBuildCommands(req, v.strArr, c);},
        "copyFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addFilesToCopy(req, v.strArr, c);},
        "extraDependencyFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addExtraDependencyFiles(req, v.strArr, c);},
        "sourcePaths": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addSourcePaths(req, v.strArr, c);},
        "sourceFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addSourceFiles(req, v.strArr, c);},
        "excludedSourceFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addExcludedSourceFiles(req, v.strArr, c);},
        "libPaths":  (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addLibPaths(req, v.strArr, c);},
        "libs":  (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addLibs(req, v.strArr, c);},
        "frameworks":  (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addFrameworks(req, v.strArr, c);},
        "versions":  (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addVersions(req, v.strArr, c);},
        "debugVersions":  (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addDebugVersions(req, v.strArr, c);},
        "lflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addLinkFlags(req, v.strArr, c);},
        "dflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){addDflags(req, v.strArr, c);},
        "configurations": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration pending)
        {
            ///If it is a recursive call (not firstRun), it won't care about configurations
            if(c.firstRun)
            {
                import std.conv:to;
                enforce(v.type == JSONType.array, "'configurations' must be an array, not " ~ v.type.to!string ~ " at file "~ c.workingDir);
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
                            "'platforms' on configuration "~name.str~" at project "~req.name ~ " must be an array"
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
                    string availableConfigs;
                    foreach(JSONValue conf; v.array)
                    {
                        JSONValue* plats = "platforms" in conf;
                        if(!plats || platformMatches(plats.array, os, c.cInfo.isa))
                            availableConfigs~= conf["name"].str;
                        else
                            availableConfigs~= conf["name"].str ~ " [OS-ISA Incompatible]";
                        availableConfigs~= "\n\t";
                    } //Using array.map is causing a memory corruption on macOS somehow. 
                    
                    // string availableConfigs = v.array.map!((JSONValue e)
                    // {
                    //     JSONValue* plats = "platforms" in e;
                    //     if(!plats || platformMatches(plats.array, os, c.cInfo.isa))
                    //         return e["name"].str;
                    //     else
                    //         return e["name"].str ~ " [OS-ISA Incompatible]";
                    // }).join("\n\t");
                    
                    throw new Exception("Configuration '"~c.subConfiguration.name~"' specified for dependency '"~req.name~"' but wasn't found or its platform is incompatible. Preferred subConfiguratio was '" ~ v.array[preferredConfiguration]["name"].str~"' . Available Configurations:\n\t"~availableConfigs);
                }
                if(preferredConfiguration != -1)
                {
                    configurationToUse = v.array[preferredConfiguration];
                    string cfgName = configurationToUse["name"].str;

                    c.subConfiguration = BuildRequirements.Configuration(cfgName, preferredConfiguration == 0);
                    c.firstRun = false;
                    BuildRequirements subCfgReq = parse(configurationToUse, c, pending);
                    req.configuration = c.subConfiguration;
                    req = req.mergeDependencies(subCfgReq);
                    pending = subCfgReq.cfg;
                }
            }
        },
        "dependencies": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _)
        {
            import std.path;
            import std.exception;
            import std.algorithm.comparison;
            import redub.package_searching.api;
            import redub.package_searching.cache;
            import std.parallelism;

            string[] keys = v.keys;

            Dependency[] foundPackages = new Dependency[](keys.length);

            static Dependency parseDep(JSONValue value, string depName, string workingDir, string requiredBy, string configVersion)
            {
                string version_, path, visibility, repo;
                string out_mainPackage;
                string subPackage = getSubPackageInfoRequiredBy(depName, requiredBy, out_mainPackage);
                bool isOptional = false;
                bool isInSameFile = false;
                ///If the main package is the same as this dependency, then simply use the same json file.
                if(subPackage && out_mainPackage == requiredBy)
                {
                    path = workingDir;
                    isInSameFile = true;
                }
                if(value.type == JSONType.object) ///Uses path style
                {
                    path = tryStr(value, "path");
                    version_ = tryStr(value, "version", "*");
                    repo = tryStr(value, "repository");
                    visibility = value.tryStr("visibility");
                    enforce(version_ || path,
                        "Dependency named "~ depName ~
                        " must contain at least a \"path\" or \"version\" property."
                    );
                    import redub.misc.path;
                    isOptional = tryBool(value, "optional") && !tryBool(value, "default");
                    if(path)
                        path = isAbsolute(path) ? path : redub.misc.path.buildNormalizedPath(workingDir, path);
                }
                else if(value.type == JSONType.string) ///Version style
                    version_ = value.str;

                if(isInSameFile)
                {
                    ///Match all dependencies which are subpackages should have the same version as the parent project.
                    if(SemVer(version_).isMatchAll())
                        version_ = configVersion;
                }
                PackageInfo* info;

                string packageFullName = getPackageFullName(depName, requiredBy);
                if(!path)
                {
                    info = redub.package_searching.cache.findPackage(packageFullName, repo, version_, requiredBy);
                    path = info.path;
                    version_ = info.bestVersion.toString;
                }
                else
                    info = findPackage(packageFullName, repo, version_, requiredBy, path);
                return Dependency(packageFullName, path, version_, BuildRequirements.Configuration.init, null, VisibilityFrom(visibility), info, isOptional);
            }


            //Having a separate branch for not doing in parallel actually reduced the time needed to resolve dependencies
            //Unfortunately, this code makes dependency resolution a little slower (4ms in case of hipreme engine)
            //But it may cut fetch time to 25% of the time required
            if(keys.length > 1)
            {
                foreach(size_t i, string depName; parallel(keys))
                    foundPackages[i] = parseDep(v[depName], depName, req.cfg.workingDir, c.extra.requiredBy, c.version_);
                foreach(pkg; foundPackages)
                    addDependency(req, c, pkg.name, pkg.version_, BuildRequirements.Configuration.init, pkg.path, getVisibilityString(pkg.visibility), pkg.pkgInfo, pkg.isOptional);
            }
            else if(keys.length == 1)
            {
                string depName = keys[0];
                Dependency pkg = parseDep(v[depName], depName, req.cfg.workingDir, c.extra.requiredBy, c.version_);
                addDependency(req, c, pkg.name, pkg.version_, BuildRequirements.Configuration.init, pkg.path, getVisibilityString(pkg.visibility), pkg.pkgInfo, pkg.isOptional);
            }

        },
        "subConfigurations": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _)
        {
            enforce(v.type == JSONType.object, "subConfigurations must be an object conversible to string[string]");
            
            foreach(string key, JSONValue value; v)
                addSubConfiguration(req, c, key, value.str);
        },
        "subPackages": (ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration _){}
    ];

    setName(buildRequirements, tryStr(json, "name", cfg.defaultPackageName), cfg);
    //If the package has subPackages, already register them so in the future they may be accessed
    JSONValue* subPackages = "subPackages" in json;
    if(json !in registeredSubpackages && subPackages)
    {
        import std.algorithm.searching:countUntil;
        registeredSubpackages[json] = true;
        string[] existingSubpackages;
        enforce("name" in json,
            "dub.json at "~cfg.workingDir~
            " which contains subPackages, must contain a name"
        );
        enforce(subPackages.type == JSONType.array, "subPackages property must be an Array");
        // setName(buildRequirements, json["name"].str, cfg);
        ///Iterate first all subpackages and add each of them inside the cache
        foreach(JSONValue p; subPackages.array)
        {
            import redub.package_searching.cache;
            enforce(p.type == JSONType.object || p.type == JSONType.string, "subPackages may only be either a string or an object");

            string subPackageName;
            string subPackagePath = cfg.workingDir;
            bool isInternalSubPackage = p.type == JSONType.object;
            if(isInternalSubPackage)
            {
                const(JSONValue)* name = "name" in p;
                enforce(name, "All subPackages entries must contain a name.");
                subPackageName = name.str;
            }
            else
            {
                import std.path;
                import redub.misc.path;
                subPackagePath = p.str;
                if(!std.path.isAbsolute(subPackagePath))
                    subPackagePath = redub.misc.path.buildNormalizedPath(cfg.workingDir, subPackagePath);
                enforce(std.file.isDir(subPackagePath), "subPackage path '"~subPackagePath~"' must be a directory " );
                subPackageName = pathSplitter(subPackagePath).back;
            }
            if(countUntil(existingSubpackages, subPackageName) != -1)
                errorTitle("Redundant SubPackage Definition: ", "SubPackage '"~subPackageName~"' was already registered. The subPackage for path " ~subPackagePath~" will be ignored");
            else
            {
                redub.package_searching.cache.putPackageInCache(buildRequirements.name~":"~subPackageName, cfg.version_, subPackagePath, cfg.extra.requiredBy, isInternalSubPackage);
                existingSubpackages~= subPackageName;
            }
        }
    }

    if(cfg.subPackage)
    {

        enforce(subPackages,
            "dub.json at "~cfg.workingDir~
            " must contain a subPackages property since it has a subPackage named "~cfg.subPackage
        );

        foreach(JSONValue p; subPackages.array)
        {
            if(p.type == JSONType.object) //subPackage is at same file
            {
                const(JSONValue)* name = "name" in p;
                if(name.str == cfg.subPackage)
                    return parse(p, ParseConfig(cfg.workingDir, cfg.subConfiguration, null, cfg.version_, cfg.cInfo, null, ParseSubConfig(cfg.extra.requiredBy, buildRequirements.name), true, true), pending);
            }
            else ///Subpackage is on other file
            {
                import std.path;
                import redub.misc.path;
                import std.range:back;
                string subPackagePath = p.str;
                if(!std.path.isAbsolute(subPackagePath))
                    subPackagePath = redub.misc.path.buildNormalizedPath(cfg.workingDir, subPackagePath);
                string subPackageName = pathSplitter(subPackagePath).back;

                if(subPackageName == cfg.subPackage)
                {
                    import redub.parsers.automatic;
                    return parseProject(subPackagePath, cfg.cInfo, cfg.subConfiguration, null, null, buildRequirements.name, false, cfg.version_);
                }
            } 
        }
        import std.array;
        import std.algorithm.iteration;

        throw new Exception("subPackage named '"~cfg.subPackage~"' could not be found " ~
            "while looking inside the requested package '"~buildRequirements.name ~ "' in path "~ cfg.workingDir~".\nAvailable subpackages:\n\t"~
            subPackages.array.map!((JSONValue v) => v.type == JSONType.string_ ? v.str : v["name"].str).join("\n\t")
        );
    }
    string[] unusedKeys;

    runHandlers(requirementsRun, buildRequirements, cfg, json, false, unusedKeys, pending);

    if(cfg.firstRun && unusedKeys.length) warn("Unused Keys -> ", unusedKeys);
    runPreGenerateCommands(cfg, buildRequirements);
    return buildRequirements;
}

private void runHandlers(
    immutable void function(ref BuildRequirements req, JSONValue v, ParseConfig c, ref BuildConfiguration pending)[string] handler,
    ref BuildRequirements buildRequirements, ParseConfig cfg,
    JSONValue target, bool bGetUnusedKeys, out string[] unusedKeys, ref BuildConfiguration pending)
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
            (*fn)(buildRequirements, v, cfg, pending);
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

private bool isOS(string osRep)
{
    switch(osRep)
    {
        case "posix", "linux", "osx", "darwin", "windows", "freebsd", "netbsd", "openbsd", "dragonflybsd", "solaris", "watchos", "tvos", "ios", "visionos", "webassembly", "emscripten": return true;
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
        case "darwin", "osx": return os == osx || os == iOS || os == tvOS || os == watchOS || cast(OSExtension)os == OSExtension.visionOS;
        case "watchos": return os == watchOS;
        case "tvos": return os == tvOS;
        case "ios": return os == iOS;
        case "visionos": return cast(OSExtension)os == OSExtension.visionOS;
        case "windows": return os == win32 || os == win64;
        case "webassembly", "wasm": return cast(OSExtension)os == OSExtension.webAssembly;
        case "emscripten": return cast(OSExtension)os == OSExtension.emscripten;
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

private bool tryBool(JSONValue input, string prop)
{
    const(JSONValue)* v = prop in input;
    if(v) return v.boolean;
    return false;
}

private string tryStr(JSONValue input, string prop, string defStr = null)
{
    const(JSONValue)* v = prop in input;
    if(v) return v.str;
    return defStr;
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

BuildRequirements getDefaultBuildRequirement(ParseConfig cfg, JSONValue json)
{
    BuildRequirements req;

    RedubLanguages l = tryStr(json, "language", "D").redubLanguage;
    ///defaultPackageName is only ever sent whenever --single is being used.
    if(cfg.firstRun && !cfg.defaultPackageName) req = BuildRequirements.defaultInit(cfg.workingDir, l);
    req.version_ = cfg.version_;
    req.configuration = cfg.subConfiguration;
    req.cfg.workingDir = cfg.workingDir;
    return req;
}