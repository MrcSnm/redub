module redub.building.compile;
import redub.building.utils;
import redub.building.cache;
import redub.building.root_objects;
import redub.building.build_timings;
import redub.logging;
import redub.buildapi;
import std.system;
import redub.tooling.compiler_identification;
import redub.command_generators.automatic;
import std.process:Pid;
import std.concurrency:Tid;

private immutable string defaultEnvJs = import("env.js");

/**
 * When using redub as a library, one may spawn multiple times the same package, having a bug on it.
 * The problem is that although it returns to execution, the threads aren't actually killed!
 * To solve that problem, finishedPackages will only ever add to it if the buildExecutions id is the same.
 */
size_t buildExecutions;
/**
 * PIDs currently running. When a package fails, `killRunningProcesses` kills
 * every entry marked `true` so the build stops instead of waiting for the
 * remaining compilers. Finished PIDs must be cleared, otherwise they could be
 * recycled by the OS and killed by mistake.
 *
 * This is only accessed by the coordinator thread (module variables are
 * thread-local in D); workers report their PIDs through `ProcessInfo`.
 */
bool[shared Pid] runningProcesses;

struct CompilationResult
{
    string compilationCommand;
    string message;
    size_t msNeeded;
    int status = 1;
    bool linkedInCompilation;
    shared ProjectNode node;
    shared Pid pid;
}

struct CompilationID
{
    size_t id;
}

/**
 * Sent by a worker to tell the coordinator about a compiler process it spawned.
 *
 * `running` is true while the process is alive and false once it exited, so
 * the coordinator can forget it. This exists because per-source compilation
 * spawns several processes per package, while `CompilationResult.pid` can only
 * carry the last one: without the explicit `false`, the earlier PIDs would stay
 * marked as running forever and a later failure could kill a recycled PID.
 */
struct ProcessInfo
{
    shared Pid pid;
    bool running = true;
}

///Notifies the coordinator about a process state. No-op when unowned.
private void reportProcess(Tid owner, size_t id, shared Pid pid, bool running)
{
    import std.concurrency : send;

    if(owner == Tid.init)
        return;
    send(owner, CompilationID(id), ProcessInfo(pid, running), CompilationResult.init);
}

struct HashPair
{
    string rootHash;
    string requirementHash;
}

import redub.api;
struct ExecutionResult
{
    int status;
    string output;
}

/**
 * Returns: The current environment. Used for caching environment and not executing it per project.
 */
string[string] getCurrentEnv()
{
    import redub.parsers.environment;
    return getRedubEnv;
}
/**
 * If any command fails, stop executing and return.
 */
private ExecutionResult executeCommands(const BuildConfiguration cfg, RedubCommands list, ref CompilationResult res, const string[string] env)
{
    import std.process;
    import std.string:strip;
    const string[] commandsList = cfg.commands.length > list ? cfg.commands[list] : null;
    foreach(cmd; commandsList)
    {
        auto execRes  = cast(ExecutionResult)executeShell(cmd, env, Config.none, size_t.max, cfg.workingDir);
        if(execRes.status)
        {
            import std.conv:to;
            res.status = execRes.status;
            res.message = "Result of "~list.to!string~" command '"~cmd~"' "~execRes.output;
            return execRes;
        }
        else
        {
            import std.conv:to;
            if(execRes.output.length)
                res.message~= "\t" ~list.to!string~" Running commands for "~cfg.name~": "~execRes.output.strip;
        }
    }
    return ExecutionResult(0, "Success");
}

void execCompilationThread(immutable ThreadBuildData data, shared ProjectNode pack, CompilationInfo info, HashPair hash, size_t id)
{
    import std.concurrency;
    Tid owner = ownerTid;
    CompilationResult res;
    res = execCompilation(data, pack, info, hash, owner, id);
    scope(exit)
    {
        owner.send(CompilationID(id), ProcessInfo.init, res);
    }
}

private bool hasDirtyDependency(const ProjectNode node)
{
    foreach(dep; node.dependencies)
    {
        ///A copy-enough dependency is already built; only its artifact needs
        ///copying, so it does not block single-call or object builds.
        if((dep.shouldEnterCompilationThread && !dep.isCopyEnough) || hasDirtyDependency(dep))
            return true;
    }
    return false;
}

///Guards the per-module object strategy. Unlike canBuildInSingleCall this is
///compatible with reuseObjects: both modes share the same object dir.
private bool canUseRootObjectStrategy(const ProjectNode node, CompilationInfo s)
{
    if(!node.isRoot)
        return false;
    if(hasDirtyDependency(node))
        return false;
    const BuildConfiguration cfg = node.requirements.cfg;
    if(cfg.syntaxOnly || !cfg.targetType.hasBuildableOutput)
        return false;
    return isDCompiler(cfg.getCompiler(s.compiler));
}

private bool canBuildInSingleCall(const ProjectNode node, CompilationInfo s)
{
    if(!node.isRoot)
        return false;
    ///Single-call links against already-built dependencies. If any still needs
    ///compiling, they must be built first and the separate link path is used.
    if(hasDirtyDependency(node))
        return false;
    const BuildConfiguration cfg = node.requirements.cfg;
    if(cfg.targetType != TargetType.executable || cfg.syntaxOnly || cfg.reuseObjects)
        return false;
    return isDCompiler(cfg.getCompiler(s.compiler));
}

private string[] getSingleCallFlags(const ThreadBuildData data, CompilationInfo s, string mainPackHash)
{
    string[] flags = getCompilationFlags(data.cfg, s, mainPackHash, data.extra.isRoot, true);
    flags ~= getLinkFlags(data, s, mainPackHash, false, false);
    return flags;
}

///Removes previously generated object files so stale sources are not archived
///or linked after the per-source compilation strategy runs.
private void removeObjectFiles(string dir)
{
    import std.file : dirEntries, exists, isDir, remove, SpanMode;
    import std.string : endsWith;

    if(!exists(dir))
        return;
    foreach(entry; dirEntries(dir, SpanMode.depth))
        if(!entry.isDir && (entry.name.endsWith(".o") || entry.name.endsWith(".obj")))
            remove(entry.name);
}

/**
 * Compiles every source in its own process, concurrently, writing one object
 * file per source into `inDir` (the cache output directory).
 */
private ExecutionResult compilePerSource(
    const BuildConfiguration cfg,
    Compiler compiler,
    immutable ThreadBuildData data,
    string[][] perSourceFlags,
    string inDir,
    Tid owner,
    size_t id,
    ref CompilationResult res)
{
    import std.algorithm.comparison:clamp;
    import std.file : remove;
    import std.parallelism : TaskPool, totalCPUs;

    struct PerSourceOutcome
    {
        string command;
        string output;
        int status;
        shared Pid pid;
    }

    ExecutionResult ret;
    PerSourceOutcome[] outcomes;
    outcomes.length = perSourceFlags.length;

    ///Spawning one process per source only pays off when they run
    ///concurrently, so use one worker per source up to the core count.
    uint workers = clamp(cast(uint)perSourceFlags.length, 1, totalCPUs);

    if(perSourceFlags.length)
    {
        auto pool = new TaskPool(workers);
        scope(exit) pool.stop();
        foreach(i, ref outcome; pool.parallel(outcomes, 1))
        {
            string cmdFile;
            ProcessExec2 ex = execCompiler(cfg, compiler, perSourceFlags[i],
                outcome.command, data.isLeaf, cmdFile, data.env);
            outcome.pid = cast(shared)ex.pipe.pid;
            reportProcess(owner, id, outcome.pid, true);
            auto one = waitProcessExec(ex);
            if(cmdFile)
                remove(cmdFile);
            reportProcess(owner, id, outcome.pid, false);
            outcome.status = one.status;
            outcome.output = one.output;
        }
    }

    foreach(i, ref outcome; outcomes)
    {
        res.compilationCommand ~= (i == 0 ? "" : "\n\n") ~ outcome.command;
        ret.output ~= outcome.output;
        if(outcome.status && !ret.status)
            ret.status = outcome.status;
    }
    if(outcomes.length)
        res.pid = outcomes[$ - 1].pid;
    return ret;
}

CompilationResult execCompilation(immutable ThreadBuildData data, shared ProjectNode pack, CompilationInfo info, HashPair hash, Tid owner, size_t id)
{
    import std.file;
    import std.process;
    import std.datetime.stopwatch;
    import redub.command_generators.commons;

    CompilationResult res;
    res.node = pack;
    StopWatch sw = StopWatch(AutoStart.yes);
    scope(exit)
    {
        res.msNeeded = sw.peek.total!"msecs";
    }
    try
    {
        if(pack.isUpToDate && !pack.isCopyEnough)
            return res;

        BuildConfiguration cfg = data.cfg.clone;
        Compiler compiler = info.compiler;
        CompilerBinary c = data.cfg.getCompiler(compiler);
        OS os = info.targetOS;
        ISA isa = info.isa;
        //Remove existing binary, since it won't be replaced by simply executing commands
        string outDir = getConfigurationOutputPath(cfg, os);
        if(exists(outDir))
            remove(outDir);

        if(executeCommands(data.cfg, RedubCommands.preBuild, res, data.env).status)
            return res;

        if(pack.requirements.cfg.targetType.hasBuildableOutput)
        {
            import std.path;
            string inDir = getCacheOutputDir(hash.rootHash, cast()pack.requirements, info);
            mkdirRecurse(inDir);
            createOutputDirFolder(cfg);

            ExecutionResult ret;
            bool singleCall;
            if(!pack.isCopyEnough)
            {
                import std.concurrency;
                import redub.command_generators.automatic : getPerSourceCompilationFlags;

                ///C/C++ sources are compiled individually so each one produces
                ///its own object file, avoiding a relocatable (-r) link that
                ///would embed the C runtime inside the object.
                string[][] perSourceFlags = isDCompiler(c) ? null
                    : getPerSourceCompilationFlags(cfg, info, inDir);

                if(perSourceFlags !is null)
                {
                    import redub.misc.hard_link : hardLinkDir;

                    removeObjectFiles(inDir);
                    ret = compilePerSource(cfg, compiler, data, perSourceFlags, inDir, owner, id, res);
                    if(!ret.status)
                        hardLinkDir(inDir, dirName(outDir), true, true);
                }
                else
                {
                    singleCall = canBuildInSingleCall(cast()pack, info);
                    res.linkedInCompilation = singleCall;
                    string[] compilationFlags;
                    if(singleCall)
                    {
                        ThreadBuildData singleCallData = ThreadBuildData(cfg, cast()data.extra, data.archiver, data.isRoot, data.isLeaf, data.env);
                        compilationFlags = getSingleCallFlags(singleCallData, info, hash.rootHash);
                    }
                    else
                        compilationFlags = getCompilationFlags(cfg, info, hash.rootHash, data.extra.isRoot);

                    if(singleCall && cfg.targetIcon.length)
                    {
                        version(Windows)
                        {
                            import redub.misc.win_icon;
                            string iconError;
                            if(processIcon(cfg.targetIcon, iconError) is null)
                            {
                                res.status = 1;
                                res.message = iconError;
                                return res;
                            }
                        }
                    }

                    string cmdFile;
                    ProcessExec2 ex = execCompiler(cfg, compiler, compilationFlags, res.compilationCommand, data.isLeaf, cmdFile, data.env);
                    scope(exit)
                    {
                        if(cmdFile)
                            std.file.remove(cmdFile);
                    }
                    res.pid = cast(shared)ex.pipe.pid;
                    reportProcess(owner, id, res.pid, true);
                    ret = cast(ExecutionResult)finishCompilerExec(cfg, compiler, inDir, dirName(outDir), ex);
                }
            }

            if(!ret.status && !isDCompiler(c) && isStaticLibrary(data.cfg.targetType)) //Must call archiver when
            {
                string cmd ;
                auto archiverRes = executeArchiver(data, info, hash.rootHash, cmd);
                ret.status = archiverRes.status;
                ret.output~= archiverRes.output;
                res.compilationCommand~= "\n\nArchiving: \n\t"~cmd;
            }

            if(!ret.status && !data.cfg.syntaxOnly)
                copyDir(inDir, dirName(outDir));

            if(!ret.status && singleCall)
            {
                version(Posix)
                {
                    import redub.command_generators.commons;
                    import redub.misc.make_file_executable;
                    import redub.misc.path;
                    string cacheExe = buildNormalizedPath(inDir, getOutputName(cfg, info.targetOS));
                    string outputExe = buildNormalizedPath(dirName(outDir), getOutputName(cfg, info.targetOS));
                    if(!makeFileExecutable(cacheExe) || !makeFileExecutable(outputExe))
                    {
                        ret.status = 1;
                        ret.output ~= "Could not make the output file executable";
                    }
                }
            }

            ///Shared Library(mostly?)
            if(!ret.status && isDCompiler(c) && isLinkedSeparately(data.cfg.targetType) && !pack.isRoot && !data.cfg.syntaxOnly)
            {
                CompilationResult linkRes = link(cast()pack, hash.requirementHash, data, info);
                ret.status = linkRes.status;
                ret.output~= linkRes.message;
                res.compilationCommand~= "\n\nLinking: \n\t"~ linkRes.compilationCommand;
            }
            res.status = ret.status;
            res.message ~= ret.output;
        }


        ///Targets without an artifact succeed once their commands/plugins ran.
        if(!pack.requirements.cfg.targetType.hasBuildableOutput)
            res.status = 0;

        if(res.status == 0)
        {
            if(!cfg.targetType.isLinkedSeparately && executeCommands(cfg, RedubCommands.postBuild, res, data.env).status)
                return res;
        }
    }
    catch(Throwable e)
    {
        res.status = 1;
        res.message = e.toString;
    }
    return res;
}


CompilationResult link(ProjectNode root, string rootHash, const ThreadBuildData data, CompilationInfo info)
{
    import std.process;
    import std.file;
    import redub.command_generators.commons;
    OS os = info.targetOS;
    CompilationResult ret;

    if(root.requirements.cfg.targetIcon && root.requirements.cfg.targetType == TargetType.executable && info.targetOS.isWindows)
    {
        import redub.misc.win_icon;
        string err;
        if(processIcon(root.requirements.cfg.targetIcon, err) == null)
        {
            ret.message~= err;
            ret.status = 1;
            return ret;
        }
    }

    if(!root.isCopyEnough)
    {
        string cmdFile;
        ProcessExec2 linkProcess = linkBase(data, info, rootHash, ret.compilationCommand, cmdFile);
        scope(exit)
        {
            if(cmdFile)
                std.file.remove(cmdFile);
        }
        auto exec = waitProcessExec(linkProcess);
        ret.status = exec.status;
        ret.message = exec.output;
        if(exec.status != 0)
            return ret;
    }
    import redub.command_generators.commons;
    import std.path;

    string inDir = getCacheOutputDir(rootHash, cast()root.requirements, info);
    if(root.requirements.cfg.targetType == TargetType.executable && std.system.os.isPosix && info.isa != ISA.webAssembly)
    {
        import redub.misc.make_file_executable;
        string execPath = buildNormalizedPath(inDir, getOutputName(data.cfg, os));
        if(!makeFileExecutable(execPath))
            throw new Exception("Could not make the output file as executable "~execPath);
    }
    copyDir(inDir, data.cfg.outputDirectory);

    return ret;
}


bool executeCommandsAndPrint(BuildRequirements req, RedubCommands phase, const string[string] env)
{
    import std.conv:to;
    CompilationResult res;
    if(executeCommands(req.cfg, phase, res, env).status)
    {
        errorTitle(phase.to!string~" Error ", "for ",req.name,": ", res.message);
        return false;
    }
    else if(res.message.length)
        info(res.message);
    return true;
}

private bool pluginDataChanged(RedubPluginData a, RedubPluginData b)
{
    import std.algorithm.comparison : equal;
    static foreach(member; __traits(allMembers, RedubPluginData))
    {
        if(!equal(__traits(getMember, a, member), __traits(getMember, b, member)))
            return true;
    }
    return false;
}

bool executePostGeneratePlugins(ProjectNode root)
{
    import redub.plugin.load : PluginPhase, executePlugins;

    foreach(node; root.collapse)
    {
        BuildConfiguration before = node.requirements.cfg;
        if(!before.postGeneratePlugins.length)
            continue;

        try
        {
            BuildConfiguration after = executePlugins(PluginPhase.postGenerate, before, before.postGeneratePlugins);
            if(pluginDataChanged(before.toRedubPluginData, after.toRedubPluginData))
                node.requirements.cfg = after;
        }
        catch(Throwable e)
        {
            errorTitle("postGenerate Plugin Error ", "for ", node.name, ": ", e.msg);
            return false;
        }
    }
    return true;
}


private bool canPersistCacheNow(const ProjectNode node)
{
    return !node.requirements.cfg.targetType.isLinkedSeparately || !node.isRoot;
}

bool buildProjectParallelSimple(ProjectDetails details, CompilationInfo s, const(AdvCacheFormula)* existingSharedFormula, AdvCacheFormula* preprocessed)
{
    import std.concurrency;
    ProjectNode root = details.tree;
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);
    bool[ProjectNode] spawned;
    string[string] env = getCurrentEnv();
    size_t execID = buildExecutions++;

    AdvCacheFormula formulaCache = preprocessed !is null ? *preprocessed : AdvCacheFormula.init;

    printCachedBuildInfo(root);
    while(true)
    {
        bool spawnedThisIteration;
        foreach(dep; dependencyFreePackages)
        {
            if(!(dep in spawned))
            {
                if(!executeCommandsAndPrint(dep.requirements, RedubCommands.postGenerate, env))
                {
                    saveBuiltPackages(finishedBuilds, mainPackHash, s, &formulaCache, existingSharedFormula);
                    killRunningProcesses();
                    return false;
                }
                if(dep.shouldEnterCompilationThread)
                {
                    spawned[dep] = true;
                    spawnedThisIteration = true;
                    spawn(&execCompilationThread,
                        dep.requirements.buildData(false, s, getEnvForProject(dep, env)), cast(shared)dep,
                        s, HashPair(mainPackHash, hashFrom(dep.requirements, s)),
                        execID
                    );
                }
                else
                    dep.becomeIndependent();
            }
        }

        ///Everything was already up to date: no worker will send a message, so just
        ///continue walking the tree instead of blocking in receiveOnly.
        if(!spawnedThisIteration)
        {
            dependencyFreePackages = root.findLeavesNodes();
            if(root.dependencies.length == 0 || dependencyFreePackages.length == 0)
                break;
            continue;
        }

        auto info = receiveOnly!(CompilationID, ProcessInfo, CompilationResult);
        if(info[0].id != execID)
            continue;
        if(info[1] != ProcessInfo.init)
        {
            runningProcesses[info[1].pid] = info[1].running;
            continue;
        }
        auto res = info[2];
        runningProcesses[res.pid] = false;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            buildFailed(finishedPackage, res, s, finishedBuilds, mainPackHash, &formulaCache, existingSharedFormula);
            return false;
        }
        else
        {
            if(!finishedPackage.isUpToDate)
                buildSucceeded(finishedPackage, res);
            finishedBuilds~= finishedPackage;
            finishedPackage.becomeIndependent();
            dependencyFreePackages = root.findLeavesNodes();

            if(canPersistCacheNow(finishedPackage))
            {
                string reqCache = hashFrom(finishedPackage.requirements, s);
                updateCache(mainPackHash, CompilationCache.make(reqCache, mainPackHash, finishedPackage.requirements, s, existingSharedFormula, &formulaCache));
            }
            if(finishedPackage is root)
                break;
        }
    }
    if(root.requirements.cfg.syntaxOnly)
        return true;
    return doLink(details, s, mainPackHash, &formulaCache, env, existingSharedFormula) && copyFiles(root);
}




private void killRunningProcesses()
{
    foreach(v, isRunning; runningProcesses)
    {
        if(isRunning)
        {
            Pid p = cast()v;
            try
            {
                version(Posix)
                {
                    if(cast(size_t)p.osHandle != -2 && cast(size_t)p.osHandle != -1)
                        kill(p);
                }
                else version(Windows)
                {
                    import core.sys.windows.winbase:INVALID_HANDLE_VALUE;
                    if(p.osHandle != INVALID_HANDLE_VALUE)
                        kill(p);
                }
            }
            catch(ProcessException e){} //Nothing to do here. All it matters is closing the processes
            //Terminated or invalid
        }
    }
    runningProcesses.clear();
}
bool buildProjectFullyParallelized(ProjectDetails details, CompilationInfo s, const(AdvCacheFormula)* existingSharedFormula, AdvCacheFormula* preprocessed)
{
    import std.concurrency;
    ProjectNode[] finishedBuilds;
    ProjectNode root = details.tree;
    string[string] env = getCurrentEnv();

    size_t i = 0;
    size_t sentPackages = 0;
    size_t processedPackages = 0;
    size_t execID = buildExecutions++;
    ProjectNode priority = root.findPriorityNode();
    ///All packages must generate their files before any compilation starts; that way a
    ///postGenerate failure aborts before any work is spawned and nothing needs to be killed.
    foreach(ProjectNode pack; root.collapse)
    {
        if(!executeCommandsAndPrint(pack.requirements, RedubCommands.postGenerate, env))
            return false;
    }
    string mainPackHash = hashFrom(root.requirements, s);
    foreach(ProjectNode pack; root.collapse)
    {
        if(pack.shouldEnterCompilationThread)
        {
            sentPackages++;
            spawn(&execCompilationThread,
                pack.requirements.buildData(pack is priority, s, getEnvForProject(pack, env)),
                cast(shared)pack,
                s,
                HashPair(mainPackHash, hashFrom(pack.requirements, s)),
                execID
            );
        }
        i++;
    }
    printCachedBuildInfo(root);
    AdvCacheFormula formulaCache = preprocessed !is null ? *preprocessed : AdvCacheFormula.init;

    ProjectNode failedPackage;
    CompilationResult failedRes;

    for(int _ = 0; _ < sentPackages; _++)
    {
        auto info = receiveOnly!(CompilationID, ProcessInfo, CompilationResult);
        ///Workaround on not actually killing threads when build fail and using redub as a library.
        if(info[0].id != execID)
        {
            _--;
            continue;
        }
        if(info[1] != ProcessInfo.init)
        {
            runningProcesses[info[1].pid] = info[1].running;
            _--;
            continue;
        }
        processedPackages++;
        auto res = info[2];
        runningProcesses[res.pid] = false;
        ProjectNode finishedPackage = cast()res.node;

        if(res.status)
        {
            if(!failedPackage)
            {
                failedPackage = finishedPackage;
                failedRes = res;
                if(failedPackage is priority)
                {
                    killRunningProcesses();
                    break;
                }
            }
        }
        else
        {
            buildSucceeded(finishedPackage, res);
            finishedBuilds~= finishedPackage;

            if(canPersistCacheNow(finishedPackage))
            {
                string reqHash = hashFrom(finishedPackage.requirements, s);
                updateCache(mainPackHash, CompilationCache.make(reqHash, mainPackHash, finishedPackage.requirements, s, existingSharedFormula, &formulaCache));
            }
        }
    }

    //TODO: What happens if the root builds first and the dependency fails? It will skip everything and just try running the .exe
    //TODO: What happens if a higher dependency finished first than a lower one? It may simply skip the lower since the parent has already finished.
    if(failedPackage)
    {
        killRunningProcesses();
        ///Packages that finished before the abort still have their result waiting in the mailbox.
        ///Record them so their cache is persisted instead of being rebuilt on the next run.
        for(int count = 0; count < sentPackages - processedPackages; count++)
        {
            auto info = receiveOnly!(CompilationID, ProcessInfo, CompilationResult);
            if(info[0].id != execID || info[1] != ProcessInfo.init)
            {
                count--;
                continue;
            }
            auto res = info[2];
            runningProcesses[res.pid] = false;
            if(res.status == 0)
            {
                ProjectNode done = cast()res.node;
                finishedBuilds ~= done;
                if(canPersistCacheNow(done))
                {
                    string reqHash = hashFrom(done.requirements, s);
                    updateCache(mainPackHash, CompilationCache.make(reqHash, mainPackHash, done.requirements, s, existingSharedFormula, &formulaCache));
                }
            }
        }
        buildFailed(failedPackage, failedRes, s, finishedBuilds, mainPackHash, &formulaCache, existingSharedFormula);
        return false;
    }
    if(root.requirements.cfg.syntaxOnly)
        return true;
    return doLink(details, s, mainPackHash, &formulaCache, env, existingSharedFormula) && copyFiles(root);
}

/**
 * When wanting to do a single thread build, this function must be called.
 * This function is also used when the project has no dependency.
 * Params:
 *   root = What is the project to build
 *   s = Compiling session including compiler, OS and ISA
 *   existingSharedFormula = Reuses the hash of existing calculations if files haven't changed
 * Returns: Has succeeded
 */
bool buildProjectSingleThread(ProjectDetails details, CompilationInfo s, const(AdvCacheFormula)* existingSharedFormula, AdvCacheFormula* preprocessed)
{
    ProjectNode root = details.tree;
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);
    string[string] env = getCurrentEnv();
    AdvCacheFormula formulaCache = preprocessed !is null ? *preprocessed : AdvCacheFormula.init;
    bool linkedInObjectBuild;

    printCachedBuildInfo(root);
    while(true)
    {
        ProjectNode finishedPackage;
        foreach(dep; dependencyFreePackages)
        {
            if(!executeCommandsAndPrint(dep.requirements, RedubCommands.postGenerate, env))
            {
                saveBuiltPackages(finishedBuilds, mainPackHash, s, &formulaCache, existingSharedFormula);
                return false;
            }
            if(dep.shouldEnterCompilationThread)
            {
                CompilationResult res;
                if(details.parallelType != ParallelType.no
                    && dep is root && canUseRootObjectStrategy(dep, s) && canUseRootObjects(dep, s))
                {
                    RootObjectResult obj = buildRootObjects(dep, s, mainPackHash,
                        getEnvForProject(dep, env));
                    if(obj.notApplicable)
                        res = execCompilation(dep.requirements.buildData(true, s, getEnvForProject(dep, env)), cast(shared)dep,
                            s,
                            HashPair(mainPackHash, hashFrom(dep.requirements, s)), Tid.init, 0
                        );
                    else
                    {
                        res.status = obj.status;
                        res.message = obj.message;
                        res.compilationCommand = obj.command;
                        res.msNeeded = obj.msNeeded;
                        res.linkedInCompilation = obj.status == 0;
                        res.node = cast(shared)dep;
                        linkedInObjectBuild = obj.status == 0;
                    }
                }
                else
                    res = execCompilation(dep.requirements.buildData(true, s, getEnvForProject(dep, env)), cast(shared)dep,
                        s,
                        HashPair(mainPackHash, hashFrom(dep.requirements, s)), Tid.init, 0
                    );
                if(res.status)
                {
                    buildFailed(dep, res, s, finishedBuilds, mainPackHash, &formulaCache, existingSharedFormula);
                    return false;
                }
                else
                {
                    if(dep is root && !linkedInObjectBuild && res.linkedInCompilation
                        && dep.requirements.cfg.buildStats)
                        recordBuildTiming(mainPackHash, TimingStrategy.single, false,
                            dep.requirements.cfg.buildStrategy == BuildStrategy.incrementalOnce,
                            1, 0, 0, cast(uint)res.msNeeded);
                    finishedBuilds~= dep;
                    buildSucceeded(dep, res);
                }
            }
            if(!dep.isUpToDate && canPersistCacheNow(dep))
            {
                string reqHash = hashFrom(dep.requirements, s);
                updateCache(mainPackHash, CompilationCache.make(reqHash, mainPackHash, dep.requirements, s, existingSharedFormula, &formulaCache));
            }
            finishedPackage = dep;
            finishedPackage.becomeIndependent();
            dependencyFreePackages = root.findLeavesNodes();
        }
        if(finishedPackage is root)
            break;
    }
    runningProcesses.clear();
    if(root.requirements.cfg.syntaxOnly)
        return true;
    return doLink(details, s, mainPackHash, &formulaCache, env, existingSharedFormula,
        linkedInObjectBuild) && copyFiles(root);
}

private void printCachedBuildInfo(ProjectNode root)
{
    string upToDate;
    string copyEnough;
    string willBuild;
    size_t upToDateCount = 0;
    foreach(ProjectNode node; root.collapse)
        if(node.isUpToDate) upToDateCount++;

    if(upToDateCount != root.collapse.length)
    {
        foreach(ProjectNode node; root.collapse)
        {
            string cfg = node.requirements.targetConfiguration ? (" ["~node.requirements.targetConfiguration~"]") : null;
            cfg = node.name~ cfg~"; ";

            if(node.isCopyEnough)
                copyEnough~= cfg;
            else if(node.isUpToDate)
                upToDate~= cfg;
            else if(node.shouldEnterCompilationThread)
                willBuild~= cfg;
        }
        if(copyEnough.length)
            infos("Copy Enough: ", copyEnough);
        if(upToDate.length)
            infos("Up-to-Date: ", upToDate);
        if(willBuild.length)
            infos("Will Build: ", willBuild);
    }
}


private void buildSucceeded(ProjectNode node, CompilationResult res)
{
    if(!node.isCopyEnough)
    {
        import std.string:stripRight;
        string cfg = node.requirements.targetConfiguration ? (" ["~node.requirements.targetConfiguration~"]") : null;
        string ver = node.requirements.version_.length ? (" "~node.requirements.version_) : null;

        if(res.linkedInCompilation)
            infos("Built+Linked: ", node.name, ver, cfg, " - ", res.msNeeded, "ms");
        else
            infos("Built: ", node.name, ver, cfg, " - ", res.msNeeded, "ms");
        if(res.message.length)
            info(res.message.stripRight);
        vlog("\n\t", res.compilationCommand, " \n");
    }

}
private void buildFailed(const ProjectNode node, CompilationResult res, CompilationInfo s,
    ProjectNode[] finishedPackages, string mainPackHash, AdvCacheFormula* formulaCache,
    const(AdvCacheFormula)* existingSharedFormula
)
{
    import redub.misc.github_tag_check;
    import std.conv:to;
    string msg = res.message ? " with message\n\t" ~res.message : null;

    errorTitle("Build Failure: ", "'", node.name, "' ",node.requirements.version_," [", node.requirements.targetConfiguration,"]' \n\t",
        RedubVersionShort, "\n\t", node.getCompiler(s.compiler).getCompilerWithVersion, "\n\tFailed with flags: \n\n\t",
        res.compilationCommand,
        "\nStatus '"~res.status.to!string~"' after ", res.msNeeded,"ms "~msg
    );
    import redub.error_driver;
    string workaround = getLinkerWorkaround(res.message);
    if(workaround.length)
        errorTitle("Linker Workaround: ", workaround);
    showNewerVersionMessage();
    ///It can save anything, except the root project as it would make it up to date while it actually requires the .lib files to be up to date.
    saveBuiltPackages(finishedPackages, mainPackHash, s, formulaCache, existingSharedFormula);
}


private bool copyFiles(ProjectNode root)
{
    static import std.file;
    import redub.misc.hard_link;
    import std.path;
    string outputDir = root.requirements.cfg.outputDirectory;
    auto globDirEntries(string glob)
    {
        import std.file:dirEntries, SpanMode;
        import std.path : dirName, baseName;
        string dir = dirName(glob);
        return dirEntries(dir.length ? dir : ".", baseName(glob), SpanMode.depth);
    }

    foreach(ProjectNode proj; root.collapse)
    {
        string[] files = proj.requirements.cfg.filesToCopy;
        if(files.length)
        {
            info("\tCopying files for project ", proj.name);
            foreach(filesSpec; files) foreach(e; globDirEntries(filesSpec))
            {
                string f = e.name;
                string inputPath;
                string outputPath;
                if(isAbsolute(f))
                {
                    inputPath = buildNormalizedPath(f);
                    outputPath = buildNormalizedPath(outputDir, f.baseName);
                }
                else
                {
                    inputPath = buildNormalizedPath(proj.requirements.cfg.workingDir, f);
                    outputPath = buildNormalizedPath(outputDir, f);
                }
                vlog("\t\tCopying ", inputPath, " to ", outputPath);

                if(!hardLink(inputPath, outputPath, true))
                {
                    error("Could not copy file ", inputPath);
                    return false;
                }
            }
        }
    }

    import std.string : indexOf;
    const cfg = root.requirements.cfg;
    if(cfg.arch.indexOf("wasm") != -1 && cfg.arch.indexOf("emscripten") == -1)
    {
        import std.file : exists, mkdirRecurse, read, write;
        import std.path : baseName;
        bool providedByRecipe;
        foreach(f; cfg.filesToCopy)
            if(baseName(f) == "env.js")
            {
                providedByRecipe = true;
                break;
            }
        if(!providedByRecipe)
        {
            string srcEnv = buildNormalizedPath(cfg.workingDir, "env.js");
            string outEnv = buildNormalizedPath(outputDir, "env.js");
            if(!exists(srcEnv))
            {
                if(exists(outEnv))
                {
                    write(srcEnv, read(outEnv));
                    info("\tKept ", outEnv, " in the project as ", srcEnv);
                }
                else
                {
                    write(srcEnv, defaultEnvJs);
                    info("\tCreated ", srcEnv, " with the JS import template");
                }
            }
            mkdirRecurse(outputDir);
            write(outEnv, read(srcEnv));
        }
    }
    return true;
}

/**
 *
 * Params:
 *   node = The node in which it will build new environment variables
 *   currEnv = The current environment before building it
 * Returns: A new associative array containing environment variables for the node
 */
immutable(string[string]) getEnvForProject(const ProjectNode node, const string[string] currEnv)
{
    import redub.parsers.environment;
    PackageDubVariables vars = getEnvironmentVariablesForPackage(node.requirements.cfg);
    string[string] env = cast(string[string])currEnv.dup;
    static foreach(mem; __traits(allMembers, PackageDubVariables))
        env[mem] = __traits(getMember, vars, mem);
    return cast(immutable)env;

}

///Saves what was built without ever saving the root, whose artifact can't be trusted after a failure.
private void saveBuiltPackages(Range)(Range builtPackages, string mainPackHash, CompilationInfo s, AdvCacheFormula* formulaCache, const(AdvCacheFormula)* existingSharedFormula)
{
    import std.algorithm.iteration : filter;
    saveFinishedBuilds(filter!((ProjectNode n) => !n.isRoot)(builtPackages), mainPackHash, s, formulaCache, existingSharedFormula);
}

private void saveFinishedBuilds(ProjNodeRange)(ProjNodeRange finishedProjects, string mainPackHash, CompilationInfo s, AdvCacheFormula* formulaCache, const(AdvCacheFormula)* existingSharedFormula)
{
    import std.datetime.stopwatch;
    AdvCacheFormula cache;
    if(formulaCache != null)
        cache = *formulaCache;
    StopWatch formulaSw = StopWatch(AutoStart.yes);
    foreach(ProjectNode node; finishedProjects)
    {
        bool hasAlreadyWrittenInCache = formulaCache != null && canPersistCacheNow(node);
        // bool hasAlreadyWrittenInCache = false;
        if(!node.isUpToDate && !hasAlreadyWrittenInCache)
        {
            updateCache(mainPackHash, CompilationCache.make(hashFrom(node.requirements, s), mainPackHash, node.requirements, s, existingSharedFormula, &cache));
        }
    }
    auto formulaMs = formulaSw.peek.total!"msecs";
    StopWatch writeSw = StopWatch(AutoStart.yes);
    updateCacheOnDisk(mainPackHash, &cache, existingSharedFormula);
    vvlog("Cache formulas: ", formulaMs, "ms; cache write: ", writeSw.peek.total!"msecs", "ms");

    ///TODO: Start comparing current build time with the last one
}

private bool doLink(ProjectDetails details, CompilationInfo info, string mainPackHash,
    AdvCacheFormula* formulaCache = null, const string[string] env = null,
    const(AdvCacheFormula)* existingSharedFormula, bool linkedAlready = false)
{
    ProjectNode root = details.tree;
    Compiler compiler = info.compiler;
    bool isUpToDate = root.isUpToDate;
    bool shouldSkipLinking = linkedAlready || isUpToDate
        || (!root.requirements.cfg.targetType.isLinkedSeparately) || canBuildInSingleCall(root, info);
    const string[string] targetEnv = getEnvForProject(root, env ? env : cast(const)getCurrentEnv());

    if(!shouldSkipLinking)
    {
        CompilationResult linkRes;

        auto result = timed(() {
            linkRes = link(root, mainPackHash, root.requirements.buildData(true, info, targetEnv), info);
            return true;
        });

        if(linkRes.status)
        {
            import redub.misc.github_tag_check;
            import redub.error_driver;
            import redub.libs.colorize;
            errorTitle("Linking Error ", "at \"", root.name.color(fg.light_red), "\". \n\t"~ RedubVersionShort~ "\n\t" ~ root.getCompiler(compiler).getCompilerWithVersion ~ "\n\tFailed with flags: \n\n\t",
                linkRes.compilationCommand,"\n\t\t  :\n\t",
                linkRes.message,
            );
            version(Windows)
            {
                string workaround = getLinkerWorkaround(linkRes.message);
                if(workaround.length)
                    redub.logging.errorTitle("Redub Linker Error Help Message: ", workaround);

                ModuleParsing modules = getModulesDependencies(details);
                if(modules !is null)
                {
                    string explanation = getUndefinedSymbolExplanationMSVC(modules, linkRes.message);
                    if(explanation.length)
                        redub.logging.errorTitle("Redub Linker Error Help Message: ", explanation);
                }
            }

            showNewerVersionMessage();
            ///Keep the packages that compiled successfully, but never the root: after a
            ///link failure its artifact is stale/missing and it must be rebuilt.
            saveBuiltPackages(root.collapse, mainPackHash, info, formulaCache, existingSharedFormula);
            return false;
        }
        else
        {
            import std.string:stripRight;
            if(linkRes.message.length)
                redub.logging.info(linkRes.message.stripRight);
            infos("Linked: ", root.name, " - ", result.msecs, "ms");
            vlog("\n\t", linkRes.compilationCommand, " \n");

            if(root.requirements.cfg.targetType.isLinkedSeparately)
            {
                if(!executeCommandsAndPrint(root.requirements, RedubCommands.postBuild, targetEnv))
                    return false;
            }
        }
    }
    ///Try copying if it already exists, this operation is fast anyway for up to date builds.
    else if(root.isCopyEnough)
    {
        import redub.command_generators.commons;
        import std.path;
        string inDir = getCacheOutputDir(mainPackHash, cast()root.requirements, info);
        string outDir = getConfigurationOutputPath(root.requirements.cfg, os);
        copyDir(inDir, dirName(outDir));
    }
    else if(!isUpToDate && (linkedAlready || canBuildInSingleCall(root, info)))
    {
        if(!executeCommandsAndPrint(root.requirements, RedubCommands.postBuild, targetEnv))
            return false;
    }

    if(isUpToDate)
        infos("Up-to-Date: ", root.name, ", skipping linking");
    else
    {
        auto result = timed(()
        {
            saveFinishedBuilds(root.collapse, mainPackHash, info, formulaCache, existingSharedFormula);
            return true;
        });
        ///Ignore that message if it is not relevant enough [more than 5 ms]
        if(result.msecs > 5)
            redub.logging.info("Wrote cache in ", result.msecs, "ms");

    }

    return true;
}