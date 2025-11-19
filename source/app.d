import redub.api;

import redub.extensions.cli;
import redub.tooling.compiler_identification;
import redub.logging;
import redub.buildapi;
import redub.parsers.automatic;
import redub.tree_generators.dub;
import redub.cli.dub;
import redub.command_generators.commons;
import redub.libs.package_suppliers.utils;


extern(C) __gshared string[] rt_options = [ "gcopt=initReserve:200 cleanup:none"];

string formatError(string err)
{
    import std.algorithm.searching:countUntil;
    if(err.countUntil("which cannot be read") != -1)
    {
        ptrdiff_t moduleNameStart = err.countUntil("`") + 1;
        ptrdiff_t moduleNameEnd = err[moduleNameStart..$].countUntil("`") + moduleNameStart;
        string moduleName = err[moduleNameStart..moduleNameEnd];

        return err~"\nMaybe you forgot to add the module '"~moduleName~"' source root to import paths?
        Redub Failed!";
    }
    return err~"\nRedub Failed!";
}
/**
* Redub work with input -> output on each step. It must be almost stateless.
* ** CLI will be optionally implemented later.
* ** Cache will be optionally implemented later
*
* FindProject -> ParseProject -> MergeWithEnvironment -> ConvertToBuildFlags ->
* Build
*/
int main(string[] args)
{
    import std.getopt;
    try
    {
        if(args.length == 1)
            return runMain(args, []);

        import std.algorithm:countUntil;
        ptrdiff_t execArgsInit = countUntil(args, "--");

        string[] runArgs;
        if(execArgsInit != -1)
        {
            runArgs = args[execArgsInit+1..$];
            args = args[0..execArgsInit];
        }

        import redub.extensions.universal;
        import redub.extensions.update;
        import redub.extensions.watcher;


        int function(string[])[string] entryPoints = [
            "build": &buildMain,
            "build-universal": &buildUniversalMain,
            "update": &updateMain,
            "clean": &cleanMain,
            "describe": &describeMain,
            "deps": &depsMain,
            "test": &testMain,
            "init": &initMain,
            "install": &installMain,
            "use": &useMain,
            // "watch": &watchMain,
            "run": cast(int function(string[]))null
        ];

        version(RedubWatcher)
            entryPoints["watch"] = &watchMain;


        if(args.length >= 2)
        {
            foreach(cmd; entryPoints.byKey)
            {
                if(args[1] == cmd)
                {
                    args = args[0..1] ~ args[2..$];
                    if(cmd == "run")
                        return runMain(args, runArgs);
                    return entryPoints[cmd](args);
                }
            }
        }
        return runMain(args, runArgs);
    }
    catch(RedubException e)
    {
        errorTitle("Redub Error: ", e.msg);
        version(Developer) throw e;
        return 1;
    }
    catch(BuildException e)
    {
        errorTitle("Build Failure: ", e.msg);
        version(Developer) throw e;
        return 1;
    }
    catch(NetworkException e)
    {
        errorTitle("Network Error: ", e.msg);
        version(Developer) throw e;
        return 1;
    }
    catch(GetOptException e)
    {
        import std.stdio;
        setLogLevel(LogLevel.error);
        errorTitle("Argument Error: ", e.msg);
        writeln(getHelpInfo);
        version(Developer) throw e;
        return 1;
    }
    catch(Exception e)
    {
        errorTitle("Internal Error: ", e.msg);
        version(Developer) throw e;
        return 1;
    }
}


int runMain(string[] args, string[] runArgs)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree || d.usesExternalErrorCode)
        return d.getReturnCode;
    if(d.tree.name == "redub")
        warnTitle("Attempt to build and run redub with redub: ", "For building redub with redub, use the command 'redub update' which already outputs an optimized build");
    d = buildProject(d);
    if(!d.tree || d.usesExternalErrorCode)
        return d.getReturnCode;
    if(d.tree.requirements.cfg.targetType != TargetType.executable)
        return 1;

    if(d.tree.name == "redub")
        return 0;
    int ret = executeProgram(d.tree, runArgs);
    if(ret)
        errorTitle("Error: ", "Program exited with code ", ret);
    return ret;
}

int describeMain(string[] args)
{
    import std.getopt;
    DubDescribeArguments desc;
    try
    {
        GetoptResult res = betterGetopt(args, desc);
        if(res.helpWanted)
        {
            defaultGetoptPrinter("redub describe help info ", res.options);
            return 1;
        }
    }
    catch(GetOptException e){}
    ProjectDetails d = resolveDependencies(args, true);
    if(!d.tree)
        return 1;

    alias OutputData = string[];

    static immutable outputs =[
        "dflags": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.dFlags;},
        "lflags": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.linkFlags;},
        "libs": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.libraries;},
        "linker-files": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d)
        {
            root.putLinkerFiles(dataContainer, osFromArch(d.cDetails.arch), isaFromArch(d.cDetails.arch));
        },
        "source-files": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d)
        {
            root.putSourceFiles(dataContainer);
        },
        "versions": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.versions;},
        // "debug-versions": (){},
        "import-paths": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.importDirectories;},
        "string-import-paths": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){dataContainer~= root.requirements.cfg.stringImportPaths;},
        "import-files": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){},
        "options": (ref string[] dataContainer, const ProjectNode root, const ProjectDetails d){}
    ];
    OutputData[] outputContainer = new OutputData[](desc.data.length);
    foreach(i, data; desc.data)
    {
        auto handler = data in outputs;
        if(handler)
            (*handler)(outputContainer[i], d.tree, d);
    }

    foreach(data; outputContainer)
    {
        import std.process;
        import std.stdio;
        writeln(escapeShellCommand(data));
    }
    return 0;
}


int depsMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(d.error)
        return 1;
    printProjectTree(d.tree);
    return 0;
}

int testMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(d.error)
        return d.getReturnCode();
    import redub.parsers.build_type;
    d.tree.requirements.cfg = d.tree.requirements.cfg.merge(parse(BuildType.unittest_, d.tree.requirements.cfg.getCompiler(d.compiler)));
    d.tree.requirements.cfg.dFlags~= "-main";
    d.tree.requirements.cfg.targetType = TargetType.executable;
    d.tree.requirements.cfg.targetName~= "-test-";

    if(d.tree.requirements.configuration.name)
        d.tree.requirements.cfg.targetName~= d.tree.requirements.configuration.name;
    else
        d.tree.requirements.cfg.targetName~= "library";

    d = buildProject(d);
    if(d.error)
        return d.getReturnCode();

    return executeProgram(d.tree, args);
}

int initMain(string[] args)
{
    import std.getopt;
    struct InitArgs
    {
        @("Creates a project of the specified type")
        @("t")
        string type;
    }
    InitArgs initArgs;
    GetoptResult res = betterGetopt(args, initArgs);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" init information:\n ", res.options);
        return 0;
    }
    setLogLevel(LogLevel.info);
    return createNewProject(initArgs.type, args.length > 1 ? args[1] : null);
}


int cleanMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return d.getReturnCode;
    return cleanProject(d, true);
}

int buildMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    return buildProject(d).getReturnCode;
}

int installMain(string[] args)
{
    import std.string;
    import redub.cli.dub;
    import redub.logging;
    import redub.misc.dmd_install;
    setLogLevel(LogLevel.info);
    if(args.length == 1)
    {
        error("redub install requires 1 additional argument: ",
        "\n\topend: installs opend",
        "\n\tldc <version?|help>: installs ldc latest if version is unspecified.",
        "\n\t\thelp: Lists available ldc versions",
        "\n\tdmd <version?>: installs the dmd with the version "~DefaultDMDVersion~" if version is unspecified"
        );
        return 1;
    }
    string compiler = args[1];
    if(compiler.startsWith("opend"))
    {
        import redub.misc.opend_install;
        if(!installOpend())
        {
            error("Could not install OpenD");
            return 1;
        }
    }
    else if(compiler.startsWith("ldc"))
    {
        import redub.api;
        import redub.misc.ldc_install;
        import redub.misc.github_tag_check;
        enum ldcRepo = "ldc-developers/ldc";
        string ldcVer = args.length > 2 ? args[2] : null;
        if(!ldcVer)
            ldcVer = getLatestGitRepositoryTag(ldcRepo);
        else if(ldcVer == "help")
        {
            import hip.data.json;
            JSONValue gitTags = getGithubRepoAPI(ldcRepo);
            info("Listing available LDC versions:");
            int limit = 25;
            foreach(entry; gitTags.array)
            {
                info("\t", entry["name"].str);
                if(--limit == 0)
                    break;
            }
            return 0;
        }
        if(!installLdc(ldcVer))
        {
            error("Could not install LDC ", ldcVer);;
            return 1;
        }
    }
    else if(compiler == "dmd")
    {
        import redub.misc.dmd_install;
        string dmdVer = args.length > 2 ? args[2] : DefaultDMDVersion;
        if(!installDmd(dmdVer))
        {
            error("Could not install DMD ", dmdVer);;
            return 1;
        }
    }
    return 0;
}

int useMain(string[] args)
{
    import std.string;
    import std.file;
    import redub.cli.dub;
    import redub.logging;
    import redub.meta;
    import redub.misc.path;
    import redub.misc.dmd_install;
    JSONValue meta = getRedubMeta();
    setLogLevel(LogLevel.info);
    if(args.length == 1)
    {
        error("redub use requires 1 additional argument: ",
        "\n\topend <dmd|ldc>: uses the wanted opend compiler as the default",
        "\n\tldc <version?>: uses the latest ldc latest if version is unspecified.",
        "\n\tdmd <version?>: uses the "~DefaultDMDVersion~" dmd if the version is unspecified.",
        "\n\treset: removes the default compiler and redub will set it again by the first one found in the PATH environment variable",
        );
        return 1;
    }
    string compiler = args[1];
    if(compiler.startsWith("opend"))
    {
        import redub.misc.opend_install;
        import redub.tooling.compiler_identification;
        string opendCompiler = args.length > 2 ? args[2] : null;
        if(opendCompiler != "dmd" && opendCompiler != "ldc2")
        {
            error("redub uses opend: requires either dmd or ldc2 as an argument");
            return 1;
        }
        string opendFolder = getOpendFolder();
        if(!exists(opendFolder))
            installOpend();
        version(Windows)
            opendCompiler~= ".exe";
        string opendBin = buildNormalizedPath(opendFolder, opendCompiler);
        saveGlobalCompiler(opendBin, meta, true, false);
    }
    else if(compiler == "ldc" || compiler == "ldc2")
    {
        import redub.api;
        import redub.misc.ldc_install;
        import redub.misc.github_tag_check;
        enum ldcRepo = "ldc-developers/ldc";
        string ldcVer = args.length > 2 ? args[2] : null;
        if(!ldcVer)
            ldcVer = getLatestGitRepositoryTag(ldcRepo);
        string ldcFolder = getLdcFolder(ldcVer);
        if(!exists(ldcFolder))
            installLdc(ldcVer);
        string ldcBin = "ldc2";
        version(Windows)
            ldcBin~= ".exe";
        ldcBin = buildNormalizedPath(ldcFolder, ldcBin);
        saveGlobalCompiler(ldcBin, meta, true, false);
    }
    else if(compiler == "dmd")
    {
        import redub.misc.dmd_install;
        string dmdVer = args.length > 2 ? args[2] : DefaultDMDVersion;
        string dmdFolder = getDmdFolder(dmdVer);
        if(!exists(dmdFolder) && !installDmd(dmdVer))
        {
            error("Could not install DMD for using it.");
            return 1;
        }
        string dmdBin = "dmd";
        version(Windows)
            dmdBin~= ".exe";
        dmdBin = buildNormalizedPath(dmdFolder, dmdBin);
        saveGlobalCompiler(dmdBin, meta, true, false);
    }
    else if(compiler.startsWith("reset"))
    {
        meta.data.object.remove("defaultCompiler");
        meta.data.object.remove("globalPaths");
        infos("Default redub compiler is now reset.");
    }

    if("defaultCompiler" in meta)
    {
        infos(meta["globalPaths"][meta["defaultCompiler"].str].str, " is now the default compiler");
    }
    saveRedubMeta(meta);
    return 0;
}