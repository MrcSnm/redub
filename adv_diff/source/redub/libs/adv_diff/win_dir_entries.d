/**
 * Fast depth-first directory walking for Windows.
 *
 * This exists because std.file.dirEntries allocates a full path string and
 * converts three FILETIMEs for every entry. The Windows implementation here
 * reuses the path/UTF conversion buffers, walks depth-first with a manual
 * stack, and reads only the last-write FILETIME.
 *
 * The strings in WinDirEntry are only valid until the next iteration. Copy
 * them (for example with idup) if they must outlive the foreach body. On
 * Posix this module falls back to std.file.dirEntries with the same contract.
 */
module redub.libs.adv_diff.win_dir_entries;

import std.file : SpanMode;
import std.exception : enforce;

version(Windows)
{
    import core.sys.windows.winbase;
    import core.sys.windows.winnt;
    import core.sys.windows.winnls;
    import core.stdc.wchar_ : wcslen;
    import std.path : isAbsolute;

    pragma(mangle, "FindFirstFileExW")
    private extern(Windows) HANDLE findFirstFileExW(const(WCHAR)* name, int infoLevel,
        void* findData, int searchOp, void* filter, DWORD flags);
}
else version(Posix)
{
    import std.file : dirEntries, DirEntry;
}

struct WinDirEntry
{
    /// Full path. Valid only until the next iteration.
    string name;
    /// Path relative to the root passed to winDirEntries. Valid only until the next iteration.
    string relativeName;
    bool isDir;
    bool isSymlink;
    ulong size;
    /// Same representation as DirEntry.timeLastModified.stdTime.
    long timeModified;
    /// Windows file attributes. Always 0 on Posix.
    uint attributes;
    /// Hidden according to the same rules used by the cache scanning code.
    bool isHidden;
}

alias WinDirEntryCallback = void delegate(const ref WinDirEntry);

private bool endsWithSep(scope const(char)[] path)
{
    return path.length != 0 && (path[$ - 1] == '\\' || path[$ - 1] == '/');
}

version(Windows)
{
    /**
     * Returns the extended (\\?\ or \\?\UNC\) form of a path.
     * Use this for file I/O when the path can exceed MAX_PATH.
     */
    string extendedPath(string path)
    {
        if (path.length == 0) return path;
        if (path.length >= 4 && path[0 .. 4] == "\\\\?\\") return path;

        string absolute = absoluteRoot(path);
        char[] result;

        if (absolute.length >= 2 && absolute[0] == '\\' && absolute[1] == '\\')
        {
            result.length = 8 + absolute.length - 2;
            result[0 .. 8] = "\\\\?\\UNC\\";
            foreach (i, c; absolute[2 .. $])
                result[8 + i] = c == '/' ? '\\' : c;
        }
        else
        {
            result.length = 4 + absolute.length;
            result[0 .. 4] = "\\\\?\\";
            foreach (i, c; absolute)
                result[4 + i] = c == '/' ? '\\' : c;
        }
        return cast(string) result;
    }

    private string absoluteRoot(string root)
    {
        if (root.length == 0) return root;
        if (root.length >= 4 && root[0 .. 4] == "\\\\?\\") return root;

        wchar[] inBuf;
        inBuf.length = root.length + 1;
        int wlen = MultiByteToWideChar(CP_UTF8, 0, root.ptr, cast(int) root.length,
            inBuf.ptr, cast(int) inBuf.length);
        if (wlen <= 0) return root;
        inBuf[wlen] = 0;

        wchar[] outBuf;
        outBuf.length = 512;
        DWORD needed = GetFullPathNameW(inBuf.ptr, cast(DWORD) outBuf.length, outBuf.ptr, null);
        if (needed == 0) return root;
        if (needed > outBuf.length)
        {
            outBuf.length = needed;
            needed = GetFullPathNameW(inBuf.ptr, cast(DWORD) outBuf.length, outBuf.ptr, null);
            if (needed == 0 || needed > outBuf.length) return root;
        }

        char[] utf8;
        utf8.length = needed * 4 + 1;
        int written = WideCharToMultiByte(CP_UTF8, 0, outBuf.ptr, cast(int) needed,
            utf8.ptr, cast(int) utf8.length, null, null);
        if (written <= 0) return root;
        return cast(string) utf8[0 .. written];
    }

    private int walkDepthImpl(string root, scope int delegate(ref WinDirEntry) onEntry,
        bool followSymlink, size_t maxDepth, bool filterHidden)
    {
        enum long hnsecsFrom1601 = 504_911_232_000_000_000L;

        struct Handle
        {
            size_t pathOffset;
            size_t pathLength;
            HANDLE h;
        }

        Handle[] stack;
        stack.length = 64;
        size_t stackCount;

        char[] arena;
        arena.length = 4096;
        size_t arenaLen;

        wchar[] patternBuf;
        patternBuf.length = 1024;
        char[] pathBuf;
        pathBuf.length = 4096;
        WIN32_FIND_DATAW findData;

        size_t pushPath(scope const(char)[] path)
        {
            if (arenaLen + path.length > arena.length)
            {
                size_t newCapacity = arena.length ? arena.length : 4096;
                while (newCapacity < arenaLen + path.length) newCapacity *= 2;
                arena.length = newCapacity;
            }
            size_t offset = arenaLen;
            arena[offset .. offset + path.length] = path[];
            arenaLen += path.length;
            return offset;
        }

        bool openDir(scope const(char)[] dir, out HANDLE handle)
        {
            static immutable wchar[4] drivePrefix = "\\\\?\\"w;
            static immutable wchar[8] uncPrefix = "\\\\?\\UNC\\"w;

            size_t prefixLength;
            scope const(char)[] src = dir;
            bool alreadyExtended = dir.length >= 4 && dir[0 .. 4] == "\\\\?\\";
            bool absolute = isAbsolute(dir);

            if (alreadyExtended || !absolute)
                prefixLength = 0;
            else if (dir.length >= 2 && dir[0] == '\\' && dir[1] == '\\')
            {
                prefixLength = 8;
                src = dir[2 .. $];
            }
            else
                prefixLength = 4;

            size_t needed = prefixLength + src.length + 4;
            if (patternBuf.length < needed) patternBuf.length = needed * 2;
            if (prefixLength == 4) patternBuf[0 .. 4] = drivePrefix[];
            else if (prefixLength == 8) patternBuf[0 .. 8] = uncPrefix[];

            int wlen = MultiByteToWideChar(CP_UTF8, 0, src.ptr, cast(int) src.length,
                patternBuf.ptr + prefixLength, cast(int) (patternBuf.length - prefixLength));
            if (wlen <= 0) return false;

            size_t pos = prefixLength + cast(size_t) wlen;
            bool lastIsSep = false;
            foreach (i; prefixLength .. pos)
            {
                if (patternBuf[i] == '/') patternBuf[i] = '\\';
                lastIsSep = patternBuf[i] == '\\';
            }
            if (!lastIsSep) patternBuf[pos++] = '\\';
            patternBuf[pos++] = '*';
            patternBuf[pos] = 0;

            handle = findFirstFileExW(patternBuf.ptr, 1, &findData, 0, null, 0);
            return handle != INVALID_HANDLE_VALUE;
        }

        size_t rootOffset = pushPath(root);
        size_t rootLength = root.length;
        HANDLE rootHandle;
        if (!openDir(root, rootHandle)) return 0;
        stack[stackCount++] = Handle(rootOffset, rootLength, rootHandle);
        scope(exit) foreach (ref h; stack[0 .. stackCount]) FindClose(h.h);

        size_t rootPrefixLength = root.length + (endsWithSep(root) ? 0 : 1);

        while (stackCount)
        {
            const(WCHAR)* namePtr = &findData.cFileName[0];
            size_t nameLen = wcslen(namePtr);
            bool isDot = nameLen == 1 && namePtr[0] == '.';
            bool isDotDot = nameLen == 2 && namePtr[0] == '.' && namePtr[1] == '.';
            bool isHidden = (findData.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN) != 0;

            if (!isDot && !isDotDot && !(filterHidden && isHidden))
            {
                Handle top = stack[stackCount - 1];
                char[] dir = arena[top.pathOffset .. top.pathOffset + top.pathLength];
                size_t baseLength = dir.length;
                bool needSep = !endsWithSep(dir);
                size_t nameStart = baseLength + (needSep ? 1 : 0);
                size_t capacity = nameStart + nameLen * 4 + 1;
                if (pathBuf.length < capacity) pathBuf.length = capacity * 2;
                pathBuf[0 .. baseLength] = dir[];
                if (needSep) pathBuf[baseLength] = '\\';

                int written = WideCharToMultiByte(CP_UTF8, 0, namePtr, cast(int) nameLen,
                    pathBuf.ptr + nameStart, cast(int) (pathBuf.length - nameStart), null, null);
                if (written > 0)
                {
                    size_t fullLength = nameStart + cast(size_t) written;
                    bool isDir = (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                    bool isSymlink = (findData.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;

                    WinDirEntry entry;
                    entry.name = cast(string) pathBuf[0 .. fullLength];
                    entry.relativeName = cast(string) pathBuf[rootPrefixLength .. fullLength];
                    entry.isDir = isDir;
                    entry.isSymlink = isSymlink;
                    entry.size = (cast(ulong) findData.nFileSizeHigh << 32) | findData.nFileSizeLow;
                    ulong fileTime = (cast(ulong) findData.ftLastWriteTime.dwHighDateTime << 32)
                        | findData.ftLastWriteTime.dwLowDateTime;
                    entry.timeModified = cast(long) (fileTime + hnsecsFrom1601);
                    entry.attributes = findData.dwFileAttributes;
                    entry.isHidden = isHidden;
                    if (onEntry(entry) != 0) return 1;

                    if (isDir && (followSymlink || !isSymlink) && stackCount < maxDepth)
                    {
                        size_t childOffset = pushPath(pathBuf[0 .. fullLength]);
                        HANDLE childHandle;
                        if (openDir(pathBuf[0 .. fullLength], childHandle))
                        {
                            if (stackCount == stack.length) stack.length *= 2;
                            stack[stackCount++] = Handle(childOffset, fullLength, childHandle);
                            continue;
                        }
                    }
                }
            }

            while (stackCount)
            {
                if (FindNextFileW(stack[stackCount - 1].h, &findData) != 0) break;
                FindClose(stack[stackCount - 1].h);
                --stackCount;
            }
        }
        return 0;
    }
}
else version(Posix)
{
    string extendedPath(string path)
    {
        return path;
    }

    private int walkDepthImpl(string root, scope int delegate(ref WinDirEntry) onEntry,
        bool followSymlink, size_t maxDepth, bool filterHidden)
    {
        import std.path : dirSeparator, baseName;

        string rootPrefix = root;
        if (!endsWithSep(rootPrefix)) rootPrefix ~= dirSeparator;
        size_t rootPrefixLength = rootPrefix.length;

        foreach (DirEntry e; dirEntries(root, SpanMode.depth, followSymlink))
        {
            WinDirEntry entry;
            entry.name = e.name;
            entry.relativeName = e.name.length >= rootPrefixLength
                ? e.name[rootPrefixLength .. $]
                : e.name;
            entry.isDir = e.isDir;
            entry.isSymlink = e.isSymlink;
            entry.size = e.size;
            entry.timeModified = e.timeLastModified.stdTime;
            entry.attributes = 0;
            string base = entry.name.baseName;
            entry.isHidden = base.length != 0 && base[0] == '.';
            if (filterHidden && entry.isHidden) continue;
            if (onEntry(entry) != 0) return 1;
        }
        return 0;
    }
}

/**
 * Chunked storage for cache file names. The returned slices stay valid for
 * the lifetime of the process because the associative array keys keep their
 * chunks alive.
 */
struct NameArena
{
    private char[][] chunks;
    private char[] current;
    private size_t used;
    private size_t chunkSize = 4096;
    private static immutable size_t maxChunkSize = 262144;

    string add(string name)
    {
        version(Posix)
        {
            // Posix fallback comes from std.file.dirEntries: the name is already
            // a stable GC string, so the caller can keep the slice directly.
            return name;
        }
        else
        {
            if (name.length == 0) return null;
            if (current.length == 0 || used + name.length > current.length)
            {
                if (current.length) chunks ~= current;
                size_t size = name.length > chunkSize ? name.length : chunkSize;
                current = new char[](size);
                used = 0;
                if (chunkSize < maxChunkSize) chunkSize *= 2;
            }
            size_t offset = used;
            current[offset .. offset + name.length] = name[];
            used += name.length;
            return cast(string) current[offset .. offset + name.length];
        }
    }
}

/**
 * Foreach-compatible facade. Usage:
 *
 * foreach (WinDirEntry e; winDirEntries(root)) { ... }
 * foreach (ref WinDirEntry e; winDirEntries(root)) { ... }
 */
struct WinDirEntries
{
    private string root;
    private bool followSymlink;
    private size_t maxDepth;
    private bool filterHidden;

    this(string root, bool followSymlink, size_t maxDepth, bool filterHidden)
    {
        this.root = root;
        this.followSymlink = followSymlink;
        this.maxDepth = maxDepth;
        this.filterHidden = filterHidden;
    }

    int opApply(scope int delegate(ref WinDirEntry) onEntry)
    {
        return walkDepthImpl(root, onEntry, followSymlink, maxDepth, filterHidden);
    }
}

auto winDirEntries(string root, SpanMode mode = SpanMode.depth,
    bool followSymlink = false, size_t maxDepth = 1024, bool filterHidden = false)
{
    enforce(mode == SpanMode.depth, "winDirEntries supports only SpanMode.depth.");
    return WinDirEntries(root, followSymlink, maxDepth, filterHidden);
}

void walkDepth(string root, scope WinDirEntryCallback onEntry,
    bool followSymlink = false, size_t maxDepth = 1024, bool filterHidden = false)
{
    walkDepthImpl(root, (ref WinDirEntry e)
    {
        onEntry(e);
        return 0;
    }, followSymlink, maxDepth, filterHidden);
}
