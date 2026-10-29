module redub.building.cache;
public import redub.tooling.compiler_identification;
public import redub.libs.adv_diff.files;
public import std.int128;
import redub.api;
import redub.buildapi;
import redub.building.cache_binary;
import std.path;

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
        CacheFileData* c = getCache(rootHash);
        string reqCache = req.extra.isRoot ? rootHash : hashFrom(req.cfg, s, false);

        if (sharedFormula.isEmptyFormula)
        {
            if (c.fullFormula.isEmptyFormula)
                return CompilationCache(reqCache, rootHash, AdvCacheFormula.init, AdvCacheFormula.init, sharedFormula);
            sharedFormula = c.fullFormula;
        }

        CacheRequirementEntry* targetCache = reqCache in c.requirements;
        if (!targetCache)
            return CompilationCache(reqCache, rootHash, AdvCacheFormula.init, AdvCacheFormula.init, sharedFormula);

        import redub.logging;
        try
            return CompilationCache(reqCache, rootHash,
                formulaFromSimple(targetCache.compileFormula, sharedFormula),
                formulaFromSimple(targetCache.copyFormula, sharedFormula),
                sharedFormula);
        catch (Exception e)
        {
            error("Cache is corrupted, regenerating...");
            return CompilationCache(reqCache, rootHash, AdvCacheFormula.init, AdvCacheFormula.init, sharedFormula);
        }
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
 * This function mutates the ProjectNode's isUpToDate property. It checks the entire tree
 * if it is not up to date, when it is not, it invalidates itself and all their parents.
 * It requires the existing cache status for the project and then, starts comparing, with its current
 * situation
 * Params:
 *   root = Project root for traversing
 *   s = The session on which the cache should be invalidated
 *   sharedFormula = Used later for not needing to recalculate hash from files which didn't change.
 *   preprocessed = Source/import directories already scanned during invalidation, reused by the build.
 */
void invalidateCaches(ProjectNode root, CompilingSession s, out AdvCacheFormula sharedFormula, out AdvCacheFormula preprocessed)
{
    import std.datetime.stopwatch;
    import redub.logging;
    StopWatch sw = StopWatch(AutoStart.yes);
    CompilationCache[] cacheStatus = cacheStatusForProject(root, s, sharedFormula);
    import std.algorithm.comparison: min;
    ptrdiff_t i = cacheStatus.length;

    string[64] dirtyFiles;
    size_t dirtyCount;

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
    vvlog("Cache invalidation took ", sw.peek.total!"msecs", "ms");
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

    void putString(string value)
    {
        xxh.put(cast(ubyte[]) (value.length.to!string));
        xxh.put(cast(ubyte[]) value);
    }

    putString(cfg.getCompiler(session.compiler).versionString);
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
                    putString(cfg.tupleof[i]);
                else static if (is(typeof(v) == string[]))
                {
                    foreach (element; cfg.tupleof[i])
                        putString(element);
                }
                else
                    putString(cfg.tupleof[i].to!string);
            }
        }
    }

    return xxh.finish().toHexString.idup;
}

string hashFrom(const BuildRequirements req, CompilingSession s)
{
    return hashFrom(req.cfg, s, req.extra.isRoot);
}

DirectoryFilterType filterTypeFromCompiler(const ref BuildRequirements cfg, const CompilingSession s )
{
    CompilerBinary b = cfg.getCompiler(s.compiler);

    final switch(b.compiler) with(AcceptedCompiler)
    {
        case dmd, ldc2: return DirectoryFilterType.d;
        case gcc: return DirectoryFilterType.c;
        case gxx: return DirectoryFilterType.cpp;
        case clang, cl: return DirectoryFilterType.cpp;
        case invalid: return DirectoryFilterType.none;
    }
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
    if(req.getCompiler(s.compiler).compiler == AcceptedCompiler.ldc2)
    {
        ///LDC object output directory
        dirs~= cacheDir~ "_obj";
    }
    if(req.cfg.outputsDeps)
        dirs~= getObjectDir(cacheDir);

    ///sourcePaths is not guaranteed to be inside importDirectories. Users may compile
    ///a source directory while only exposing a different directory for imports.
    string[] sourcePaths;
    foreach(path; req.cfg.sourcePaths)
    {
        bool alreadyWatched;
        foreach(importPath; req.cfg.importDirectories)
            if(importPath == path)
            {
                alreadyWatched = true;
                break;
            }
        if(!alreadyWatched)
            sourcePaths~= path;
    }

    ///Output directories change during the build, so they must be rescanned instead of reused.
    if(preprocessed !is null)
        foreach(dir; dirs)
            preprocessed.directories.remove(dir);

    return AdvCacheFormula.make(
        &hashFunction,
        [
            DirectoriesWithFilter(req.cfg.importDirectories, filterTypeFromCompiler(req, s), req.cfg.excludeSourceFiles),
            DirectoriesWithFilter(sourcePaths, filterTypeFromCompiler(req, s), req.cfg.excludeSourceFiles),
            DirectoriesWithFilter(req.cfg.stringImportPaths, DirectoryFilterType.none, null, false),
            DirectoriesWithFilter(dirs, DirectoryFilterType.none, null, true) //Use simplified hashing for other object dirs
        ], ///This is causing problems when using subPackages without output path, they may clash after
        // the compilation is finished. Solving this would require hash calculation after linking
        joiner([
            req.cfg.sourceFiles,
            req.cfg.filesToCopy, req.cfg.extraDependencyFiles,
            req.cfg.targetIcon
        ]),
        existing,
        preprocessed,
        false,
        false
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
            (libPath) => getLibraryPath(libPath, req.cfg.outputDirectory, s.os)).array;

    return AdvCacheFormula.make(
        &hashFunction,//DO NOT use sourcePaths since importPaths is always custom + sourcePaths
        [DirectoriesWithFilter([], DirectoryFilterType.none)],
        joiner([getExpectedArtifacts(req, s.os, s.isa), extraRequirements]),
        existing,
        preprocessed,
        true,
        false
    );
}

string[] updateCache(string rootCache, const CompilationCache cache)
{
    CacheFileData* cacheFile = getCache(rootCache);
    cacheFile.requirements[cache.requirementCache] = CacheRequirementEntry(
        simpleFromFormula(cache.formula),
        simpleFromFormula(cache.copyFormula)
    );
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
    CacheFileData* cache = getCache(rootCache);
    assert(fullCache !is null, "Full cache can't be null");
    if(!fullCache.isEmptyFormula)
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
        cache.fullFormula = *fullCache;
    }

    writeCacheFile(getCacheFilePath(rootCache), *cache);
}


///Loads the previous full formula so a forced build can still reuse file hashes.
AdvCacheFormula loadExistingSharedFormula(ProjectNode root, CompilingSession s)
{
    return getCache(hashFrom(root.requirements, s)).fullFormula;
}

private __gshared CacheFileData[string] cacheFiles;
private CacheFileData* getCache(string rootCache)
{
    static import std.file;
    string folder = getCacheFolder;
    import redub.meta;
    import redub.logging;

    if(cacheFiles == cacheFiles.init)
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
    {
        CacheFileData empty;
        writeCacheFile(file, empty);
    }

    if (!(rootCache in cacheFiles))
    {
        try
            cacheFiles[rootCache] = readCacheFile(file);
        catch (Exception e)
        {
            CacheFileData empty;
            writeCacheFile(file, empty);
            cacheFiles[rootCache] = empty;
        }
    }

    return &cacheFiles[rootCache];
}

/**
*   Clears memory cache. This will allow to redub correctly identify files that changed in subsequent runs.
*/
void clearCompilationInfoCache()
{
    cacheFiles = null;
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
    return redub.misc.path.buildNormalizedPath(getCacheFolder, rootCache ~ ".bin");
}

