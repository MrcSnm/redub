module redub.libs.package_suppliers.utils;


class NetworkException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
	{
		super(msg, file, line, nextInChain);
	}
}
string getFirstFileInDirectory(string inputDir)
{
	import std.file;
	if(!std.file.exists(inputDir))
		return null;
	auto entries = dirEntries(inputDir,SpanMode.shallow);
	return entries.front;
}

bool extractZipToFolder(ubyte[] data, string outputDirectory)
{
	import std.file;
    import std.path;
	import std.zip;
	ZipArchive zip = new ZipArchive(data);
	if(!std.file.exists(outputDirectory))
		std.file.mkdirRecurse(outputDirectory);
	foreach(string fileName, ArchiveMember archiveMember; zip.directory)
	{
		string outputFile = buildNormalizedPath(outputDirectory, fileName);
		if(!std.file.exists(outputFile))
		{
			if(archiveMember.expandedSize == 0)
				std.file.mkdirRecurse(outputFile);
			else
			{
				string currentDirName = outputFile.dirName;
				if(!std.file.exists(currentDirName))
					std.file.mkdirRecurse(currentDirName);
				std.file.write(outputFile, zip.expand(archiveMember));
			}
		}
	}
	return true;
}


bool extractZipToFolder(string zipPath, string outputDirectory)
{
	import std.file;
    return extractZipToFolder(cast(ubyte[])std.file.read(zipPath), outputDirectory);
}
