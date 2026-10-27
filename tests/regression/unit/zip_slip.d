module zip_slip;
import std.file;
import std.path;
import std.stdio;
import std.zip;
import core.stdc.stdlib : exit;
import redub.libs.package_suppliers.utils;

void main()
{
    string root = buildPath(tempDir, "redub-zip-slip-test");
    if (exists(root))
        rmdirRecurse(root);
    mkdirRecurse(root);

    size_t failures;

    void check(string label, string memberName, string escapedPath)
    {
        string outDir = buildPath(root, "out");
        if (exists(outDir))
            rmdirRecurse(outDir);
        mkdirRecurse(outDir);
        if (exists(escapedPath))
            remove(escapedPath);

        auto member = new ArchiveMember();
        member.name = memberName;
        member.expandedData(cast(ubyte[])"pwned".dup);
        member.compressionMethod = CompressionMethod.none;

        auto zip = new ZipArchive();
        zip.addMember(member);
        ubyte[] data = cast(ubyte[]) zip.build();

        try
            extractZipToFolder(data, outDir);
        catch (Exception)
        {
            // Rejecting the entry is also a correct outcome.
        }

        if (exists(escapedPath))
        {
            writeln("FAIL [", label, "]: wrote outside the output directory: ", escapedPath);
            failures++;
            remove(escapedPath);
        }
    }

    // A correct guard must reject the malicious entries without breaking normal extraction.
    {
        string outDir = buildPath(root, "out-ok");
        if (exists(outDir))
            rmdirRecurse(outDir);
        mkdirRecurse(outDir);

        auto member = new ArchiveMember();
        member.name = "ok.txt";
        member.expandedData(cast(ubyte[])"ok".dup);
        member.compressionMethod = CompressionMethod.none;
        auto zip = new ZipArchive();
        zip.addMember(member);
        ubyte[] data = cast(ubyte[]) zip.build();

        try
            extractZipToFolder(data, outDir);
        catch (Exception e)
        {
            writeln("FAIL [benign]: normal extraction threw: ", e.msg);
            failures++;
        }

        string okPath = buildPath(outDir, "ok.txt");
        if (!exists(okPath) || readText(okPath) != "ok")
        {
            writeln("FAIL [benign]: normal entry was not extracted");
            failures++;
        }
    }

    check("../", "../escaped.txt", buildNormalizedPath(root, "escaped.txt"));
    check("nested ../", "a/../../escaped2.txt", buildNormalizedPath(root, "escaped2.txt"));
    check("absolute", buildPath(tempDir, "redub-zip-slip-absolute.txt"),
        buildPath(tempDir, "redub-zip-slip-absolute.txt"));

    version (Windows)
    {
        check("backslash ../", `..\escaped3.txt`, buildNormalizedPath(root, "escaped3.txt"));
        check("drive absolute", buildPath(tempDir, "redub-zip-slip-drive.txt"),
            buildPath(tempDir, "redub-zip-slip-drive.txt"));
    }

    if (failures)
    {
        writeln(failures, " zip-slip case(s) failed");
        exit(1);
    }
    writeln("PASS: extractZipToFolder rejected every escaping entry");
}
