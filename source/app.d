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
 * Redub works with input -> output on each step. It must be almost stateless.
 * - CLI may be implemented later.
 * - Cache may be implemented later.
 *
 * FindProject -> ParseProject -> MergeWithEnvironment -> ConvertToBuildFlags -> Build
 */
int main(string[] args)
{
    import std.getopt;
    try
    {
        if(args.length == 1)
        {
            import std.stdio : stderr;
            stderr.writeln("redub: no command given; running default: run");
            return runMain(args, []);
        }

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
        import redub.extensions.setup;
        import redub.extensions.watcher;
        import redub.extensions.imports;
        version(RedubCLI) import redub.extensions.serve;
        version(RedubCLI) import redub.extensions.android_run;


        int function(string[])[string] entryPoints = [
            "build": &buildMain,
            "build-universal": &buildUniversalMain,
            "update": &updateMain,
            "setup": &setupMain,
            "clean": &cleanMain,
            "describe": &describeMain,
            "deps": &depsMain,
            "imports": &importsMain,
            "init": &initMain,
            "install": &installMain,
            "configure": &configureMain,
            "use": &useMain,
            // "watch": &watchMain,
            "test": cast(int function(string[]))null,
            "run": cast(int function(string[]))null
        ];

        version(RedubWatcher)
            entryPoints["watch"] = &watchMain;
        version(RedubCLI)
        {
            entryPoints["serve"] = &serveMain;
            entryPoints["android-run"] = &androidRunMain;
        }


        bool strictDispatch = isStrictDispatch(args);

        if(args.length >= 2 && args[1] == "help")
        {
            import std.stdio : writeln;
            if(args.length >= 3 && args[2] != "run")
            {
                if(auto fn = args[2] in entryPoints)
                    return (*fn)([args[0], "--help"]);
                if(args[2] != "help")
                    return unknownHelpTopic(args[2], entryPoints.keys ~ "help");
            }
            writeln(getHelpInfo());
            return 0;
        }

        if(args.length >= 2)
        {
            foreach(cmd; entryPoints.byKey)
            {
                if(args[1] == cmd)
                {
                    args = args[0..1] ~ args[2..$];
                    if(cmd == "run")
                        return runMain(args, runArgs);
                    else if(cmd == "test")
                        return testMain(args, runArgs);
                    return entryPoints[cmd](args);
                }
            }
        }
        if(args.length >= 2 && args[1].length && args[1][0] != '-')
        {
            if(int code = checkUnknownCommand(args[1], entryPoints.keys ~ "help", strictDispatch))
                return code;
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


/**
 * Strict dispatch opt-in (OpenShellOrg CLI Dispatch CD-11, CD-14).
 * `--strict` (removed from args) takes precedence over REDUB_STRICT=1.
 * Planned: strict becomes the default in the next major version (CD-12).
 */
bool isStrictDispatch(ref string[] args)
{
    import std.algorithm.searching : countUntil;
    import std.process : environment;
    bool strict = environment.get("REDUB_STRICT", "") == "1";
    ptrdiff_t idx;
    while((idx = countUntil(args, "--strict")) != -1)
    {
        args = args[0..idx] ~ args[idx+1..$];
        strict = true;
    }
    return strict;
}

/**
 * Handles a first word that is not a redub command (CD-1, CD-3, CD-13).
 * Returns 0 to continue with the deprecated implicit run, or the exit code (2) in strict mode.
 */
int checkUnknownCommand(string word, string[] commands, bool strict)
{
    import std.stdio : stderr;
    import std.algorithm : sort, filter, map, minElement;
    import std.algorithm.comparison : levenshteinDistance;
    import std.array : array, join;
    import std.typecons : tuple;

    string[] cmds = commands.dup;
    sort(cmds);
    string suggestion;
    auto close = cmds.map!(c => tuple(levenshteinDistance(word, c), c)).filter!(t => t[0] <= 2).array;
    if(close.length)
        suggestion = close.minElement!"a[0]"[1];

    if(strict)
    {
        stderr.writeln("error: unknown command '", word, "'");
        if(suggestion.length)
            stderr.writeln("  did you mean: redub ", suggestion);
        stderr.writeln("  to run a package named ", word, ": redub run ", word);
        stderr.writeln("  redub commands: ", cmds.join(", "));
        stderr.writeln("  see: redub help");
        return 2;
    }
    stderr.writeln("warning: '", word, "' is not a redub command; running package '", word, "' implicitly is deprecated");
    stderr.writeln("  use: redub run ", word);
    stderr.writeln("  this will be an error in redub 2.0; enable now with --strict or REDUB_STRICT=1");
    return 0;
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
    if(d.tree.requirements.cfg.targetType != TargetType.executable
        && !(d.bundle == BundleType.android && d.androidApk.length))
    {
        warnTitle("Warning: Unexpected Run", "Built target is an '", d.tree.requirements.cfg.targetType, "'not an executable. Build with 'redub build' to not get this warning message.'");
        return 1;
    }

    if(d.tree.name == "redub")
        return 0;
    import std.system;
    if(d.cDetails.targetOS != std.system.os)
    {
        if(!d.tree.requirements.cfg.runCommand.length)
        {
            warnTitle("Cross Compilation Warning: ", "Built target can't be run since it was cross-compiled to '",d.cDetails.targetOS, 
                "'. \n\tDefine a \"runCommand\" inside your recipe: \"runCommand\": [\"nxlink\", \"${BUILD_ARTIFACT}\", \"-s\"]"
            );
            return 2;
        }
    }

    int ret = executeProgram(d, runArgs);
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

int testMain(string[] args, string[] runArgs)
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

    return executeProgram(d, runArgs);
}

int initMain(string[] args)
{
    import std.getopt;
    struct InitArgs
    {
        @("Creates a project of the specified type")
        @("t")
        string type;

        @("Creates a --single targetable project. Specifies the name to be used. Specification: https://dub.pm/dub-guide/single/")
        @("s")
        string singleName;

    }
    InitArgs initArgs;
    GetoptResult res = betterGetopt(args, initArgs);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" init usage: redub init [options] targetPath\nOptions:", res.options);
        return 0;
    }
    setLogLevel(LogLevel.info);

    return createNewProject(initArgs.type, initArgs.singleName, args.length > 1 ? args[1] : null);
}


int cleanMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    if(!d.tree)
        return d.getReturnCode;
    int olderThanDays = d.cleanOlderThanDays < 0 ? 30 : d.cleanOlderThanDays;
    return cleanProject(d, true, d.cleanAll, olderThanDays) ? 0 : 1;
}

int buildMain(string[] args)
{
    ProjectDetails d = resolveDependencies(args);
    d = buildProject(d);
    if(d.error)
        return d.getReturnCode();
    if(d.tree.requirements.cfg.serveAfterBuild
        && !d.tree.requirements.cfg.syntaxOnly
        && d.tree.requirements.cfg.runCommand.length)
        return executeProgram(d, null);
    return d.getReturnCode();
}

private void printInstallHelp()
{
    import redub.misc.dmd_install : DefaultDMDVersion;
    import std.format : format;
    import std.stdio : write;

    enum helpText = q"EOS
Redub install

Usage:
  redub install <target> [<version>|help] [options]
  redub install --addon=<group> [<version>]
  redub install --help

Targets:
  ldc [<version>|help] [--addon=<group>]...
      Installs LDC (latest when <version> is omitted). Use 'help' to list
      available versions. Addons require LDC 1.43+ and accept:
      windows, android, wasi, emscripten (or a target triple).
      Examples:
        redub install ldc
        redub install ldc 1.43.0
        redub install ldc 1.43.0 --addon=wasi --addon=windows

  dmd [<version>]
      Installs DMD (default: %s). Use a release version
      from https://downloads.dlang.org/releases/2.x, e.g. 2.112.0.

  opend
      Installs the latest OpenD. OpenD has a single version.

  wasi-sdk [<version>|help]
      Installs a prebuilt WASI SDK (latest when omitted). Use 'help' to list
      versions. Redub exposes it automatically to wasip1/wasip2 targets.
      Accepts '25', 'v25' or 'wasi-sdk-25'.

  emsdk [<version>|help]
      Installs the Emscripten SDK (latest when omitted). Use 'help' to list
      versions. No system Python is required.

  android-ndk [<version>|help]
      Installs an official Android NDK (default: r27c, ~660 MB). Accepts
      r27c, 27c or android-ndk-r27c. Redub also finds NDKs installed by
      Android Studio/SDK.

Addon shortcut:
  redub install --addon=<group> [<version>]
      Installs LDC with the given addon group. '--addon=emsdk' is a
      shortcut for 'redub install emsdk'.

Notes:
  * Versions may be written with or without a leading 'v'.
  * LDC addons may be repeated or comma-separated via --addons.
  * Use 'redub use' to select an installed compiler.
EOS";
    write(format(helpText, DefaultDMDVersion));
}

private struct InstallArgs
{
    @("Installs a cross-compilation addon (repeatable)")
    @("addon")
    string[] addon;

    @("Comma-separated cross-compilation addons")
    @("addons")
    string[] addons;
}

private string[] collectAddons(const ref InstallArgs parsed)
{
    import std.array : split;
    string[] ret;
    foreach(addon; parsed.addon)
        if(addon.length)
            ret ~= addon;
    foreach(groups; parsed.addons)
        foreach(addon; groups.split(","))
            if(addon.length)
                ret ~= addon;
    return ret;
}

private bool isInstallTarget(string target)
{
    import std.string : startsWith;
    return target.startsWith("opend") || target.startsWith("ldc")
        || target == "dmd" || target == "emsdk" || target == "emscripten"
        || target == "wasi-sdk" || target == "wasi" || target == "android-ndk";
}

int installMain(string[] args)
{
    import std.string;
    import std.getopt : GetOptException;
    import redub.cli.dub;
    import redub.logging;
    import redub.misc.dmd_install;
    setLogLevel(LogLevel.info);

    bool addonFirst = args.length > 1
        && (args[1] == "--addon" || args[1].startsWith("--addon=")
            || args[1] == "--addons" || args[1].startsWith("--addons="));
    InstallArgs parsed;
    try
    {
        auto res = betterGetopt(args, parsed);
        if(res.helpWanted)
        {
            printInstallHelp();
            return 0;
        }
    }
    catch(GetOptException e)
    {
        error("Argument Error: ", e.msg);
        printInstallHelp();
        return 1;
    }

    string[] addons = collectAddons(parsed);
    if(addonFirst && addons.length == 0)
    {
        error("--addon requires a value");
        return 1;
    }
    string[] positional = args[1 .. $];
    string compiler;
    string ver;
    string[] extra;

    if(positional.length && positional[0] == "help")
    {
        printInstallHelp();
        return 0;
    }
    if(positional.length && isInstallTarget(positional[0]))
    {
        compiler = positional[0];
        ver = positional.length > 1 ? positional[1] : null;
        extra = positional.length > 2 ? positional[2 .. $] : [];
    }
    else if(addonFirst && addons.length)
    {
        compiler = "ldc";
        foreach(addon; addons)
            if(addon == "emsdk" || addon == "emscripten-sdk")
            {
                compiler = "emsdk";
                addons = null;
                break;
            }
        ver = positional.length ? positional[0] : null;
        extra = positional.length > 1 ? positional[1 .. $] : [];
    }
    else if(positional.length)
    {
        error("Unknown install target: ", positional[0],
            "\nAvailable targets: opend, ldc, dmd, wasi-sdk, emsdk");
        return 1;
    }
    else
    {
        printInstallHelp();
        return 1;
    }

    if(extra.length)
    {
        error("Unexpected argument: ", extra[0]);
        return 1;
    }
    if(compiler != "ldc" && addons.length)
    {
        error("Addons only apply to ldc. Use 'redub install ldc ... --addon=<group>'.");
        return 1;
    }

    if(compiler.startsWith("opend"))
    {
        import redub.misc.opend_install;
        if(ver == "help")
        {
            info("OpenD has a single version. Install with 'redub install opend'.");
            return 0;
        }
        if(ver !is null)
        {
            error("opend has a single version; unexpected argument: ", ver);
            return 1;
        }
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
        import redub.libs.semver : SemVer;
        import redub.tooling.compiler_identification : CompilerBinary,
            AcceptedCompiler, searchCompiler;
        import std.path : dirName;
        enum ldcRepo = "ldc-developers/ldc";
        string ldcVer = ver;
        string[] requestedAddons = addons;
        foreach(addon; requestedAddons)
            if(addon == "help")
            {
                info("Addon groups: windows, android, wasi, emscripten");
                info("Use 'redub install ldc <version> --addon=<group>' or 'redub install --addon=<group>'.");
                return 0;
            }

        string currentRoot;
        if(!ldcVer && requestedAddons.length)
        {
            CompilerBinary current = searchCompiler("ldc2", false);
            if(current.compiler == AcceptedCompiler.ldc2 && current.bin.length)
            {
                if(current.version_ >= SemVer("1.43.0"))
                {
                    ldcVer = current.version_.toString;
                    currentRoot = dirName(dirName(current.bin));
                }
                else
                    info("Installed LDC ", current.version_.toString,
                        " does not support addons; using the latest release.");
            }
        }

        if(!ldcVer)
            ldcVer = getLatestGitRepositoryTag(ldcRepo);
        else if(ldcVer == "help")
        {
            import hip.data.json;
            JSONValue gitTags = getGithubRepoAPI(ldcRepo);
            if(gitTags.type != JSONType.array || gitTags.array.length == 0)
            {
                error("Could not fetch LDC versions. See https://github.com/ldc-developers/ldc/releases");
                return 1;
            }
            info("Listing available LDC versions:");
            int limit = 25;
            foreach(entry; gitTags.array)
            {
                info("\t", entry["name"].str);
                if(--limit == 0)
                    break;
            }
            info("Install with 'redub install ldc <version>'.");
            info("Addon targets: windows, android, wasi, emscripten");
            return 0;
        }
        if(currentRoot.length)
        {
            foreach(addon; requestedAddons)
            {
                if(!installLdcAddonTo(ldcVer, currentRoot, addon))
                {
                    error("Could not install LDC addon '", addon, "'");
                    return 1;
                }
            }
            return 0;
        }
        if(!installLdc(ldcVer))
        {
            error("Could not install LDC ", ldcVer);
            return 1;
        }
        foreach(addon; requestedAddons)
        {
            if(!installLdcAddon(ldcVer, addon))
            {
                error("Could not install LDC addon '", addon, "'");
                return 1;
            }
        }
    }
    else if(compiler == "emsdk" || compiler == "emscripten")
    {
        import redub.misc.emscripten_install;
        string emsdkVer = ver is null || ver.length == 0 ? "latest" : ver;
        if(emsdkVer == "help")
        {
            import d_downloader : downloadToBuffer;
            import hip.data.json;
            import redub.libs.semver : SemVer;
            import std.algorithm.sorting : sort;
            import std.string : endsWith;
            try
            {
                auto raw = downloadToBuffer(
                    "https://raw.githubusercontent.com/emscripten-core/emsdk/main/emscripten-releases-tags.json");
                JSONValue tags = parseJSON(cast(char[]) raw, true);
                if(auto releases = "releases" in tags)
                {
                    string[] versions;
                    foreach(string releaseVer, JSONValue _; (*releases).object)
                        if(!releaseVer.endsWith("-asserts"))
                            versions ~= releaseVer;
                    versions.sort!((a, b) => SemVer(a) > SemVer(b));
                    info("Listing available Emscripten SDK versions:");
                    size_t limit = versions.length < 25 ? versions.length : 25;
                    foreach(releaseVer; versions[0 .. limit])
                        info("\t", releaseVer);
                    info("Install with 'redub install emsdk <version>'.");
                    return 0;
                }
            }
            catch(Exception) {}
            info("Use 'latest' or a version from https://github.com/emscripten-core/emsdk.");
            return 0;
        }
        if(!installEmscriptenSdk(emsdkVer))
        {
            error("Could not install the Emscripten SDK");
            return 1;
        }
    }
    else if(compiler == "wasi-sdk" || compiler == "wasi")
    {
        import redub.misc.wasi_sdk_install;
        string wasiVer = ver;
        if(wasiVer == "help")
        {
            import redub.misc.github_tag_check : getGithubRepoAPI;
            import hip.data.json;
            JSONValue tags = getGithubRepoAPI("WebAssembly/wasi-sdk");
            if(tags.type != JSONType.array || tags.array.length == 0)
            {
                error("Could not fetch WASI SDK versions. See https://github.com/WebAssembly/wasi-sdk/releases");
                return 1;
            }
            info("Listing available WASI SDK versions:");
            int limit = 25;
            foreach(entry; tags.array)
            {
                string name = entry["name"].str;
                if(name.indexOf("-rc") != -1)
                    continue;
                info("\t", name);
                if(--limit == 0)
                    break;
            }
            info("Install with 'redub install wasi-sdk <version>' (e.g. '25', 'v25' or 'wasi-sdk-25').");
            return 0;
        }
        if(!installWasiSdk(wasiVer))
        {
            error("Could not install WASI SDK");
            return 1;
        }
    }
    else if(compiler == "android-ndk")
    {
        import redub.misc.android_install : DefaultAndroidNdkVersion,
            installAndroidNdk, listAndroidNdkVersions;
        if(ver == "help")
        {
            listAndroidNdkVersions();
            return 0;
        }
        string ndkVer = ver is null || ver.length == 0 ? DefaultAndroidNdkVersion : ver;
        if(!installAndroidNdk(ndkVer))
        {
            error("Could not install Android NDK ", ndkVer);
            return 1;
        }
    }
    else if(compiler == "dmd")
    {
        import redub.misc.dmd_install;
        if(ver == "help")
        {
            import hip.data.json;
            import redub.misc.github_tag_check : getGithubRepoAPI;
            JSONValue tags = getGithubRepoAPI("dlang/dmd");
            if(tags.type == JSONType.array && tags.array.length)
            {
                info("Listing available DMD versions:");
                int limit = 25;
                foreach(entry; tags.array)
                {
                    info("\t", entry["name"].str);
                    if(--limit == 0)
                        break;
                }
            }
            else
                info("Could not fetch DMD versions. See https://downloads.dlang.org/releases/2.x");
            info("Default version: ", DefaultDMDVersion,
                ". Install with 'redub install dmd <version>'.");
            return 0;
        }
        string dmdVer = ver is null || ver.length == 0 ? DefaultDMDVersion : ver;
        if(!installDmd(dmdVer))
        {
            error("Could not install DMD ", dmdVer);;
            return 1;
        }
    }
    else
    {
        error("Unknown install target: ", compiler,
            "\nAvailable targets: opend, ldc, dmd, wasi-sdk, emsdk");
        info("Run 'redub install --help' for usage, versions and examples.");
        return 1;
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

    static int errorMessage()
    {
        error("redub use requires 1 additional argument: ",
        "\n\topend <dmd|ldc>: uses the wanted opend compiler as the default",
        "\n\tldc <version|path?>: looks in PATH if version|path is unspecified. Downloads latest if not found.",
        "\n\tdmd <version|path?>: looks in PATH if version|path is unspecified. Downloads "~DefaultDMDVersion~" if not found.",
        "\n\treset: removes the default compiler and redub will set it again by the first one found in the PATH environment variable.",
        );
        return 1;
    }
    if(args.length == 1)
        return errorMessage();

    static string tryGetCompiler(AcceptedCompiler comp, string compilerPath, out bool useInternalCompilers)
    {
        bool useDefaultBehavior = compilerPath.length == 0;
        string compiler = comp == AcceptedCompiler.dmd ? "dmd" : "ldc2";
        if(useDefaultBehavior)
        {
            import redub.tooling.compiler_identification;
            CompilerBinary bin = searchCompiler(compiler, false);
            if(bin.compiler == comp)
            {
                useInternalCompilers = true;
                return bin.bin;
            }
        }
        else if(exists(compilerPath)) //Path
        {
            CompilerBinary bin = searchCompiler(compilerPath, false);
            if(bin.compiler != comp)
                throw new RedubException("Attempt to use path "~compilerPath~" as a "~compiler~" compiler, but it is a "~bin.getCompilerString);
            useInternalCompilers = true;
            return bin.bin;
        }
        return null;
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
        string ldcVerOrPath = args.length > 2 ? args[2] : null;
        bool useInternal;
        string ldcBin = tryGetCompiler(AcceptedCompiler.ldc2, ldcVerOrPath, useInternal);
        if(!useInternal)
        {
            import redub.misc.ldc_install;
            import redub.misc.github_tag_check;
            enum ldcRepo = "ldc-developers/ldc";

            if(!ldcVerOrPath)
                ldcVerOrPath = getLatestGitRepositoryTag(ldcRepo);
            string ldcFolder = getLdcFolder(ldcVerOrPath);

            if(!exists(ldcFolder))
                installLdc(ldcVerOrPath);
            version(Windows)
                ldcBin = buildNormalizedPath(ldcFolder, "ldc2.exe");
            else
                ldcBin = buildNormalizedPath(ldcFolder, "ldc2");
        }
        saveGlobalCompiler(ldcBin, meta, true, false);
    }
    else if(compiler == "dmd")
    {
        import redub.misc.dmd_install;
        string dmdVerOrPath = args.length > 2 ? args[2] : null;
        bool useInternal;
        string dmdBin = tryGetCompiler(AcceptedCompiler.dmd, dmdVerOrPath, useInternal);
        import std.stdio;
        writeln("DMD ", dmdBin);
        if(!useInternal)
        {
            if(!dmdVerOrPath)
                dmdVerOrPath = DefaultDMDVersion;
            string dmdFolder = getDmdFolder(dmdVerOrPath);
            if(!exists(dmdFolder) && !installDmd(dmdVerOrPath))
            {
                error("Could not install DMD for using it.");
                return 1;
            }
            version(Windows)
                dmdBin = buildNormalizedPath(dmdFolder, "dmd.exe");
            else
                dmdBin = buildNormalizedPath(dmdFolder, "dmd");
        }
        saveGlobalCompiler(dmdBin, meta, true, false);
    }
    else if(compiler.startsWith("reset"))
    {
        meta.data.object.remove("defaultCompiler");
        meta.data.object.remove("globalPaths");
        infos("Default redub compiler is now reset.");
    }
    else
        return errorMessage();

    if("defaultCompiler" in meta)
    {
        infos(meta["globalPaths"][meta["defaultCompiler"].str].str, " is now the default compiler");
    }
    saveRedubMeta(meta);
    return 0;
}

int configureMain(string[] args)
{
    import redub.cli.dub;
    import redub.logging;
    import redub.meta;
    import redub.misc.path;
    import std.getopt;
    setLogLevel(LogLevel.info);

    struct ConfigArgs
    {
        @("Sets whether redub checks for update when an error happens")
        @("update-check")
        bool updateCheck = true;
    }
    ConfigArgs config;
    GetoptResult res = betterGetopt(args, config);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" configure usage: redub configure [options]\nOptions:", res.options);
        return 0;
    }
    JSONValue meta = getRedubMeta();
    meta["updateCheck"] = JSONValue(config.updateCheck);
    saveRedubMeta(meta);
    return 0;
}

/**
 * `redub help <topic>` with a topic that is not a command (OpenShellOrg CLI Help CH-16, CLI Dispatch CD-1):
 * name the token, suggest a close command, point at the top-level help, stderr, exit 2.
 */
int unknownHelpTopic(string topic, string[] commands)
{
    import std.stdio : stderr;
    import std.algorithm : sort, filter, map, minElement;
    import std.algorithm.comparison : levenshteinDistance;
    import std.array : array, join;
    import std.typecons : tuple;

    string[] cmds = commands.dup;
    sort(cmds);
    stderr.writeln("error: no help topic '", topic, "'");
    auto close = cmds.map!(c => tuple(levenshteinDistance(topic, c), c)).filter!(t => t[0] <= 2).array;
    if(close.length)
        stderr.writeln("  did you mean: redub help ", close.minElement!"a[0]"[1]);
    stderr.writeln("  redub commands: ", cmds.join(", "));
    stderr.writeln("  see: redub help");
    return 2;
}