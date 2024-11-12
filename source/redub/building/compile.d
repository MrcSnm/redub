module redub.building.compile;
import redub.building.utils;
import redub.building.cache;
import redub.logging;
import redub.buildapi;
import std.system;
import redub.compiler_identification;
import redub.command_generators.automatic;

struct CompilationResult
{
    string compilationCommand;
    string message;
    size_t msNeeded;
    int status;
    shared ProjectNode node;
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
*   If any command has status, it will stop executing them and return
*/
private ExecutionResult executeCommands(const string[] commandsList, string listName, ref CompilationResult res, string workingDir, immutable string[string] env)
{
    import std.process;
    foreach(cmd; commandsList)
    {
        auto execRes  = cast(ExecutionResult)executeShell(cmd, env, Config.none, size_t.max, workingDir);
        if(execRes.status)
        {
            res.status = execRes.status;
            res.message = "Result of "~listName~" command '"~cmd~"' "~execRes.output;
            return execRes;
        }
    }
    return ExecutionResult(0, "Success");
}

void execCompilationThread(immutable ThreadBuildData data, shared ProjectNode pack, CompilingSession info, HashPair hash, immutable string[string] env)
{
    import std.concurrency;
    CompilationResult res = execCompilation(data, pack, info, hash, env);
    scope(exit)
    {
        ownerTid.send(res);
    }
}


CompilationResult execCompilation(immutable ThreadBuildData data, shared ProjectNode pack, CompilingSession info, HashPair hash, immutable string[string] env)
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
        {
            import std.stdio;
            writeln("Copy is not necessary for ", (cast()pack).name);
            return res;
        }

        immutable BuildConfiguration cfg = data.cfg;
        Compiler compiler = info.compiler;
        OS os = info.os;
        ISA isa = info.isa;
        //Remove existing binary, since it won't be replaced by simply executing commands
        string outDir = getConfigurationOutputPath(cfg, os);
        if(exists(outDir))
            remove(outDir);
        
        if(executeCommands(cfg.preBuildCommands, "preBuildCommand", res, cfg.workingDir, env).status)
            return res;


        if(pack.requirements.cfg.targetType != TargetType.none)
        {
            import std.path;
            string inDir = getCacheOutputDir(hash.rootHash, cast()pack.requirements, info);
            mkdirRecurse(inDir);
            createOutputDirFolder(cfg);

            ExecutionResult ret;
            if(!pack.isCopyEnough)
                ret = cast(ExecutionResult)execCompiler(cfg, compiler.binOrPath, getCompilationFlags(cfg, info, hash.rootHash), res.compilationCommand, compiler, inDir);

            if(!isDCompiler(compiler) && !ret.status) //Always requires link.
            {
                CompilationResult linkRes = link(cast()pack, hash.requirementHash, data, info, env);
                ret.status = linkRes.status;
                ret.output~= linkRes.message;
                res.compilationCommand~= linkRes.compilationCommand;
            }

            copyDir(inDir, dirName(outDir));

            ///Shared Library(mostly?)
            if(isDCompiler(compiler) && isLinkedSeparately(data.cfg.targetType) && !pack.isRoot)
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
            if(!cfg.targetType.isLinkedSeparately && executeCommands(cfg.postBuildCommands, "postBuildCommand", res, cfg.workingDir, env).status)
                return res;
            if(!cfg.targetType.isLinkedSeparately && executeCommands(cfg.postGenerateCommands, "postGenerateCommand", res, cfg.workingDir, env).status)
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
        auto exec = linkBase(data, info, rootHash, ret.compilationCommand);
        ret.status = exec.status;
        ret.message = exec.output;
        if(exec.status != 0)
            return ret;
    }
    import redub.command_generators.commons;
    import std.path;

    string inDir = getCacheOutputDir(rootHash, cast()root.requirements, info);
    string outDir = getConfigurationOutputPath(data.cfg, os);
    copyDir(inDir, dirName(outDir));

    if(root.requirements.cfg.targetType == TargetType.executable && std.system.os.isPosix && info.isa != ISA.webAssembly)
    {
        //TODO: Make it executable
        string execPath = buildNormalizedPath(dirName(outDir), getOutputName(root.requirements.cfg, os));
        if(!makeFileExecutable(execPath))
            throw new Exception("Could not make the output file as executable "~execPath);
    }



    if(data.cfg.targetType.isLinkedSeparately)
    {
        if(executeCommands(data.cfg.postBuildCommands, "postBuildCommand", ret, data.cfg.workingDir, env).status)
            return ret;
        if(executeCommands(data.cfg.postGenerateCommands, "postGenerateCommand", ret, data.cfg.workingDir, env).status)
            return ret;
    }

    return ret;
}


bool buildProjectParallelSimple(ProjectNode root, CompilingSession s)
{
    import std.concurrency;
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);
    bool[ProjectNode] spawned;

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
                        dep.requirements.buildData, cast(shared)dep, 
                        s, HashPair(mainPackHash, hashFrom(dep.requirements, s)),
                        getEnvForProject(dep)
                    );
                }
                else
                    dep.becomeIndependent();
            }
        }
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;
        if(res.status)
        {
            buildFailed(finishedPackage, res, s, finishedBuilds, mainPackHash, &formulaCache);
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
                CompilationCache existingCache = CompilationCache.get(mainPackHash, finishedPackage.requirements, s);
                const AdvCacheFormula existingFormula = existingCache.getFormula();
                CompilationCache.make(existingCache.requirementCache, mainPackHash, finishedPackage.requirements, s, &existingFormula, &formulaCache);
                updateCache(mainPackHash, CompilationCache.make(existingCache.requirementCache, mainPackHash, finishedPackage.requirements, s, &existingFormula, &formulaCache));
            }
            if(finishedPackage is root)
                break;
        }
    }
    return doLink(root, s, mainPackHash, &formulaCache) && copyFiles(root);
}


bool buildProjectFullyParallelized(ProjectNode root, CompilingSession s)
{
    import std.concurrency;
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);

    size_t i = 0;
    size_t sentPackages = 0;
    foreach(ProjectNode pack; root.collapse)
    {
        if(pack.shouldEnterCompilationThread)
        {
            sentPackages++;
            spawn(&execCompilationThread,
                pack.requirements.buildData,
                cast(shared)pack, 
                s,
                HashPair(mainPackHash, hashFrom(pack.requirements, s)),
                getEnvForProject(pack)
            );

        }
        i++;
    }

    printCachedBuildInfo(root);

    AdvCacheFormula formulaCache;
    foreach(_; 0..sentPackages)
    {
        CompilationResult res = receiveOnly!CompilationResult;
        ProjectNode finishedPackage = cast()res.node;

        if(res.status)
        {
            import core.thread;
            buildFailed(finishedPackage, res, s, finishedBuilds, mainPackHash, &formulaCache);
            thread_joinAll();
            return false;
        }
        else
        {
            buildSucceeded(finishedPackage, res);
            finishedBuilds~= finishedPackage;

            if(!finishedPackage.requirements.cfg.targetType.isLinkedSeparately)
            {
                CompilationCache existingCache = CompilationCache.get(mainPackHash, finishedPackage.requirements, s);
                const AdvCacheFormula existingFormula = existingCache.getFormula();
                updateCache(mainPackHash, CompilationCache.make(existingCache.requirementCache, mainPackHash, finishedPackage.requirements, s, &existingFormula, &formulaCache));
            }
        }
    }
    return doLink(root, s, mainPackHash, &formulaCache) && copyFiles(root);
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
bool buildProjectSingleThread(ProjectNode root, CompilingSession s)
{
    ProjectNode[] dependencyFreePackages = root.findLeavesNodes();
    ProjectNode[] finishedBuilds;
    string mainPackHash = hashFrom(root.requirements, s);

    printCachedBuildInfo(root);
    while(true)
    {
        ProjectNode finishedPackage;
        foreach(dep; dependencyFreePackages)
        {
            if(dep.shouldEnterCompilationThread)
            {
                CompilationResult res = execCompilation(dep.requirements.buildData, cast(shared)dep, 
                    s,
                    HashPair(mainPackHash,  hashFrom(dep.requirements, s)), getEnvForProject(dep)
                );
                if(res.status)
                {
                    buildFailed(dep, res, s, finishedBuilds, mainPackHash, null);
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
    return doLink(root, s, mainPackHash) && copyFiles(root);
}

private void printCachedBuildInfo(ProjectNode root)
{
    string upToDate;
    string copyEnough;
    foreach(ProjectNode node; root.collapse)
    {
        string cfg = node.requirements.targetConfiguration ? (" ["~node.requirements.targetConfiguration~"]") : null;
        cfg = node.name~ cfg~"; ";

        if(node.isCopyEnough)
            copyEnough~= cfg;
        else if(node.isUpToDate)
            upToDate~= cfg;
    }
    if(copyEnough.length)
        infos("Copy Enough: ", copyEnough);
    if(upToDate.length)
        infos("Up-to-Date: ", upToDate);
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
    ProjectNode[] finishedPackages, string mainPackHash, AdvCacheFormula* formulaCache
)
{
    import redub.misc.github_tag_check;
    errorTitle("Build Failure: '", node.name, " ",node.requirements.version_," [", node.requirements.targetConfiguration,"]' \n\t",
        RedubVersionShort, "\n\t", s.compiler.getCompilerWithVersion, "\n\tFailed with flags: \n\n\t",
        res.compilationCommand, 
        "\nFailed after ", res.msNeeded,"ms with message\n\t", res.message
    );
    showNewerVersionMessage();
    saveFinishedBuilds(finishedPackages, mainPackHash, s, formulaCache);
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

immutable(string[string]) getEnvForProject(const ProjectNode node)
{
    import redub.parsers.environment;
    import std.process:environment;
    PackageDubVariables vars = getEnvironmentVariablesForPackage(node.requirements.cfg);
    string[string] env = environment.toAA;
    static foreach(mem; __traits(allMembers, PackageDubVariables))
        env[mem] = __traits(getMember, vars, mem);
    return cast(immutable)env;

}

private void saveFinishedBuilds(ProjNodeRange)(ProjNodeRange finishedProjects, string mainPackHash, CompilingSession s, AdvCacheFormula* formulaCache)
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
            CompilationCache existingCache = CompilationCache.get(mainPackHash, node.requirements, s);
            const AdvCacheFormula existingFormula = existingCache.getFormula();
            updateCache(mainPackHash, CompilationCache.make(existingCache.requirementCache, mainPackHash, node.requirements, s, &existingFormula, &cache));
        }
    }
    updateCacheOnDisk(mainPackHash);

    ///TODO: Start comparing current build time with the last one
}

private bool doLink(ProjectNode root, CompilingSession info, string mainPackHash, AdvCacheFormula* formulaCache = null)
{
    Compiler compiler = info.compiler;
    bool isUpToDate = root.isUpToDate;
    bool shouldSkipLinking = isUpToDate || (compiler.isDCompiler && !root.requirements.cfg.targetType.isLinkedSeparately);

    if(!shouldSkipLinking)
    {
        CompilationResult linkRes;
        auto result = timed(() {
             linkRes = link(root, mainPackHash, root.requirements.buildData, info, getEnvForProject(root));
             return true;
        });
        if(linkRes.status)
        {
            import redub.misc.github_tag_check;
            errorTitle("Linking Error at \"", root.name, "\". \n\t"~ RedubVersionShort~ "\n\t" ~ compiler.getCompilerWithVersion ~ "\n\tFailed with flags: \n\n\t",
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
            saveFinishedBuilds(root.collapse, mainPackHash, info, formulaCache);
            return true;
        });
        ///Ignore that message if it is not relevant enough [more than 5 ms]
        if(result.msecs > 5)
            redub.logging.info("Wrote cache in ", result.msecs, "ms");

    }
        
    return true;
}