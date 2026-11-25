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

    import redub.misc.atomic_write : writeFileAtomic;
    writeFileAtomic(getRedubMetaFileName, content.toString);
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

string getLatestRedubVersion()
{
    import redub.misc.github_tag_check;
    import std.datetime.systime;
    JSONValue meta = getRedubMeta();
    JSONValue* latest = "latestVersion" in meta;
    if(latest)
    {
        long time = latest.array[1].get!long;
        int currHour = Clock.currTime.hour - SysTime(time).hour;
        if(currHour == 0)
            return latest.array[0].str;
    }
    string v = redub.misc.github_tag_check.getLatestRedubVersion();
    JSONValue data = JSONValue([JSONValue(v), JSONValue(Clock.currStdTime)]);
    meta["latestVersion"] = data;
    saveRedubMeta(meta);
    return v;
}

bool shouldShowNewerVersionMessage()
{
    JSONValue meta = getRedubMeta();
    JSONValue* updateCheck = "updateCheck" in meta;
    if(updateCheck)
        return updateCheck.get!bool;
    return true;
}