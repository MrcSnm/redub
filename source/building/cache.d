module building.cache;
import package_searching.dub;
import buildapi;
static import std.file;
import std.stdio;
import std.path;
import std.json;


enum cacheFolder = ".dubv2";
enum cacheFile = "dubv2_cache.json";

struct CompilationCache
{
    ///Key for finding the cache
    string requirementCache;
    ///First member of the cache array
    string dateCache;
    ///Second member of the cache array
    string contentCache;

    static CompilationCache get(string rootHash, const BuildRequirements req)
    {
        import std.exception;
        JSONValue c = *getCache();
        string reqCache = hashFrom(req);
        JSONValue* root = rootHash in c;
        if(!root)
            return CompilationCache(reqCache);
        enforce(root.type == JSONType.object, "Cache is corrupted, delete it.");
        JSONValue* targetCache = reqCache in *root;
        if(!targetCache)
            return CompilationCache(reqCache);
            
        enforce(targetCache.type == JSONType.array, "Cache is corrupted, delete it.");
        JSONValue[] caches = targetCache.array;
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

string hashFunction(const char[] input)
{
    import std.conv:to;
    import std.digest.md:md5Of;
    return input.hashOf.to!string;
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

string hashFromPathDates(scope const(string[]) entryPaths...)
{
    import std.conv:to;
    import std.digest.md;
    import std.file;
    import std.bigint;
    BigInt bInt;
    foreach(path; entryPaths)
    {
        if(std.file.isDir(path))
        {
            foreach(DirEntry e; dirEntries(path, SpanMode.depth))
                bInt+= e.timeLastModified.stdTime;
        }
        else 
            bInt+= std.file.timeLastModified(path).stdTime;
    }
    
    char[2048] output;
    size_t length;
    bInt.toString((scope const(char)[] str)
    {
        length = str.length;
        output[0..length] = str[];
    }, "%x"); //Hexadecimal to save space?
    return hashFunction(output[0..length]);
}

string hashFromDates(immutable BuildConfiguration cfg)
{
    string[] sourceFiles;
    string[] libs;

    foreach(s; cfg.sourceFiles)
        sourceFiles~= buildNormalizedPath(cfg.workingDir, s);
    foreach(s; cfg.libraries)
        libs~= buildNormalizedPath(cfg.workingDir, s);

    return hashFromPathDates(
        cfg.importDirectories~
        cfg.sourcePaths~
        cfg.libraryPaths~
        cfg.stringImportPaths~
        sourceFiles~
        libs
    );
    
}

string hashFromPathContents(scope const string[] entryPaths...)
{
    import std.array;
    import std.conv:to;
    import std.file;
    scope string[] contentsToInclude;
    foreach(path; entryPaths)
        foreach(DirEntry e; dirEntries(path, SpanMode.depth))
            contentsToInclude~= cast(string)std.file.read(e.name);
    
    return hashFunction(contentsToInclude.join);
}

string[] updateCache(string rootCache, CompilationCache cache, bool writeToDisk = false)
{
    JSONValue* v = getCache();
    if(!(rootCache in *v)) (*v)[rootCache] = JSONValue.emptyObject;
    (*v)[rootCache][cache.requirementCache] = JSONValue([cache.dateCache, cache.contentCache]);
    if(writeToDisk)
        std.file.write(getCacheFilePath, getCache().toString());
    return null;
}

private JSONValue* getCache()
{
    static JSONValue cacheJson;
    string folder = getCacheFolder;
    if(!std.file.exists(folder)) std.file.mkdirRecurse(folder);
    string file = getCacheFilePath;
    if(!std.file.exists(file)) std.file.write(file, "{}");
    if(cacheJson == JSONValue.init)
    {
        try cacheJson = parseJSON(std.file.readText(file));
        catch(Exception e)
        {
            std.file.write(file, "{}");
            cacheJson = JSONValue.emptyObject;
        }
    }
    return &cacheJson;
}



private string getCacheFolder()
{
    return buildNormalizedPath(getDubWorkspacePath(), cacheFolder);
}

private string getCacheFilePath()
{
    return buildNormalizedPath(getCacheFolder, cacheFile);
}