module redub.parsers.environment;
import redub.cli.dub;
import redub.buildapi;
import std.process;
import std.system;


/** 
 * Handles dub defined project configuration based on environment
 * Returns: 
 */
BuildConfiguration parse()
{
    import std.process;
    import std.string;
    import std.array;
    BuildConfiguration ret;
    static string[] getArgs(string v){return std.string.split(v, " ");}
    static immutable handlers = [
        ///Contents of the "dflags" field as defined by the package recipe
        "DFLAGS": (ref BuildConfiguration cfg, string v){cfg.dFlags = getArgs(v);},
        ///Contents of the "lflags" field as defined by the package recipe
        "LFLAGS": (ref BuildConfiguration cfg, string v){cfg.linkFlags = getArgs(v);},
        ///Contents of the "versions" field as defined by the package recipe
        "VERSIONS": (ref BuildConfiguration cfg, string v){cfg.versions = getArgs(v);},
        ///Contents of the "libs" field as defined by the package recipe
        "LIBS": (ref BuildConfiguration cfg, string v){cfg.libraries = getArgs(v);},
        ///Contents of the "sourceFiles" field as defined by the package recipe
        "SOURCE_FILES": (ref BuildConfiguration cfg, string v){cfg.sourceFiles = getArgs(v);},
        ///Contents of the "importPaths" field as defined by the package recipe
        "IMPORT_PATHS": (ref BuildConfiguration cfg, string v){cfg.importDirectories = getArgs(v);},
        ///Contents of the "stringImportPaths" field as defined by the package recipe
        "STRING_IMPORT_PATHS": (ref BuildConfiguration cfg, string v){cfg.stringImportPaths = getArgs(v);},
    ];
   
    foreach(string key, fn; handlers)
    {
        if(key in environment)
            fn(ret, environment[key]);
    }
    return ret;
}


struct InitialDubVariables
{
    ///Path to the DUB executable
    string DUB;
    ///Name of the package
    string DUB_PACKAGE ;
    ///Version of the package
    string DUB_PACKAGE_VERSION ;
    ///Compiler binary name (e.g. "../dmd" or "ldc2")
    string DC ;
    ///Canonical name of the compiler (e.g. "dmd" or "ldc")
    string DC_BASE ;

    ///Name of the selected build configuration (e.g. "application" or "library")
    string DUB_CONFIG ;
    ///Name of the selected build type (e.g. "debug" or "unittest")
    string DUB_BUILD_TYPE ;
    ///Name of the selected build mode (e.g. "separate" or "singleFile")
    string DUB_BUILD_MODE ;
    ///Absolute path in which the package was compiled (defined for "postBuildCommands" only)
    string DUB_BUILD_PATH ;
    ///"TRUE" if the --combined flag was used, empty otherwise
    string DUB_COMBINED ;
    ///"TRUE" if the "run" command was invoked, empty otherwise
    string DUB_RUN ;
    ///"TRUE" if the --force flag was used, empty otherwise
    string DUB_FORCE ;
    ///"TRUE" if the --rdmd flag was used, empty otherwise
    string DUB_RDMD ;
    ///"TRUE" if the --temp-build flag was used, empty otherwise
    string DUB_TEMP_BUILD ;
    ///"TRUE" if the --parallel flag was used, empty otherwise
    string DUB_PARALLEL_BUILD="TRUE";
    ///Contains the arguments passed to the built executable in shell compatible format
    string DUB_RUN_ARGS ;

    ///The compiler frontend version represented as a single integer, for example "2072" for DMD 2.072.2
    string D_FRONTEND_VER ;
    ///Path to the DUB executable
    string DUB_EXE ;
    ///Name of the target platform (e.g. "windows" or "linux")
    string DUB_PLATFORM ;
    ///Name of the target architecture (e.g. "x86" or "x86_64")
    string DUB_ARCH ;

    ///Working directory in which the compiled program gets run
    string DUB_WORKING_DIRECTORY;
}

struct RootPackageDubVariables
{
    ///Name of the root package that is being built
    string DUB_ROOT_PACKAGE ;
    ///Contents of the "targetType" field of the root package as defined by the package recipe
    string DUB_ROOT_PACKAGE_TARGET_TYPE ;
    ///Contents of the "targetPath" field of the root package as defined by the package recipe
    string DUB_ROOT_PACKAGE_TARGET_PATH ;
    ///Contents of the "targetName" field of the root package as defined by the package recipe
    string DUB_ROOT_PACKAGE_TARGET_NAME ;
}

struct PackageDubVariables
{
    ///Path to the package itself
    string PACKAGE_DIR ;
    ///Contents of the "targetType" field as defined by the package recipe
    string DUB_TARGET_TYPE ;
    ///Contents of the "targetPath" field as defined by the package recipe
    string DUB_TARGET_PATH ;
    ///Contents of the "targetName" field as defined by the package recipe
    string DUB_TARGET_NAME ;
    ///Contents of the "mainSourceFile" field as defined by the package recipe
    string DUB_MAIN_SOURCE_FILE ;

}

void setupBuildEnvironmentVariables(InitialDubVariables dubVars)
{
    static foreach(member; __traits(allMembers, InitialDubVariables))
        environment[member] = mixin("dubVars.",member);
}


InitialDubVariables getInitialDubVariablesFromArguments(DubArguments args, DubBuildArguments bArgs, OS os, string[] rawArgs)
{
    import std.file;
    InitialDubVariables dubVars;
    dubVars.DUB = rawArgs[0];
    dubVars.DUB_BUILD_TYPE = args.buildType;
    dubVars.DUB_CONFIG = args.config;
    dubVars.DC_BASE = args.compiler;
    dubVars.DUB_ARCH = args.arch;
    dubVars.DUB_PLATFORM = os.str;
    dubVars.DUB_TEMP_BUILD = bArgs.tempBuild.str;
    dubVars.DUB_RDMD = bArgs.rdmd.str;
    dubVars.DUB_FORCE = bArgs.force.str;
    dubVars.DUB_RUN_ARGS = escapeShellCommand(rawArgs[1..$]);
    dubVars.DUB_WORKING_DIRECTORY = args.cArgs.getRoot(std.file.getcwd());
    return dubVars;
}

void setupEnvironmentVariablesForRootPackage(immutable BuildRequirements root)
{
    import std.conv:to;
    environment["DUB_ROOT_PACKAGE"] = root.name;
    environment["DUB_ROOT_PACKAGE_TARGET_TYPE"] = root.cfg.targetType.to!string;
    environment["DUB_ROOT_PACKAGE_TARGET_PATH"] = root.cfg.outputDirectory;
    environment["DUB_ROOT_PACKAGE_TARGET_NAME"] = root.cfg.name;
}
void setupEnvironmentVariablesForPackageTree(ProjectNode root)
{
    ///Path to a specific package that is part of the package's dependency graph. $ must be in uppercase letters without the semver string.
    // <PKG>_PACKAGE_DIR ;
    foreach(ProjectNode mem; root.collapse)
        environment[mem.name.toUppercase~"_PACKAGE_DIR"] = mem.requirements.cfg.workingDir;
}

void setupEnvironmentVariablesForPackage(immutable BuildRequirements root)
{
    import std.conv:to;
    environment["PACKAGE_DIR"] = root.cfg.workingDir;
    environment["DUB_TARGET_TYPE"] = root.cfg.targetType.to!string;
    environment["DUB_TARGET_PATH"] = root.cfg.outputDirectory;
    environment["DUB_TARGET_NAME"] = root.cfg.name;
    environment["DUB_MAIN_SOURCE_FILE"] = root.cfg.sourceEntryPoint;
}
string parseStringWithEnvironment(string str)
{
    import std.ascii:isAlphaNum;
    struct VarPos
    {
        size_t start, end;
    }
    VarPos[] variables;
    size_t lengthToReduce;
    for(int i = 0; i < str.length; i++)
    {
        if(str[i] == '$')
        {
            size_t start = i+1;
            size_t end = start;
            while(end < str.length && (str[end].isAlphaNum || str[end] == '_')) end++;
            variables~= VarPos(i, end);
            lengthToReduce+= end - i;
            i = cast(int)end;
        }
    }
    if(variables.length == 0)
        return str;
    char[] ret;
    size_t lengthToIncrease;
    for(int i = 0; i < variables.length; i++)
    {
        VarPos v = variables[i];
        string strVar = str[v.start+1..v.end];
        if(strVar.length == 0) //$
            continue;
        else if(!(strVar in environment))
        {
            variables = variables[0..i] ~ variables[i+1..$];
            i--;
            continue;
        }
        lengthToIncrease+= environment[strVar].length;
    }
	if(variables.length == 0) return str;
	
    ret = new char[]((str.length+lengthToIncrease)-lengthToReduce);

	size_t outStart;
	size_t srcStart;
	foreach(v; variables)
	{
		//Remove the $
		string envVar = str[v.start+1..v.end];
		envVar = envVar.length == 0 ? "$" : environment[envVar];

		ret[outStart..outStart+(v.start-srcStart)] = str[srcStart..v.start];
		outStart+= (v.start-srcStart);
		ret[outStart..outStart+envVar.length] = envVar[];
		outStart+= envVar.length;
		srcStart = v.end;
	}
	if(outStart != ret.length)
		ret[outStart..$] = str[srcStart..$];

    return cast(string)ret;
}

/** 
 * 
 * Params:
 *   cfg = Base build configuration which will have its variables merged with environment
 * Returns: Merged configuration
 */
BuildConfiguration parseEnvironment(BuildConfiguration cfg)
{
    with(cfg)
    {
        importDirectories = arrParseEnv(importDirectories);
        sourcePaths = arrParseEnv(sourcePaths);
        sourceFiles = arrParseEnv(sourceFiles);
        dFlags = arrParseEnv(dFlags);
        preGenerateCommands = arrParseEnv(preGenerateCommands);
        postGenerateCommands = arrParseEnv(postGenerateCommands);
        preBuildCommands = arrParseEnv(preBuildCommands);
        postBuildCommands = arrParseEnv(postBuildCommands);
        stringImportPaths = arrParseEnv(stringImportPaths);
    }
    return cfg;
}

///Parse all inside the string array with environment 
string[] arrParseEnv(const string[] input)
{
    if(input.length == 0)
        return null;
    string[] ret = new string[](input.length);
    foreach(i, str; input)
        ret[i] = parseStringWithEnvironment(str);
    return ret;
}

private string toUppercase(string a)
{
    import std.ascii:toUpper;
    char[] ret = new char[](a.length);
    for(int i = 0; i < a.length; i++)
        ret[i] = a[i].toUpper;
    return cast(string)ret;
}



string str(OS os)
{
    switch(os)
    {
        case OS.win32, OS.win64: return "windows";
        case OS.linux, OS.android: return "linux";
        case OS.osx, OS.iOS, OS.tvOS, OS.watchOS: return "osx";
        default: return "posix";
    }
}
string str(bool b){return b ? "TRUE" : "FALSE";}