module redub.parsers.environment;
import redub.cli.dub;
import redub.buildapi;
import core.sync.mutex;
import std.system;



/** 
 * Handles dub defined project configuration based on environment
 * Returns: 
 */
BuildConfiguration parse()
{
    import std.process;
    import std.string;
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
        string v = getEnvVariable(key);
        if(v)
            fn(ret, v);
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
    string DC;
    ///Canonical name of the compiler (e.g. "dmd" or "ldc")
    string DC_BASE ;

    ///Name of the selected build configuration (e.g. "application" or "library")
    string DUB_CONFIG ;
    ///Name of the selected build type (e.g. "debug" or "unittest")
    string DUB_BUILD_TYPE ;
    ///Name of the selected build mode (e.g. "separate" or "singleFile")
    string DUB_BUILD_MODE = "separate";
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
    ///Directory of the root package that is being built
    string DUB_ROOT_PACKAGE_DIR ;
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
    string PACKAGE_DIR;
    ///Path to the package itself
    string DUB_PACKAGE_DIR ;
    ///Contents of the "targetType" field as defined by the package recipe
    string DUB_TARGET_TYPE ;
    ///Contents of the "targetPath" field as defined by the package recipe
    string DUB_TARGET_PATH ;
    ///Contents of the "targetName" field as defined by the package recipe
    string DUB_TARGET_NAME ;
    ///Contents of the "mainSourceFile" field as defined by the package recipe
    string DUB_MAIN_SOURCE_FILE ;

}

/** 
 * Reflects InitialDubVariables in the environment
 */
void setupBuildEnvironmentVariables(InitialDubVariables dubVars)
{
    import std.process;
    static foreach(member; __traits(allMembers, InitialDubVariables))
    {
        setEnvVariable(member, mixin("dubVars.",member));
    }
}


InitialDubVariables getInitialDubVariablesFromArguments(DubArguments args, DubBuildArguments bArgs, OS os, string[] rawArgs)
{
    import std.process;
    import std.file;
    InitialDubVariables dubVars;
    dubVars.DUB                 = rawArgs[0];
    dubVars.DUB_BUILD_TYPE      = args.buildType;
    dubVars.DUB_CONFIG          = args.config;
    dubVars.DC_BASE             = args.compiler;
    dubVars.DUB_ARCH            = args.arch;
    dubVars.DUB_PLATFORM        = os.str;
    dubVars.DUB_TEMP_BUILD      = bArgs.tempBuild.str;
    dubVars.DUB_RDMD            = bArgs.rdmd.str;
    dubVars.DUB_FORCE           = bArgs.force.str;
    dubVars.DUB_PARALLEL_BUILD  = str(bArgs.parallel == ParallelType.no);
    dubVars.DUB_RUN_ARGS        = escapeShellCommand(rawArgs[1..$]);
    dubVars.DUB_WORKING_DIRECTORY = args.cArgs.getRoot(std.file.getcwd());
    return dubVars;
}

/** 
 * This, setups on environment the following variables:
 * - DUB_ROOT_PACKAGE
 * - DUB_ROOT_PACKAGE_DIR
 * - DUB_ROOT_PACKAGE_TARGET_TYPE
 * - DUB_ROOT_TARGET_PATH
 * - DUB_ROOT_PACKAGE_TARGET_NAME
 * Params:
 *   root = The root project being parsed
 */
void setupEnvironmentVariablesForRootPackage(immutable BuildRequirements root)
{
    import std.process;
    import std.conv:to;
    setEnvVariable("DUB_ROOT_PACKAGE", root.name);
    setEnvVariable("DUB_ROOT_PACKAGE_DIR",  root.cfg.workingDir.forceTrailingDirSeparator);
    setEnvVariable("DUB_ROOT_PACKAGE_TARGET_TYPE",  root.cfg.targetType.to!string);
    setEnvVariable("DUB_ROOT_PACKAGE_TARGET_PATH",  root.cfg.outputDirectory);
    setEnvVariable("DUB_ROOT_PACKAGE_TARGET_NAME",  root.cfg.name);
}


/** 
 * This function traverses the project tree, while generating environment variables for the directory
 * of the package, by using its name and post-fixed with _PACKAGE_DIR
 * e.g:
 * - redub will generate REDUB_PACKAGE_DIR: containing its working directory
 * Params:
 *   root = The root where <PKG>_PACKAGE_DIR will be started to be put on environment
 */
void setupEnvironmentVariablesForPackageTree(ProjectNode root)
{
    ///Path to a specific package that is part of the package's dependency graph. $ must be in uppercase letters without the semver string.
    // <PKG>_PACKAGE_DIR ;
    foreach(ProjectNode mem; root.collapse)
        setEnvVariable(asPackageVariable(mem.name)~"_PACKAGE_DIR",  mem.requirements.cfg.workingDir.forceTrailingDirSeparator);
}

/** 
 * Gets the following variables for including in the environment in the build step.
 * - DUB_PACKAGE_DIR
 * - DUB_TARGET_TYPE
 * - DUB_TARGET_PATH
 * - DUB_TARGET_NAME
 * - DUB_MAIN_SOURCE_FILE
 */
PackageDubVariables getEnvironmentVariablesForPackage(const BuildConfiguration cfg)
{
    import std.conv:to;

    string dir = cfg.workingDir.forceTrailingDirSeparator;
    return PackageDubVariables(
        PACKAGE_DIR: dir,
        DUB_PACKAGE_DIR: dir,
        DUB_TARGET_TYPE: cfg.targetType.to!string,
        DUB_TARGET_PATH: cfg.outputDirectory,
        DUB_TARGET_NAME: cfg.name
    );
}

/** 
 * Setups environment variables based on BuildConfiguration -
 * - DUB_PACKAGE_DIR
 * - DUB_TARGET_TYPE
 * - DUB_TARGET_PATH
 * - DUB_TARGET_NAME
 * - DUB_MAIN_SOURCE_FILE
 */
void setupEnvironmentVariablesForPackage(const BuildConfiguration cfg)
{
    import std.process;
    PackageDubVariables pack = getEnvironmentVariablesForPackage(cfg);
    static foreach(mem; __traits(allMembers, PackageDubVariables))
        setEnvVariable(mem, __traits(getMember, pack, mem));
}
string parseStringWithEnvironment(string str)
{
    import std.process;
    import std.exception;
    import std.string;
    import std.ascii:isAlphaNum;
    struct VarPos
    {
        size_t start, end;
    }
    VarPos[] variables;
    ptrdiff_t diffLength;
    for(int i = 0; i < str.length; i++)
    {
        if(str[i] == '$')
        {
            if(i + 1 < str.length && str[i+1] == '{')
            {
                int end = cast(int)indexOf(str, '}', i);
                enforce(++end != 0, "Could not find matching brackets at "~str);
                variables~= VarPos(i, end);
                i = end;
            }
            else
            {
                size_t start = i+1;
                size_t end = start;
                while(end < str.length && (str[end].isAlphaNum || str[end] == '_')) end++;
                variables~= VarPos(i, end);
                i = cast(int)end;
            }
        }
    }
    if(variables.length == 0)
        return str;

    char[] ret;
    ///Count the difference length between input string and output string and remove inexisntet variables.
    for(int i = 0; i < variables.length; i++)
    {
        VarPos v = variables[i];
        bool useBrackets = v.end > 0 && str[v.end - 1] == '}';
        int bracketOffset = useBrackets ? 1 : 0;
        string strVar = str[v.start+1 + bracketOffset..v.end - bracketOffset];
        diffLength-= 1+strVar.length + bracketOffset*2; //$.length + (abcd).length {}.length (optionally)

        if(strVar.length == 0) //$
            continue;
        else if(!getEnvVariable(strVar))
        {
            variables = variables[0..i] ~ variables[i+1..$];
            i--;
            continue;
        }
        diffLength+= getEnvVariable(strVar).length;
    }
	if(variables.length == 0) return str;
	
    ret = new char[](str.length+diffLength);
	size_t outStart;
	size_t srcStart;

    void appendToRet(string what)
    {
        ret[outStart..outStart+what.length] = what[];
        outStart+= what.length;
    }

    ///Starts appending text or variable depending on the variable positions
	foreach(v; variables)
	{
		//Remove the $ {} optionally
        int bracketOffset = v.end > 0 && str[v.end - 1] == '}';
		string envVar = str[v.start+1 + bracketOffset..v.end - bracketOffset];

        ///Copy text up to the variable 
        string leftText = str[srcStart..v.start];
        appendToRet(leftText);

        ///Insert the variable value
        if(envVar.length)
            appendToRet(getEnvVariable(envVar));

        ///Move the start pointer past the variable
		srcStart = v.end;
	}

	if(outStart != ret.length)
		ret[outStart..$] = str[srcStart..$];

    return cast(string)ret;
}

unittest
{
    import std.stdio;
    assert(parseStringWithEnvironment("$$ORIGIN") == "$ORIGIN");
    assert(parseStringWithEnvironment("'-rpath=$$ORIGIN'") == "'-rpath=$ORIGIN'");
    redubEnv["HOME"] = "test";
    assert(parseStringWithEnvironment("$HOME") == "test");
    assert(parseStringWithEnvironment("${HOME}") == "test");
    assert(parseStringWithEnvironment("$HOME $$ORIGIN") == "test $ORIGIN");
    redubEnv["SOKOL_D_PACKAGE_DIR"] = "test";
    assert(
        parseStringWithEnvironment(`C:\Users\Marcelo\Documents\D\test\sokol-d\${SOKOL_D_PACKAGE_DIR}\src\sokol\c\sokol_log.c`) ==
        `C:\Users\Marcelo\Documents\D\test\sokol-d\test\src\sokol\c\sokol_log.c`
    );

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
        libraries = arrParseEnv(libraries);
        libraryPaths = arrParseEnv(libraryPaths);
        dFlags = arrParseEnv(dFlags);
        linkFlags = arrParseEnv(linkFlags);

        if(cfg.commands.length > RedubCommands.preGenerate)
            cfg.commands[RedubCommands.preGenerate] = arrParseEnv(cfg.commands[RedubCommands.preGenerate]);
        if(cfg.commands.length > RedubCommands.postGenerate)
            cfg.commands[RedubCommands.postGenerate] = arrParseEnv(cfg.commands[RedubCommands.postGenerate]);
        if(cfg.commands.length > RedubCommands.preBuild)
            cfg.commands[RedubCommands.preBuild] = arrParseEnv(cfg.commands[RedubCommands.preBuild]);
        if(cfg.commands.length > RedubCommands.postBuild)
            cfg.commands[RedubCommands.postBuild] = arrParseEnv(cfg.commands[RedubCommands.postBuild]);
        stringImportPaths = arrParseEnv(stringImportPaths);
        filesToCopy = arrParseEnv(filesToCopy);
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

/**
 *
 * Params:
 *   a = Input package name
 * Returns: The package name in uppercase and with '-' turnt into '_'
 */
private string asPackageVariable(string a)
{
    import std.ascii:toUpper;
    char[] ret = new char[](a.length);
    for(int i = 0; i < a.length; i++)
    {
        if(a[i] == '-')
            ret[i] = '_';
        else
            ret[i] = a[i].toUpper;
    }
    return cast(string)ret;
}

string forceTrailingDirSeparator(string input)
{
    import std.path;
    import std.string;
    return input.endsWith(dirSeparator) ? input : input~dirSeparator;
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
string str(bool b){return b ? "TRUE" : null;}




import std.process;
version(AsLibrary) //Library version will use environment instead of redubEnv since it will become easier to interop
{
    alias redubEnv = std.process.environment;
    /**
     * Sets the environment variable. Use std.process.environment if it is being used as a library
     * Params:
     *   key =
     *   value =
     */
    void setEnvVariable(string key, string value){environment[key] = value;}
    /**
     * Gets the environment as a string[string] to be used inside a function
     * Returns:
     */
    string[string] getRedubEnv(){return environment.toAA;}
    /**
     * Gets the environment from within the environment if used as a library, else, use internal associative array
     * with caching
     * Params:
     *   key =
     * Returns:
     */
    string getEnvVariable(string key)
    {
        while(key in environment)
        {
            key = environment[key];
            if(key.length == 0)
                return null;
            else if(key[0] != '$')
                return environment[key];
            else
            {
                key = key[1..$];
                if(key.length > 1 && key[0] == '{' && key[$-1] == '}')
                    key = key[1..$-1];
            }
        }
        return null;
    }
}
else
{
    __gshared string[string] redubEnv;
    private __gshared Mutex envMutex;

    void setEnvVariable(string key, string value)
    {
        synchronized(envMutex)
        {
            redubEnv[key] = value;
        }
    }
    string[string] getRedubEnv(){return redubEnv;}
    string getEnvVariable(string key)
    {
        string* ret = key in redubEnv;
        if(ret) return *ret;
        return null;
    }
    shared static this()
    {
        envMutex = new Mutex;
        redubEnv = environment.toAA;
    }
}
