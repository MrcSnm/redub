module redub.building.root_objects;

import d_dependencies;
import redub.buildapi;
import redub.api : RedubException;
import redub.logging : warn, infos;
import redub.building.cache;
import redub.building.build_timings;
import redub.building.utils;
import redub.command_generators.automatic;
import redub.command_generators.commons;
import redub.tooling.compiler_identification;
import std.parallelism : TaskPool, totalCPUs;
import std.file : exists, mkdirRecurse, readText, remove;
import std.path : buildNormalizedPath, baseName, stripExtension;
import std.string : endsWith, splitLines, split, startsWith;
import std.array : join;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.conv : to;

struct RootObjectResult
{
    int status;
    string message;
    string command;
    long msNeeded;
    bool notApplicable;
}

private struct ModuleObject
{
    string name;
    string objectPath;
    string command;
    string output;
    int status;
}

///Object builds need enough workers to beat a single compiler invocation.
bool canUseRootObjects(const ProjectNode root, CompilingSession s)
{
    const BuildConfiguration cfg = root.requirements.cfg;
    if(cfg.buildStrategy == BuildStrategy.incrementalOnce || cfg.buildStrategy == BuildStrategy.fullOnce)
        return false;
    if(cfg.buildStrategy != BuildStrategy.incrementalParallel && cfg.buildStrategy != BuildStrategy.fullParallel && totalCPUs < MIN_OBJECT_BUILD_CPUS)
        return false;
    if(cfg.syntaxOnly || !cfg.targetType.hasBuildableOutput)
        return false;
    return isDCompiler(cfg.getCompiler(s.compiler));
}

private uint objectWorkers(size_t moduleCount)
{
    uint workers = totalCPUs;
    version(Posix)
    {
        try
        {
            import std.algorithm : find;
            import std.array : array;
            foreach(line; readText("/proc/meminfo").splitLines)
                if(line.startsWith("MemAvailable:"))
                {
                    ///Keep a conservative 1 GiB per compiler process.
                    ulong availableKb = line.split()[1].to!ulong;
                    uint memoryWorkers = cast(uint)(availableKb / (1024 * 1024));
                    if(memoryWorkers < workers)
                        workers = memoryWorkers;
                    break;
                }
        }
        catch(Exception) {}
    }
    if(workers > moduleCount)
        workers = cast(uint)moduleCount;
    return workers ? workers : 1;
}

private string objectPath(string objDir, string moduleName, OS os)
{
    import redub.command_generators.commons : getObjectExtension;
    return buildNormalizedPath(objDir, moduleName ~ getObjectExtension(os));
}

private string[] withoutObjectFiles(string[] flags)
{
    string[] ret;
    foreach(flag; flags)
        if(!flag.endsWith(".o") && !flag.endsWith(".obj"))
            ret ~= flag;
    return ret;
}

private int runCompiler(const BuildConfiguration cfg, Compiler compiler, string[] flags,
    const string[string] env, out string command, out string output)
{
    string cmdFile;
    auto process = execCompiler(cfg, compiler, flags, command, true, cmdFile, env);
    scope(exit)
    {
        if(cmdFile.length)
            remove(cmdFile);
    }
    auto result = waitProcessExec(process);
    output = result.output;
    return result.status;
}

///Builds the root package one object per module, recompiling only changed
///modules and their dependents, then links the cached objects.
RootObjectResult buildRootObjects(ProjectNode root, CompilingSession s, string mainPackHash,
    const string[string] env)
{
    RootObjectResult result;
    StopWatch sw = StopWatch(AutoStart.yes);
    scope(exit)
        result.msNeeded = sw.peek.total!"msecs";

    BuildConfiguration cfg = root.requirements.cfg;
    string cacheDir = getCacheOutputDir(mainPackHash, root.requirements, s);
    string objDir = getObjectDir(cacheDir);
    mkdirRecurse(cacheDir);

    ImportScanContext ctx = makeImportScanContext(s, cfg);

    ///When sourceFiles is explicit, redub compiles only those files; do not
    ///pull test/example sources from sourcePaths into the object graph.
    string[] sourceDirs = cfg.sourceFiles.length ? null : cfg.sourcePaths;
    SourceImportGraph graph = parseSourceImportGraph(sourceDirs, cfg.sourceFiles,
        cfg.excludeSourceFiles, ctx, true);
    if(graph.modules.length == 0)
        throw new RedubException("No D modules found for object build in " ~ cfg.workingDir);
    bool[string] changed;
    const(string[]) dirtyFiles = root.getDirtyFiles();
    bool dirtyTruncated = root.isDirtyTruncated();
    bool anyCachedObject;
    foreach(name; graph.compileOrder)
    {
        auto mod = graph.byName[name];
        bool objectExists = exists(objectPath(objDir, name, s.os));
        anyCachedObject = anyCachedObject || objectExists;
        if(dirtyTruncated || !objectExists)
        {
            changed[name] = true;
            continue;
        }
        foreach(dirty; dirtyFiles)
            if(mod.modPath == dirty || mod.modPath.endsWith("/" ~ dirty)
                || mod.modPath.endsWith("\\" ~ dirty))
            {
                changed[name] = true;
                break;
            }
    }

    bool[string] affected;
    foreach(name, _; changed)
    {
        affected[name] = true;
        foreach(dependent; graph.findDependents(name))
            affected[dependent] = true;
    }
    ///Unknown dynamic imports mean any module may be reached; rebuild all.
    string[] importRisks;
    foreach(name, mod; graph.byName)
        if(mod.isImportRisk || mod.hasUnresolvedStringMixins)
            importRisks ~= name ~ (mod.doubts.length ? " (" ~ mod.doubts[0] ~ ")" : "");
    if(importRisks.length)
        warn("Object build: cannot use incremental parallelization because imports could not be resolved in ",
            importRisks, ". Rebuilding all modules.");
    if(graph.skippedFiles.length)
        warn("Object build: cannot use incremental parallelization because files were skipped: ",
            graph.skippedFiles, ". Rebuilding all modules.");
    if(importRisks.length || graph.skippedFiles.length)
        foreach(name; graph.compileOrder)
            affected[name] = true;
    ///parallel-full rebuilds every module without touching cached dependencies.
    if(cfg.buildStrategy == BuildStrategy.fullParallel)
        foreach(name; graph.compileOrder)
            affected[name] = true;

    ModuleObject[] builds;
    foreach(name; graph.compileOrder)
        if(name in affected)
            builds ~= ModuleObject(name, objectPath(objDir, name, s.os));

    size_t rootWeight;
    bool conservativeWeight;
    foreach(name; graph.compileOrder)
    {
        auto mod = graph.byName[name];
        rootWeight += mod.compileWeight;
        conservativeWeight = conservativeWeight || mod.conservativeWeight;
    }
    bool highWeight = conservativeWeight || rootWeight >= 10_000;
    bool small = graph.modules.length < 8;
    bool probeObject;
    StrategyPreference preference;
    if(cfg.buildStrategy == BuildStrategy.auto_)
    {
        TimingSamples samples = timingSamples(mainPackHash, cast(uint)builds.length,
            cast(uint)graph.modules.length);
        if(small && highWeight)
        {
            ///Small but potentially expensive: take a single baseline, then
            ///one object probe. If it is not clearly better, stay on single.
            if(samples.single == 0)
            {
                result.notApplicable = true;
                return result;
            }
            if(samples.object == 0)
                probeObject = true;
            else
                preference = timingPreference(mainPackHash, cast(uint)builds.length,
                    cast(uint)graph.modules.length, 1);
        }
        else
        {
            ///A cold object cache makes every module look changed, which would
            ///always pick single and never populate the cache. Probe once after
            ///a single baseline so the timing comparison can start.
            if(!small && !anyCachedObject && samples.single > 0)
                probeObject = true;
            preference = timingPreference(mainPackHash, cast(uint)builds.length,
                cast(uint)graph.modules.length);
        }
    }
    if(preference == StrategyPreference.preferSingle)
    {
        result.notApplicable = true;
        return result;
    }
    ///Tiny cheap projects link faster in a single compiler invocation.
    if(cfg.buildStrategy != BuildStrategy.incrementalParallel && cfg.buildStrategy != BuildStrategy.fullParallel && !probeObject
        && preference != StrategyPreference.preferObject && graph.modules.length < 8)
    {
        result.notApplicable = true;
        return result;
    }
    ///Many cheap modules accepting the entire object graph is slower than one
    ///compiler invocation, while a leaf change still benefits from objects.
    bool allAffected = builds.length == graph.modules.length;
    if(cfg.buildStrategy == BuildStrategy.auto_ && preference == StrategyPreference.none
        && !probeObject && !conservativeWeight && rootWeight < 10_000 && allAffected)
    {
        result.notApplicable = true;
        return result;
    }

    uint workers = objectWorkers(builds.length ? builds.length : 1);
    StopWatch compileSw = StopWatch(AutoStart.yes);
    if(builds.length && builds.length < graph.modules.length)
        infos("Incremental object build: ", builds.length, "/", graph.modules.length,
            " modules, ", workers, " jobs");
    if(builds.length)
    {
        auto pool = new TaskPool(workers);
        scope(exit) pool.stop();
        foreach(ref build; pool.parallel(builds, 1))
        {
            auto mod = graph.byName[build.name];
            string[] flags = getCompilationFlags(cfg, s, mainPackHash, true, false,
                build.objectPath, mod.modPath);
            build.status = runCompiler(cfg, s.compiler, flags, env, build.command, build.output);
        }
    }

    long compileMs = compileSw.peek.total!"msecs";
    string[] commands;
    foreach(build; builds)
    {
        commands ~= build.command;
        if(build.status)
        {
            result.status = build.status;
            result.message = build.output;
            result.command = commands.join("\n\n");
            return result;
        }
    }

    if(cfg.targetIcon.length && cfg.targetType == TargetType.executable && s.os.isWindows)
    {
        import redub.misc.win_icon;
        string iconError;
        if(processIcon(cfg.targetIcon, iconError) is null)
        {
            result.status = 1;
            result.message = iconError;
            return result;
        }
    }

    auto data = root.requirements.buildData(true, s, env);
    string[] objects;
    foreach(name; graph.compileOrder)
        objects ~= objectPath(objDir, name, s.os);
    string[] linkFlags = objects ~ withoutObjectFiles(getLinkFlags(data, s, mainPackHash));
    string linkCommand;
    string linkOutput;
    StopWatch linkSw = StopWatch(AutoStart.yes);
    int linkStatus = runCompiler(cfg, s.compiler, linkFlags, env, linkCommand, linkOutput);
    long linkMs = linkSw.peek.total!"msecs";
    result.command = (commands ~ [linkCommand]).join("\n\n");
    if(linkStatus)
    {
        result.status = linkStatus;
        result.message = linkOutput;
        return result;
    }

    string cacheExe = buildNormalizedPath(cacheDir, getOutputName(cfg, s.os));
    if(cfg.targetType == TargetType.executable)
    {
        version(Posix)
        {
            import redub.misc.make_file_executable : makeFileExecutable;
            if(!makeFileExecutable(cacheExe))
            {
                result.status = 1;
                result.message = "Could not make the output file executable";
                return result;
            }
        }
    }
    copyDir(cacheDir, cfg.outputDirectory);
    result.msNeeded = sw.peek.total!"msecs";
    if(cfg.buildStats)
        recordBuildTiming(mainPackHash,
            builds.length < graph.modules.length ? TimingStrategy.objectIncremental : TimingStrategy.objectFull,
            builds.length == graph.modules.length,
            (cfg.buildStrategy == BuildStrategy.incrementalParallel || cfg.buildStrategy == BuildStrategy.fullParallel),
            workers, cast(uint)builds.length, cast(uint)graph.modules.length,
            cast(uint)result.msNeeded, cast(uint)compileMs, cast(uint)linkMs);

    return result;
}
