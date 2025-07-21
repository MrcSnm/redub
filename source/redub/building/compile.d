module redub.building.compile;
import redub.building.utils;
import redub.building.cache;
import redub.logging;
import redub.buildapi;
import std.system;
import redub.compiler_identification;
import redub.command_generators.automatic;
import std.process:Pid;
import std.concurrency:Tid;

/** 
 * When using redub as a library, one may spawn multiple times the same package, having a bug on it.
 * The problem is that although it returns to execution, the threads aren't actually killed!
 * To solve that problem, finishedPackages will only ever add to it if the buildExecutions id is the same.
 */
size_t buildExecutions;
/** 
 * Saves which PIDs are currently running. Used whenever some process fails and kills all of them.
 */
bool[shared Pid] runningProcesses;

struct CompilationResult
{
    string compilationCommand;
    string message;
    size_t msNeeded;
    int status;
    shared ProjectNode node;
    shared Pid pid;
    size_t id;
}

struct ProcessInfo
{
    shared Pid pid;
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
*   If any command has status, it will stop executing them and return
*/
private ExecutionResult executeCommands(const(string[])[] commands, RedubCommands list, ref CompilationResult res, string workingDir, immutable string[string] env)
{
    import std.process;
    const string[] commandsList = commands.length > list ? commands[list] : null;
    foreach(cmd; commandsList)
    {
        auto execRes  = cast(ExecutionResult)executeShell(cmd, env, Config.none, size_t.max, workingDir);
        if(execRes.status)
        {
            import std.conv:to;
            res.status = execRes.status;
            res.message = "Result of "~list.to!string~" command '"~cmd~"' "~execRes.output;
            return execRes;
        }
    }
    return ExecutionResult(0, "Success");
}

void execCompilationThread(immutable ThreadBuildData data, shared ProjectNode pack, CompilingSession info, HashPair hash, immutable string[string] env, size_t id)
{
    import std.concurrency;
    Tid owner = ownerTid;
    CompilationResult res = execCompilation(data, pack, info, hash, env, owner);
    res.id = id;
    scope(exit)
    {
        owner.send(ProcessInfo.init, res);
    }
}

CompilationResult execCompilation(immutable ThreadBuildData data, shared ProjectNode pack, CompilingSession info, HashPair hash, immutable string[string] env, Tid owner)
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
        OS os = info.os;
        ISA isa = info.isa;
        //Remove existing binary, since it won't be replaced by simply executing commands
        string outDir = getConfigurationOutputPath(cfg, os);
        if(exists(outDir))
            remove(outDir);
        
        if(executeCommands(cfg.commands, RedubCommands.preBuild, res, cfg.workingDir, env).status)
            return res;

        import redub.plugin.load;

        foreach(plugin; cfg.preBuildPlugins)
        {
            cfg = executePlugin(plugin.name, cfg, plugin.args);
        }


        if(pack.requirements.cfg.targetType != TargetType.none)
        {
            import std.path;
            string inDir = getCacheOutputDir(hash.rootHash, cast()pack.requirements, info);
            mkdirRecurse(inDir);
            createOutputDirFolder(cfg);

            ExecutionResult ret;
            if(!pack.isCopyEnough)
            {
                import std.concurrency;
                string cmdFile;
                ProcessExec2 ex = execCompiler(cfg, compiler, getCompilationFlags(cfg, info, hash.rootHash, data.extra.isRoot), res.compilationCommand, data.isLeaf, cmdFile);
                scope(exit)
                {
                    if(cmdFile)
                        std.file.remove(cmdFile);
                }
                res.pid = cast(shared)ex.pipe.pid;
                if(owner != Tid.init)
                    owner.send(ProcessInfo(res.pid), CompilationResult.init);
                ret = cast(ExecutionResult)finishCompilerExec(cfg, compiler, inDir, outDir, ex);
            }

            if(!isDCompiler(c) && !ret.status && isStaticLibrary(data.cfg.targetType)) //Must call archiver when
            {
                string cmd ;
                auto archiverRes = executeArchiver(data, info, hash.rootHash, cmd);
                ret.status = archiverRes.status;
                ret.output~= archiverRes.output;
                res.compilationCommand~= "\n\nArchiving: \n\t"~cmd;
            }

            copyDir(inDir, dirName(outDir));

            ///Shared Library(mostly?)
            if(isDCompiler(c) && isLinkedSeparately(data.cfg.targetType) && !pack.isRoot)
            {
                CompilationResult linkRes = link(cast()pack, hash.requirementHash, data, info, env);
                ret.status = linkRes.status;
                ret.output~= linkRes.message;
                res.compilationCommand~= "\n\nLinking: \n\t"~ linkRes.compilationCommand;
            }
            res.status = ret.status;
            res.message = ret.output;
        }


        if(res.status == 0)
        {
            if(!cfg.targetType.isLinkedSeparately && executeCommands(cfg.commands, RedubCommands.postBuild, res, cfg.workingDir, env).status)
                return res;
            if(!cfg.targetType.isLinkedSeparately && executeCommands(cfg.commands, RedubCommands.postGenerate, res, cfg.workingDir, env).status)
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

bool makeFileExecutable(string filePath)
{
	version(Windows) return true;
	version(Posix)
	{
        import std.file;
		if(!std.file.exists(filePath)) return false;
		import std.conv:octal;
		std.file.setAttributes(filePath, octal!700);
		return true;
	}
}

CompilationResult link(ProjectNode root, string rootHash, const ThreadBuildData data, CompilingSession info, immutable string[string] env)
{
    import std.process;
    import std.file;
    import redub.command_generators.commons;
    OS os = info.os;

    CompilationResult ret;
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
        string execPath = buildNormalizedPath(inDir, getOutputName(data.cfg, os));
        if(!makeFileExecutable(execPath))
            throw new Exception("Could not make the output file as executable "~execPath);
    }
    copyDir(inDir, data.cfg.outputDirectory);



    if(data.cfg.targetType.isLinkedSeparately)
    {
        if(executeCommands(data.cfg.commands, RedubCommands.postBuild, ret, data.cfg.workingDir, env).status)
            return ret;
        if(executeCommands(data.cfg.commands, RedubCommands.postGenerate, ret, data.cfg.workingDir, env).status)
            return ret;
    }

    return ret;
}


bool buildProjectParallelSimple(ProjectNode root, CompilingSession s, const(AdvCacheFormula)* existingSharedFormula)
{
    import std.concurrency;
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);
    bool[ProjectNode] spawned;
    string[string] env = getCurrentEnv();

    AdvCacheFormula formulaCache;

    printCachedBuildInfo(root);
    while(true)
    {
        foreach(dep; dependencyFreePackages)
        {
            if(!(dep in spawned))
            {
                if(dep.shouldEnterCompilationThread)
                {
                    spawned[dep] = true;
                    spawn(&execCompilationThread,
                        dep.requirements.buildData(false), cast(shared)dep, 
                        s, HashPair(mainPackHash, hashFrom(dep.requirements, s)),
                        getEnvForProject(dep, env),
                        0
                    );
                }
                else
                    dep.becomeIndependent();
            }
        }
        auto info = receiveOnly!(ProcessInfo, CompilationResult);
        if(info[0] != ProcessInfo.init)
        {
            runningProcesses[info[0].pid] = true;
            continue;
        }
        auto res = info[1];
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

            if(!finishedPackage.requirements.cfg.targetType.isLinkedSeparately)
            {
                string reqCache = hashFrom(finishedPackage.requirements, s);
                updateCache(mainPackHash, CompilationCache.make(reqCache, mainPackHash, finishedPackage.requirements, s, existingSharedFormula, &formulaCache));
            }
            if(finishedPackage is root)
                break;
        }
    }
    return doLink(root, s, mainPackHash, &formulaCache, env, existingSharedFormula) && copyFiles(root);
}


bool buildProjectFullyParallelized(ProjectNode root, CompilingSession s, const(AdvCacheFormula)* existingSharedFormula)
{
    import std.concurrency;
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);
    string[string] env = getCurrentEnv();

    size_t i = 0;
    size_t sentPackages = 0;
    size_t execID = buildExecutions++;
    ProjectNode priority = root.findPriorityNode();
    foreach(ProjectNode pack; root.collapse)
    {
        if(pack.shouldEnterCompilationThread)
        {
            sentPackages++;
            spawn(&execCompilationThread,
                pack.requirements.buildData(pack is priority),
                cast(shared)pack, 
                s,
                HashPair(mainPackHash, hashFrom(pack.requirements, s)),
                getEnvForProject(pack, env),
                execID
            );
        }
        i++;
    }
    printCachedBuildInfo(root);
    AdvCacheFormula formulaCache;

    ProjectNode failedPackage;
    CompilationResult failedRes;

    for(int _ = 0; _ < sentPackages; _++)
    {
        auto info = receiveOnly!(ProcessInfo, CompilationResult);
        if(info[0] != ProcessInfo.init)
        {
            runningProcesses[info[0].pid] = true;
            _--;
            continue;
        }
        auto res = info[1];
        runningProcesses[res.pid] = false;
        ///Workaround on not actually killing threads when build fail and using redub as a library.
        if(res.id != execID)
        {
            _--;
            continue;
        }
        ProjectNode finishedPackage = cast()res.node;

        if(res.status && !failedPackage)
        {
            failedPackage = finishedPackage;
            failedRes = res;
            if(failedPackage is priority)
            {
                foreach(v, isRunning; runningProcesses)
                {
                    if(isRunning)
                        kill(cast()v);
                }
                break;
            }
        }
        else
        {
            buildSucceeded(finishedPackage, res);
            finishedBuilds~= finishedPackage;

            if(!finishedPackage.requirements.cfg.targetType.isLinkedSeparately)
            {
                string reqHash = hashFrom(finishedPackage.requirements, s);
                updateCache(mainPackHash, CompilationCache.make(reqHash, mainPackHash, finishedPackage.requirements, s, existingSharedFormula, &formulaCache));
            }
        }
    }
    runningProcesses.clear();
    if(failedPackage)
    {
        import core.thread;
        buildFailed(failedPackage, failedRes, s, finishedBuilds, mainPackHash, &formulaCache, existingSharedFormula);
        thread_joinAll();
        return false;
    }
    return doLink(root, s, mainPackHash, &formulaCache, env, existingSharedFormula) && copyFiles(root);
}

/** 
 * When wanting to do a single thread build, this function must be called.
 * This function is also used when the project has no dependency.
 * Params:
 *   root = What is the project to build
 *   compiler = Which compiler
 *   os = Which OS
 * Returns: Has succeeded
 */
bool buildProjectSingleThread(ProjectNode root, CompilingSession s, const(AdvCacheFormula)* existingSharedFormula)
{
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);
    string[string] env = getCurrentEnv();


    printCachedBuildInfo(root);
    while(true)
    {
        ProjectNode finishedPackage;
        foreach(dep; dependencyFreePackages)
        {
            if(dep.shouldEnterCompilationThread)
            {
                CompilationResult res = execCompilation(dep.requirements.buildData(true), cast(shared)dep, 
                    s,
                    HashPair(mainPackHash, hashFrom(dep.requirements, s)), getEnvForProject(dep, env), Tid.init
                );
                if(res.status)
                {
                    buildFailed(dep, res, s, finishedBuilds, mainPackHash, null, existingSharedFormula);
                    return false;
                }
                else
                {
                    finishedBuilds~= dep;
                    buildSucceeded(dep, res);
                }
            }
            finishedPackage = dep;
            finishedPackage.becomeIndependent();
            dependencyFreePackages = root.findLeavesNodes();
        }
        if(finishedPackage is root)
            break;
    }
    runningProcesses.clear();
    return doLink(root, s, mainPackHash, null, env, existingSharedFormula) && copyFiles(root);
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
            else
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
        string cfg = node.requirements.targetConfiguration ? (" ["~node.requirements.targetConfiguration~"]") : null;
        string ver = node.requirements.version_.length ? (" "~node.requirements.version_) : null;

        infos("Built: ", node.name, ver, cfg, " - ", res.msNeeded, "ms");
        vlog("\n\t", res.compilationCommand, " \n");
    }

}
private void buildFailed(const ProjectNode node, CompilationResult res, CompilingSession s,
    ProjectNode[] finishedPackages, string mainPackHash, AdvCacheFormula* formulaCache,
    const(AdvCacheFormula)* existingSharedFormula
)
{
    import redub.misc.github_tag_check;
    errorTitle("Build Failure: '", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"]' \n\t",
        RedubVersionShort, "\n\t", node.getCompiler(s.compiler).getCompilerWithVersion, "\n\tFailed with flags: \n\n\t",
        res.compilationCommand, 
        "\nFailed after ", res.msNeeded,"ms with message\n\t", res.message
    );
    showNewerVersionMessage();
    saveFinishedBuilds(finishedPackages, mainPackHash, s, formulaCache, existingSharedFormula);
}


private bool copyFiles(ProjectNode root)
{
    static import std.file;
    import redub.misc.hard_link;
    import redub.misc.glob_entries;
    import std.path;
    string outputDir = root.requirements.cfg.outputDirectory;
    foreach(ProjectNode proj; root.collapse)
    {
        string[] files = proj.requirements.cfg.filesToCopy;
        if(files.length)
        {
            info("\tCopying files for project ", proj.name);
            foreach(filesSpec; files) foreach(e; globDirEntriesShallow(filesSpec))
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

private void saveFinishedBuilds(ProjNodeRange)(ProjNodeRange finishedProjects, string mainPackHash, CompilingSession s, AdvCacheFormula* formulaCache, const(AdvCacheFormula)* existingSharedFormula)
{
    AdvCacheFormula cache;
    if(formulaCache != null)
        cache = *formulaCache;
    foreach(ProjectNode node; finishedProjects)
    {
        bool hasAlreadyWrittenInCache = formulaCache != null && !node.requirements.cfg.targetType.isLinkedSeparately;
        // bool hasAlreadyWrittenInCache = false;
        if(!node.isUpToDate && !hasAlreadyWrittenInCache)
        {
            updateCache(mainPackHash, CompilationCache.make(hashFrom(node.requirements, s), mainPackHash, node.requirements, s, existingSharedFormula, &cache));
        }
    }
    updateCacheOnDisk(mainPackHash, &cache, existingSharedFormula);

    ///TODO: Start comparing current build time with the last one
}

private bool doLink(ProjectNode root, CompilingSession info, string mainPackHash, AdvCacheFormula* formulaCache = null, const string[string] env = null, const(AdvCacheFormula)* existingSharedFormula)
{
    Compiler compiler = info.compiler;
    bool isUpToDate = root.isUpToDate;
    bool shouldSkipLinking = isUpToDate || (root.getCompiler(info.compiler).isDCompiler && !root.requirements.cfg.targetType.isLinkedSeparately);

    if(!shouldSkipLinking)
    {
        CompilationResult linkRes;
        auto result = timed(() {
             linkRes = link(root, mainPackHash, root.requirements.buildData(true), info, getEnvForProject(root, env ? env : cast(const)getCurrentEnv()));
             return true;
        });
        if(linkRes.status)
        {
            import redub.misc.github_tag_check;
            import redub.libs.colorize;
            errorTitle("Linking Error ", "at \"", root.name.color(fg.light_red), "\". \n\t"~ RedubVersionShort~ "\n\t" ~ root.getCompiler(compiler).getCompilerWithVersion ~ "\n\tFailed with flags: \n\n\t",
                linkRes.compilationCommand,"\n\t\t  :\n\t",
                linkRes.message,
            );
            showNewerVersionMessage();
            return false;
        }
        else
        {
            infos("Linked: ", root.name, " - ", result.msecs, "ms");
            vlog("\n\t", linkRes.compilationCommand, " \n");
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

    if(isUpToDate)
        infos("Up-to-Date: ", root.name, ", skipping linking");
    else if(root.requirements.cfg.targetType != TargetType.none)
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