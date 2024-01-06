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
BuildRequirements parse(JSONValue json)
{
    BuildRequirements buildRequirements;
    BuildConfiguration* cfg = &buildRequirements.cfg;


    foreach(string key, JSONValue v; json)
    {
        switch(key)
        {
            case "importPaths":
                cfg.importDirectories = v.strArr;
                break;
            case "libPaths": 
                cfg.libraryPaths = v.strArr;
                break;
            case "libraries": 
                cfg.libraries = v.strArr;
                break;
            case "versions": 
                cfg.versions = v.strArr;
                break;
            default: break;
        }
    }

    //OS specific stuff


    //Compiler specific stuff


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

private bool osMatches(OS os, string osRep)
{
    final switch(osRep) with(OS)
    {
        case "posix": return os == solaris || 
                             os == dragonFlyBSD || 
                             os == freeBSD || 
                             os ==  netBSD ||
                             os == openBSD || 
                             os == otherPosix || 
                             osMatches(os, "linux") || 
                             osMatches(os, "osx");
        case "linux": return os == linux || os == android;
        case "osx": return os == osx || os == iOS || os == tvOS || os == watchOS;
        case "windows": return os == win32 || os == win64;
    }
}
