module redub.misc.find_executable;

string findExecutable(string executableName)
{
    import redub.parsers.environment;
    import redub.misc.path;
    import std.path : isAbsolute, extension, buildPath;
    import std.file;
    import std.algorithm.iteration:splitter;
    string pathEnv = getEnvVariable("PATH");

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
            if(stat(toStringz(tPath), &stats) != 0)
                return false;

            static immutable flags = S_IXUSR | S_IXGRP | S_IXOTH;
            return (stats.st_mode & flags) == flags;
        }
        else return std.file.exists(tPath);
    }

    if(isAbsolute(executableName) && isExecutable(executableName))
        return executableName;


    char[4096] buffer = void;
    char[] bufferSink = buffer;

    foreach(path; splitter(pathEnv, pathSeparator))
    {
        string str = redub.misc.path.normalizePath(bufferSink, path, executableName);
        foreach(ext; EXTENSIONS)
        {
            bufferSink[str.length..str.length+ext.length] = ext;
            string fullPath = cast(string)buffer[0..str.length+ext.length];
            if(std.file.exists(fullPath))
                return fullPath.dup;
        }

    }
    return "";
}