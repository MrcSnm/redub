module redub.misc._7zip;
version(Windows):
private enum installLink = "https://www.7-zip.org/a/7zr.exe";
//7zip is only used on windows currently.

private bool install7Zip(out string _7zpath)
{
    import std.array;
    import std.file;
    import redub.api;
    import redub.meta;
    import redub.misc.path;
    import std.net.curl;
    import redub.libs.package_suppliers.utils;
    string workspace = getDubWorkspacePath;
    _7zpath = buildNormalizedPath(workspace, "7z.exe");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    if(exists(_7zpath))
        return true;

    try
        download(installLink, _7zpath);
    catch (Exception e)
        throw new NetworkException("Could not download "~installLink~": "~e.msg);
	return true;
}

bool extract7ZipToFolder(string zPath, string outputDirectory)
{
    import redub.logging;
    import std.file;
    import std.process;
    string _7z;
    if(!install7Zip(_7z))
        return false;
	if(!std.file.exists(zPath)) 
	{
		error("File ", zPath, " does not exists.");
		return false;
	}
	info("Extracting ", zPath, " to ", outputDirectory);
	if(!std.file.exists(outputDirectory))
		std.file.mkdirRecurse(outputDirectory);

    string dir = getcwd;
    chdir(outputDirectory);
    scope(exit)
        chdir(dir);
    auto res = executeShell(_7z ~ " x -y "~zPath, t);
    if(res.status)
        error("Could not extract 7z '", zPath, "' to '", outputDirectory, "': ", res.output);
    return res.status == 0;
}