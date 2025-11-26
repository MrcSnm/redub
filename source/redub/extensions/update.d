module redub.extensions.update;

version(RedubCLI):
import redub.extensions.cli;

int updateMain(string[] args)
{
    import core.runtime;
    import redub.cli.dub;
    import redub.logging;
    import std.stdio;
    import std.process;
    import std.file;
    import std.path;
    import redub.misc.github_tag_check;
    import redub.misc.find_executable;
    import redub.libs.package_suppliers.utils;
    string redubExePath = thisExePath;
    string currentRedubDir = dirName(redubExePath);
    string redubPath = buildNormalizedPath(currentRedubDir, "..");
    string latest;

    struct UpdateArgs
    {
        @("Builds redub using dmd -b debug for faster iteration on redub")
        bool fast;

        @("Throws stack instead of simply pretty-printing the message")
        bool dev;

        @("Sets the compiler to build redub")
        string compiler = "ldc2";

        @("Does not execute git pull")
        @("no-pull")
        bool noPull;

        @("Makes the update very verbose")
        bool vverbose;
    }
    import std.getopt;
    UpdateArgs update;
    GetoptResult res = betterGetopt(args, update);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" update information: \n", res.options);
        return 0;
    }
    setLogLevel(update.vverbose ? LogLevel.vverbose : LogLevel.info);

    enum isNotGitRepo = 128;
    int gitCode = isNotGitRepo;
    bool hasGit = findExecutable("git") != null;

    bool replaceRedub = false || update.noPull;

    if(hasGit && !update.noPull)
    {
        auto ret = execute(["git", "pull"], null, Config.none, size_t.max, redubPath);
        gitCode = ret.status;
        if(gitCode != 0 && gitCode != isNotGitRepo)
        {
            errorTitle("Git Pull Error: \n", ret.output);
            return 1;
        }
        else if(gitCode == 0)
        {
            info("Redub will be rebuilt using git repo found at ", redubPath);
            replaceRedub = true;
        }
    }

    if(gitCode == isNotGitRepo || hasGit)
    {
        import d_downloader;
        latest = getLatestRedubVersion();
        if(SemVer(latest[1..$]) > SemVer(RedubVersionOnly[1..$]))
        {
            replaceRedub = true;
            string redubLink = getRedubDownloadLink(latest);
            info("Downloading redub from '", redubLink, "'");
            ubyte[] redubZip = downloadToBuffer(redubLink);
            redubPath = tempDir;
            mkdirRecurse(redubPath);
            extractZipToFolder(redubZip, redubPath);
            redubPath = buildNormalizedPath(redubPath, "redub-"~latest[1..$]);
        }
    }


    if(replaceRedub)
    {
        import redub.api;
        import std.exception;
        info("Preparing to build redub at ", redubPath);
        BuildType bt = BuildType.release_debug;
        if(update.fast)
            bt = BuildType.debug_;

        ProjectDetails d = redub.api.resolveDependencies(false, os, CompilationDetails(compilerOrPath: update.compiler, combinedBuild:true), ProjectToParse(update.dev ? "cli-dev" : null, redubPath), InitialDubVariables.init, bt);
        enforce(d.tree.name == "redub", "Redub update should only be used to update redub.");
        d.tree.requirements.cfg.outputDirectory = buildNormalizedPath(tempDir, "redub_build");
        d = buildProject(d);
        if(d.error)
            return 1;
        info("Replacing current redub at path ", currentRedubDir, " with the built file: ", d.getOutputFile);

        string redubScriptPath;
        version(Windows)
            redubScriptPath = buildNormalizedPath(redubPath, "replace_redub.bat");
        else
            redubScriptPath = buildNormalizedPath(redubPath, "replace_redub.sh");

        if(!exists(redubScriptPath))
        {
            error("Redub Script not found at path ", redubScriptPath);
            return 1;
        }

        version(Windows)
        {
            spawnShell(`start cmd /c "`~redubScriptPath~" "~d.getOutputFile~" "~redubExePath~'"');
        }
        else version(Posix)
        {
            import core.sys.posix.unistd;
            import std.conv:to;
            string pid = getpid().to!string;
            string exec = `chmod +x `~redubScriptPath~` && nohup bash `~redubScriptPath~" "~pid~" "~d.getOutputFile~" "~redubExePath~" > /dev/null 2>&1";
            spawnShell(exec);
        }
        else assert(false, "Your system does not have any command right now for auto copying the new content.");
        return 0;
    }
    warn("Your redub version '", RedubVersionOnly, "' is already greater or equal than the latest redub version '", latest);
    return 0;
}