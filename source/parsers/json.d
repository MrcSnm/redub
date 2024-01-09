module parsers.json;
import std.system;
import buildapi;
import std.json;
import std.file;
import etc.c.zlib;

BuildRequirements parse(string filePath, string subConfiguration = "", string subPackage = "")
{
    import std.path;
    ParseConfig c = ParseConfig(true, dirName(filePath), subConfiguration, subPackage);
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
    }
    BuildRequirements buildRequirements = getDefaultBuildRequirement(cfg);
    immutable static  handler = [
        "name": (ref BuildRequirements req, JSONValue v, ParseConfig c){if(c.firstRun) req.cfg.name = v.str;},
        "targetType": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.targetType = targetFrom(v.str);},
        "targetPath": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.outputDirectory = v.str;},
        "importPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.importDirectories = v.strArr;},
        "stringImportPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.stringImportPaths = v.strArr;},
        "sourcePaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.sourcePaths = v.strArr;},
        "libPaths":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.libraryPaths = v.strArr;},
        "libs":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.libraries = v.strArr;},
        "versions":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.versions = v.strArr;},
        "lflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.linkFlags = v.strArr;},
        "dflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.dFlags = v.strArr;},
        "configurations": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            if(c.firstRun)
            {
                enforce(v.type == JSONType.array, "'configurations' must be an array.");
                enforce(v.array.length, "'configurations' must have at least one member.");
                c.firstRun = false;
                JSONValue configurationToUse = v.array[0];
                foreach(JSONValue projectConfiguration; v.array)
                {
                    JSONValue* name = "name" in projectConfiguration;
                    enforce(name, "'configurations' must have a 'name' on each");
                    if(name.str == c.subConfiguration)
                    {
                        configurationToUse = projectConfiguration;
                        break;
                    }
                }
                req = req.merge(parse(configurationToUse, c));
                req.targetConfiguration = configurationToUse["name"].str;
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

                if(out_MainPackage.length)
                {
                    newDep.name = out_MainPackage;
                    newDep.subPackage = subPackageName;
                }
                ///Inside this same package
                if(out_MainPackage == req.name && subPackageName)
                    newDep.path = c.workingDir;

                import std.stdio;
                writeln(out_MainPackage,  " : ", req.name, " ", subPackageName, " ", c.workingDir);

                
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
        foreach(JSONValue p; json["subPackages"].array)
        {
            enforce(p.type == JSONType.object || p.type == JSONType.string, "subPackages may only be either a string or an object");
            if(p.type == JSONType.object)
            {
                const(JSONValue)* name = "name" in p;
                enforce(name, "All subPackages entries must contain a name.");
                if(name.str == cfg.subPackage)
                {
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
                    return parseProject(subPackagePath, cfg.subConfiguration, null);
                }
            } 
        }
    }

    string[] unusedKeys;
    foreach(string key, JSONValue v; json)
    {
        bool mustExecuteHandler = true;
        auto fn = key in handler;
        if(!fn)
        {
            CommandWithFilter filtered = CommandWithFilter.fromKey(key);
            fn = filtered.command in handler;
            //TODO: Add mathesCompiler
            mustExecuteHandler = filtered.matchesOS(os);
        }
        if(fn && mustExecuteHandler)
            (*fn)(buildRequirements, v, cfg);
        else
            unusedKeys~= key;
    }

    import std.algorithm.iteration:filter;
    import std.array:array;
    ///Remove dependencies without paths.
    buildRequirements.dependencies = buildRequirements.dependencies.filter!((dep) => dep.path.length).array;

    // if(cfg.firstRun) writeln("WARNING: Unused Keys -> ", unusedKeys);

    return buildRequirements;
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
    final switch(osRep) with(OS)
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
        case "windows": return os == win32 || os == win64;
    }
}

struct CommandWithFilter
{
    string command;
    string compiler;
    string targetOS;

    bool matchesOS(OS os){return targetOS && parsers.json.matchesOS(targetOS, os);}

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

/** 
* Every parse step can't return a parse dependency.
* If they are null, that means they they won't be deferred. If they return something, that means
* they will need to wait for this dependency to be completed. 
*   (They will only be checked after complete parse)
*/
private alias ParseDependency = string;


struct ParseConfig
{
    bool firstRun;
    string workingDir;
    string subConfiguration;
    string subPackage;
    string requiredBy;
}


BuildRequirements getDefaultBuildRequirement(ParseConfig cfg)
{
    BuildRequirements req = BuildRequirements.defaultInit;
    req.version_ = "~master";
    req.targetConfiguration = cfg.subConfiguration;
    req.cfg.workingDir = cfg.workingDir;
    return req;
}

private string getSubPackageInfo(string packageName, out string mainPackageName)
{
    import std.string:indexOf;
    ptrdiff_t ind = packageName.indexOf(":");
    if(ind == -1) return null;
    mainPackageName = packageName[0..ind];
    return packageName[ind+1..$];
}