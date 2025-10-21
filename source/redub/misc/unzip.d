module redub.misc.unzip;
import redub.misc._7zip;
import redub.libs.package_suppliers.utils;

bool downloadAndExtract(string downloadLink, string outputDirectory)
{
    import redub.logging;
    import d_downloader;
    import std.file;
    import std.path:baseName;
    import redub.misc.path;
    string tempName = baseName(downloadLink);
    string tempPath = buildNormalizedPath(tempDir, tempName);
    try
    {
        info("Downloading ", downloadLink, " to ", tempPath);
        downloadToFile(downloadLink, tempPath);
    }
    catch (Exception e)
        throw new NetworkException("Could not download '"~downloadLink~"' to path '"~outputDirectory~"': "~e.msg);
    return extractToFolder(tempPath, outputDirectory);
}

bool extractToFolder(string inputCompressedArchive, string outputDirectory)
{
    import std.path;
    import redub.api;
    string ext = inputCompressedArchive.extension;
    switch(ext)
    {
        case ".zip":
            return extractZipToFolder(inputCompressedArchive, outputDirectory);
        case ".7z", ".7zip":
            version(Windows)
                return extract7ZipToFolder(inputCompressedArchive, outputDirectory);
            goto default;
        case ".xz", ".gz":
            version(Posix)
                return extractTarGzToFolder(inputCompressedArchive, outputDirectory);
            goto default;
        default:
            throw new RedubException("Unsupported extension '"~ext~"' while trying to extract "~inputCompressedArchive);
    }
}


version(Posix)
bool extractTarGzToFolder(string tarGzPath, string outputDirectory)
{
    import redub.logging;
    import std.file;
    import std.process;
	if(!std.file.exists(tarGzPath))
	{
		error("File ", tarGzPath, " does not exists.");
		return false;
	}
	info("Extracting ", tarGzPath, " to ", outputDirectory);
	std.file.mkdirRecurse(outputDirectory);
    auto res = executeShell("tar -xf "~tarGzPath~" -C "~outputDirectory);
    if(res.status)
        error("Could not extract '",tarGzPath, "' to '", outputDirectory, "': ", res.output);
	return res.status == 0;
}
