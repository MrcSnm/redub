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
    string[] stringImportPaths;
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
    BuildConfiguration mergeImport(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.importDirectories~= other.importDirectories;
        return ret;
    }

    BuildConfiguration mergeDFlags(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.dFlags~= other.dFlags;
        return ret;
    }
    BuildConfiguration mergeVersions(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.versions~= other.versions;
        return ret;
    }
}

struct Dependency
{
    string name;
    string path;
    string version_ = "*";
}

struct BuildRequirements
{
    BuildConfiguration cfg;
    Dependency[] dependencies;
    string version_;
}

class ProjectNode
{
    BuildRequirements requirements;
    ProjectNode parent;
    ProjectNode[] dependencies;

    string name() const { return requirements.cfg.name; }

    this(BuildRequirements req)
    {
        this.requirements = req;
    }

    ProjectNode addDependency(ProjectNode dep)
    {
        dep.parent = this;
        dependencies~= dep;
        return this;
    }
}