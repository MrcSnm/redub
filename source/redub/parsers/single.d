module redub.parsers.single;
import redub.parsers.automatic;
import redub.logging;
public import redub.buildapi;
public import std.system;
static import redub.parsers.json;
static import redub.parsers.sdl;
static import redub.parsers.environment;
import redub.command_generators.commons;
import redub.tree_generators.dub;

/** 
 * Parses an initial directory, not recursively. Currently only .sdl and .json are parsed.
 * After the parse happens, it also partially finish the requirements by using a generalized fix
 * for after the parsing stage.
 * Params:
 *   projectWorkingDir = Optional working dir. What is the root being considered for the recipe file
 *   compiler = Which compiler to use
 *   subConfiguration = Sub configuration to use
 *   subPackage = Optional sub package
 *   recipe = Optional recipe to read. It's path is not used as root.
 *   targetOS = Will be used to filter out some commands
 *   isa = Instruction Set Architexture to use for filtering commands
 *   isRoot = When the package is root, it is added to the package searching cache automatically with version 0.0.0
 *   version = The actual version of that project, may be null on root
 *   useExistingObj = Makes the project output dependencies if it is a root project. Disabled by default since compilation may be way slower
 * Returns: The build requirements to the project. Not recursive.
 */
BuildRequirements parseProject(
    string projectWorkingDir, 
    CompilationInfo cInfo,
    BuildRequirements.Configuration subConfiguration,
    string subPackage, 
    string recipe,
    bool isRoot = false,
    string version_ = null,
    bool useExistingObj = false
)
{
    import std.path;
    import std.file;
    import redub.package_searching.entry;
    if(!std.file.exists(projectWorkingDir))
        throw new Exception("Directory '"~projectWorkingDir~"' does not exists.");

    SingleFileData singleInfo = readConfigurationFromFile(recipe);

    inLogLevel(LogLevel.vverbose, infos("Single Recipe", "'", singleInfo.defaultPackageName, "': ", singleInfo.recipe));
    BuildRequirements req;
    BuildConfiguration pending;
    switch(extension(singleInfo.fileName))
    {
        case ".sdl":   req = redub.parsers.sdl.parseWithData(recipe, singleInfo.recipe, projectWorkingDir, cInfo, singleInfo.defaultPackageName, version_, subConfiguration, subPackage, pending, "", false, isRoot); break;
        case ".json":  req = redub.parsers.json.parseWithData(recipe, singleInfo.recipe, projectWorkingDir, cInfo, singleInfo.defaultPackageName ,version_, subConfiguration, subPackage, pending, "", false, isRoot); break;
        default: throw new Exception("Unsupported project type "~recipe~" at dir "~projectWorkingDir);
    }
    req.cfg.targetType = TargetType.executable;
    req.cfg.outputDirectory = dirName(recipe);
    req.cfg.sourceFiles.exclusiveMerge([recipe]);

    return postProcessBuildRequirements(req, pending, cInfo, isRoot, useExistingObj);
}



struct SingleFileData
{
    string recipe;
    string fileName;
    string defaultPackageName;
}


/**
 * Most of it took from https://github.com/dlang/dub/blob/059291d1e4438a7925be4923e8b93495643d205e/source/dub/dub.d#L559
 * Params:
 *   file = The file which contains a dub recipe to be parsed, must start with a comment using /+ +/, and contain the type of it:
 * e.g:
 ```d
 /+
 dub.json:
 {
    "dependencies": {
        "redub": "~>1.14.16"
    }
 }
 +/
 ```
 * Returns:
 */
SingleFileData readConfigurationFromFile(string file)
{
    import std.file;
    import std.string;
    import std.exception;
    import std.path;
    string data = readText(file);

    if (data.startsWith("#!")) {
        auto idx = data.indexOf('\n');
        enforce(idx > 0, "The source fine doesn't contain anything but a shebang line.");
        data = data[idx+1 .. $];
    }

    string recipeContent;

    if (data.startsWith("/+")) {
        data = data[2 .. $];
        auto idx = data.indexOf("+/");
        enforce(idx >= 0, "Missing \"+/\" to close comment.");
        recipeContent = data[0 .. idx].strip();
    }
    else
        throw new Exception("The source file must start with a recipe comment.");

    auto nidx = recipeContent.indexOf('\n');
    auto idx = recipeContent.indexOf(':');

    enforce(idx > 0 && (nidx < 0 || nidx > idx),
        "The first line of the recipe comment must list the recipe file name followed by a colon (e.g. \"/+ dub.sdl:\").");
    string fileName = recipeContent[0 .. idx];
    recipeContent = recipeContent[idx+1 .. $];
    string defaultPackageName = file.baseName.stripExtension.strip;

    return SingleFileData(
        recipeContent,
        fileName,
        defaultPackageName
    );
}