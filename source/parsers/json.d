module parsers.json;
import std.system;
import buildapi;
import std.json;
import std.file;
import etc.c.zlib;
import core.cpuid;

BuildRequirements parse(string filePath, string compiler, string version_, string subConfiguration = "", string subPackage = "")
{
    import std.path;
    ParseConfig c = ParseConfig(dirName(filePath), subConfiguration, subPackage, version_, compiler);
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
        "name": (ref BuildRequirements req, JSONValue v, ParseConfig c){if(c.firstRun) req.cfg.name = v.str;},
        "targetType": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.targetType = targetFrom(v.str);},
        "targetPath": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.outputDirectory = v.str;},
        "importPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.importDirectories.exclusiveMerge(v.strArr);},
        "stringImportPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.stringImportPaths.exclusiveMergePaths(v.strArr);},
        "preGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.preGenerateCommands~= v.strArr;},
        "postGenerateCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.postGenerateCommands~= v.strArr;},
        "preBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.preBuildCommands~= v.strArr;},
        "postBuildCommands": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.postBuildCommands~= v.strArr;},
        "sourcePaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.sourcePaths.exclusiveMergePaths(v.strArr);},
        "sourceFiles": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.sourceFiles.exclusiveMerge(v.strArr);},
        "libPaths":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.libraryPaths.exclusiveMerge(v.strArr);},
        "libs":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.libraries.exclusiveMerge(v.strArr);},
        "versions":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.versions.exclusiveMerge(v.strArr);},
        "lflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.linkFlags.exclusiveMerge(v.strArr);},
        "dflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.dFlags.exclusiveMerge(v.strArr);},
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
                    if(name.str == c.subConfiguration)
                    {
                        preferredConfiguration = i.to!int;
                        break;
                    }
                }
                if(preferredConfiguration != -1)
                {
                    configurationToUse = v.array[preferredConfiguration];
                    BuildRequirements subCfgReq = parse(configurationToUse, c);
                    req = req.merge(subCfgReq);
                    req.targetConfiguration = configurationToUse["name"].str;
                }
            }
        },
        "dependencies": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            import std.path;
            import std.exception;
            import package_searching.dub;
            foreach(string depName, JSONValue value; v.object)
            {
                Dependency newDep = Dependency(depName);
                string out_MainPackage;
                string subPackageName = getSubPackageInfo(depName, out_MainPackage);

                ///If subPackage was found, populate informations on it
                if(out_MainPackage.length)
                {
                    newDep.name = out_MainPackage;
                    newDep.subPackage = subPackageName;
                }
                ///Inside this same package
                if(out_MainPackage == req.name && subPackageName)
                    newDep.path = c.workingDir;

                
                if(value.type == JSONType.object) ///Uses path style
                {
                    const(JSONValue)* depPath = "path" in value;
                    const(JSONValue)* depVer = "version" in value;
                    const(JSONValue)* depOpt = "optional" in value;
                    const(JSONValue)* depDef = "default" in value;
                    enforce(depPath || depVer, 
                        "Dependency named "~ depName ~ 
                        " must contain at least a \"path\" or \"version\" property."
                    );

                    if(depOpt && depOpt.boolean == true)
                    {
                        if(!depDef || depDef.boolean == false)
                            continue;
                    }

                    if(depPath && !newDep.path)
                        newDep.path = depPath.str;
                    if(depVer)
                    {
                        if(!depPath && !newDep.path) newDep.path = package_searching.dub.getPackagePath(depName, depVer.str, req.cfg.name);
                        newDep.version_ = depVer.str;
                    }
                }
                else if(value.type == JSONType.string) ///Version style
                {
                    newDep.version_ = value.str;
                    if(!newDep.path) newDep.path = package_searching.dub.getPackagePath(depName, value.str, c.requiredBy);
                }
                if(newDep.path.length && !isAbsolute(newDep.path)) newDep.path = buildNormalizedPath(c.workingDir, newDep.path);
                import std.algorithm.searching:countUntil;

                //If dependency already exists, use the existing one
                ptrdiff_t depIndex = countUntil!((a) => a.isSameAs(newDep))(req.dependencies);
                if(depIndex == -1)
                    req.dependencies~= newDep;
                else
                {
                    newDep.subConfiguration = req.dependencies[depIndex].subConfiguration;
                    req.dependencies[depIndex] = newDep;
                }
                
            }
        },
        "subConfigurations": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            enforce(v.type == JSONType.object, "subConfigurations must be an object conversible to string[string]");

            if(req.dependencies.length == 0)
            {
                foreach(string key, JSONValue value; v)
                    req.dependencies~= Dependency(key, null, null, value.str);
            }
            else
            {
                foreach(ref Dependency dep; req.dependencies)
                {
                    JSONValue* subCfg = dep.name in v;
                    if(subCfg)
                        dep.subConfiguration = subCfg.str;
                }
            }
        },
        "subPackages": (ref BuildRequirements req, JSONValue v, ParseConfig c){}
    ];
    if(cfg.subPackage.length)
    {
        enforce("name" in json, 
            "dub.json at "~cfg.workingDir~
            " which contains subPackages, must contain a name"
        );
        buildRequirements.cfg.name = json["name"].str;
        enforce("subPackages" in json, 
            "dub.json at "~cfg.workingDir~
            " must contain a subPackages property since it has a subPackage named "~cfg.subPackage
        );
        enforce(json["subPackages"].type == JSONType.array,
            "subPackages property must ben Array"
        );
        bool isSubpackageInPackage = false;
        foreach(JSONValue p; json["subPackages"].array)
        {
            enforce(p.type == JSONType.object || p.type == JSONType.string, "subPackages may only be either a string or an object");
            if(p.type == JSONType.object)
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
            else
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
                    return parseProject(subPackagePath, cfg.compiler, cfg.subConfiguration, null);
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


    import std.algorithm.iteration:filter;
    import std.array:array;
    ///Remove dependencies without paths.
    buildRequirements.dependencies = buildRequirements.dependencies.filter!((dep) => dep.path.length).array;

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
    {return this.compiler is null || compiler == this.compiler;}

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

/** 
* Every parse step can't return a parse dependency.
* If they are null, that means they they won't be deferred. If they return something, that means
* they will need to wait for this dependency to be completed. 
*   (They will only be checked after complete parse)
*/
private alias ParseDependency = string;


struct ParseConfig
{
    string workingDir;
    string subConfiguration;
    string subPackage;
    string version_ = "~master";
    string compiler;
    string requiredBy;
    bool firstRun = true;
    bool preGenerateRun = true;
}


BuildRequirements getDefaultBuildRequirement(ParseConfig cfg)
{
    BuildRequirements req = BuildRequirements.defaultInit(cfg.workingDir);
    req.version_ = cfg.version_;
    req.targetConfiguration = cfg.subConfiguration;
    req.cfg.workingDir = cfg.workingDir;
    return req;
}