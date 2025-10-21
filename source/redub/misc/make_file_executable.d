module redub.misc.make_file_executable;

bool makeFileExecutable(string filePath)
{
    import std.file;
	version(Windows) return true;
	version(Posix)
	{
		if(!std.file.exists(filePath)) return false;
		import std.conv:octal;
		std.file.setAttributes(filePath, octal!700);
		return true;
	}
}