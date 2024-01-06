import std.path;

enum TargetType
{
    executable,
    library,
    sharedLibrary,
}
TargetType targetFrom(string s)
{
    TargetType ret;
    static foreach(mem; __traits(allMembers, TargetType))
        if(s == mem) ret = __traits(getMember, TargetType, mem);
    return ret;
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
    TargetType targetType;

    BuildConfiguration clone() const{return cast()this;}

    BuildConfiguration merge(BuildConfiguration other) const
    {
        import std.traits:isArray;
        BuildConfiguration ret = clone;
        foreach(i, ref val; ret.tupleof)
        {
            static if(isArray!(typeof(val)) && !is(typeof(val) == string))
                val~= other.tupleof[i][];
            else 
            {
                if(other.tupleof[i] != BuildConfiguration.init.tupleof[i])
                    val = other.tupleof[i];
            }
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