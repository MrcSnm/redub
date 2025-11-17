/**
 * This module provides a way for accessing meta information on redub execution.
 * Things such as compiler information and redub version are saved here.
 *
 */
module redub.meta;
public import hip.data.json;

private string getRedubMetaFileName()
{
    import redub.misc.path;
    import redub.api;
    static string redubCompilersFile;
    if(redubCompilersFile == null)
        redubCompilersFile = buildNormalizedPath(getDubWorkspacePath, "redub_meta.json");
    return redubCompilersFile;
}


void saveRedubMeta(JSONValue content)
{
    import redub.buildapi;
    import std.file;
    import std.path;
    string dir = dirName(getRedubMetaFileName);
    if(!std.file.exists(dir))
        mkdirRecurse(dir);

    if(!("version" in content))
        content["version"] = JSONValue(RedubVersionOnly);

    std.file.write(getRedubMetaFileName, content.toString);
}

string getCachedString(ref JSONValue v, string prop, scope lazy string valueWhenNotFound)
{
    JSONValue* ret = prop in v;
    if(ret)
    {
        string val = ret.str;
        if(val.length)
            return val;
    }
    string res = valueWhenNotFound;
    v[prop] = JSONValue(res);
    saveRedubMeta(v);
    return res;
}

JSONValue getRedubMeta()
{
    import std.file;
    import redub.buildapi;
    static JSONValue meta;
    string metaFile = getRedubMetaFileName;
    if(meta == JSONValue.init)
    {
        if(exists(metaFile))
        {
            meta = parseJSON(cast(string)std.file.read(getRedubMetaFileName), true);
            if(meta == JSONValue.IncompleteStream || meta.hasErrorOccurred)
                return JSONValue.emptyObject;
            JSONValue* ver = "version" in meta;
            if(ver == null || ver.str != RedubVersionOnly)
                return JSONValue.emptyObject;
        }
        else
        {
            return JSONValue.emptyObject;
        }
    }
    return meta;
}

string getExistingRedubVersion()
{
    JSONValue redubMeta = getRedubMeta();
    if(redubMeta.hasErrorOccurred)
        return null;
    JSONValue* ver = "version" in redubMeta;
    if(!ver)
        return null;
    return ver.str;
}