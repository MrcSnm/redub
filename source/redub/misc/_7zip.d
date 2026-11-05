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
    import redub.misc.download : downloadWithProgress;
    import redub.libs.package_suppliers.utils;
    string workspace = getDubWorkspacePath;
    _7zpath = buildNormalizedPath(workspace, "7z.exe");
    if(!exists(workspace))
        mkdirRecurse(workspace);
    if(exists(_7zpath))
        return true;

    try
        downloadWithProgress(installLink, _7zpath);
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
    auto res = execute([_7z, "x", "-y",zPath]);
    if(res.status)
        error("Could not extract 7z '", zPath, "' to '", outputDirectory, "': ", res.output);
    return res.status == 0;
}

private bool install7za(out string _7zaPath)
{
    import redub.misc.download : downloadWithProgress;
    import redub.api;
    import redub.misc.github_tag_check;
    import redub.misc.path;
    import redub.logging;
    import std.file;
    import std.path : baseName, buildNormalizedPath;
    import std.process;
    import std.string : replace;

    string workspace = getDubWorkspacePath;
    _7zaPath = buildNormalizedPath(workspace, "7za.exe");
    if(exists(_7zaPath)) return true;

    string _7z;
    if(!install7Zip(_7z)) return false;
    string tag = getLatestGitRepositoryTag("ip7z/7zip");
    if(!tag) return false;
    string compact = tag.replace(".", "");
    string url = "https://github.com/ip7z/7zip/releases/download/"~tag~
        "/7z"~compact~"-extra.7z";
    string extra = buildNormalizedPath(tempDir, "7z-extra.7z");
    try
        downloadWithProgress(url, extra);
    catch(Exception e)
    {
        error("Could not download ", url, ": ", e.msg);
        return false;
    }

    string temp = buildNormalizedPath(tempDir, "7z-extra-extract");
    if(exists(temp)) rmdirRecurse(temp);
    mkdirRecurse(temp);
    string cwd = getcwd;
    chdir(temp);
    auto res = execute([_7z, "x", "-y", extra]);
    chdir(cwd);
    if(res.status)
    {
        error("Could not extract 7-Zip extra package: ", res.output);
        return false;
    }
    foreach(e; dirEntries(temp, SpanMode.depth))
        if(!e.isDir && baseName(e.name) == "7za.exe")
        {
            std.file.copy(e.name, _7zaPath);
            return true;
        }
    return false;
}

///Extracts a .tar.gz/.tar.xz on Windows using standalone 7za (gzip+xz+tar).
bool extractTarWith7za(string archivePath, string outputDirectory)
{
    import redub.logging;
    import std.file;
    import std.path;
    import std.process;

    string _7za;
    if(!install7za(_7za))
        return false;
    if(!exists(archivePath))
    {
        error("File ", archivePath, " does not exist.");
        return false;
    }
    string temp = buildNormalizedPath(tempDir, "redub-tar-" ~ baseName(archivePath));
    if(exists(temp)) rmdirRecurse(temp);
    mkdirRecurse(temp);
    scope(exit) if(exists(temp)) rmdirRecurse(temp);

    string cwd = getcwd;
    chdir(temp);
    auto res = execute([_7za, "x", "-y", archivePath]);
    chdir(cwd);
    if(res.status)
    {
        error("Could not extract '", archivePath, "': ", res.output);
        return false;
    }

    string tarFile;
    foreach(e; dirEntries(temp, SpanMode.depth))
        if(!e.isDir && extension(e.name) == ".tar")
        {
            tarFile = e.name;
            break;
        }
    if(!tarFile.length)
    {
        error("Could not find a .tar file inside ", archivePath);
        return false;
    }

    if(!exists(outputDirectory)) mkdirRecurse(outputDirectory);
    chdir(outputDirectory);
    res = execute([_7za, "x", "-y", tarFile]);
    chdir(cwd);
    if(res.status)
    {
        error("Could not extract '", tarFile, "': ", res.output);
        return false;
    }
    return true;
}
