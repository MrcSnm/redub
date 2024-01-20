import std.path;
import logging;

enum TargetType
{
    none = 0, //Bug
    autodetect,
    executable,
    library,
    staticLibrary,
    dynamicLibrary,
    sourceLibrary
}
bool isStaticLibrary(TargetType t)
{
    return t == TargetType.staticLibrary || t == TargetType.library;
}

bool isLinkedSeparately(TargetType t)
{
    return t == TargetType.executable || t == TargetType.dynamicLibrary;
}

TargetType targetFrom(string s)
{
    import std.exception;
    TargetType ret;
    bool found = false;
    static foreach(mem; __traits(allMembers, TargetType))
    {
        if(s == mem)
        {
            found = true;
            ret = __traits(getMember, TargetType, mem);
        } 
    }
    enforce(found, "Could not find targetType with value "~s);
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
        foreach(sourceFolder; inferredSourceFolder)
        {
            if(exists(buildNormalizedPath(workingDir, sourceFolder)))
            {
                initialSource = sourceFolder;
                break;
            }
        }
        
        BuildConfiguration ret;
        if(initialSource) ret.sourcePaths = [initialSource];
        ret.targetType = TargetType.autodetect;
        ret.sourceEntryPoint = "source/app.d";
        ret.outputDirectory = "bin";
        return ret;
    }

    immutable(BuildConfiguration) idup() inout
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
        import std.algorithm.comparison:either;
        BuildConfiguration ret = clone;
        ret.targetType = either(other.targetType, ret.targetType);
        ret.stringImportPaths.exclusiveMergePaths(other.stringImportPaths);
        ret.sourceFiles.exclusiveMerge(other.sourceFiles);
        ret.sourcePaths.exclusiveMergePaths(other.sourcePaths);
        ret.importDirectories.exclusiveMergePaths(other.importDirectories);
        ret.versions.exclusiveMerge(other.versions);
        ret.dFlags.exclusiveMerge(other.dFlags);
        ret.libraries.exclusiveMerge(other.libraries);
        ret.libraryPaths.exclusiveMergePaths(other.libraryPaths);
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
        ret.libraryPaths.exclusiveMergePaths(other.libraryPaths);
        return ret;
    }
    BuildConfiguration mergeImport(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.importDirectories.exclusiveMergePaths(other.importDirectories);
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
        ret.sourcePaths.exclusiveMergePaths(other.sourcePaths);
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
ref string[] exclusiveMerge (return scope ref string[] a, string[] b)
{
    import std.algorithm.searching:countUntil;
    foreach(v; b)
        if(a.countUntil(v) == -1) a~= v;
    return a;
}

ref string[] exclusiveMergeFront (return scope ref string[] a, string[] b)
{
    import std.algorithm.searching:countUntil;
    int pushFrontCount;
    foreach(v; b) if(a.countUntil(v) == -1) pushFrontCount++;
    string[] toPush = new string[](pushFrontCount);
    int i = 0;
    foreach(v; b) if(a.countUntil(v) == -1) toPush[i++] = v;
    a = toPush~a;
    return a;
}
ref string[] exclusiveMergePaths(return scope ref string[] a, string[] b)
{
    import std.algorithm.searching:countUntil;
    foreach(v; b)
    {
        string normB = buildNormalizedPath(v);
        ptrdiff_t index = -1;
        foreach(i, path; a)
        {
            if(buildNormalizedPath(path) == normB)
            {
                index = i;
                break;
            }
        }
        if(index == -1) a~= v;
    }
    return a;
}

enum Visibility
{
    public_,  
    private_,
}
Visibility VisibilityFrom(string vis)
{
    final switch(vis)
    {
        case "private": return Visibility.private_;
        case "public":  return Visibility.public_;
    }
}
struct Dependency
{
    string name;
    string path;
    string version_ = "*";
    BuildRequirements.Configuration subConfiguration;
    string subPackage;
    Visibility visibility = Visibility.public_;

    bool isSameAs(string name, string subPackage) const
    {
        return this.name == name && this.subPackage == subPackage;
    }

    bool isSameAs(Dependency other) const{return isSameAs(other.name, other.subPackage);}

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

    struct Configuration
    {
        string name;
        bool isDefault = true;

        this(string name, bool isDefault)
        {
            this.name = name;
            this.isDefault = isDefault;
            if(name == null)
                isDefault = true;
        }

        bool opEquals(const Configuration other) const
        {
            if(isDefault && other.isDefault) return true;
            return name == other.name;    
        }
    }

    Configuration configuration;
    string targetConfiguration() const { return configuration.name; }
    string[string] getSubConfigurations() const
    {
        string[string] ret;
        foreach(dep; dependencies)
        {
            if(dep.subConfiguration.name)
                ret[dep.name] = dep.subConfiguration.name;
        }
        return ret;
    }

    immutable(BuildRequirements) idup() inout
    {
        return immutable BuildRequirements(
            cfg.idup,
            dependencies.idup,
            version_,
            configuration
        );
    }

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
        return ret.mergeDependencies(other);
    }

    BuildRequirements mergeDependencies(BuildRequirements other) const
    {
        import std.algorithm.searching;
        import std.exception;
        BuildRequirements ret = cast()this;

        vlog("Merging dependencies: ", ret.name, " with ", other.name, " ", other.dependencies);
        foreach(dep; other.dependencies)
        {
            ptrdiff_t index = countUntil!((d) => d.isSameAs(dep))(ret.dependencies);
            if(index == -1) ret.dependencies~= dep;
            else 
            {
                if(dep.subConfiguration != ret.dependencies[index].subConfiguration)
                    enforce(ret.dependencies[index].subConfiguration.isDefault, "Can't merge 2 non default subConfigurations.");
                ret.dependencies[index].subConfiguration = dep.subConfiguration;
            }
        }
        return ret;
    }

    string name() const {return cfg.name;}
}

class ProjectNode
{
    BuildRequirements requirements;
    ProjectNode[] parent;
    ProjectNode[] dependencies;
    private bool shouldRebuild = false;
    private ProjectNode[] collapsedRef;

    string name() const { return requirements.name; }

    this(BuildRequirements req)
    {
        this.requirements = req;
    }

    ProjectNode debugFindDep(string depName)
    {
        foreach(pack; collapse)
            if(pack.name == depName)
                return pack;
        return null;
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
     * - Adds Have_ version for the current project name.
     * - Populating parent imports using children:
     * >-  Imports paths.
     * >-  Versions.
     * >-  dflags.
     * >-  sourceFiles if they are libraries.
     * - Infer target type if it is on autodetect
     * - Add the dependency as a library if it is a library
     * - Add the dependency's libraries 
     * - Remove source libraries from projects to build
     *
     * Also receives an argument containing the collapsed reference of its unique nodes.
     */
    void finish(ProjectNode[] collapsedRef)
    {
        this.collapsedRef = collapsedRef;
        foreach(dep; dependencies)
            dep.finish(collapsedRef);
        import std.string:replace;
        requirements.cfg.name = requirements.cfg.name.replace(":", "_");
        requirements.cfg.versions.exclusiveMerge(["Have_"~requirements.cfg.name.replace("-", "_")]);
        if(requirements.cfg.targetType == TargetType.autodetect)
            requirements.cfg.targetType = inferTargetType(requirements.cfg);
        
        BuildConfiguration toMerge;
        foreach(dep; dependencies)
        {
            import std.string:replace;
            toMerge.versions~= "Have_"~dep.name.replace("-", "_");
        }
        requirements.cfg = requirements.cfg.mergeVersions(toMerge);
        foreach(p; parent)
        {
            p.requirements.cfg = p.requirements.cfg.mergeImport(requirements.cfg);
            p.requirements.cfg = p.requirements.cfg.mergeVersions(requirements.cfg);
            p.requirements.cfg = p.requirements.cfg.mergeDFlags(requirements.cfg);
            p.requirements.cfg = p.requirements.cfg.mergeLinkFilesFromSource(requirements.cfg);
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
                    p.requirements.cfg = p.requirements.cfg.mergeLibraries(requirements.cfg);
                    p.requirements.cfg = p.requirements.cfg.mergeLibPaths(requirements.cfg);
                    p.requirements.cfg = p.requirements.cfg.mergeSourcePaths(requirements.cfg);
                    p.requirements.cfg = p.requirements.cfg.mergeSourceFiles(requirements.cfg);
                    break;
                case dynamicLibrary: throw new Error("Uninplemented support for shared libraries");
                case executable: break;
                case none: throw new Error("Invalid targetType: none");
            }
        }
        
        
        if(requirements.cfg.targetType == TargetType.sourceLibrary)
        {
            vlog("Project ", name, " is a sourceLibrary. Becoming independent.");
            becomeIndependent();
        }
    }
    
    bool isUpToDate() const { return !shouldRebuild; }
    bool isUpToDate() const shared { return !shouldRebuild; }

    ///Invalidates self and parent caches
    void invalidateCache()
    {
        shouldRebuild = true;
        foreach(p; parent) p.invalidateCache();
    }
    ///Helper function for --force
    void invalidateCacheOnTree()
    {
        foreach(node; collapse) node.shouldRebuild = true;
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
    final auto collapse()
    {
        static struct CollapsedRange
        {
            private ProjectNode[] nodes;
            int index = 0;
            bool empty(){return index >= nodes.length; }
            void popFront(){index++;}
            size_t length(){return nodes.length;}
            inout(ProjectNode) front() inout {return nodes[index];}
        }

        return CollapsedRange(collapsedRef);
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


enum ProjectType
{
    D,
    C,
    CPP
}

private TargetType inferTargetType(BuildConfiguration cfg)
{
    static immutable string[] filesThatInfersExecutable = ["app.d", "main.d", "app.c", "main.c"];
    foreach(p; cfg.sourcePaths)
    {
        static import std.file;
        foreach(f; filesThatInfersExecutable)
        if(std.file.exists(buildNormalizedPath(cfg.workingDir, p,f)))
            return TargetType.executable;
    }
    return TargetType.library;
}