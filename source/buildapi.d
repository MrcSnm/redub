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
    string subConfiguration;

    bool isSameAs(string name, string subConfiguration)
    {
        return this.name == name && this.subConfiguration == subConfiguration;
    }
}

struct BuildRequirements
{
    BuildConfiguration cfg;
    Dependency[] dependencies;
    string version_;
    string targetConfiguration;

    string name(){return cfg.name;}
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
ProjectNode[][] fromTree(ProjectNode root)
{
    ProjectNode[][] ret;
    int[string] visited;
    fromTreeImpl(root, ret, visited);
    return ret;
}

private void fromTreeImpl(ProjectNode root, ref ProjectNode[][] output, ref int[string] visited, int depth = 0)
{
    if(depth >= output.length) output.length = depth+1;

    foreach(c; root.dependencies)
    {
        fromTreeImpl(c, output, visited, depth+1);
    }
    if(root.name in visited)
    {
        int oldDepth = visited[root.name];
        if(depth > oldDepth)
        {
            visited[root.name] = depth;
            output[depth] ~= root;
            ///Remove frol the oldDepth
            for(int i = 0; i < output[oldDepth].length; i++)
            {
                if(output[oldDepth][i].name == root.name)
                {
                    output[oldDepth] = output[oldDepth][0..i] ~ output[oldDepth][i+1..$];
                    i--;
                }
            }
        }
    }
    else
    {
        visited[root.name] = depth;
        output[depth]~= root;
    }
}

import tree_generators.dub;

void printMatrixTree(ProjectNode[][] mat)
{
    import std.stdio;
    foreach_reverse(i, node; mat)
        foreach(n; node)
            writeln("-".repeat(cast(int)i), " ", n.name);
}