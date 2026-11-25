module redub.misc.atomic_write;

/**
 * Writes `data` to `path` atomically.
 *
 * The bytes go to a temporary file in the same directory and are renamed into
 * place, so a reader never sees a partial file and an interrupted write leaves
 * at most a temporary sibling behind.
 *
 * Params:
 *   path = Destination path. Its parent directory must exist.
 *   data = Bytes to write.
 */
void writeFileAtomic(string path, const(void)[] data)
{
    import std.conv : to;
    import std.file : rename, remove, write;
    import std.random : Random, unpredictableSeed, uniform;

    Random seed = Random(unpredictableSeed);
    string temporaryPath = path ~ "." ~ uniform(0u, uint.max, seed).to!string ~ ".tmp";
    write(temporaryPath, data);
    scope(failure) remove(temporaryPath);
    rename(temporaryPath, path);
}

unittest
{
    import std.conv : to;
    import std.file : exists, readText, remove, tempDir;
    import std.path : buildNormalizedPath;
    import std.random : Random, unpredictableSeed, uniform;

    Random seed = Random(unpredictableSeed);
    string path = buildNormalizedPath(tempDir, "redub-atomic-" ~ uniform(0u, uint.max, seed).to!string);
    scope(exit) if(exists(path)) remove(path);

    writeFileAtomic(path, "first");
    assert(readText(path) == "first");
    writeFileAtomic(path, "second");
    assert(readText(path) == "second");
}
