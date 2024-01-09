import std.path;

enum TargetType
{
    autodetect,
    executable,
    library,
    staticLibrary,
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
    string[] sourcePaths;
    string sourceEntryPoint;
    string outputDirectory;
    string workingDir;
    TargetType targetType;

    static BuildConfiguration defaultInit()
    {
        BuildConfiguration ret;
        ret.importDirectories = ["source"];
        ret.sourcePaths = ["source"];
        ret.sourceEntryPoint = "source/app.d";
        ret.outputDirectory = "bin";
        return ret;
    }

    BuildConfiguration clone() const{return cast()this;}

    BuildConfiguration merge(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.stringImportPaths.exclusiveMerge(other.stringImportPaths);
        ret.importDirectories.exclusiveMerge(other.importDirectories);
        ret.versions.exclusiveMerge(other.versions);
        ret.dFlags.exclusiveMerge(other.dFlags);
        ret.libraries.exclusiveMerge(other.libraries);
        ret.libraryPaths.exclusiveMerge(other.libraryPaths);
        ret.linkFlags.exclusiveMerge(other.linkFlags);
        return ret;
    }
    BuildConfiguration mergeLibraries(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.libraries.exclusiveMerge(other.libraries);
        return ret;
    }
    BuildConfiguration mergeLibPaths(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.libraryPaths.exclusiveMerge(other.libraryPaths);
        return ret;
    }
    BuildConfiguration mergeImport(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.importDirectories.exclusiveMerge(other.importDirectories);
        return ret;
    }

    BuildConfiguration mergeDFlags(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.dFlags.exclusiveMerge(other.dFlags);
        return ret;
    }
    BuildConfiguration mergeVersions(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.versions.exclusiveMerge(other.versions);
        return ret;
    }
}
private ref string[] exclusiveMerge(return scope ref string[] a, string[] b)
{
    import std.algorithm.searching:countUntil;
    foreach(v; b)
        if(a.countUntil(v) == -1) a~= v;
    return a;
}

struct Dependency
{
    string name;
    string path;
    string version_ = "*";
    string subConfiguration;
    string subPackage;

    bool isSameAs(string name, string subConfiguration, string subPackage) const
    {
        return this.name == name && this.subConfiguration == subConfiguration && this.subPackage == subPackage;
    }

    bool isSameAs(Dependency other) const{return isSameAs(other.name, other.subConfiguration, other.subPackage);}

    string fullName()
    {
        if(subPackage.length) return name~":"~subPackage;
        return name;
    }
}

struct BuildRequirements
{
    BuildConfiguration cfg;
    Dependency[] dependencies;
    string version_;
    string targetConfiguration;

    static BuildRequirements defaultInit()
    {
        BuildRequirements req;
        req.cfg = BuildConfiguration.defaultInit;
        return req;
    }

    /** 
     * Configurations and dependencies are merged.
     */
    BuildRequirements merge(BuildRequirements other) const
    {
        BuildRequirements ret = cast()this;
        ret.cfg = ret.cfg.merge(other.cfg);
        ret.dependencies~= other.dependencies;
        return ret;
    }

    string name() const {return cfg.name;}
}

class ProjectNode
{
    BuildRequirements requirements;
    ProjectNode parent;
    ProjectNode[] dependencies;

    string name() const { return requirements.name; }

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

    /** 
     * This function will iterate recursively, from bottom to top, and it:
     * - Fixes the name if it is using subPackage name type.
     * - Populating parent imports using child imports paths.
     * - Infer target type if it is on autodetect
     * - Add the dependency as a library if it is a library
     * - Add the dependency's libraries 
     */
    void finish()
    {
        foreach(dep; dependencies)
            dep.finish();
        import std.string:replace;
        requirements.cfg.name = requirements.cfg.name.replace(":", "_");

        if(parent)
            parent.requirements.cfg = parent.requirements.cfg.mergeImport(requirements.cfg);
        static TargetType inferTargetType(BuildConfiguration cfg)
        {
            static immutable string[] filesThatInfersExecutable = ["app.d", "main.d"];
            foreach(p; cfg.sourcePaths)
            {
                static import std.file;
                foreach(f; filesThatInfersExecutable)
                if(std.file.exists(buildNormalizedPath(cfg.workingDir, p,f)))
                    return TargetType.executable;
            }
            return TargetType.library;
        }
        with(TargetType)
        {
            HandleTargetType: final switch(requirements.cfg.targetType)
            {
                case autodetect: requirements.cfg.targetType = inferTargetType(requirements.cfg); goto HandleTargetType;
                case library, staticLibrary:
                    if(parent)
                    {
                        BuildConfiguration other = requirements.cfg.clone;
                        other.libraries~= other.name;
                        other.libraryPaths~= other.outputDirectory;
                        parent.requirements.cfg = parent.requirements.cfg.mergeLibraries(other);
                        parent.requirements.cfg = parent.requirements.cfg.mergeLibPaths(other);
                    }
                    break;
                case sharedLibrary: throw new Error("Uninplemented support for shared libraries");
                case executable: break;
            }
        }
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