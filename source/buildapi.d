import std.path;

enum OutputType
{
    executable,
    library,
    sharedLibrary,
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
    string outputDirectory  = "bin";
    OutputType outputType;

    BuildConfiguration clone() const{return cast()this;}

    BuildConfiguration merge(BuildConfiguration other) const
    {
        import std.traits:isArray;
        BuildConfiguration ret = clone;
        foreach(i, ref val; ret.tupleof)
        {
            static if(isArray!(typeof(val)) && !is(typeof(val) == string))
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