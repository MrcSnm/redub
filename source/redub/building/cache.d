module redub.building.cache;
public import redub.compiler_identification;
public import redub.libs.adv_diff.files;
public import std.int128;
import redub.api;
import redub.buildapi;
static import std.file;
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

    static CompilationCache make(string requirementCache, string mainPackHash, const BuildRequirements req, OS target, Compiler compiler,
        const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
    {
        return CompilationCache(requirementCache, mainPackHash, getCompilationCacheFormula(req, target, existing, preprocessed), getCopyCacheFormula(mainPackHash, req, compiler, target, existing, preprocessed));
    }

    /**
     *
     * Params:
     *   rootHash = The root BuildRequirements hash
     *   req = The BuildRequirements in which it will calculate the hash to find its cache
     *   compiler = The compiler which the requirement was built with
     * Returns: The compilation cache found inside .redub folder.
     */
    static CompilationCache get(string rootHash, const BuildRequirements req, Compiler compiler)
    {
        import std.exception;
        JSONValue c = *getCache(rootHash);
        string reqCache = hashFrom(req, compiler, false);
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
    bool isCompilationUpToDate(const BuildRequirements req, Compiler compiler, OS target, AdvCacheFormula* preprocessed, out string[64] diffs, out size_t diffCount) const
    {
        if(requirementCache != hashFrom(req, compiler, false))
            return false;
        AdvCacheFormula otherFormula = getCompilationCacheFormula(req, target, &formula, preprocessed);
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
    bool needsNewCopy(const BuildRequirements req, Compiler compiler, OS target, AdvCacheFormula* preprocessed) const
    {
        if(copyFormula.isEmptyFormula)
            return false;
        AdvCacheFormula otherFormula = getCopyCacheFormula(rootHash, req, compiler, target, &formula, preprocessed);
        size_t diffCount;
        string[64] diffs = copyFormula.diffStatus(otherFormula, diffCount);
        return diffCount != 0 && !copyFormula.isEmptyFormula;
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
    foreach (const ProjectNode node; root.collapse)
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

    string[64] dirtyFiles;
    size_t dirtyCount;


    foreach_reverse (ProjectNode n; root.collapse)
    {
        --i;
        if (!n.isUpToDate)
            continue;
        if(cacheStatus[i].needsNewCopy(n.requirements, compiler, target, &preprocessed))
            n.setCopyEnough();

        if (!cacheStatus[i].isCompilationUpToDate(n.requirements, compiler, target, &preprocessed, dirtyFiles, dirtyCount))
        {
            n.setFilesDirty(dirtyFiles[0..dirtyCount]);
            n.invalidateCache();
        }
    }
}

ubyte[] hashFunction(const char[] input, ref ubyte[] output)
{
    import xxhash3;

    XXH_64 xxh;
    xxh.put(cast(const ubyte[]) input);

    auto hash = xxh.finish;
    if (output.length < hash.length)
        output.length = hash.length;
    output[] = hash[];
    return output;
}

bool attrIncludesUDA(LookType, Attribs...)()
{
    static foreach (value; Attribs)
        static if (is(typeof(value) == LookType) || is(LookType == value))
            return true;
    return false;
}

/**
 *
 * Params:
 *   req = The requirements to generate
 *   compiler = Using compiler
 *   isRoot = This one may include less information. This allows more cache to be reused while keeping the smaller pieces of cache more restrained.
 * Returns: The hash.
 */
string hashFrom(const BuildConfiguration cfg, Compiler compiler, bool isRoot = true)
{
    import std.conv : to;
    import xxhash3;

    XXH_64 xxh;
    xxh.start();
    xxh.put(cast(ubyte[]) compiler.versionString);
    // xxh.put(cast(ubyte[])req.targetConfiguration);
    // xxh.put(cast(ubyte[])req.version_);

    static foreach (i, v; BuildConfiguration.tupleof)
    {
        {

            bool isExcludedFromRoot = attrIncludesUDA!(cacheExclude, __traits(getAttributes, v));
            if (!isRoot || (isRoot && !isExcludedFromRoot))
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

string hashFrom(const BuildRequirements req, Compiler compiler, bool isRoot = true)
{
    return hashFrom(req.cfg, compiler, isRoot);
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
AdvCacheFormula getCompilationCacheFormula(const BuildRequirements req, OS target, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
{
    import std.algorithm.iteration, std.array;

    static contentHasher = (ubyte[] content, ref ubyte[] output) {
        return hashFunction(cast(string) content, output);
    };


    return AdvCacheFormula.make(
        contentHasher,//DO NOT use sourcePaths since importPaths is always custom + sourcePaths
        [
        DirectoriesWithFilter(req.cfg.importDirectories, true),
        DirectoriesWithFilter(req.cfg.stringImportPaths, false)
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

string getCacheOutputDir(string mainPackHash, const BuildRequirements req, Compiler compiler, OS os)
{
    if(mainPackHash.length == 0)
        throw new Exception("No hash.");
    return buildNormalizedPath(getCacheFolder, mainPackHash, hashFrom(req, compiler));
}

string getCacheOutputDir(string mainPackHash, const BuildConfiguration cfg, Compiler compiler, OS os)
{
    if(mainPackHash.length == 0)
        throw new Exception("No hash.");
    return buildNormalizedPath(getCacheFolder, mainPackHash, hashFrom(cfg, compiler));
}


/**
 * Stores the output artifact directory. Used for saving artifacts elsewhere and simply copying if they are already up to date.
 * Params:
 *   mainPackHash = The root cache on which this formula was built with. It is used for finding the output directory.
 *   req = The requirements will load adv_diff with the paths to watch for changes
 *   target = Target is important for knowing how the library is called
 *   existing = An existing formula reference as input is important for getting content hash if they aren't up to date
 *   preprocessed = This will store calculations on an AdvCacheFormula, so, subsequent checks are much faster
 * Returns: A new AdvCacheFormula
 */
AdvCacheFormula getCopyCacheFormula(string mainPackHash, const BuildRequirements req, Compiler compiler, OS os, const(AdvCacheFormula)* existing, AdvCacheFormula* preprocessed)
{
    import std.algorithm.iteration, std.array;

    static contentHasher = (ubyte[] content, ref ubyte[] output) {
        return hashFunction(cast(string) content, output);
    };


    string[] extraRequirements = [];
    if (req.cfg.targetType.isLinkedSeparately)
        extraRequirements = req.extra.librariesFullPath.map!(
            (libPath) => getLibraryPath(libPath, req.cfg.outputDirectory, os)).array;


    return AdvCacheFormula.make(
        contentHasher,//DO NOT use sourcePaths since importPaths is always custom + sourcePaths
        [
            DirectoriesWithFilter([], false)
        ],
        joiner([req.extra.expectedArtifacts, extraRequirements]),
        existing,
        preprocessed
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
    std.file.write(getCacheFilePath(rootCache), getCache(rootCache).toString());
}

private JSONValue* getCache(string rootCache)
{
    static JSONValue[string] cacheJson;
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
            cacheJson[rootCache] = parseJSON(std.file.readText(file));
        catch (Exception e)
        {
            std.file.write(file, "{}");
            cacheJson[rootCache] = JSONValue.emptyObject;
        }
    }

    return &cacheJson[rootCache];
}

private string getCacheFolder()
{
    static string cacheFolder;
    if (!cacheFolder)
        cacheFolder = buildNormalizedPath(getDubWorkspacePath(), CACHE_FOLDER_NAME);
    return cacheFolder;
}

private string getBinCacheFolder()
{
    static string cacheFolder;
    if (!cacheFolder)
        cacheFolder = buildNormalizedPath(getCacheFolder, BIN_CACHE_FOLDER);
    return cacheFolder;
}

private string getCacheFilePath(string rootCache)
{
    return buildNormalizedPath(getCacheFolder, rootCache ~ ".json");
}
