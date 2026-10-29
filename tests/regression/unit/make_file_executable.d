module make_file_executable_test;
import std.file;
import std.path;
import std.stdio;
import std.conv : octal;
import redub.misc.make_file_executable;

void main()
{
    string path = buildPath(tempDir, "redub-make-exec-test");
    std.file.write(path, "x");
    scope(exit) remove(path);

    assert(makeFileExecutable(path));
    auto attributes = getAttributes(path);
    assert((attributes & octal!100) != 0, "owner execute bit was not set");
    writeln("PASS");
}
