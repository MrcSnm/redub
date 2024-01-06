import std.path;

enum OutputType
{
    library,
    sharedLibrary,
    executable
}

struct BuildConfiguration
{
    bool isDebug;
    string name;
    string[] versions;
    string[] importDirectories;
    string[] libraryPaths;
    string[] libraries;
    string[] linkFlags;
    string[] dFlags;
    string sourceEntryPoint = "source/app.d";
    string outputDirectory  = "build";
    OutputType outputType;


    BuildConfiguration merge(BuildConfiguration other) const
    {
        import std.traits:isArray;
        BuildConfiguration ret = cast()this;
        foreach(i, ref val; ret.tupleof)
        {
            static if(isArray!(typeof(val)))
                cast()val~= other.tupleof[i][];
        }
        return ret;
    }
}

struct Dependency{}

struct BuildRequirements
{
    BuildConfiguration cfg;
    Dependency[] dependencies;
}