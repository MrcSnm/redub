module redub.building.cache;
public import redub.compiler_identification;
public import redub.libs.adv_diff.files;
public import std.int128;
import redub.package_searching.dub;
import redub.buildapi;
static import std.file;
import std.path;
import std.json;
import redub.command_generators.commons;


enum cacheFolder = ".redub";
enum cacheFile = "redub_cache.json";

Int128 toInt128(string input)
{
    if(input.length == 0) throw new Exception("Tried to send an empty string to convert.");
    Int128 ret;
    bool isNegative;
    if(input[0] == '-') 
    {
        input = input[1..$];
        isNegative = true;
    }
    foreach(c; input)
    {
        if(c < '0' || c > '9') throw new Exception("Input string "~input~" is not a number.");
        int digit = c - '0';
        Int128 newResult = ret * 10 + digit;
        if(newResult < ret)
            throw new Exception("Input string "~input~" is too large for an Int128");
        ret = newResult;
    }
    return isNegative ? ret * -1 : ret;
}



struct CompilationCache
{
    ///Key for finding the cache
    string requirementCache;
    private AdvCacheFormula formula;

    const(AdvCacheFormula) getFormula() const
    {
        return formula;
    }

    static CompilationCache make(string requirementCache, const BuildRequirements req, OS target, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
    {
        return CompilationCache(requirementCache, generateCache(req, target, existing, preprocessed));
    }
    

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
        return CompilationCache(reqCache, AdvCacheFormula.deserialize(*targetCache));
    }

    /** 
     * 
     * Params:
     *   req = Requirement to generate hash 
     *   compiler = Compiler to generate hash
     *   target = Target to generate hash
     *   cache = Optional argument which stores precalculated results
     * Returns: isUpToDate
     */
    bool isUpToDate(const BuildRequirements req, Compiler compiler, OS target, AdvCacheFormula* preprocessed) const
    {
        AdvCacheFormula otherFormula = generateCache(req, target, &formula, preprocessed);
        size_t diffCount;
        string[64] diffs = formula.diffStatus(otherFormula, diffCount);
        return requirementCache == hashFrom(req, compiler) && diffCount == 0;
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
 * This function mutates the ProjectNode|s, isUpToDate property. It checks on the entire tree
 * if it is not up to date, when it is not, it invalidates itself and all their parents.
 * It requires the existing cache status for the project and then, starts comparing, with its current
 * situation
 * Params:
 *   root = Project root for traversing
 *   compiler = Which compiler is being used to check the caches
 */
void invalidateCaches(ProjectNode root, Compiler compiler, OS target)
{
    const CompilationCache[] cacheStatus = cacheStatusForProject(root, compiler);
    ptrdiff_t i = cacheStatus.length;
    AdvCacheFormula preprocessed;

    foreach_reverse(ProjectNode n; root.collapse)
    {
        --i;
        if(!n.isUpToDate) continue;
        if(!cacheStatus[i].isUpToDate(n.requirements, compiler, target, &preprocessed))
        {
            import redub.logging;
            info("Project ", n.name," requires rebuild.");
            n.invalidateCache();
        }
    }
}

ubyte[] hashFunction(const char[] input, ref ubyte[] output)
{
    import xxhash3;
    XXH_64 xxh;
    xxh.put(cast(const ubyte[])input);

    auto hash = xxh.finish;
    if(output.length < hash.length)
        output.length = hash.length;
    output[] = hash[];
    return output;
}

string hashFrom(const BuildRequirements req, Compiler compiler)
{
    import std.conv:to;
    import std.array:join;
    import std.digest;
    string[] inputHash = [compiler.versionString, req.targetConfiguration, req.version_];
    static foreach(i, v; BuildConfiguration.tupleof)
    {
        static if(is(typeof(v) == string)) inputHash~= req.cfg.tupleof[i];
        else inputHash~= req.cfg.tupleof[i].to!string;
    }
    ubyte[] output;
    return hashFunction(inputHash.join, output).toHexString.idup;
}


AdvCacheFormula generateCache(const BuildRequirements req, OS target, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
{
    import std.algorithm.iteration, std.array;
    static contentHasher = (ubyte[] content, ref ubyte[] output)
    {
        return hashFunction(cast(string)content, output);
    };
    string[] libs = req.extra.librariesFullPath.map!((libPath) => getLibraryPath(libPath, req.cfg.outputDirectory, target)).array;

    return AdvCacheFormula.make(
        contentHasher, 
        //DO NOT use sourcePaths since importPaths is always custom + sourcePaths
        joinFlattened(req.cfg.importDirectories, req.cfg.stringImportPaths), ///This is causing problems when using subPackages without output path, they may clash after
        // the compilation is finished. Solving this would require hash calculation after linking
        joinFlattened(req.cfg.sourceFiles, libs),
        existing,
        preprocessed
    );
}


string[] updateCache(string rootCache, const CompilationCache cache, bool writeToDisk = false)
{
    JSONValue* v = getCache();
    if(!(rootCache in *v)) (*v)[rootCache] = JSONValue.emptyObject;
    JSONValue serializeTarget;
    cache.formula.serialize(serializeTarget);
    (*v)[rootCache][cache.requirementCache] = serializeTarget;

    if(writeToDisk)
        updateCacheOnDisk();
    return null;
}

void updateCacheOnDisk()
{
    std.file.write(getCacheFilePath, getCache().toString(JSONOptions.doNotEscapeSlashes));
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