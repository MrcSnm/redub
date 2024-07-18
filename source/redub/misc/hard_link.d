module redub.misc.hard_link;


version(Windows)
extern(Windows) int CreateHardLinkW(const(wchar)* to, const(wchar)* from, void* secAttributes);

private bool isSameFile(string a, string b)
{
    import std.file;
    DirEntry aDir = DirEntry(a);
    DirEntry bDir = DirEntry(b);
    version(Posix)
    {
		return aDir.statBuf == bDir.statBuf;
    }
    else
    {
        return aDir.isDir == bDir.isDir &&
                aDir.timeLastModified == bDir.timeLastModified &&
                aDir.size == bDir.size &&
                aDir.isSymlink == bDir.isSymlink;
    }
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
            return (attributes & (S_IWUSR | S_IWGRP | S_IWOTH)) == 0;
        }
    }

	const writeAccessChangeRequired = overwrite && !isWritable(attr);
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
	    std.file.copy(from, to);        
    }
    catch(Exception e)
    {
        errorTitle("Could not copy "~from, " " , e.toString());
        return false;
    }
    return true;
}