module package_searching.entry;
immutable string[] validEntryFiles = ["dub.json", "dub.sdl"];

/** 
 * 
 * Params:
 *   workingDir = A non null working directory. Null is reserved for not found packages. Only absolute paths valid
 * Returns: An accepted project file type.
 */
string findEntryProjectFile(string workingDir, string recipe = null)
{
    import std.path;
    static import std.file;
    if(recipe)
        return recipe;
    if(!workingDir.length)
        return null;
    foreach(entry; validEntryFiles)
    {
        string entryPath = buildNormalizedPath(workingDir, entry);
        if(std.file.exists(entryPath))
            return entryPath;
    }
    return null;
}