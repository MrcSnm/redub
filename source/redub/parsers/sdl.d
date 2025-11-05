module redub.parsers.sdl;
public import redub.buildapi;
public import std.system;
import hip.data.json;
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
    out BuildConfiguration pending,
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
        pending,
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
    out BuildConfiguration pending,
    string parentName,
    bool isDescribeOnly = false,
    bool isRoot = false
)
{
    static import redub.parsers.json;
    import redub.parsers.base;

    ParseConfig c = ParseConfig(workingDir, subConfiguration, subPackage, version_, cInfo, defaultPackageName, ParseSubConfig(null, parentName), preGenerateRun: !isDescribeOnly);
    JSONValue json = parseSdlCached(filePath, fileData);
    BuildRequirements ret = redub.parsers.json.parse(json, c, pending, isRoot);
    return ret;
}

/**
 *
 * Params:
 *   filePath = The path of the recipe file
 * Returns: Only the file name. Way faster than parsing the configurations
 */
string getPackageName(string filePath)
{
    import std.file;
    JSONValue v = parseSdlCached(filePath, readText(filePath));
    return v["name"].str;
}

private JSONValue[string] sdlJsonCache;
JSONValue parseSdlCached(string filePath, string fileData)
{
    import dub_sdl_to_json;
    JSONValue* cached = filePath in sdlJsonCache;
    if(cached) return *cached;
    JSONValue ret = sdlToJSON(parseSDL(filePath, fileData));
    if(ret.hasErrorOccurred)
        throw new Exception(ret.error);
    return sdlJsonCache[filePath] = ret;
}

void clearSdlRecipeCache(){sdlJsonCache = null;}