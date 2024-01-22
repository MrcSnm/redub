module redub.parsers.sdl;
public import redub.buildapi;

BuildRequirements parse(
    string filePath, 
    string workingDir,  
    string compiler, 
    string version_, 
    BuildRequirements.Configuration subConfiguration, 
    string subPackage
)
{
    static import redub.parsers.json;
    import std.process;
    import std.file;
    import std.path;

    string currDir = getcwd();
    chdir(workingDir);
    auto exec = executeShell("dub convert -f json -s");

    if(exec.status)
        throw new Exception("dub could not convert file at path "~filePath~" to json: "~exec.output);
    
    string tempFile = filePath~".json"; //.sdl.json
    std.file.write(tempFile, exec.output);
    BuildRequirements ret = redub.parsers.json.parse(tempFile, workingDir, compiler, version_, subConfiguration, subPackage);
    chdir(currDir);
    std.file.remove(tempFile);
    return ret;
}