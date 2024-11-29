module redub.building.cache;
public import redub.compiler_identification;
public import redub.libs.adv_diff.files;
public import std.int128;
import redub.api;
import redub.buildapi;
import std.path;
import hipjson;

// import std.json;
import redub.command_generators.commons;

enum CACHE_FOLDER_NAME = ".redub";
enum BIN_CACHE_FOLDER = "bin";

Int128 toInt128(string input)
{
    if (input.length == 0)
        throw new Exception("Tried to send an empty string to convert.");
    Int128 ret;
    bool isNegative;
    if (input[0] == '-')
    {
        input = input[1 .. $];
        isNegative = true;
    }
    foreach (c; input)
    {
        if (c < '0' || c > '9')
            throw new Exception("Input string " ~ input ~ " is not a number.");
        int digit = c - '0';
        Int128 newResult = ret * 10 + digit;
        if (newResult < ret)
            throw new Exception("Input string " ~ input ~ " is too large for an Int128");
        ret = newResult;
    }
    return isNegative ? ret * -1 : ret;
}

struct CompilationCache
{
    ///Key for finding the cache
    string requirementCache;
    string rootHash;
    private AdvCacheFormula formula;
    private AdvCacheFormula copyFormula;
    private AdvCacheFormula sharedFormula;

    const(AdvCacheFormula) getSharedFormula() const
    {
        return sharedFormula;
    }

    static CompilationCache make(string requirementCache,
        string mainPackHash,
        const BuildRequirements req,
        CompilingSession s,
        const(AdvCacheFormula)* existing,
        AdvCacheFormula* preprocessed
        )
    {
        return CompilationCache(requirementCache, mainPackHash, getCompilationCacheFormula(req, mainPackHash, s, existing, preprocessed), getCopyCacheFormula(mainPackHash, req, s, existing, preprocessed));
    }

    /**
     *
     * Params:
     *   rootHash = The root BuildRequirements hash
     *   req = The BuildRequirements in which it will calculate the hash to find its cache
     *   s = CompilingSession for getting the hash
     *   sharedFormula = Holds the formula for the entire compilation cache.
     * Returns: The compilation cache found inside .redub folder.
     */
    static CompilationCache get(string rootHash, const BuildRequirements req, CompilingSession s, ref AdvCacheFormula sharedFormula)
    {
        import std.exception;
        JSONValue c = *getCache(rootHash);
        string reqCache = req.extra.isRoot ? rootHash : hashFrom(req.cfg, s, false);
        if (c.type != JSONType.array || c.hasErrorOccurred || c.array.length != 2)
        {
            import redub.logging;
            error("Cache is corrupted, regenerating...");
            return CompilationCache(reqCache, rootHash);
        }
        if(c.array[0].array.length == 3)
        {
            if(sharedFormula.isEmptyFormula)
                sharedFormula = AdvCacheFormula.deserialize(c.array[0]);
        }
        else 
            return CompilationCache(reqCache, rootHash, AdvCacheFormula.init, AdvCacheFormula.init, sharedFormula);
        JSONValue* targetCache = reqCache in c.array[1];
        if (!targetCache || targetCache.type != JSONType.array)
            return CompilationCache(reqCache, rootHash, AdvCacheFormula.init, AdvCacheFormula.init, sharedFormula);

        return CompilationCache(reqCache, rootHash, AdvCacheFormula.deserializeSimple(targetCache.array[0], sharedFormula), AdvCacheFormula.deserializeSimple(targetCache.array[1], sharedFormula), sharedFormula);
    }

    /** 
     * 
     * Params:
     *   req = Requirement to generate hash 
     *   compiler = Compiler to generate hash
     *   target = Target to generate hash
     *   cache = Optional argument which stores precalculated results
     * Returns: isCompilationUpToDate
     */
    bool isCompilationUpToDate(const BuildRequirements req, CompilingSession s, AdvCacheFormula* preprocessed, out string[64] diffs, out size_t diffCount) const
    {
        if(requirementCache != hashFrom(req, s))
            return false;
        AdvCacheFormula otherFormula = getCompilationCacheFormula(req, rootHash, s, &sharedFormula, preprocessed);
        diffs = formula.diffStatus(otherFormula, diffCount);
        return diffCount == 0;
    }

    /**
     *
     * Params:
     *   req = Requirement to generate hash
     *   compiler = Compiler to generate hash
     *   target = Target to generate hash
     *   cache = Optional argument which stores precalculated results
     * Returns: isCompilationUpToDate
     */
    bool needsNewCopy(const BuildRequirements req, CompilingSession s, AdvCacheFormula* preprocessed, out string[64] diffs, out size_t diffCount) const
    {
        if(copyFormula.isEmptyFormula)
            return false;
        AdvCacheFormula otherFormula = getCopyCacheFormula(rootHash, req, s, &sharedFormula, preprocessed);
        diffs = copyFormula.diffStatus(otherFormula, diffCount);
        return diffCount != 0;
    }
}

/** 
 * Params:
 *   root = 
 * Returns: Current cache status from root, without modifying it
 */
CompilationCache[] cacheStatusForProject(ProjectNode root, CompilingSession s, out AdvCacheFormula sharedFormula)
{
    CompilationCache[] cache = new CompilationCache[](root.collapse.length);
    string rootCache = hashFrom(root.requirements, s);
    int i = 0;
    foreach (const ProjectNode node; root.collapse)
        cache[i++] = CompilationCache.get(rootCache, node.requirements, s, sharedFormula);
    return cache;
}

/** 
 * This function mutates the ProjectNode|s, isUpToDate property. It checks on the entire tree
 * if it is not up to date, when it is not, it invalidates itself and all their parents.
 * It requires the existing cache status for the project and then, starts comparing, with its current
 * situation
 * Params:
 *   root = Project root for traversing
 *   s = The session on which the cache should be invalidated
 *   sharedFormula = Used later for not needing to recalculate hash from files which didn't change.
 */
void invalidateCaches(ProjectNode root, CompilingSession s, out AdvCacheFormula sharedFormula)
{
    CompilationCache[] cacheStatus = cacheStatusForProject(root, s, sharedFormula);
    import std.algorithm.comparison: min;
    ptrdiff_t i = cacheStatus.length;
    AdvCacheFormula preprocessed;

    string[64] dirtyFiles;
    size_t dirtyCount;
    import redub.logging;

    foreach_reverse (ProjectNode n; root.collapse)
    {
        --i;
        if (!n.isUpToDate)
            continue;
        if (!cacheStatus[i].isCompilationUpToDate(n.requirements, s, &preprocessed, dirtyFiles, dirtyCount))
        {
            n.setFilesDirty(dirtyFiles[0..min(dirtyCount, 64)]);
            n.invalidateCache();
            continue;
        }
        if(cacheStatus[i].needsNewCopy(n.requirements, s, &preprocessed, dirtyFiles, dirtyCount))
            n.setCopyEnough(dirtyFiles[0..min(dirtyCount, 64)]);
    }
}

ubyte[] hashFunction(const ubyte[] input, ref ubyte[8] output)
{
    import xxhash3;

    XXH_64 xxh;
    xxh.put(cast(const ubyte[]) input);

    auto hash = xxh.finish;
    output[] = hash[];
    return output;
}

bool attrIncludesUDA(LookType, Attribs...)()
{
    bool hasFound = false;
    static foreach (value; Attribs)
        static if (is(typeof(value) == LookType) || is(LookType == value))
            hasFound = true;
    return hasFound;
}

/**
 *
 * Params:
 *   req = The requirements to generate
 *   compiler = Using compiler
 *   os = The target os is important for the cache so it doesn't build the same files, same configuration but different OS
 *   isa = ISA is important as one may build other ISA for the same OS
 *   isRoot = This one may include less information. This allows more cache to be reused while keeping the smaller pieces of cache more restrained.
 * Returns: The hash.
 */
string hashFrom(const BuildConfiguration cfg, CompilingSession session, bool isRoot)
{
    import std.conv : to;
    import xxhash3;

    XXH_64 xxh;
    xxh.start();
    xxh.put(cast(ubyte[]) session.compiler.versionString);
    xxh.put(cast(ubyte)session.os);
    xxh.put(cast(ubyte)session.isa);
    // xxh.put(cast(ubyte[])req.targetConfiguration);
    // xxh.put(cast(ubyte[])req.version_);

    static foreach (i, v; BuildConfiguration.tupleof)
    {
        {
            bool isExcluded = attrIncludesUDA!(cacheExclude, __traits(getAttributes, v));
            bool isExcludedFromRoot = attrIncludesUDA!(excludeRoot, __traits(getAttributes, v));
            if (!(isExcluded || (isRoot && isExcludedFromRoot)))
            {
                static if (is(typeof(v) == string))
                    xxh.put(cast(ubyte[]) cfg.tupleof[i]);
                else static if (is(typeof(v) == string[]))
                {
                    foreach (v; cfg.tupleof[i])
                        xxh.put(cast(ubyte[]) v);
                }
                else
                    xxh.put(cast(ubyte[]) cfg.tupleof[i].to!string);
            }
        }
    }

    return xxh.finish().toHexString.idup;
}

string hashFrom(const BuildRequirements req, CompilingSession s)
{
    return hashFrom(req.cfg, s, req.extra.isRoot);
}

/** 
 * This function will generate a formula based on its inputs. Every dependency will check for its output artifact. This is the most reliable way
 * to build across multiple compilers and configurations without having a separate cache.
 * Params:
 *   req = The requirements will load adv_diff with the paths to watch for changes
 *   target = Target is important for knowing how the library is called
 *   existing = Reuses the hash of the existing calculated if the file hasn't changed
 *   preprocessed = This will store calculations on an AdvCacheFormula, so, subsequent checks are much faster
 *   isRoot = Used to calculate some of the output directories.
 * Returns: A new AdvCacheFormula
 */
AdvCacheFormula getCompilationCacheFormula(const BuildRequirements req, string mainPackHash, CompilingSession s, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
{
    import std.algorithm.iteration, std.array, std.path;

    string cacheDir = getCacheOutputDir(mainPackHash, req, s);

    string[] dirs = [cacheDir];
    if(s.compiler.compiler == AcceptedCompiler.ldc2)
    {
        ///LDC object output directory
        dirs~= cacheDir~ "_obj";
    }
    if(req.cfg.outputsDeps)
        dirs~= getObjectDir(cacheDir);



    return AdvCacheFormula.make(
        &hashFunction,//DO NOT use sourcePaths since importPaths is always custom + sourcePaths
        [
            DirectoriesWithFilter(req.cfg.importDirectories, true),
            DirectoriesWithFilter(req.cfg.stringImportPaths, false),
            DirectoriesWithFilter(dirs, false, true)
        ], ///This is causing problems when using subPackages without output path, they may clash after
        // the compilation is finished. Solving this would require hash calculation after linking
        joiner([
            req.cfg.sourceFiles,
            req.cfg.filesToCopy, req.cfg.extraDependencyFiles
        ]),
        existing,
        preprocessed
    );
}

string getCacheOutputDir(string mainPackHash, const BuildRequirements req, CompilingSession s)
{
    import redub.misc.path;
    if(mainPackHash.length == 0)
        throw new Exception("No hash.");
    return redub.misc.path.buildNormalizedPath(getCacheFolder, mainPackHash, hashFrom(req, s));
}

string getCacheOutputDir(string mainPackHash, const BuildConfiguration cfg, CompilingSession s, bool isRoot)
{
    import redub.misc.path;
    if(mainPackHash.length == 0)
        throw new Exception("No hash.");
    return redub.misc.path.buildNormalizedPath(getCacheFolder, mainPackHash, hashFrom(cfg, s, isRoot));
}


/**
 * Stores the output artifact directory. Used for saving artifacts elsewhere and simply copying if they are already up to date.
 * Params:
 *   mainPackHash = The root cache on which this formula was built with. It is used for finding the output directory.
 *   req = The requirements will load adv_diff with the paths to watch for changes
 *   s = The session in which the compilation is happening
 *   existing = Reuses the hash of the existing calculated if the file hasn't changed
 *   preprocessed = This will store calculations on an AdvCacheFormula, so, subsequent checks are much faster
 * Returns: A new AdvCacheFormula
 */
AdvCacheFormula getCopyCacheFormula(string mainPackHash, const BuildRequirements req, CompilingSession s, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
{
    import std.algorithm.iteration, std.array, std.path;


    string[] extraRequirements = [];
    if (req.cfg.targetType.isLinkedSeparately)
        extraRequirements = req.extra.librariesFullPath.map!(
            (libPath) => getLibraryPath(libPath, req.cfg.outputDirectory, os)).array;

    return AdvCacheFormula.make(
        &hashFunction,//DO NOT use sourcePaths since importPaths is always custom + sourcePaths
        [DirectoriesWithFilter([], false)],
        joiner([getExpectedArtifacts(req, s.os, s.isa), extraRequirements]),
        existing,
        preprocessed,
        true
    );
}

string[] updateCache(string rootCache, const CompilationCache cache)
{
    JSONValue* v = getCache(rootCache);
    JSONValue compileFormula;
    JSONValue copyFormula;
    cache.formula.serializeSimple(compileFormula);
    cache.copyFormula.serializeSimple(copyFormula);


    v.array[1][cache.requirementCache] = JSONValue([compileFormula, copyFormula]);
    return null;
}

/**
 *
 * Params:
 *   rootCache = Root hash requirement to save
 *   fullCache = The full AdvCacheFormula that were shared during execution. Will be dumped and saved as a simple
 */
void updateCacheOnDisk(string rootCache, AdvCacheFormula* fullCache, const(AdvCacheFormula)* sharedFormula)
{
    static import std.file;
    JSONValue fullCacheJson;
    JSONValue* cache = getCache(rootCache);
    assert(fullCache !is null, "Full cache can't be null");
    if(fullCache.isEmptyFormula)
        fullCacheJson = cache.array[0];
    else
    {
        ///Merge with the fullCache if they are different
        ///This is also a promise that it won't modify
        foreach(string name, const AdvDirectory d; sharedFormula.directories)
        {
            if(!(name in fullCache.directories))
                fullCache.directories[name] = cast()d;
        }
        foreach(string name, const AdvFile f; sharedFormula.files)
        {
            if(!(name in fullCache.files))
                fullCache.files[name] = cast()f;
        }

        //Full cache doesn't need to have a hash calculation because it will never be used.
        // fullCache.recalculateHash(&hashFunction);
        fullCache.serialize(fullCacheJson);
    }


    std.file.write(getCacheFilePath(rootCache),
        JSONValue([fullCacheJson, cache.array[1]]).toString!true
    );
}


private __gshared JSONValue[string] cacheJson;
private JSONValue* getCache(string rootCache)
{
    static import std.file;
    string folder = getCacheFolder;
    import redub.meta;
    import redub.logging;

    if(cacheJson == cacheJson.init)
    {
        ///Deletes the cache folder if the version is different from the current one.
        if(getExistingRedubVersion() != RedubVersionOnly && std.file.exists(folder))
        {
            info("Different redub version. Cleaning cache folder.");
            std.file.rmdirRecurse(folder);
        }
    }
    if (!std.file.exists(folder))
        std.file.mkdirRecurse(folder);

    string file = getCacheFilePath(rootCache);
    if (!std.file.exists(file))
        std.file.write(file, "[[], {}]");

    if (!(rootCache in cacheJson))
    {
        try
            cacheJson[rootCache] = parseJSON(cast(string)std.file.read(file));
        catch (Exception e)
        {
            std.file.write(file, "[[], {}]");
            cacheJson[rootCache] = JSONValue([JSONValue.emptyArray, JSONValue.emptyObject]);
        }
    }

    return &cacheJson[rootCache];
}

/**
*   Clears memory cache. This will allow to redub correctly identify files that changed in subsequent runs.
*/
void clearJsonCompilationInfoCache()
{
    cacheJson = null;
}

string getCacheFolder()
{
    import redub.misc.path;
    static string cacheFolder;
    if (!cacheFolder)
        cacheFolder = redub.misc.path.buildNormalizedPath(getDubWorkspacePath(), CACHE_FOLDER_NAME);
    return cacheFolder;
}

string getCacheFilePath(string rootCache)
{
    import redub.misc.path;
    return redub.misc.path.buildNormalizedPath(getCacheFolder, rootCache ~ ".json");
}

