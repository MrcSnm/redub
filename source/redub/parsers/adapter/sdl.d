module redub.parsers.adapter.sdl;
public import redub.buildapi;
import hip.data.json;

JSONValue sdlToJSONCache(string filePath)
{
    import std.file;
    return sdlToJSONCache(filePath, readText(filePath));
}

private JSONValue[string] sdlJsonCache;
JSONValue sdlToJSONCache(string filePath, string fileData)
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