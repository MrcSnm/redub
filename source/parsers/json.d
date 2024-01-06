module parsers.json;
import std.system;
import buildapi;
import std.json;
import std.file;

BuildRequirements parse(string filePath)
{
    return parse(parseJSON(std.file.readText(filePath)));
}


/** 
 * Params:
 *   json = A dub.json equivalent
 * Returns: 
 */
BuildRequirements parse(JSONValue json, bool firstRun = true)
{
    import std.string:split;
    BuildRequirements buildRequirements;
    immutable static handler = [
        "name": (ref BuildRequirements req, JSONValue v, bool firstRun){if(firstRun) req.cfg.name = v.str;},
        "targetType": (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.targetType = targetFrom(v.str);},
        "targetPath": (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.outputDirectory = v.str;},
        "importPaths": (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.importDirectories = v.strArr;},
        "libPaths":  (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.libraryPaths = v.strArr;},
        "libs":  (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.libraries = v.strArr;},
        "versions":  (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.versions = v.strArr;},
        "lflags":  (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.linkFlags = v.strArr;},
        "dflags":  (ref BuildRequirements req, JSONValue v, bool firstRun){req.cfg.dFlags = v.strArr;},
        "configurations": (ref BuildRequirements req, JSONValue v, bool firstRun)
        {
            if(firstRun) req.cfg = req.cfg.merge(parse(v.array[0], false).cfg);
        },
        "dependencies": (ref BuildRequirements req, JSONValue v, bool firstRun)
        {
            import std.exception;
            import package_searching.dub;
            foreach(string depName, JSONValue value; v.object)
            {
                Dependency newDep = Dependency(depName);
                if(value.type == JSONType.object) ///Uses path style
                {
                    const(JSONValue)* depPath = "path" in value;
                    enforce(depPath, "Dependency named "~depName~" must contain a \"path\" property.");
                    newDep.path = depPath.str;
                    const(JSONValue)* depVer = "version" in value;
                    if(depVer) newDep.version_ = depVer.str;
                }
                else if(value.type == JSONType.string) ///Version style
                {
                    newDep.version_ = value.str;
                    newDep.path = getPackagePath(depName, value.str);
                }
                req.dependencies~= newDep;
            }
        }
    ];

    string[] unusedKeys;
    foreach(string key, JSONValue v; json)
    {
        auto fn = key in handler;
        if(fn)
            (*fn)(buildRequirements, v, firstRun);
        else
        {
            CommandWithFilter filtered = CommandWithFilter.fromKey(key);
            fn = filtered.command in handler;
            if(fn)
            {
                //TODO: Add mathesCompiler
                if(filtered.matchesOS(os))
                    (*fn)(buildRequirements, v, firstRun);
            }
            else
                unusedKeys~= key;
        }
    }
    import std.stdio;
    if(firstRun) writeln("WARNING: Unused Keys -> ", unusedKeys);

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