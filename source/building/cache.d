module building.cache;
import package_searching.dub;
import buildapi;
static import std.file;
import std.stdio;
import std.path;
import std.json;


enum cacheFolder = ".dubv2";
enum cacheFile = ".dubv2_cache.json";

struct CompilationCache
{
    string requirementCache;
    string dateCache;
    string contentCache;

    static CompilationCache get(string rootCache, const BuildRequirements req)
    {
        import std.exception;
        JSONValue c = *getCache();
        string reqCache = hashFrom(req);
        if(!(rootCache in c))
            return CompilationCache(reqCache);

        enforce(c[rootCache].type == JSONType.array, "Cache is corrupted, delete it.");
        JSONValue[] caches = c[rootCache].array;
        return CompilationCache(reqCache, caches[0].str, caches[1].str);
    }
}


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

string hashFunction(string input)
{
    import std.conv:to;
    import std.digest.md:md5Of;
    return md5Of(input).to!string;
}

string hashFrom(const BuildRequirements req)
{
    import std.conv:to;
    import std.array:join;
    string[] inputHash;
    inputHash~= req.targetConfiguration;
    inputHash~= req.version_;
    static foreach(i, v; BuildConfiguration.tupleof)
    {
        static if(is(typeof(v) == string)) inputHash~= req.cfg.tupleof[i];
        else inputHash~= req.cfg.tupleof[i].to!string;
    }
    return hashFunction(inputHash.join);
}

string hashFromPathDates(scope const string[] entryPaths...)
{
    import std.conv:to;
    import std.digest.md;
    import std.file;
    import std.bigint;
    BigInt bInt;
    foreach(path; entryPaths)
        foreach(DirEntry e; dirEntries(path, SpanMode.depth))
            bInt+= e.timeLastModified.stdTime;
    
    char[] output;
    bInt.toString(output, "x"); //Hexadecimal to save space?
    return md5Of(output).to!string;
}

string hashFromPathContents(scope const string[] entryPaths...)
{
    import std.conv:to;
    import std.digest.md;
    import std.file;
    scope string[] contentsToInclude;
    foreach(path; entryPaths)
        foreach(DirEntry e; dirEntries(path, SpanMode.depth))
            contentsToInclude~= cast(string)std.file.read(e.name);
    
    return md5Of(contentsToInclude).to!string;
}

string[] generateBaseCacheForProject(immutable ProjectNode node, bool writeToDisk = false)
{
    immutable ProjectNode[] nodes = node.collapse;
    string mainProjectHash = hashFrom(nodes[0].requirements); //Root is always 0
    string[] dependenciesHash;
    foreach(dep; nodes[1..$])
        dependenciesHash~= hashFrom(dep.requirements);
    if(writeToDisk)
        std.file.write(getCacheFilePath, getCache().toString());
}

private string getCacheFolder()
{
    return buildNormalizedPath(getDubWorkspacePath(), cacheFolder);
}

private string getCacheFilePath()
{
    return buildNormalizedPath(getCacheFolder, cacheFile);
}

private JSONValue* getCache()
{
    static JSONValue cacheJson;
    string folder = getCacheFolder;
    if(!std.file.exists(folder)) std.file.mkdirRecurse(folder);
    string file = getCacheFilePath;
    if(!std.file.exists(file)) std.file.write(file, "{}");
    if(cacheJson == JSONValue.init) cacheJson = parseJSON(std.file.readText(file));
    return &cacheJson;
}

