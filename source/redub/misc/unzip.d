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
            version(Windows)
                return extractTarXzToFolder(inputCompressedArchive, outputDirectory);
            else
                return extractTarGzToFolder(inputCompressedArchive, outputDirectory);
        default:
            throw new RedubException("Unsupported extension '"~ext~"' while trying to extract "~inputCompressedArchive);
    }
}


private string tarField(const(ubyte)[] data, size_t start, size_t len)
{
    size_t end = start;
    while(end < start + len && end < data.length && data[end] != 0)
        end++;
    return cast(string) data[start .. end];
}

private size_t tarNumber(const(ubyte)[] data, size_t start, size_t len)
{
    if(start + len > data.length) return 0;
    auto field = data[start .. start + len];
    size_t value;
    if(field.length && (field[0] & 0x80))
    {
        foreach(i, b; field)
            value = (value << 8) | (i == 0 ? (b & 0x7F) : b);
        return value;
    }
    foreach(b; field)
    {
        if(b == 0 || b == ' ') break;
        if(b < '0' || b > '7') continue;
        value = value * 8 + (b - '0');
    }
    return value;
}

private bool tarPathSafe(string name)
{
    import std.path : isAbsolute;
    import std.string : split;
    if(name.length == 0 || isAbsolute(name)) return false;
    if(name.length >= 2 && name[1] == ':') return false;
    foreach(part; name.split("/"))
        if(part == "..") return false;
    return true;
}

///Minimal ustar extractor used for the LDC addon archives.
bool extractTarToFolder(string tarPath, string outputDirectory)
{
    import redub.logging : error;
    import std.file : exists, mkdirRecurse, read, write;
    import std.path : buildNormalizedPath, dirName;
    import std.string : indexOf, split;

    if(!exists(tarPath))
    {
        error("File ", tarPath, " does not exist.");
        return false;
    }
    ubyte[] data = cast(ubyte[]) read(tarPath);
    size_t pos;
    string longName, longLink, paxPath, paxLink;
    while(pos + 512 <= data.length)
    {
        bool empty = true;
        foreach(b; data[pos .. pos + 512]) if(b) { empty = false; break; }
        if(empty) break;

        string name = tarField(data, pos, 100);
        char type = cast(char) data[pos + 156];
        size_t size = tarNumber(data, pos + 124, 12);
        string link = tarField(data, pos + 157, 100);
        string prefix = tarField(data, pos + 345, 155);
        if(prefix.length) name = prefix ~ "/" ~ name;
        size_t dataStart = pos + 512;
        size_t next = dataStart + ((size + 511) & ~cast(size_t)511);
        if(next > data.length)
        {
            error("Truncated tar archive: ", tarPath);
            return false;
        }

        if(type == 'L') longName = tarField(data, dataStart, size);
        else if(type == 'K') longLink = tarField(data, dataStart, size);
        else if(type == 'x')
        {
            string pax = cast(string) data[dataStart .. dataStart + size];
            foreach(line; pax.split("\n"))
            {
                auto space = line.indexOf(' ');
                if(space < 0) continue;
                string entry = line[space + 1 .. $];
                auto eq = entry.indexOf('=');
                if(eq < 0) continue;
                string key = entry[0 .. eq];
                string value = entry[eq + 1 .. $];
                if(key == "path") paxPath = value;
                else if(key == "linkpath") paxLink = value;
            }
        }
        else if(type != 'g')
        {
            if(longName.length) { name = longName; longName = null; }
            if(longLink.length) { link = longLink; longLink = null; }
            if(paxPath.length) { name = paxPath; paxPath = null; }
            if(paxLink.length) { link = paxLink; paxLink = null; }

            if(type == '5')
            {
                if(!tarPathSafe(name))
                {
                    error("Unsafe path in tar archive: ", name);
                    return false;
                }
                mkdirRecurse(buildNormalizedPath(outputDirectory, name));
            }
            else if(type == 0 || type == '0')
            {
                if(!tarPathSafe(name))
                {
                    error("Unsafe path in tar archive: ", name);
                    return false;
                }
                string target = buildNormalizedPath(outputDirectory, name);
                mkdirRecurse(dirName(target));
                write(target, data[dataStart .. dataStart + size]);
            }
            else
            {
                error("Unsupported tar entry type '", type, "' for ", name);
                return false;
            }
        }
        pos = next;
    }
    return true;
}

version(Posix)
unittest
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.path : buildNormalizedPath;
    import std.process : execute;

    string root = buildNormalizedPath(tempDir, "redub_tar_test");
    if(exists(root)) rmdirRecurse(root);
    mkdirRecurse(buildNormalizedPath(root, "src", "sub"));
    write(buildNormalizedPath(root, "src", "a.txt"), "hello");
    write(buildNormalizedPath(root, "src", "sub", "b.txt"), "world");
    auto res = execute(["tar", "-cf", buildNormalizedPath(root, "test.tar"),
        "-C", buildNormalizedPath(root, "src"), "."]);
    assert(res.status == 0);
    string outDir = buildNormalizedPath(root, "out");
    assert(extractTarToFolder(buildNormalizedPath(root, "test.tar"), outDir));
    assert(readText(buildNormalizedPath(outDir, "a.txt")) == "hello");
    assert(readText(buildNormalizedPath(outDir, "sub", "b.txt")) == "world");
    rmdirRecurse(root);
}

version(Windows)
private bool extractTarXzToFolder(string archivePath, string outputDirectory)
{
    import redub.logging : error;
    import redub.misc._7zip : extract7ZipToFolder;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, dirEntries, SpanMode;
    import std.path : buildNormalizedPath, baseName;

    string temp = buildNormalizedPath(tempDir, "redub-tar-" ~ baseName(archivePath));
    if(exists(temp)) rmdirRecurse(temp);
    mkdirRecurse(temp);
    scope(exit) if(exists(temp)) rmdirRecurse(temp);
    if(!extract7ZipToFolder(archivePath, temp))
        return false;

    string tarFile;
    foreach(e; dirEntries(temp, SpanMode.shallow))
        if(!e.isDir) { tarFile = e.name; break; }
    if(tarFile.length == 0)
    {
        error("Could not find the .tar file inside ", archivePath);
        return false;
    }
    return extractTarToFolder(tarFile, outputDirectory);
}

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
    auto res = execute(["tar", "-xf", tarGzPath, "-C", outputDirectory]);
    if(res.status)
        error("Could not extract '",tarGzPath, "' to '", outputDirectory, "': ", res.output);
	return res.status == 0;
}
