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
    bool isDescribeOnly = false,
    bool isRoot = false
)
{
    static import redub.parsers.json;
    import std.process;
    import std.file;
    import std.path;

    string currDir = getcwd();
    string tempFile = filePath~".redub_cache_json"; //.sdl.redub_cache_json
    chdir(workingDir);

    ///If the dub.sdl is newer than the json generated or if it does not exists.
    if(!std.file.exists(tempFile) || timeLastModified(tempFile).stdTime < timeLastModified(filePath).stdTime)
    {
        auto exec = execDubConvert(fileData);
        if(exec.status)
            throw new Exception("dub could not convert file at path "~filePath~" to json: "~exec.output);
        std.file.write(tempFile, exec.output);
    }
    BuildRequirements ret = redub.parsers.json.parse(tempFile, workingDir, cInfo, defaultPackageName, version_, subConfiguration, subPackage, "", isDescribeOnly, isRoot);
    chdir(currDir);
    return ret;
}



string fixSDLParsingBugs(string sdlData)
{
    import std.file;
    import std.string:replace;

    version(Windows)
        enum lb = "\r\n";
    else
        enum lb = "\n";
    return sdlData.replace("\\"~lb, " ").replace("`"~lb, "`");
}

auto execDubConvert(string sdlData)
{
    import std.file;
    import std.path;
    import std.process;

    mkdirRecurse("redub_convert_temp");
    std.file.write(buildNormalizedPath("redub_convert_temp", "dub.sdl"), fixSDLParsingBugs(sdlData));
    scope(exit)
    {
        std.file.rmdirRecurse("redub_convert_temp");
    }
    return executeShell("dub convert -f json -s ", null, Config.none, size_t.max, buildNormalizedPath(getcwd, "redub_convert_temp"));
}