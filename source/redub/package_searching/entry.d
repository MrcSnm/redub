module redub.package_searching.entry;
immutable string[] validEntryFiles = ["dub.json", "dub.sdl", "package.json"];

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
        string entryPath = getCachedNormalizedPath(workingDir, entry);
        if(std.file.exists(entryPath))
            return entryPath;
    }
    return null;
}

private scope string getCachedNormalizedPath(string dir, string file)
{
    static char[4096] entryCache;
    char[] temp = entryCache;
    import redub.misc.path;
    string ret = normalizePath(temp, dir, file);
    return ret;
}