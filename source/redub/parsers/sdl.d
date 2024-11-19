module redub.parsers.sdl;
public import redub.buildapi;
public import std.system;
import redub.tree_generators.dub;

/**
 * Converts SDL into a JSON file and parse it as a JSON
 * Uses filePath as fileData for parseWithData
 * Params:
 *   filePath = The path in which the SDL file is located
 *   workingDir = Working dir of the recipe
 *   cInfo = Compilation Info filters
 *   defaultPackageName = Default name, used for --single
 *   version_ = Version being used
 *   subConfiguration = The configuration to use
 *   subPackage = The sub package to use
 *   parentName = Used as metadata
 *   isDescribeOnly = Used for not running the preGenerate commands
 *   isRoot = metadata
 * Returns: The new build requirements
 */
BuildRequirements parse(
    string filePath, 
    string workingDir,  
    CompilationInfo cInfo,
    string defaultPackageName,
    string version_, 
    BuildRequirements.Configuration subConfiguration, 
    string subPackage,
    string parentName,
    bool isDescribeOnly = false,
    bool isRoot = false
)
{
    import std.file;
    return parseWithData(filePath,
        readText(filePath),
        workingDir,
        cInfo,
        defaultPackageName,
        version_,
        subConfiguration,
        subPackage,
        parentName,
        isDescribeOnly,
        isRoot,
    );
}

/**
 * Converts SDL into a JSON file and parse it as a JSON
 * Params:
 *   filePath = The path in which the SDL file is located
 *   fileData = Uses that data instead of file path for parsing
 *   workingDir = Working dir of the recipe
 *   cInfo = Compilation Info filters
 *   defaultPackageName = Default name, used for --single
 *   version_ = Version being used
 *   subConfiguration = The configuration to use
 *   subPackage = The sub package to use
 *   parentName = Metadata
 *   isDescribeOnly = Used for not running preGenerate commands
 *   isRoot = metadata
 * Returns: The new build requirements
 */
BuildRequirements parseWithData(
    string filePath,
    string fileData,
    string workingDir,
    CompilationInfo cInfo,
    string defaultPackageName,
    string version_,
    BuildRequirements.Configuration subConfiguration,
    string subPackage,
    string parentName,
    bool isDescribeOnly = false,
    bool isRoot = false
)
{
    static import redub.parsers.json;
    import redub.parsers.base;
    import dub_sdl_to_json;

    ParseConfig c = ParseConfig(workingDir, subConfiguration, subPackage, version_, cInfo, defaultPackageName, null, parentName, preGenerateRun: !isDescribeOnly);
    JSONValue json = sdlToJSON(parseSDL(filePath, fileData));
    BuildRequirements ret = redub.parsers.json.parse(json, c, isRoot);
    return ret;
}