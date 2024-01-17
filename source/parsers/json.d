module parsers.json;
import std.system;
import buildapi;
import std.json;
import std.file;
import parsers.base;

BuildRequirements parse(string filePath, 
    string projectWorkingDir, 
    string compiler, 
    string version_, 
    BuildRequirements.Configuration subConfiguration,
    string subPackage
)
{
    import std.path;
    ParseConfig c = ParseConfig(projectWorkingDir, subConfiguration, subPackage, version_, compiler);
    return parse(parseJSONCached(filePath), c);
}

private JSONValue[string] jsonCache;
///Optimization to be used when dealing with subPackages
private JSONValue parseJSONCached(string filePath)
{
    const(JSONValue)* cached = filePath in jsonCache;
    if(cached) return *cached;
    jsonCache[filePath] = parseJSON(std.file.readText(filePath));
    return jsonCache[filePath];
}



/** 
 * Params:
 *   json = A dub.json equivalent
 * Returns: 
 */
BuildRequirements parse(JSONValue json, ParseConfig cfg)
{
    import std.exception;
    import std.stdio;
    ///Setup base of configuration before finding anything
    if(cfg.firstRun)
    {
        enforce("name" in json, "Every package must contain a 'name'");
        cfg.requiredBy = json["name"].str;
        if("version" in json)
            cfg.version_ = json["version"].str;
    }
    BuildRequirements buildRequirements = getDefaultBuildRequirement(cfg);

    immutable static preGenerateRun = [
        "preGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            foreach(JSONValue cmd; v.array)
            {
                import std.process;
                import std.conv:to;
                auto res = executeShell(cmd.str, null, Config.none, size_t.max, c.workingDir);
                if(res.status)
                    throw new Error("preGenerateCommand '"~cmd.str~"; exited with code "~res.status.to!string);
            }
        }
    ];

    immutable static requirementsRun = [
        "name": (ref BuildRequirements req, JSONValue v, ParseConfig c){setName(req, v.str, c);},
        "targetType": (ref BuildRequirements req, JSONValue v, ParseConfig c){setTargetType(req, v.str, c);},
        "targetPath": (ref BuildRequirements req, JSONValue v, ParseConfig c){setTargetPath(req, v.str, c);},
        "importPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){addImportPaths(req, v.strArr, c);},
        "stringImportPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){addStringImportPaths(req, v.strArr, c);},
        "preGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPreGenerateCommands(req, v.strArr, c);},
        "postGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPostGenerateCommands(req, v.strArr, c);},
        "preBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPreBuildCommands(req, v.strArr, c);},
        "postBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){addPostBuildCommands(req, v.strArr, c);},
        "sourcePaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){addSourcePaths(req, v.strArr, c);},
        "sourceFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c){addSourceFiles(req, v.strArr, c);},
        "libPaths":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addLibPaths(req, v.strArr, c);},
        "libs":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addLibs(req, v.strArr, c);},
        "versions":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addVersions(req, v.strArr, c);},
        "lflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addLinkFlags(req, v.strArr, c);},
        "dflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){addDflags(req, v.strArr, c);},
        "configurations": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            if(c.firstRun)
            {
                import std.conv:to;
                enforce(v.type == JSONType.array, "'configurations' must be an array.");
                enforce(v.array.length, "'configurations' must have at least one member.");
                c.firstRun = false;
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
                        if(!platformMatches(platforms.array, os))
                            continue;
                    }
                    if(preferredConfiguration == -1)
                        preferredConfiguration = i.to!int;
                    if(name.str == c.subConfiguration.name)
                    {
                        preferredConfiguration = i.to!int;
                        break;
                    }
                }
                if(preferredConfiguration != -1)
                {
                    configurationToUse = v.array[preferredConfiguration];
                    string cfgName = configurationToUse["name"].str;
                    c.subConfiguration = BuildRequirements.Configuration(cfgName, preferredConfiguration == 0);
                    BuildRequirements subCfgReq = parse(configurationToUse, c);
                    req.configuration = c.subConfiguration;
                    req = req.merge(subCfgReq);
                }
            }
        },
        "dependencies": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            import std.path;
            import std.exception;
            import std.algorithm.comparison;
            import package_searching.dub;
            
            foreach(string depName, JSONValue value; v.object)
            {
                string name, version_, path, visibility;
                name = depName;
                if(value.type == JSONType.object) ///Uses path style
                {
                    const(JSONValue)* depPath = "path" in value;
                    const(JSONValue)* depVer = "version" in value;
                    visibility = value.tryStr("visibility");
                    enforce(depPath || depVer, 
                        "Dependency named "~ name ~ 
                        " must contain at least a \"path\" or \"version\" property."
                    );

                    if("optional" in value && value["optional"].boolean == true)
                    {
                        if(!("default" in value) || value["default"].boolean == false)
                        {
                            import std.stdio;
                            writeln("Warning: redub does not handle optional dependencies.");
                            continue;
                        }
                    }

                    path = either(path, depPath ? depPath.str : null, depVer ? package_searching.dub.getPackagePath(name, depVer.str, req.cfg.name) : null);
                    version_ = either(version_, depVer ? depVer.str : null);
                }
                else if(value.type == JSONType.string) ///Version style
                {
                    version_ = value.str;
                    if(!path) path = package_searching.dub.getPackagePath(name, value.str, c.requiredBy);
                }
                addDependency(req, c, name, version_, BuildRequirements.Configuration.init, path, visibility);
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
        enforce("subPackages" in json, 
            "dub.json at "~cfg.workingDir~
            " must contain a subPackages property since it has a subPackage named "~cfg.subPackage
        );
        enforce(json["subPackages"].type == JSONType.array,
            "subPackages property must ben Array"
        );
        buildRequirements.cfg.name = json["name"].str;
        bool isSubpackageInPackage = false;
        foreach(JSONValue p; json["subPackages"].array)
        {
            enforce(p.type == JSONType.object || p.type == JSONType.string, "subPackages may only be either a string or an object");
            if(p.type == JSONType.object) //subPackage is at same file
            {
                const(JSONValue)* name = "name" in p;
                enforce(name, "All subPackages entries must contain a name.");
                if(name.str == cfg.subPackage)
                {
                    isSubpackageInPackage = true;
                    json = p;
                    break;
                }
            }
            else ///Subpackage is on other file
            {
                import std.path;
                import std.array;
                string subPackagePath = p.str;
                if(!std.path.isAbsolute(subPackagePath))
                    subPackagePath = buildNormalizedPath(cfg.workingDir, subPackagePath);
                enforce(std.file.isDir(subPackagePath), 
                    "subPackage path '"~subPackagePath~"' must be a directory "
                );
                string subPackageName = pathSplitter(subPackagePath).array[$-1];
                if(subPackageName == cfg.subPackage)
                {
                    import parsers.automatic;
                    isSubpackageInPackage = true;
                    return parseProject(subPackagePath, cfg.compiler, cfg.subConfiguration, null, null);
                }
            } 
        }
        enforce(isSubpackageInPackage, 
            "subPackage named '"~cfg.subPackage~"' could not be found " ~
            "while looking inside the requested package '"~buildRequirements.name ~ "' "~
            "in path "~cfg.workingDir
        );
    }
    string[] unusedKeys;
    if(cfg.preGenerateRun)
    {
        runHandlers(preGenerateRun, buildRequirements, cfg, json, false, unusedKeys);
        cfg.preGenerateRun = false;
    }
    runHandlers(requirementsRun, buildRequirements, cfg, json, false, unusedKeys);


    // if(cfg.firstRun) writeln("WARNING: Unused Keys -> ", unusedKeys);

    return buildRequirements;
}

private void runHandlers(
    immutable void function(ref BuildRequirements req, JSONValue v, ParseConfig c)[string] handler,
    ref BuildRequirements buildRequirements, ParseConfig cfg,
    JSONValue target, bool bGetUnusedKeys, out string[] unusedKeys)
{
    foreach(string key, JSONValue v; target)
    {
        bool mustExecuteHandler = true;
        auto fn = key in handler;
        if(!fn)
        {
            CommandWithFilter filtered = CommandWithFilter.fromKey(key);
            fn = filtered.command in handler;

            mustExecuteHandler = filtered.matchesOS(os) && filtered.matchesCompiler(cfg.compiler) && fn;
        }
        if(mustExecuteHandler)
            (*fn)(buildRequirements, v, cfg);
        else if(bGetUnusedKeys)
            unusedKeys~= key;
    }
}

private string[] strArr(JSONValue target)
{
    JSONValue[] arr = target.array;
    string[] ret = new string[](arr.length);
    foreach(i, JSONValue v; arr) 
        ret[i] = v.str;
    return ret;
}

private string[] strArr(JSONValue target, string prop)
{
    if(prop in target)
        return strArr(target[prop]);
    return [];
}

private bool isOS(string osRep)
{
    switch(osRep)
    {
        case "posix", "linux", "osx", "windows": return true;
        default: return false;
    }
}
private bool isArch(string archRep)
{
    switch(archRep)
    {
        case "x86", "x84_64", "amd64", "x86_mscoff": return true;
        default: return false;
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
        case "linux": return os == linux || os == android;
        case "osx": return os == osx || os == iOS || os == tvOS || os == watchOS;
        case "windows", "windows-x86_64", "windows-x86_mscoff": return os == win32 || os == win64;
        default: throw new Error("No appropriate switch clause found for "~osRep);
    }
}

struct CommandWithFilter
{
    string command;
    string compiler;
    string targetOS;

    bool matchesOS(OS os){return this.targetOS is null || parsers.json.matchesOS(targetOS, os);}
    bool matchesCompiler(string compiler)
    {
        import std.string:startsWith;
        if(this.compiler is null) return true;
        if(this.compiler.startsWith("ldc")) return compiler.startsWith("ldc");
        return this.compiler == compiler;
    }

    /** 
     * Splits command-compiler-os into a struct.
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
        ret.compiler = keys[1];

        if(keys.length == 3) ret.targetOS = keys[2];
        if(isOS(ret.compiler)) swap(ret.compiler, ret.targetOS);
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

private bool platformMatches(JSONValue[] platforms, OS os)
{
    foreach(p; platforms)
        if(matchesOS(p.str, os))
            return true;
    return false;
}

BuildRequirements getDefaultBuildRequirement(ParseConfig cfg)
{
    BuildRequirements req = BuildRequirements.defaultInit(cfg.workingDir);
    req.version_ = cfg.version_;
    req.configuration = cfg.subConfiguration;
    req.cfg.workingDir = cfg.workingDir;
    return req;
}