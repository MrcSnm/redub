module redub.misc.find_executable;

string findExecutable(string executableName)
{
    import std.process;
    import std.path;
    import std.file;
    import std.algorithm.iteration:splitter;
    string pathEnv = environment.get("PATH", "");

    version(Windows)
        static string[] EXTENSIONS = [".exe", ".bat", ".cmd", ".com", ""];
    else
        static string[] EXTENSIONS = [""];

    string[] extensionsTest = EXTENSIONS;
    if(extension(executableName) != null)
        extensionsTest = [""];

    static bool isExecutable(string tPath)
    {
        version(Posix)
        {
            import std.string:toStringz;
            import core.sys.posix.sys.stat;
            stat_t stats;
            stat(toStringz(tPath), &stats);
            return stats.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH);
        }
        else return std.file.exists(tPath);
    }

    if(isAbsolute(executableName) && isExecutable(executableName))
        return executableName;

    foreach(path; splitter(pathEnv, pathSeparator))
    {

        foreach(ext; EXTENSIONS)
        {
            string fullPath = buildPath(path, executableName ~ ext);
            if(std.file.exists(fullPath))
                return fullPath;
        }

    }
    return "";
}