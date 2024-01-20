module building.cache;
public import std.bigint;
public import compiler_identification;
public import core.int128;
import package_searching.dub;
import buildapi;
static import std.file;
import std.path;
import std.json;
import std.encoding;


enum cacheFolder = ".redub";
enum cacheFile = "redub_cache.json";

struct CompilationCache
{
    ///Key for finding the cache
    string requirementCache;
    ///First member of the cache array
    string dateCache;
    ///Second member of the cache array
    string contentCache;

    static CompilationCache get(string rootHash, const BuildRequirements req, Compiler compiler)
    {
        import std.exception;
        JSONValue c = *getCache();
        string reqCache = hashFrom(req, compiler);
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

    bool isUpToDate(const BuildRequirements req, Compiler compiler, ref BigInt[string] cachedDirTime) const
    {
        return requirementCache == hashFrom(req, compiler) &&
            dateCache == hashFromDates(req.cfg, cachedDirTime);
    }
}

/** 
 * Params:
 *   root = 
 * Returns: Current cache status from root, without modifying it
 */
CompilationCache[] cacheStatusForProject(ProjectNode root, Compiler compiler)
{
    CompilationCache[] cache = new CompilationCache[](root.collapse.length);
    string rootCache = hashFrom(root.requirements, compiler);
    int i = 0;
    foreach(const ProjectNode node; root.collapse)
        cache[i++] = CompilationCache.get(rootCache, node.requirements, compiler);
    return cache;
}

/**
*   Invalidate caches that aren't up to date
*/
void invalidateCaches(ProjectNode root, Compiler compiler)
{
    import std.array;
    const CompilationCache[] cacheStatus = cacheStatusForProject(root, compiler);
    ptrdiff_t i = cacheStatus.length;
    BigInt[string] cachedDirTime;

    foreach_reverse(ProjectNode n; root.collapse.array)
    {
        if(!n.isUpToDate) continue;
        if(!cacheStatus[--i].isUpToDate(n.requirements, compiler, cachedDirTime))
            n.invalidateCache();
    }
}

string hashFunction(const char[] input)
{
    import std.digest.md:md5Of, toHexString;
    return md5Of(input).toHexString.idup;
}

string hashFrom(const BuildRequirements req, Compiler compiler)
{
    import std.conv:to;
    import std.array:join;
    string[] inputHash = [compiler.versionString];
    inputHash~= req.targetConfiguration;
    inputHash~= req.version_;
    static foreach(i, v; BuildConfiguration.tupleof)
    {
        static if(is(typeof(v) == string)) inputHash~= req.cfg.tupleof[i];
        else inputHash~= req.cfg.tupleof[i].to!string;
    }
    return hashFunction(inputHash.join);
}

string hashFromPathDates(ref BigInt[string] cachedDirTime, scope const(string[]) entryPaths...)
{
    import std.conv:to;
    import std.file;
    BigInt bInt;
    foreach(path; entryPaths)
    {
        if(!std.file.exists(path)) continue;
        if(path in cachedDirTime) bInt+= cachedDirTime[path];
        else if(std.file.isDir(path))
        {
            BigInt dirTime;
            foreach(DirEntry e; dirEntries(path, SpanMode.depth))
            {
                // import std.string;
                // if(e.name.endsWith(".o")) throw new Error("Found .o at "~e.name);
                dirTime+= e.timeLastModified.stdTime;
            }
            bInt+= dirTime;
            cachedDirTime[path] = dirTime;
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
    // return hashFunction(output[0..length]); No need to use hash, use just the number.
    return (output[0..length]).dup;
}

string hashFromDates(const BuildConfiguration cfg, ref BigInt[string] cachedDirTime)
{
    import std.system;
    import command_generators.commons;
    string[] sourceFiles = new string[](cfg.sourceFiles.length);
    string[] libs = new string[](cfg.libraries.length);

    foreach(i, s; cfg.sourceFiles)
        sourceFiles[i] = buildNormalizedPath(cfg.workingDir, s);
    foreach(i, s; cfg.libraries)
        libs[i] = buildNormalizedPath(cfg.workingDir, s);

    return hashFromPathDates(
        cachedDirTime,
        cfg.importDirectories~
        cfg.sourcePaths ~
        cfg.stringImportPaths~
        sourceFiles~
        libs ~ 
        buildNormalizedPath(cfg.outputDirectory, getOutputName(cfg.targetType, cfg.name, os))
        // cfg.libraryPaths~ ///This is causing problems when using subPackages without output path, they may clash after
        // the compilation is finished. Solving this would require hash calculation after linking
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