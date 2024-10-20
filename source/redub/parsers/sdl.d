module redub.parsers.sdl;
public import redub.buildapi;
public import std.system;
import redub.tree_generators.dub;

BuildRequirements parse(
    string filePath, 
    string workingDir,  
    CompilationInfo cInfo,
    string version_, 
    BuildRequirements.Configuration subConfiguration, 
    string subPackage,
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
        auto exec = executeShell("dub convert -f json -s");

        if(exec.status)
            throw new Exception("dub could not convert file at path "~filePath~" to json: "~exec.output);
        std.file.write(tempFile, exec.output);
    }
    BuildRequirements ret = redub.parsers.json.parse(tempFile, workingDir, cInfo, version_, subConfiguration, subPackage, "", isRoot);
    chdir(currDir);
    return ret;
}