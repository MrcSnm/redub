import std.algorithm:countUntil;
import std.conv:to;
import std.array;
import std.path;
import std.file;
import std.process;
import redub.api;

import redub.compiler_identification;
import redub.logging;
import redub.buildapi;
import redub.parsers.automatic;
import redub.tree_generators.dub;
import redub.cli.dub;
import redub.command_generators.commons;

enum RedubVersion = "Redub v1.3.7 - A reimagined DUB";


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
    if(args.length == 1)
        return runMain(args);

    string action = args[1];
    switch(action)
    {
        case "build":
            args = args[0] ~ args[2..$];
            return buildMain(args);
        case "clean":
            args = args[0] ~ args[2..$];
            return cleanMain(args);
        case "describe":
            args = args[0] ~ args[2..$];
            return describeMain(args);
        case "run":
            args = args[0] ~ args[2..$];
            goto default;
        default:
            return runMain(args);
    }
}


int runMain(string[] args)
{
    ProjectDetails d = buildProject(resolveDependencies(args));
    if(!d.tree)
    {
        if(d.printOnly)
            return 0;
        return 1;
    }
    if(d.tree.requirements.cfg.targetType != TargetType.executable)
        return 1;

    ptrdiff_t execArgsInit = countUntil(args, "--");
    string execArgs;
    if(execArgsInit != -1) execArgs = " " ~ escapeShellCommand(args[execArgsInit+1..$]);


    import redub.command_generators.commons;
    
    return wait(spawnShell(
        buildNormalizedPath(d.tree.requirements.cfg.outputDirectory, 
        d.tree.requirements.cfg.name~getExecutableExtension(os)) ~  execArgs
    ));
}

int describeMain(string[] args)
{
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
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return 1;
    
    alias OutputData = string[];

    static immutable outputs =[
        "main-source-file": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.sourceEntryPoint;},
        "dflags": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.dFlags;},
        "lflags": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.linkFlags;},
        "libs": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.libraries;},
        "linker-files": (ref string[] dataContainer, const ProjectNode root)
        {
            import std.algorithm.iteration;
            import std.range;
            import std.array;
            
            if(root.requirements.cfg.targetType.isStaticLibrary)
                dataContainer~= buildNormalizedPath(
                    root.requirements.cfg.outputDirectory, 
                    getOutputName(
                        root.requirements.cfg.targetType, 
                        root.requirements.cfg.name, 
                        os));

            dataContainer~= root.requirements.extra.librariesFullPath.map!((string libPath)
            {
                return buildNormalizedPath(dirName(libPath), getOutputName(TargetType.staticLibrary, baseName(libPath), os));
            }).retro.array;

        },
        "source-files": (ref string[] dataContainer, const ProjectNode root)
        {
            import redub.command_generators.commons;
            // foreach(node; (cast()root).collapse)
            // {
                putSourceFiles(dataContainer, 
                    root.requirements.cfg.workingDir,
                    root.requirements.cfg.sourcePaths,
                    root.requirements.cfg.sourceFiles,
                    root.requirements.cfg.excludeSourceFiles,
                    ".d"
                );
            // }
        },
        "versions": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.versions;},
        // "debug-versions": (){},
        "import-paths": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.importDirectories;},
        "string-import-paths": (ref string[] dataContainer, const ProjectNode root){dataContainer~= root.requirements.cfg.stringImportPaths;}, 
        "import-files": (ref string[] dataContainer, const ProjectNode root){}, 
        "options": (ref string[] dataContainer, const ProjectNode root){}
    ];
    OutputData[] outputContainer = new OutputData[](desc.data.length);
    foreach(i, data; desc.data)
    {
        auto handler = data in outputs;
        if(handler)
            (*handler)(outputContainer[i], d.tree);
    }

    foreach(data; outputContainer)
    {
        import std.stdio;
        writeln(escapeShellCommand(data));
    }
    return 0;
}

int cleanMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return 1;
    
    auto res = timed(()
    {
        info("Cleaning project ", d.tree.name);
        import std.file;
        foreach(ProjectNode node; d.tree.collapse)
        {
            string output = buildNormalizedPath(
                node.requirements.cfg.outputDirectory, 
                getOutputName(node.requirements.cfg.targetType, node.name, os)
            );
            if(std.file.exists(output))
            {
                vlog("Removing ", output);
                remove(output);
            }
        }
        return true;
    });

    info("Finished cleaning project in ", res.msecs, "ms");

    return res.value ? 0 : 1;
}

int buildMain(string[] args)
{
    if(!buildProject(resolveDependencies(args)).tree)
        return 1;
    return 0;
}


ProjectDetails resolveDependencies(string[] args)
{
    import std.algorithm.comparison:either;
    import redub.api;
    string subPackage = parseSubpackageFromCli(args);
    string workingDir = std.file.getcwd();
    string recipe;

    DubArguments bArgs;
    GetoptResult res = betterGetopt(args, bArgs);
    if(res.helpWanted)
    {
        import std.getopt;
        defaultGetoptPrinter("redub build information\n\t", res.options);
        return ProjectDetails.init;
    }
    if(bArgs.version_)
    {
        import std.stdio;
        writeln(RedubVersion);
        return ProjectDetails(null, Compiler.init, true);
    }
    updateVerbosity(bArgs.cArgs);
    if(bArgs.arch) bArgs.compiler = "ldc2";
    DubCommonArguments cArgs = bArgs.cArgs;
    if(cArgs.root)
        workingDir = cArgs.getRoot(workingDir);
    if(cArgs.recipe)
        recipe = cArgs.getRecipe(workingDir);

    BuildType bt = BuildType.debug_;
    if(bArgs.buildType) bt = buildTypeFromString(bArgs.buildType);

    return redub.api.resolveDependencies(
        bArgs.build.force,
        os,
        CompilationDetails(either(bArgs.compiler, "dmd"), bArgs.arch, bArgs.compilerAssumption),
        ProjectToParse(bArgs.config, workingDir, subPackage, recipe),
        getInitialDubVariablesFromArguments(bArgs, DubBuildArguments.init, os, args),
        bt
    );

}

void updateVerbosity(DubCommonArguments a)
{
    import redub.logging;
    if(a.vquiet) return setLogLevel(LogLevel.none);
    if(a.verror) return setLogLevel(LogLevel.error);
    if(a.quiet) return setLogLevel(LogLevel.warn);
    if(a.verbose) return setLogLevel(LogLevel.verbose);
    if(a.vverbose) return setLogLevel(LogLevel.vverbose);
    return setLogLevel(LogLevel.info);
}

private string parseSubpackageFromCli(ref string[] args)
{
    import std.string:startsWith;
    import std.algorithm.searching;
    ptrdiff_t subPackIndex = countUntil!((a => a.startsWith(':')))(args);
    if(subPackIndex == -1) return null;

    string ret;
    ret = args[subPackIndex][1..$];
    args = args[0..subPackIndex] ~ args[subPackIndex+1..$];
    return ret;
}