module parsers.sdl;
public import buildapi;

BuildRequirements parse(string filePath, string compiler, string subConfiguration = "", string subPackage = "")
{
    static import parsers.json;
    import std.process;
    import std.file;
    import std.path;

    string currDir = getcwd();
    chdir(dirName(filePath));
    auto exec = executeShell("dub convert -f json -s");

    if(exec.status)
        throw new Exception("dub could not convert file at path "~filePath~" to json: "~exec.output);
    
    string tempFile = filePath~".json"; //.sdl.json
    std.file.write(tempFile, exec.output);
    BuildRequirements ret = parsers.json.parse(tempFile, compiler, subConfiguration, subPackage);
    chdir(currDir);
    std.file.remove(tempFile);
    return ret;
}