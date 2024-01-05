import std.algorithm:countUntil;
import std.conv:to;
import std.typecons:Tuple;
import std.array;
import std.path;
import std.file;
import std.process;
import std.stdio;

import buildapi;

struct DependencyInfo
{
    string name;
    string path;
}

alias DependencySet = bool[DependencyInfo];


struct DependencyNode
{
    DependencyInfo info;
    DependenciesPack pack;

    DependencyNode*[] children;

    public void addChild(DependencyNode* node){children~= node;}


    alias info this;
}

private __gshared DependencySet[DependencyInfo] handledDependencies;
private __gshared DependencyNode root;

version(Windows)
    enum outputExt = ".exe";
else
    enum outputExt = "";


bool handleDependency(DependencyInfo parent, DependencyInfo child, out string err)
{
    if(!(parent in handledDependencies))
        handledDependencies[parent] = DependencySet.init;
    if(child in handledDependencies && parent in handledDependencies[child])
    {
        err = "Diamond dependency problem ( infinite loop found ). \n" ~
        "Child project '"~child.name~"'("~child.path~"') already depends on '"~parent.name~"'("~parent.path~")";
        return false;
    }
    if(child in handledDependencies[parent])
    {
        err = "Dependency called '"~child.name~"' at path '"~child.path~
        "' is already included on project '"~parent.name~"'("~parent.path~")";
        return false;
    }

    handledDependencies[parent][child] = true;
    return true;
}

enum environmentVariable = "HIPMAKE_SOURCE_PATH";
enum projectFileName     = "project.d";
enum cacheFile             = ".hipmake_cache";


nothrow long getTimeLastModified(string file)
{
    if(!std.file.exists(file))
        return -1;
    try{return std.file.timeLastModified(file).stdTime;}
    catch(Exception e){return -1;}
}

nothrow bool isUpToDate(string workspace, out DependenciesPack outputPack)
{
    string cache = buildPath(workspace, ".hipmake", cacheFile);
    string proj = buildPath(workspace, projectFileName);

    if(!std.file.exists(proj))
        return false;
    if(!std.file.exists(cache))
        return false;

    //Read the timestamp
    try
    {
        File f = File(cache, "rb");
        ubyte[] buff = new ubyte[cast(uint)(f.size)];
        f.rawRead(buff);
        f.close();

        string[] content = (cast(string)buff).split('\n');

        long ts = to!long(content[1]);
        long projMod = getTimeLastModified(proj);
        outputPack = packDependencies(workspace, content[2..$].join("\n"));

        return ts == projMod;    
    }
    catch(Exception e)
    {
        try{writeln(e.toString); return false;}
        catch(Exception e){return false;}
    }

    return false;
}

/**
*  Returns if operation was succesful
*/
nothrow bool createCache(string workspace, DependenciesPack pack = DependenciesPack.init)
{
    try
    {
        long t = std.file.timeLastModified(buildPath(workspace, projectFileName)).stdTime;
        string path = buildPath(workspace, ".hipmake", cacheFile);
        File f = File(path, "wb");
        f.write("TIMESTAMP:\n");
        f.write(t);
        f.write("\n", unpackDependencies(pack));
        f.close();
    }
    catch(Exception e)
    {
        try{writeln(e.toString); return false;}
        catch(Exception e){return false;}
    }
    return true;
}

int buildCommandGenerator(string hipMakePath, string workingDir)
{
    chdir(workingDir);
    string outputPath = buildPath(workingDir, ".hipmake");
    string[] commands = 
    [
        "dmd",
        "-i", 
        "-I"~buildPath(hipMakePath, "source"),
        "-I"~workingDir,
        "-od="~outputPath,
        "-of="~buildPath(outputPath, "build"~outputExt),
        buildPath(hipMakePath, "source", "command_generator.d")
    ];

    //Build the command generator
    auto res = std.process.execute(commands);

    if(res.status)
    {
        writeln(res.output);
        return res.status;
    }

    return 0;
}


void makeImportPathAbsolute(string workingDir, ref DependenciesPack pack)
{
    foreach(ref i; pack.importPaths)
        i = buildNormalizedPath(workingDir, i);
    
}

string replaceAll(string str, string replaceWhat, string replaceWith)
{
    int checking = 0;
    string ret = "";
    for(int i = 0; i < str.length; i++)
    {
        while(i+checking < str.length && str[i + checking] == replaceWhat[checking])
        {
            checking++;
            if(checking == replaceWhat.length)
            {
                ret~= replaceWith;
                i+= replaceWhat.length;
                break;
            }
        }
        ret~= str[i];
        checking = 0;
    }
    return ret;
}

alias ShellOutput = Tuple!(int, "status", string, "output");

ShellOutput
execBuild(string workingDir, string projectName, DependencyNode* parentNode, bool dependenciesRequired = false)
{
    chdir(workingDir);
    string file = buildPath(workingDir, ".hipmake", "build"~outputExt);
    string cmd = file;
    //This must be later after resolves the dependencies
    if(willGetCommand)
        cmd~= " getCommand";
    if(dependenciesRequired)
        cmd~= " "~CommandGeneratorControl.dependenciesRequired;

    auto ret = std.process.executeShell(cmd);

    if(ret.status == ExitCodes.commands)
    {
        std.file.write(buildPath(workingDir, ".hipmake", "command.txt"), ret.output);
        return ShellOutput(ExitCodes.success, "");
    }
    else if(ret.status == ExitCodes.dependencies)
    {
        DependenciesPack pack = packDependencies(workingDir, ret.output.replaceAll("\r", ""));
        makeImportPathAbsolute(workingDir, pack);
        if(parentNode == &root)
            root = *parentNode = DependencyNode(DependencyInfo("Root", workingDir), pack, []);
        //Save the current dependencies on the parentNode pack.            
        parentNode.pack = pack;

        //If it has project dependencies, create a new dependency node and add it
        foreach(string dependencyProjectName, dependencyProjectPath; pack.projects) //Build the command generator for them
        {
            string path = dependencyProjectPath;
            DependencyNode* dep = new DependencyNode(DependencyInfo(dependencyProjectName, dependencyProjectPath),
            DependenciesPack.init, []);

            parentNode.addChild(dep);

            path = (!path.isAbsolute) ? buildNormalizedPath(workingDir, path) : path;
            

            if(int status = buildCommandGenerator(hipMakePath, path))
            {
                writeln("Building generator failed at directory '"~path~"' with status ", status);
                return ShellOutput(ExitCodes.error, "");
            }

            auto depBuild = execBuild(path, dependencyProjectName, dep, true);

            switch(depBuild.status)
            {
                case ExitCodes.success:break;
                case ExitCodes.dependencies:break;
                default:
                    writeln("Dependency build failed at project '"~
                        dependencyProjectName~"'("~path~") with error\n", depBuild.output);
                    return depBuild;

            }
        }
    }
    return ret;
}


ref DependenciesPack packFromRoot(DependencyNode* node, return ref DependenciesPack toPack)
{
    if(node != &root) //As it only needs the extra things, don't take root
    {
        toPack.importPaths~= node.pack.importPaths;
        toPack.versions~= node.pack.versions;
        toPack.libPaths~= node.pack.libPaths;
        toPack.libs~= node.pack.libs;
    }
    
    foreach(c;  node.children)
        packFromRoot(c, toPack);

    return toPack;
}


ShellOutput resolveDependencies(string workingDir, DependenciesPack p)
{
    chdir(workingDir);
    string file = buildPath(workingDir, ".hipmake", "build"~outputExt);
    string[] cmd = [file];
    cmd~= CommandGeneratorControl.dependenciesResolved;

    cmd~= unpackDependencies(p);

    if(willGetCommand)
    {
        cmd~= CommandGeneratorControl.getCommand;
    }

    auto ret = std.process.execute(cmd);

    if(ret.status == ExitCodes.commands)
    {
        std.file.write(buildPath(workingDir, ".hipmake", "command.txt"), ret.output);
        return ShellOutput(ExitCodes.success, "");
    }

    return ret;
}

nothrow bool clean(string workingDir)
{
    try
    {
        if(std.file.exists(buildPath(workingDir, ".hipmake")))
            rmdirRecurse(buildPath(workingDir, ".hipmake"));
        return true;
    }
    catch(Exception e)
    {
        try{writeln("Could not remove .hipmake: ", e.toString); return false;}
        catch(Exception e){return false;}
    }
    return false;
}

int checkEnvironment(ref string hipMakePath)
{
    if(environment.get(environmentVariable) is null)
    {
        writefln("%s environment variable not defined. This variable is necessary for
building the project.d file. For setting it under:
        Windows: set %s=\"path\\where\\hipmake\\is\"
        Linux  : export %s=\"path/where/hipmake/is\"

        Beware: If you set it under User Variables or System Variables on Windows, you may need
        to restart your PC.
        
", environmentVariable, environmentVariable, environmentVariable);
        return 1;
    }
    hipMakePath = environment[environmentVariable];
    return 0;
}

int checkProject(string workingDir)
{
    if(!std.file.exists(buildPath(workingDir, projectFileName).asAbsolutePath))
    {
        writeln("'project.d' file not found in the current directory ( "~workingDir~ " )");
        return 1;
    }
    return 0;
}

void createHipmakeFolder(string workingDir)
{
    std.file.mkdirRecurse(buildPath(workingDir, ".hipmake"));
}

string formatError(string err)
{

    if(err.countUntil("which cannot be read") != -1)
    {
        int moduleNameStart = err.countUntil("`") + 1;
        int moduleNameEnd = err[moduleNameStart..$].countUntil("`") + moduleNameStart;
        string moduleName = err[moduleNameStart..moduleNameEnd];

        return err~"\nMaybe you forgot to add the module '"~moduleName~"' source root to import paths?
        Hipmake Failed!";
    }
    return err~"\nHipmake Failed!";
}

bool willGetCommand = false;
string hipMakePath;

/**
*
*   All this file does is:
*   1. Search in the current directory for project.d
*   2. Use that directory as an import place for the project generator
*   3. Build the command generator together with the project.d (as it is being blindly imported )
*   4. Run the command generator using the project gotten from getProject function
*   5. Caches the command generated from the generator until project.d is modified.
*   6. If it is cached, it will only run the command
*/
int main(string[] args)
{
    string workingDir = getcwd();

    DependenciesPack packToCache;

    if(args.length > 1 && args[1] == "clean")
        return cast(int)clean(workingDir);
    else if(args.length > 1 && args[1] == "rebuild")
    {
        if(!clean(workingDir))
        {
            writeln("Error while trying to clean");
            return 1;
        }
    }
    else if(args.length > 1 && args[1] == "command")
        willGetCommand = true;

    if(isUpToDate(workingDir, packToCache))
    {
        writeln("Building "~workingDir);
        auto ret = resolveDependencies(workingDir, packToCache);
        if(ret.status)
            writeln(formatError(ret.output));
        else
            writeln(ret.output);
        return ret.status;
    }

    if(checkEnvironment(hipMakePath))
        return ExitCodes.error;
    if(checkProject(workingDir))
        return ExitCodes.error;
    createHipmakeFolder(workingDir);
    
    if(int cmdGen = buildCommandGenerator(hipMakePath, workingDir))
    {
        writeln("HipMake failed at building command generator for the directory: '"~workingDir~"'");
        return cmdGen;
    }

    writeln("Building "~workingDir);

    auto res = execBuild(workingDir, "Root", &root);
    if(res.status == ExitCodes.dependencies)
    {
        packFromRoot(&root, packToCache);
        res = resolveDependencies(workingDir, packToCache);
        if(res.status)
            writeln(formatError(res.output));
        else
            writeln(res.output);
    }
    else if(res.status == ExitCodes.error)
    {
        writeln(res.output);
        return ExitCodes.error;
    }
    chdir(workingDir);

    if(!createCache(workingDir, packToCache))
        writeln("Could not create a timestamp cache");

    return ExitCodes.success;
}