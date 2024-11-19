module redub.libs.package_suppliers.utils;

ubyte[] downloadFile(string file)
{
	import std.net.curl;
	HTTP http = HTTP(file);
	ubyte[] temp;
	http.onReceive = (ubyte[] data)
	{
		temp~= data;
		return data.length;
	};
	http.perform();
	return temp;
}

bool extractZipToFolder(ubyte[] data, string outputDirectory)
{
	import std.file;
    import std.path;
	import std.zip;
	ZipArchive zip = new ZipArchive(data);
	if(!std.file.exists(outputDirectory))
		std.file.mkdirRecurse(outputDirectory);
	foreach(fileName, archiveMember; zip.directory)
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
