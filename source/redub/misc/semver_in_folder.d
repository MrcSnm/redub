module redub.misc.semver_in_folder;
public import redub.libs.semver;

SemVer[] semverInFolder(string folder)
{
    import std.file;
    import std.path;
    SemVer[] ret;
    foreach(DirEntry e; dirEntries(folder, SpanMode.shallow))
    {
        string name = e.name.baseName;
        if(!name.length || name[0] == '.') //No invisible files
            continue;
        ret~= SemVer(name);
    }
    return ret;
}