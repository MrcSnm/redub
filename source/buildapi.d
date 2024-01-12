import std.path;

enum TargetType
{
    autodetect,
    executable,
    library,
    staticLibrary,
    sharedLibrary,
    sourceLibrary
}
bool isStaticLibrary(TargetType t)
{
    return t == TargetType.staticLibrary || t == TargetType.library;
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
    string[] sourceFiles;
    string[] preGenerateCommands;
    string[] postGenerateCommands;
    string[] preBuildCommands;
    string[] postBuildCommands;
    string sourceEntryPoint;
    string outputDirectory;
    string workingDir;
    TargetType targetType;

    static BuildConfiguration defaultInit(string workingDir)
    {
        import std.path;
        import std.file;
        static immutable inferredSourceFolder = ["source", "src"];
        string initialSource;
        foreach(i; inferredSourceFolder)
        {
            if(exists(buildNormalizedPath(workingDir, i)))
            {
                initialSource = i;
                break;
            }
        }
        
        BuildConfiguration ret;
        if(initialSource)
        {
            ret.importDirectories = [initialSource];
            ret.sourcePaths = [initialSource];
        }
        ret.sourceEntryPoint = "source/app.d";
        ret.outputDirectory = "bin";
        return ret;
    }

    immutable(BuildConfiguration) idup()
    {
        return immutable BuildConfiguration(
            isDebug,
            name,
            versions.idup,
            importDirectories.idup,
            libraryPaths.idup,
            stringImportPaths.idup,
            libraries.idup,
            linkFlags.idup,
            dFlags.idup,
            sourcePaths.idup,
            sourceFiles.idup,
            preGenerateCommands.idup,
            postGenerateCommands.idup,
            preBuildCommands.idup,
            postBuildCommands.idup,
            sourceEntryPoint,
            outputDirectory,
            workingDir,
            targetType
        );

    }

    BuildConfiguration clone() const{return cast()this;}

    BuildConfiguration merge(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.stringImportPaths.exclusiveMerge(other.stringImportPaths);
        ret.sourceFiles.exclusiveMerge(other.sourceFiles);
        ret.sourcePaths.exclusiveMerge(other.sourcePaths);
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
    BuildConfiguration mergeSourceFiles(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.sourceFiles.exclusiveMerge(other.sourceFiles);
        return ret;
    }
    BuildConfiguration mergeSourcePaths(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.sourcePaths.exclusiveMerge(other.sourcePaths);
        return ret;
    }


    BuildConfiguration mergeLinkFilesFromSource(BuildConfiguration other) const
    {
        import command_generators.commons;
        BuildConfiguration ret = clone;
        ret.sourceFiles.exclusiveMerge(getLinkFiles(other.sourceFiles));
        return ret;
    }
}
ref string[] exclusiveMerge(return scope ref string[] a, string[] b)
{
    import std.algorithm.searching:countUntil;
    foreach(v; b)
        if(a.countUntil(v) == -1) a~= v;
    return a;
}
ref string[] exclusiveMergePaths(return scope ref string[] a, string[] b)
{
    import std.algorithm.searching:countUntil;
    foreach(v; b)
        if(buildNormalizedPath(a).countUntil(buildNormalizedPath(v)) == -1) 
            a~= v;
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

    static BuildRequirements defaultInit(string workingDir)
    {
        BuildRequirements req;
        req.cfg = BuildConfiguration.defaultInit(workingDir);
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
    ProjectNode[] parent;
    ProjectNode[] dependencies;

    string name() const { return requirements.name; }

    this(BuildRequirements req)
    {
        this.requirements = req;
    }

    ProjectNode addDependency(ProjectNode dep)
    {
        import std.exception;
        if(this.requirements.cfg.targetType == TargetType.sourceLibrary)
        {
            import std.conv;
            enforce(dep.requirements.cfg.targetType == TargetType.sourceLibrary, 
                "Project named '"~name~" which is a sourceLibrary, can not depend on project "~
                dep.name~" since it can only depend on sourceLibrary. Dependency is a "~dep.requirements.cfg.targetType.to!string
            );
        }
        dep.parent~= this;
        dependencies~= dep;
        return this;
    }

    bool isFullyParallelizable()
    {
        bool parallelizable = 
            requirements.cfg.preBuildCommands.length == 0 &&
            requirements.cfg.postBuildCommands.length == 0;
        foreach(dep; dependencies)
        {
            parallelizable|= dep.isFullyParallelizable;
            if(!parallelizable) return false;
        }
        return parallelizable;

    }

    /** 
     * This function will iterate recursively, from bottom to top, and it:
     * - Fixes the name if it is using subPackage name type.
     * - Populating parent imports using children:
     * >-  Imports paths.
     * >-  Versions.
     * >-  dflags.
     * >-  sourceFiles if they are libraries.
     * - Infer target type if it is on autodetect
     * - Add the dependency as a library if it is a library
     * - Add the dependency's libraries 
     * - Remove source libraries from projects to build
     */
    void finish()
    {
        foreach(dep; dependencies)
            dep.finish();
        import std.string:replace;
        requirements.cfg.name = requirements.cfg.name.replace(":", "_");
        if(requirements.cfg.targetType == TargetType.autodetect)
            requirements.cfg.targetType = inferTargetType(requirements.cfg);

        foreach(p; parent)
        {
            p.requirements.cfg = p.requirements.cfg.mergeImport(requirements.cfg);
            p.requirements.cfg = p.requirements.cfg.mergeVersions(requirements.cfg);
            p.requirements.cfg = p.requirements.cfg.mergeDFlags(requirements.cfg);
            p.requirements.cfg = p.requirements.cfg.mergeLinkFilesFromSource(requirements.cfg);
        }
        
        foreach(p; parent)
        {
            HandleTargetType: final switch(requirements.cfg.targetType) with(TargetType)
            {
                case autodetect: requirements.cfg.targetType = inferTargetType(requirements.cfg); goto HandleTargetType;
                case library, staticLibrary:
                        BuildConfiguration other = requirements.cfg.clone;
                        other.libraries~= other.name;
                        other.libraryPaths~= other.outputDirectory;
                        p.requirements.cfg = p.requirements.cfg.mergeLibraries(other);
                        p.requirements.cfg = p.requirements.cfg.mergeLibPaths(other);
                    break;
                case sourceLibrary: 
                    p.requirements.cfg = p.requirements.cfg.merge(requirements.cfg);
                    p.requirements.cfg = p.requirements.cfg.mergeSourcePaths(requirements.cfg);
                    p.requirements.cfg = p.requirements.cfg.mergeSourceFiles(requirements.cfg);
                    break;
                case sharedLibrary: throw new Error("Uninplemented support for shared libraries");
                case executable: break;
            }
        }

        if(requirements.cfg.targetType == TargetType.sourceLibrary)
            becomeIndependent();
    }

    void becomeIndependent()
    {
        assert(dependencies.length == 0, "Can't be independent when having dependencies.");

        foreach(p; parent)
            for(int i = 0; i < p.dependencies.length; i++)
            {
                if(p.dependencies[i] is this)
                {
                    p.dependencies = p.dependencies[0..i] ~ p.dependencies[i+1..$];
                    break;
                }
            }
    }

    ///Collapses the tree in a single list.
    ProjectNode[] collapse()
    {
        bool[ProjectNode] visited;
        return collapseImpl(visited);
    }
    private ProjectNode[] collapseImpl(ref bool[ProjectNode] visited)
    {
        ProjectNode[] ret;
        if(!(this in visited))
        {
            ret~= this;
            visited[this] = true;
        }
        foreach(dep; dependencies)
            ret~= dep.collapseImpl(visited);
        return ret;
    }

    ProjectNode[] findLeavesNodes()
    {
        ProjectNode[] leaves;
        bool[ProjectNode] visited;
        findLeavesNodesImpl(leaves, visited);
        return leaves;
    }

    private void findLeavesNodesImpl(ref ProjectNode[] leaves, ref bool[ProjectNode] visited)
    {
        foreach(dep; dependencies)
            dep.findLeavesNodesImpl(leaves, visited);
        if(dependencies.length == 0)
        {
            if(!(this in visited))
            {
                leaves~= this;
                visited[this] = true;
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

private TargetType inferTargetType(BuildConfiguration cfg)
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

import tree_generators.dub;

void printMatrixTree(ProjectNode[][] mat)
{
    import std.stdio;
    foreach_reverse(i, node; mat)
        foreach(n; node)
            writeln("-".repeat(cast(int)i), " ", n.name);
}