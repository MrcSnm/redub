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

    const(AdvCacheFormula) getFormula() const
    {
        return formula;
    }

    static CompilationCache make(string requirementCache, string mainPackHash, const BuildRequirements req, CompilingSession s,
        const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
    {
        return CompilationCache(requirementCache, mainPackHash, getCompilationCacheFormula(req, mainPackHash, s, existing, preprocessed), getCopyCacheFormula(mainPackHash, req, s, existing, preprocessed));
    }

    /**
     *
     * Params:
     *   rootHash = The root BuildRequirements hash
     *   req = The BuildRequirements in which it will calculate the hash to find its cache
     *   s = CompilingSession for getting the hash
     * Returns: The compilation cache found inside .redub folder.
     */
    static CompilationCache get(string rootHash, const BuildRequirements req, CompilingSession s)
    {
        import std.exception;
        JSONValue c = *getCache(rootHash);
        string reqCache = hashFrom(req, s, false);
        if (c.type != JSONType.object || c.hasErrorOccurred)
        {
            import redub.logging;
            error("Cache is corrupted, regenerating...");
            return CompilationCache(reqCache, rootHash);
        }
        if (c == JSONValue.emptyObject)
            return CompilationCache(reqCache, rootHash);
        JSONValue* targetCache = reqCache in c;
        if (!targetCache || targetCache.type != JSONType.array)
            return CompilationCache(reqCache, rootHash);

        return CompilationCache(reqCache, rootHash, AdvCacheFormula.deserialize(targetCache.array[0]), AdvCacheFormula.deserialize(targetCache.array[1]));
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
        if(requirementCache != hashFrom(req, s, false))
            return false;
        AdvCacheFormula otherFormula = getCompilationCacheFormula(req, rootHash, s, &formula, preprocessed);
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
        AdvCacheFormula otherFormula = getCopyCacheFormula(rootHash, req, s, &formula, preprocessed);
        diffs = copyFormula.diffStatus(otherFormula, diffCount);
        return diffCount != 0;
    }
}

/** 
 * Params:
 *   root = 
 * Returns: Current cache status from root, without modifying it
 */
CompilationCache[] cacheStatusForProject(ProjectNode root, CompilingSession s)
{
    CompilationCache[] cache = new CompilationCache[](root.collapse.length);
    string rootCache = hashFrom(root.requirements, s);
    int i = 0;
    foreach (const ProjectNode node; root.collapse)
        cache[i++] = CompilationCache.get(rootCache, node.requirements, s);
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
 */
void invalidateCaches(ProjectNode root, CompilingSession s)
{
    CompilationCache[] cacheStatus = cacheStatusForProject(root, s);
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
            n.setFilesDirty(dirtyFiles[0..dirtyCount]);
            n.invalidateCache();
            continue;
        }
        if(cacheStatus[i].needsNewCopy(n.requirements, s, &preprocessed, dirtyFiles, dirtyCount))
            n.setCopyEnough(dirtyFiles[0..dirtyCount]);
    }
}

ubyte[] hashFunction(const char[] input, ref ubyte[8] output)
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
string hashFrom(const BuildConfiguration cfg, CompilingSession session, bool isRoot = true)
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

string hashFrom(const BuildRequirements req, CompilingSession s, bool isRoot = true)
{
    return hashFrom(req.cfg, s, isRoot);
}

/** 
 * This function will generate a formula based on its inputs. Every dependency will check for its output artifact. This is the most reliable way
 * to build across multiple compilers and configurations without having a separate cache.
 * Params:
 *   req = The requirements will load adv_diff with the paths to watch for changes
 *   target = Target is important for knowing how the library is called
 *   existing = An existing formula reference as input is important for getting content hash if they aren't up to date
 *   preprocessed = This will store calculations on an AdvCacheFormula, so, subsequent checks are much faster
 * Returns: A new AdvCacheFormula
 */
AdvCacheFormula getCompilationCacheFormula(const BuildRequirements req, string mainPackHash, CompilingSession s, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
{
    import std.algorithm.iteration, std.array, std.path;

    static contentHasher = (ubyte[] content, ref ubyte[8] output) {
        return hashFunction(cast(string) content, output);
    };

    string cacheDir = getCacheOutputDir(mainPackHash, req.cfg, s);

    string[] dirs = [cacheDir];
    if(s.compiler.compiler == AcceptedCompiler.ldc2)
    {
        ///LDC object output directory
        dirs~= cacheDir~ "_obj";
    }
    if(req.cfg.outputsDeps)
        dirs~= getObjectDir(cacheDir);



    return AdvCacheFormula.make(
        contentHasher,//DO NOT use sourcePaths since importPaths is always custom + sourcePaths
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
    if(mainPackHash.length == 0)
        throw new Exception("No hash.");
    return buildNormalizedPath(getCacheFolder, mainPackHash, hashFrom(req, s));
}

string getCacheOutputDir(string mainPackHash, const BuildConfiguration cfg, CompilingSession s)
{
    if(mainPackHash.length == 0)
        throw new Exception("No hash.");
    return buildNormalizedPath(getCacheFolder, mainPackHash, hashFrom(cfg, s));
}


/**
 * Stores the output artifact directory. Used for saving artifacts elsewhere and simply copying if they are already up to date.
 * Params:
 *   mainPackHash = The root cache on which this formula was built with. It is used for finding the output directory.
 *   req = The requirements will load adv_diff with the paths to watch for changes
 *   s = The session in which the compilation is happening
 *   existing = An existing formula reference as input is important for getting content hash if they aren't up to date
 *   preprocessed = This will store calculations on an AdvCacheFormula, so, subsequent checks are much faster
 * Returns: A new AdvCacheFormula
 */
AdvCacheFormula getCopyCacheFormula(string mainPackHash, const BuildRequirements req, CompilingSession s, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
{
    import std.algorithm.iteration, std.array, std.path;

    static contentHasher = (ubyte[] content, ref ubyte[8] output) {
        return hashFunction(cast(string) content, output);
    };

    string[] extraRequirements = [];
    if (req.cfg.targetType.isLinkedSeparately)
        extraRequirements = req.extra.librariesFullPath.map!(
            (libPath) => getLibraryPath(libPath, req.cfg.outputDirectory, os)).array;

    return AdvCacheFormula.make(
        contentHasher,//DO NOT use sourcePaths since importPaths is always custom + sourcePaths
        [DirectoriesWithFilter([], false)],
        joiner([getExpectedArtifacts(req, s.os, s.isa), extraRequirements]),
        existing,
        preprocessed,
        true
    );
}

string[] updateCache(string rootCache, const CompilationCache cache, bool writeToDisk = false)
{
    JSONValue* v = getCache(rootCache);
    JSONValue compileFormula;
    JSONValue copyFormula;
    cache.formula.serialize(compileFormula);
    cache.copyFormula.serialize(copyFormula);

    (*v)[cache.requirementCache] = JSONValue([compileFormula, copyFormula]);

    if (writeToDisk)
        updateCacheOnDisk(rootCache);
    return null;
}

void updateCacheOnDisk(string rootCache)
{
    static import std.file;
    std.file.write(getCacheFilePath(rootCache), getCache(rootCache).toString());
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
        std.file.write(file, "{}");

    if (!(rootCache in cacheJson))
    {
        try
            cacheJson[rootCache] = parseJSON(cast(string)std.file.read(file));
        catch (Exception e)
        {
            std.file.write(file, "{}");
            cacheJson[rootCache] = JSONValue.emptyObject;
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
    static string cacheFolder;
    if (!cacheFolder)
        cacheFolder = buildNormalizedPath(getDubWorkspacePath(), CACHE_FOLDER_NAME);
    return cacheFolder;
}

string getCacheFilePath(string rootCache)
{
    return buildNormalizedPath(getCacheFolder, rootCache ~ ".json");
}

