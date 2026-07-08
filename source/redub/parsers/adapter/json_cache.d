module redub.parsers.adapter.json_cache;
public import hip.data.json;

private __gshared JSONValue[string] jsonCache;

/**
 * Params:
 *   filePath = Uses filePath as the file data for parsing. Better API
 * Returns: Same as parseJSONCache
 */
JSONValue parseJSONCached(string filePath)
{
    import std.file;
    return parseJSONCached(filePath, std.file.readText(filePath));
}

/**
 * Optimization to be used when dealing with subPackages.
 * Params:
 *   filePath = The path to use for getting it from cache, used simply as a key to the jsonCache
 *   fileData = The actual content to be used for parsing
 */
JSONValue parseJSONCached(string filePath, string fileData)
{
    synchronized
    {
        JSONValue* cached = filePath in jsonCache;
        if(cached) return *cached;
        jsonCache[filePath] = parseJSON(fileData, true);
        if(jsonCache[filePath].hasErrorOccurred)
            throw new Exception(jsonCache[filePath].error);
        return jsonCache[filePath];
    }
}

/**
 * This function was created since on libraries, they may be reusing multiple times and thus
 * storing the cache between runs may trigger errors.
 */
public void clearJsonCache()
{
    jsonCache = null;
}
