module redub.misc.glob_entries;
public import std.file:DirEntry;

auto globDirEntriesShallow(string dirGlob)
{
    import std.path;
    import redub.misc.path;
    import std.file;
    import std.traits:ReturnType;
    import std.string:indexOf;
    import std.stdio;


    struct ShallowGlob
    {
        string glob;
        typeof(dirEntries("", SpanMode.shallow)) entries;

        bool empty()
        {
            if(entries == entries.init)
                return glob.length == 0;
            return entries.empty;
        }
        void popFront()
        {
            if(entries == entries.init)
                return;
            entries.popFront;
        }
        DirEntry front()
        {
            if(entries == entries.init)
            {
                DirEntry ret = DirEntry(glob);
                glob = null;
                return ret;
            }
            while(!entries.front.name.globMatch(glob))
                entries.popFront;
            return entries.front;
        }
    }

    ptrdiff_t idx = indexOf(dirGlob, '*');
    if(idx == -1)
        return ShallowGlob(dirGlob);

    import std.exception : enforce;
    enforce(indexOf(dirGlob[idx+1..$], '*') == -1, "Only shallow dir entries can be used from that function, received " ~ dirGlob);
    string initialPath = redub.misc.path.buildNormalizedPath(dirGlob[0..idx]);
    string theGlob = dirGlob[idx..$];
    enforce(isDir(initialPath), "Path "~initialPath~" is not a directory to iterate.");

    return ShallowGlob(theGlob, dirEntries(initialPath, SpanMode.shallow));
}