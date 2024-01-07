module parsers.json;
import std.system;
import buildapi;
import std.json;
import std.file;

BuildRequirements parse(string filePath, string subConfiguration = "")
{
    import std.path;
    ParseConfig c = ParseConfig(true, dirName(filePath), subConfiguration);
    return parse(parseJSON(std.file.readText(filePath)), c);
}

/** 
 * Params:
 *   json = A dub.json equivalent
 * Returns: 
 */
BuildRequirements parse(JSONValue json, ParseConfig cfg)
{
    ///Setup base of configuration before finding anything
    BuildRequirements buildRequirements = getDefaultBuildRequirement(cfg);
    immutable static handler = [
        "name": (ref BuildRequirements req, JSONValue v, ParseConfig c){if(c.firstRun) req.cfg.name = v.str;},
        "targetType": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.targetType = targetFrom(v.str);},
        "targetPath": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.outputDirectory = v.str;},
        "importPaths": (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.importDirectories = v.strArr;},
        "libPaths":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.libraryPaths = v.strArr;},
        "libs":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.libraries = v.strArr;},
        "versions":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.versions = v.strArr;},
        "lflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.linkFlags = v.strArr;},
        "dflags":  (ref BuildRequirements req, JSONValue v, ParseConfig c){req.cfg.dFlags = v.strArr;},
        "configurations": (ref BuildRequirements req, JSONValue v, ParseConfig c)
        {
            if(c.firstRun)
            {
                c.firstRun = false;
                req.cfg = req.cfg.merge(parse(v.array[0], c).cfg);
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
                if(value.type == JSONType.object) ///Uses path style
                {
                    const(JSONValue)* depPath = "path" in value;
                    const(JSONValue)* depVer = "version" in value;
                    enforce(depPath || depVer, "Dependency named "~ depName ~ " must contain at least a \"path\" or \"version\" property.");
                    if(depPath)
                        newDep.path = depPath.str;
                    if(depVer)
                    {
                        if(!depPath) newDep.path = package_searching.dub.getPackagePath(depName, depVer.str, req.cfg.name);
                        newDep.version_ = depVer.str;
                    }
                }
                else if(value.type == JSONType.string) ///Version style
                {
                    newDep.version_ = value.str;
                    newDep.path = package_searching.dub.getPackagePath(depName, value.str);
                }
                if(newDep.path.length && !isAbsolute(newDep.path)) newDep.path = buildNormalizedPath(c.workingDir, newDep.path);
                req.dependencies~= newDep;
            }
        }
    ];

    string[] unusedKeys;
    foreach(string key, JSONValue v; json)
    {
        auto fn = key in handler;
        if(fn)
            (*fn)(buildRequirements, v, cfg);
        else
        {
            CommandWithFilter filtered = CommandWithFilter.fromKey(key);
            fn = filtered.command in handler;
            if(fn)
            {
                //TODO: Add mathesCompiler
                if(filtered.matchesOS(os))
                    (*fn)(buildRequirements, v, cfg);
            }
            else
                unusedKeys~= key;
        }
    }
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



struct ParseConfig
{
    bool firstRun;
    string workingDir;
    string subConfiguration;
}


BuildRequirements getDefaultBuildRequirement(ParseConfig cfg)
{
    BuildRequirements req = BuildRequirements.init;
    req.version_ = "~master";
    req.targetConfiguration = cfg.subConfiguration;
    req.cfg.workingDir = cfg.workingDir;
    return req;
}