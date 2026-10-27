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

bool safeZipPath(string root, string member, out string result)
{
	import std.path;
	import std.string;

	if(member.length == 0 || member.indexOf('\0') != -1)
		return false;
	
    // "/etc/passwd", "C:\Windows", "\\server\share", "\root"
    if (isRooted(member) || driveName(member).length != 0)
        return false;

    // "a/../../x", "..\..\x"
    foreach (part; member.pathSplitter)
	{
        if (part == "..")
            return false;
		version(Windows)
		{
            if (part.indexOf(':') != -1) // avoids ADS: "foo.txt:stream"
                return false;
		}
	}

    string rootNorm = buildNormalizedPath(root);
    string candidate = buildNormalizedPath(root, member);
    string rel = relativePath(candidate, rootNorm);

    // "..\x", "../x", ou caminho absoluto de outra unidade
    if (rel == ".." || rel.startsWith(".." ~ dirSeparator) || isAbsolute(rel))
        return false;

    result = candidate;
    return true;
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
		string outputFile;
		if(!safeZipPath(outputDirectory, fileName, outputFile))
			throw new Exception("Unsafe path in archive: " ~ fileName);
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
