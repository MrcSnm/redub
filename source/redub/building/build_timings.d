module redub.building.build_timings;

import redub.building.cache : getCacheFolder;
import std.file : exists, mkdirRecurse, read, remove, rename, write;
import std.path : buildNormalizedPath, dirName;
import std.algorithm : map, sort;
import std.array : array;

enum TimingStrategy : ubyte
{
    single,
    objectIncremental,
    objectFull
}

enum StrategyPreference
{
    none,
    preferSingle,
    preferObject
}

private enum magic = "RDBT";
private enum formatVersion = 1;
private enum recordSize = 20;
private enum maxRecords = 64;

private struct TimingRecord
{
    TimingStrategy strategy;
    bool cold;
    bool forced;
    ushort jobs;
    ushort affected;
    ushort modules;
    uint elapsedMs;
    uint compileMs;
    uint linkMs;
}

string timingsPath(string rootHash)
{
    return buildNormalizedPath(getCacheFolder, rootHash, "build_timings.bin");
}

private void putU16(ref ubyte[] data, ushort value)
{
    data ~= cast(ubyte)(value & 0xff);
    data ~= cast(ubyte)(value >> 8);
}

private void putU32(ref ubyte[] data, uint value)
{
    data ~= cast(ubyte)(value & 0xff);
    data ~= cast(ubyte)((value >> 8) & 0xff);
    data ~= cast(ubyte)((value >> 16) & 0xff);
    data ~= cast(ubyte)((value >> 24) & 0xff);
}

private ushort getU16(const(ubyte)[] data, ref size_t pos)
{
    ushort value = cast(ushort)data[pos] | (cast(ushort)data[pos + 1] << 8);
    pos += 2;
    return value;
}

private uint getU32(const(ubyte)[] data, ref size_t pos)
{
    uint value = cast(uint)data[pos] | (cast(uint)data[pos + 1] << 8)
        | (cast(uint)data[pos + 2] << 16) | (cast(uint)data[pos + 3] << 24);
    pos += 4;
    return value;
}

private TimingRecord[] load(string path)
{
    TimingRecord[] records;
    if(!exists(path))
        return records;
    try
    {
        auto data = cast(ubyte[]) read(path);
        if(data.length < 10 || data[0 .. 4] != cast(const(ubyte)[])magic)
            return records;
        size_t pos = 4;
        if(getU16(data, pos) != formatVersion)
            return records;
        if(getU16(data, pos) != recordSize)
            return records;
        ushort count = getU16(data, pos);
        foreach(_; 0 .. count)
        {
            if(pos + recordSize > data.length)
                break;
            TimingRecord record;
            record.strategy = cast(TimingStrategy)data[pos++];
            ubyte flags = data[pos++];
            record.cold = (flags & 1) != 0;
            record.forced = (flags & 2) != 0;
            record.jobs = getU16(data, pos);
            record.affected = getU16(data, pos);
            record.modules = getU16(data, pos);
            record.elapsedMs = getU32(data, pos);
            record.compileMs = getU32(data, pos);
            record.linkMs = getU32(data, pos);
            records ~= record;
        }
    }
    catch(Exception) {}
    return records;
}

private void save(string path, TimingRecord[] records)
{
    if(records.length > maxRecords)
        records = records[$ - maxRecords .. $];
    ubyte[] data = cast(ubyte[])magic.dup;
    putU16(data, formatVersion);
    putU16(data, recordSize);
    putU16(data, cast(ushort)records.length);
    foreach(record; records)
    {
        data ~= cast(ubyte)record.strategy;
        ubyte flags;
        if(record.cold) flags |= 1;
        if(record.forced) flags |= 2;
        data ~= flags;
        putU16(data, record.jobs);
        putU16(data, record.affected);
        putU16(data, record.modules);
        putU32(data, record.elapsedMs);
        putU32(data, record.compileMs);
        putU32(data, record.linkMs);
    }
    mkdirRecurse(dirName(path));
    string temp = path ~ ".tmp";
    write(temp, data);
    version(Windows)
        if(exists(path)) remove(path);
    rename(temp, path);
}

private long median(uint[] values)
{
    if(values.length == 0)
        return 0;
    ulong[] sorted = values.map!(v => cast(ulong)v).array;
    sorted.sort();
    return cast(long)sorted[sorted.length / 2];
}

///Uses only strategies with at least two samples; returns none while learning.
private int absInt(int value)
{
    return value < 0 ? -value : value;
}

struct TimingSamples
{
    uint single;
    uint object;
}

private bool sameShape(const TimingRecord record, uint affected, uint modules)
{
    if(record.modules != 0 && absInt(cast(int)record.modules - cast(int)modules) > 2)
        return false;
    int affectedTolerance = cast(int)modules / 5;
    if(affectedTolerance < 2) affectedTolerance = 2;
    return record.affected == 0
        || absInt(cast(int)record.affected - cast(int)affected) <= affectedTolerance;
}

TimingSamples timingSamples(string rootHash, uint affected, uint modules)
{
    TimingSamples ret;
    try
    {
        foreach(record; load(timingsPath(rootHash)))
        {
            if(record.strategy == TimingStrategy.single)
                ret.single++;
            else if(sameShape(record, affected, modules))
                ret.object++;
        }
    }
    catch(Exception) {}
    return ret;
}

StrategyPreference timingPreference(string rootHash, uint affected, uint modules, uint minSamples = 2)
{
    try
    {
        auto records = load(timingsPath(rootHash));
        uint[] singles;
        uint[] objects;
        foreach(record; records)
        {
            if(record.strategy == TimingStrategy.single)
                singles ~= record.elapsedMs;
            else
            {
                ///Compare only runs with a similar affected/module shape.
                if(!sameShape(record, affected, modules))
                    continue;
                objects ~= record.elapsedMs;
            }
        }
        if(singles.length < minSamples || objects.length < minSamples)
            return StrategyPreference.none;
        long single = median(singles);
        long object = median(objects);
        if(object >= single)
            return StrategyPreference.preferSingle;
        if(object * 100 < single * 95)
            return StrategyPreference.preferObject;
    }
    catch(Exception) {}
    return StrategyPreference.none;
}

///Records one root build. Failures are ignored: timing is diagnostic data.
void recordBuildTiming(string rootHash, TimingStrategy strategy, bool cold, bool forced,
    uint jobs, uint affected, uint modules, uint elapsedMs, uint compileMs = 0, uint linkMs = 0)
{
    try
    {
        string path = timingsPath(rootHash);
        auto records = load(path);
        records ~= TimingRecord(strategy, cold, forced, cast(ushort)jobs, cast(ushort)affected,
            cast(ushort)modules, elapsedMs, compileMs, linkMs);
        save(path, records);
    }
    catch(Exception) {}
}
