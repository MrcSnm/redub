module package_searching.entry;
immutable string[] validEntryFiles = ["dub.json", "dub.sdl"];

string findEntryProjectFile(string workingDir)
{
    import std.path;
    static import std.file;
    foreach(entry; validEntryFiles)
    {
        string entryPath = buildNormalizedPath(workingDir, entry);
        if(std.file.exists(entryPath))
            return entryPath;
    }
    return null;
}