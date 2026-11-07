module redub.misc.hard_link;


version(Windows)
extern(Windows) int CreateHardLinkW(const(wchar)* to, const(wchar)* from, void* secAttributes);

private bool isSameFile(string a, string b)
{
    import std.file;
    version(Posix)
    {
        return DirEntry(a).statBuf == DirEntry(b).statBuf;
    }
    else version(Windows)
    {
        import core.sys.windows.basetsd : HANDLE;
        import core.sys.windows.winbase : CreateFileW, GetFileInformationByHandle,
            CloseHandle, BY_HANDLE_FILE_INFORMATION, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS, INVALID_HANDLE_VALUE;
        import core.sys.windows.winnt : FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE;
        import std.utf : toUTFz;

        struct FileId
        {
            uint volume;
            ulong index;
        }

        static bool fileId(string path, out FileId id)
        {
            HANDLE h = CreateFileW(toUTFz!(const(wchar)*)(path), 0u,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
            if(h == INVALID_HANDLE_VALUE)
                return false;
            scope(exit) CloseHandle(h);
            BY_HANDLE_FILE_INFORMATION info;
            if(!GetFileInformationByHandle(h, &info))
                return false;
            id.volume = info.dwVolumeSerialNumber;
            id.index = (cast(ulong)info.nFileIndexHigh << 32) | info.nFileIndexLow;
            return true;
        }

        FileId aId, bId;
        if(!fileId(a, aId) || !fileId(b, bId))
            return false;
        return aId.volume == bId.volume && aId.index == bId.index;
    }
    else
        return false;
}


bool hardLinkFile(string from, string to, bool overwrite = false)
{
    import redub.logging;
    import std.exception;
    import std.file;
    import std.path;
    import std.utf;
    if(!exists(from))
        throw new Exception("File "~from~ " does not exists. ");
    if(!isFile(from))
        throw new Exception("Input '"~from~"' is not a file. ");
    string toDir = dirName(to);
    if(!exists(toDir))
    {
        throw new Exception("The output directory '"~toDir~"' from the copy operation with input file '"~from~"' does not exists.");
    }
	if (exists(to)) 
    {
		enforce(overwrite, "Destination file already exists.");
        if(isSameFile(from, to))
            return true;
	}
    uint attr = DirEntry(from).attributes;
    const bool destinationExists = exists(to);
    const uint destinationAttr = destinationExists ? DirEntry(to).attributes : 0;
    static bool isWritable(uint attributes)
    {
        version(Windows)
        {
            enum FILE_ATTRIBUTE_READONLY = 0x01;
            return (attributes & FILE_ATTRIBUTE_READONLY) == 0;
        }
        else
        {
            import core.sys.posix.sys.stat : S_IWUSR, S_IWGRP, S_IWOTH;
            return (attributes & (S_IWUSR | S_IWGRP | S_IWOTH)) != 0;
        }
    }

	const writeAccessChangeRequired = overwrite && destinationExists && !isWritable(destinationAttr);
	if (!writeAccessChangeRequired)
	{
		version (Windows)
		{
            alias cstr = toUTFz!(const(wchar)*);
			if(CreateHardLinkW(cstr(to), cstr(from), null) != 0)
                return true;
		}
		else
		{
            alias cstr = toUTFz!(const(char)*);
			import core.sys.posix.unistd : link;
            if(link(cstr(from), cstr(to)) == 0)
                return true;
		}
	}
	// fallback to copy
    try
    {
        if(destinationExists && overwrite && !isWritable(destinationAttr))
        {
            version(Windows)
            {
                enum FILE_ATTRIBUTE_READONLY = 0x01;
                std.file.setAttributes(to, destinationAttr & ~FILE_ATTRIBUTE_READONLY);
            }
            else
            {
                import core.sys.posix.sys.stat : S_IWUSR;
                std.file.setAttributes(to, destinationAttr | S_IWUSR);
            }
        }
        if(std.file.exists(to))
        {
            import std.random;
            static import std.conv;
            Random seed = Random(unpredictableSeed);
            uint num = uniform(0, int.max, seed);
            string output = to~ std.conv.to!string(num);
	        std.file.copy(from, output);
            std.file.rename(output, to);
        }
        else
        {
	        std.file.copy(from, to);
        }
        std.file.setAttributes(to, attr);
    }
    catch(Exception e)
    {
        errorTitle("Could not copy "~from, " " , e.toString());
        return false;
    }
    return true;
}

bool hardLinkDir(string dir, string to, bool overwrite = false, bool shallow = false)
{
    import std.exception;
    import redub.misc.path;
    import std.path;
    import std.file;

    foreach(DirEntry e; dirEntries(dir, shallow ? SpanMode.shallow : SpanMode.depth))
    {
        if(e.isDir)
            continue;
        string output = redub.misc.path.buildNormalizedPath(to, e.name[dir.length+1..$]);
        string outputDir = dirName(output);
        if(!exists(outputDir))
            mkdirRecurse(outputDir);

        if(!hardLinkFile(e.name, output, overwrite))
            return false;
    }
    return true;
}

bool hardLink(string input, string to, bool overwrite = false)
{
    import std.file;
    if(isDir(input))
        return hardLinkDir(input, to, overwrite);
    return hardLinkFile(input, to, overwrite);
}