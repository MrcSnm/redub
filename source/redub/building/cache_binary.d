/**
 * Binary cache backend, kept alongside the JSON backend.
 *
 * The JSON implementation in redub.building.cache remains the active one. This
 * module only provides the format and codec so the integration can be done
 * incrementally. Strings in the decoded model are slices into the input buffer
 * (zero-copy), so the buffer must stay alive while the result is used.
 */
module redub.building.cache_binary;

import redub.libs.adv_diff.files;

import std.array : Appender, appender;
import std.exception : enforce;

enum cacheBinaryMagic = "RDB1";
enum cacheBinaryVersion = 2;
enum cacheBinaryStringLengthPrefixed = 0;

struct CacheSimpleFormula
{
    ubyte[8] contentHash;
    string[] directories;
    string[] files;
}

struct CacheRequirementEntry
{
    CacheSimpleFormula compileFormula;
    CacheSimpleFormula copyFormula;
}

struct CacheFileData
{
    AdvCacheFormula fullFormula;
    CacheRequirementEntry[string] requirements;
}

CacheSimpleFormula simpleFromFormula(const ref AdvCacheFormula formula)
{
    CacheSimpleFormula ret;
    ret.contentHash = formula.contentHash;
    foreach (string name, const AdvDirectory _; formula.directories)
        ret.directories ~= name;
    foreach (string name, const AdvFile _; formula.files)
        ret.files ~= name;
    return ret;
}

AdvCacheFormula formulaFromSimple(const ref CacheSimpleFormula simple, ref AdvCacheFormula reference)
{
    AdvDirectory[string] directories;
    foreach (string name; simple.directories)
    {
        AdvDirectory* directory = name in reference.directories;
        enforce(directory !is null, "Could not find directory '" ~ name ~ "' inside formula reference.");
        directories[name] = *directory;
    }

    AdvFile[string] files;
    foreach (string name; simple.files)
    {
        AdvFile* file = name in reference.files;
        enforce(file !is null, "Could not find file '" ~ name ~ "' inside formula reference.");
        files[name] = *file;
    }

    return AdvCacheFormula(simple.contentHash, directories, files);
}

private void putU8(ref Appender!(ubyte[]) sink, ubyte value)
{
    sink.put(value);
}

private void putU32(ref Appender!(ubyte[]) sink, uint value)
{
    foreach (i; 0 .. 4) sink.put(cast(ubyte) ((value >> (i * 8)) & 0xFF));
}

private void putU64(ref Appender!(ubyte[]) sink, ulong value)
{
    foreach (i; 0 .. 8) sink.put(cast(ubyte) ((value >> (i * 8)) & 0xFF));
}

private void putU16(ref Appender!(ubyte[]) sink, ushort value)
{
    foreach (i; 0 .. 2) sink.put(cast(ubyte) ((value >> (i * 8)) & 0xFF));
}

private void putString(ref Appender!(ubyte[]) sink, string value)
{
    // shortcut: cache strings are limited to 65535 bytes, widen to u32 if paths ever exceed it
    enforce(value.length <= ushort.max, "Cache string exceeds 65535 bytes.");
    putU16(sink, cast(ushort) value.length);
    sink.put(cast(const(ubyte)[]) value);
}

private void putHash(ref Appender!(ubyte[]) sink, const ubyte[8] hash)
{
    sink.put(hash[]);
}

private void putSimpleFormula(ref Appender!(ubyte[]) sink, const ref CacheSimpleFormula formula)
{
    putHash(sink, formula.contentHash);
    putU32(sink, cast(uint) formula.directories.length);
    foreach (name; formula.directories) putString(sink, name);
    putU32(sink, cast(uint) formula.files.length);
    foreach (name; formula.files) putString(sink, name);
}

private ushort getU16(const(ubyte)[] data, ref size_t pos)
{
    enforce(pos + 2 <= data.length, "Unexpected end of binary cache.");
    ushort value = cast(ushort) (data[pos] | (data[pos + 1] << 8));
    pos += 2;
    return value;
}

private uint getU32(const(ubyte)[] data, ref size_t pos)
{
    enforce(pos + 4 <= data.length, "Unexpected end of binary cache.");
    uint value = data[pos] | (data[pos + 1] << 8) | (data[pos + 2] << 16) | (cast(uint) data[pos + 3] << 24);
    pos += 4;
    return value;
}

private ulong getU64(const(ubyte)[] data, ref size_t pos)
{
    enforce(pos + 8 <= data.length, "Unexpected end of binary cache.");
    ulong value;
    foreach (i; 0 .. 8) value |= cast(ulong) data[pos + i] << (i * 8);
    pos += 8;
    return value;
}

private ubyte[8] getHash(const(ubyte)[] data, ref size_t pos)
{
    enforce(pos + 8 <= data.length, "Unexpected end of binary cache.");
    ubyte[8] ret;
    ret[] = data[pos .. pos + 8];
    pos += 8;
    return ret;
}

private string getString(const(ubyte)[] data, ref size_t pos)
{
    ushort length = getU16(data, pos);
    enforce(length <= data.length - pos, "String in binary cache extends past the buffer.");
    string ret = cast(string) cast(ubyte[]) data[pos .. pos + length];
    pos += length;
    return ret;
}

private CacheSimpleFormula getSimpleFormula(const(ubyte)[] data, ref size_t pos)
{
    CacheSimpleFormula formula;
    formula.contentHash = getHash(data, pos);

    uint directoryCount = getU32(data, pos);
    enforce(directoryCount <= data.length - pos, "Invalid directory count in binary cache.");
    formula.directories.length = directoryCount;
    foreach (i; 0 .. directoryCount) formula.directories[i] = getString(data, pos);

    uint fileCount = getU32(data, pos);
    enforce(fileCount <= data.length - pos, "Invalid file count in binary cache.");
    formula.files.length = fileCount;
    foreach (i; 0 .. fileCount) formula.files[i] = getString(data, pos);
    return formula;
}

ubyte[] encodeCacheFile(const ref CacheFileData cache)
{
    auto sink = appender!(ubyte[])();
    sink.put(cast(const(ubyte)[]) cacheBinaryMagic);
    putU8(sink, cacheBinaryVersion);
    putU8(sink, cacheBinaryStringLengthPrefixed);

    putHash(sink, cache.fullFormula.contentHash);
    putU32(sink, cast(uint) cache.fullFormula.directories.length);
    foreach (string name, const AdvDirectory directory; cache.fullFormula.directories)
    {
        putString(sink, name);
        putHash(sink, directory.contentHash);
        putU32(sink, cast(uint) directory.files.length);
        foreach (string fileName, const AdvFile file; directory.files)
        {
            putString(sink, fileName);
            putU64(sink, file.timeModified);
            putHash(sink, file.contentHash);
        }
    }

    putU32(sink, cast(uint) cache.fullFormula.files.length);
    foreach (string name, const AdvFile file; cache.fullFormula.files)
    {
        putString(sink, name);
        putU64(sink, file.timeModified);
        putHash(sink, file.contentHash);
    }

    putU32(sink, cast(uint) cache.requirements.length);
    foreach (string key, const CacheRequirementEntry entry; cache.requirements)
    {
        putString(sink, key);
        putSimpleFormula(sink, entry.compileFormula);
        putSimpleFormula(sink, entry.copyFormula);
    }
    return sink.data;
}

CacheFileData decodeCacheFile(ubyte[] data)
{
    enforce(data.length >= 6, "Binary cache is too small.");
    enforce(cast(string) data[0 .. 4] == cacheBinaryMagic, "Invalid binary cache magic.");
    enforce(data[4] == cacheBinaryVersion, "Unsupported binary cache version.");
    enforce(data[5] == cacheBinaryStringLengthPrefixed, "Unsupported binary cache string encoding.");

    size_t pos = 6;
    CacheFileData cache;

    cache.fullFormula.contentHash = getHash(data, pos);
    uint directoryCount = getU32(data, pos);
    enforce(directoryCount <= data.length - pos, "Invalid directory count in binary cache.");
    foreach (_; 0 .. directoryCount)
    {
        string name = getString(data, pos);
        ubyte[8] contentHash = getHash(data, pos);
        uint fileCount = getU32(data, pos);
        enforce(fileCount <= data.length - pos, "Invalid file count in binary cache.");
        AdvFile[string] files;
        foreach (__; 0 .. fileCount)
        {
            string fileName = getString(data, pos);
            ulong timeModified = getU64(data, pos);
            ubyte[8] fileHash = getHash(data, pos);
            files[fileName] = AdvFile(timeModified, fileHash);
        }
        cache.fullFormula.directories[name] = AdvDirectory(contentHash, files);
    }

    uint rootFileCount = getU32(data, pos);
    enforce(rootFileCount <= data.length - pos, "Invalid file count in binary cache.");
    foreach (_; 0 .. rootFileCount)
    {
        string name = getString(data, pos);
        ulong timeModified = getU64(data, pos);
        ubyte[8] fileHash = getHash(data, pos);
        cache.fullFormula.files[name] = AdvFile(timeModified, fileHash);
    }

    uint requirementCount = getU32(data, pos);
    enforce(requirementCount <= data.length - pos, "Invalid requirement count in binary cache.");
    foreach (_; 0 .. requirementCount)
    {
        string key = getString(data, pos);
        CacheRequirementEntry entry;
        entry.compileFormula = getSimpleFormula(data, pos);
        entry.copyFormula = getSimpleFormula(data, pos);
        cache.requirements[key] = entry;
    }
    return cache;
}

void writeCacheFile(string path, const ref CacheFileData cache)
{
    import std.file : write, rename, remove;
    import std.random : Random, unpredictableSeed, uniform;
    import std.conv : to;

    Random seed = Random(unpredictableSeed);
    string temporaryPath = path ~ "." ~ uniform(0u, uint.max, seed).to!string ~ ".tmp";
    write(temporaryPath, encodeCacheFile(cache));
    scope(failure) remove(temporaryPath);
    rename(temporaryPath, path);
}

CacheFileData readCacheFile(string path)
{
    import std.file : read;
    ubyte[] data = cast(ubyte[]) read(path);
    return decodeCacheFile(data);
}

unittest
{
    ubyte[8] hash1 = [1, 2, 3, 4, 5, 6, 7, 8];
    ubyte[8] hash2 = [9, 10, 11, 12, 13, 14, 15, 16];

    AdvFile[string] directoryFiles;
    directoryFiles["a.d"] = AdvFile(1234, hash1);
    AdvDirectory[string] directories;
    directories["source"] = AdvDirectory(hash2, directoryFiles);
    AdvFile[string] files;
    files["dub.json"] = AdvFile(5678, hash2);
    AdvCacheFormula fullFormula = AdvCacheFormula(hash1, directories, files);

    CacheFileData original;
    original.fullFormula = fullFormula;
    original.requirements["req"] = CacheRequirementEntry(
        simpleFromFormula(fullFormula),
        simpleFromFormula(fullFormula)
    );

    CacheFileData decoded = decodeCacheFile(encodeCacheFile(original));
    assert(decoded.fullFormula.contentHash == fullFormula.contentHash);
    assert(decoded.fullFormula.directories.length == 1);
    assert(decoded.fullFormula.files.length == 1);
    assert(decoded.requirements.length == 1);

    AdvCacheFormula restored = formulaFromSimple(decoded.requirements["req"].compileFormula, decoded.fullFormula);
    assert(restored.contentHash == fullFormula.contentHash);
    assert(restored.directories.length == 1);
    assert(restored.files.length == 1);
}
