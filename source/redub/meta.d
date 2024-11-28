/**
 * This module provides a way for accessing meta information on redub execution.
 * Things such as compiler information and redub version are saved here.
 *
 */
module redub.meta;
public import hipjson;

private string getRedubMetaFileName()
{
    import redub.misc.path;
    import redub.api;
    static string redubCompilersFile;
    if(redubCompilersFile == null)
        redubCompilersFile = buildNormalizedPath(getDubWorkspacePath, "redub_meta.json");
    return redubCompilersFile;
}


void saveRedubMeta(string content)
{
    import std.file;
    import std.path;
    string dir = dirName(getRedubMetaFileName);
    if(!std.file.exists(dir))
        mkdirRecurse(dir);
    std.file.write(getRedubMetaFileName, content);
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
            meta = parseJSON(cast(string)std.file.read(getRedubMetaFileName));
            JSONValue* ver = "version" in meta;
            if(ver == null || ver.str != RedubVersionOnly)
                return JSONValue.emptyObject;
        }
        else
            return JSONValue.emptyObject;
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