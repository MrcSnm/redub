module building.cache;
static import std.file;
import std.stdio;
import std.path;


enum cacheFolder = ".dubv2";
enum cacheFile = ".dubv2_cache";

nothrow bool isUpToDate(string workspace)
{

    string cache = buildPath(workspace, cacheFolder, cacheFile);
    if(!std.file.exists(cache))
        return false;

    return false;
}

/**
*  Returns if operation was succesful
*/
nothrow bool createCache(string workspace)
{
    return false;
}

private nothrow long getTimeLastModified(string file)
{
    if(!std.file.exists(file))
        return -1;
    try{return std.file.timeLastModified(file).stdTime;}
    catch(Exception e){return -1;}
}