module redub.buildapi;

import std.path;
public import std.system:OS;
import redub.logging;

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

enum BuildType
{
    debug_ = "debug",
    plain = "plain",
    release = "release",
    release_debug = "release-debug",
    release_nobounds = "release-nobounds",
    unittest_ = "unittest",
    profile = "profile",
    profile_gc = "profile-gc",
    docs = "docs",
    ddox = "ddox",
    cov = "cov",
    cov_ctfe = "cov-ctfe",
    unittest_cov = "unittest-cov",
    unittest_cov_ctfe = "unittest-cov-ctfe",
    syntax = "syntax",
}

BuildType buildTypeFromString(string bt)
{
    switch(bt)
    {
        static foreach(member; __traits(allMembers, BuildType))
            case __traits(getMember, BuildType, member):
                return __traits(getMember, BuildType, member);
        default: throw new Error("Could not find build type for string "~bt);
    }
}

bool isStaticLibrary(TargetType t)
{
    return t == TargetType.staticLibrary || t == TargetType.library;
}

bool isAnyLibrary(TargetType t)
{
    return t == TargetType.staticLibrary || t == TargetType.library || t == TargetType.dynamicLibrary;
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
    string[] excludeSourceFiles;
    string[] preGenerateCommands;
    string[] postGenerateCommands;
    string[] preBuildCommands;
    string[] postBuildCommands;
    string sourceEntryPoint;
    string outputDirectory;
    string workingDir;
    string arch;
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
        ret.outputDirectory = ".";
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
            excludeSourceFiles.idup,
            preGenerateCommands.idup,
            postGenerateCommands.idup,
            preBuildCommands.idup,
            postBuildCommands.idup,
            sourceEntryPoint,
            outputDirectory,
            workingDir,
            arch,
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
        ret.excludeSourceFiles.exclusiveMerge(other.excludeSourceFiles);
        ret.sourcePaths.exclusiveMergePaths(other.sourcePaths);
        ret.importDirectories.exclusiveMergePaths(other.importDirectories);
        ret.versions.exclusiveMerge(other.versions);
        ret.dFlags.exclusiveMerge(other.dFlags);
        ret.libraries.exclusiveMerge(other.libraries);
        ret.libraryPaths.exclusiveMergePaths(other.libraryPaths);
        ret.linkFlags.exclusiveMerge(other.linkFlags);
        return ret;
    }
    BuildConfiguration mergeLibraries(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.libraries.exclusiveMerge(other.libraries);
        return ret;
    }
    BuildConfiguration mergeLibPaths(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.libraryPaths.exclusiveMergePaths(other.libraryPaths);
        return ret;
    }
    BuildConfiguration mergeImport(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.importDirectories.exclusiveMergePaths(other.importDirectories);
        return ret;
    }
    BuildConfiguration mergeStringImport(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.stringImportPaths.exclusiveMergePaths(other.stringImportPaths);
        return ret;
    }


    BuildConfiguration mergeDFlags(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.dFlags.exclusiveMerge(other.dFlags);
        return ret;
    }
    
    BuildConfiguration mergeVersions(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.versions.exclusiveMerge(other.versions);
        return ret;
    }
    BuildConfiguration mergeSourceFiles(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.sourceFiles.exclusiveMerge(other.sourceFiles);
        return ret;
    }
    BuildConfiguration mergeSourcePaths(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.sourcePaths.exclusiveMergePaths(other.sourcePaths);
        return ret;
    }


    BuildConfiguration mergeLinkFilesFromSource(const BuildConfiguration other) const
    {
        import redub.command_generators.commons;
        BuildConfiguration ret = clone;
        ret.sourceFiles.exclusiveMerge(getLinkFiles(other.sourceFiles));
        return ret;
    }
}

/**
*   Optimized for direct memory allocation.
*/
ref string[] exclusiveMerge (return scope ref string[] a, const scope string[] b)
{
    size_t notFoundCount;
    foreach(bV; b)
    {
        bool found = false;
        if(bV.length == 0) continue;
        foreach(aV; a)
        {
            if(aV == bV) 
            {
                found = true;
                break;
            }
        }
        if(!found) notFoundCount++;
    }

    if(notFoundCount)
    {
        size_t length = a.length;
        size_t index = length;
        a.length+= notFoundCount;
        foreach(bV; b)
        {
            bool found = false;
            if(bV.length == 0) continue;
            foreach(i; 0..length)
            {
                if(a[i] == bV)
                {
                    found = true;
                    break;
                }
            }
            if(!found)
                a[index++] = bV;
        }
    }
    return a;
}

/** 
 * Used when dealing with paths. It normalizes them for not getting the same path twice.
 * This function has been optimized for less memory allocation
 */
ref string[] exclusiveMergePaths(return scope ref string[] a, const string[] b)
{
    static string noTrailingSlash(string input)
    {
        if(input.length > 0 && (input[$-1] == '\\' || input[$-1] == '/')) return input[0..$-1];
        return input;
    }
    static string noInitialDot(string input)
    {
        if(input.length > 1 && input[0] == '.' && (input[1] == '/' || input[1] == '\\')) return input[2..$];
        return input;
    }
    static string fixPath(string input)
    {
        return noTrailingSlash(noInitialDot(input));
    }
    size_t countToMerge;
    foreach(bPath; b)
    {
        bool found;
        foreach(aPath; a)
        {
            found = fixPath(bPath) == fixPath(aPath);
            if(found)
                break;
        }
        if(!found)
            countToMerge++;
    } 
    if(countToMerge > 0)
    {
        size_t putStart = a.length, length = a.length ;
        a.length+= countToMerge;
        foreach(bPath; b) 
        {
            bool found;
            foreach(i; 0..length)
            {
                found = fixPath(bPath) == fixPath(a[i]);
                if(found)
                    break;
            }
            if(!found)
                a[putStart++] = bPath;
        }
    }
    return a;
}

/** 
 * This may be more useful in the future. Also may increase compilation speed
 */
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
    bool isSubConfigurationOnly() const
    {
        return path.length == 0 && subConfiguration.name.length != 0;
    }

    bool isSameAs(Dependency other) const{return isSameAs(other.name, other.subPackage);}

    string fullName() const
    {
        // if(_fullName is null)
        {
            if(subPackage.length) return name~":"~subPackage;
            // else _fullName = name;
        }
        return name;
    }
}

struct PendingMergeConfiguration
{
    bool isPending = false;
    BuildConfiguration configuration;

    immutable(PendingMergeConfiguration) idup() inout
    {
        return immutable PendingMergeConfiguration(
            isPending,
            configuration.idup
        );
    }
}

/**
*   The information inside this struct is not used directly on the build process,
*   but may be used in other areas. One such example is for `describe`. Which will
*   get the full path for each library.
*/
struct ExtraInformation
{
    string[] librariesFullPath;
    string expectedArtifact;

    immutable(ExtraInformation) idup() inout
    {
        return immutable ExtraInformation(
            librariesFullPath.idup
        );
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
    /**
    *   Should not be managed directly. This member is used
    * for holding configuration until the parsing is finished.
    * This will guarantee the correct evaluation order.
    */
    private PendingMergeConfiguration pending;

    ExtraInformation extra;



    BuildRequirements addPending(PendingMergeConfiguration pending) const
    {
        BuildRequirements ret = cast()this;
        ret.pending = pending;
        return ret;
    }

    BuildRequirements mergePending() const
    {
        if(!pending.isPending) return cast()this;
        BuildRequirements ret = cast()this;
        ret.cfg = ret.cfg.merge(ret.pending.configuration);
        ret.pending = PendingMergeConfiguration.init;
        return ret;
    }

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

    /**
    *   Put every subConfiguration which aren't default and not existing in
    *   a subConfigurations map. This is useful for subConfigurations resolution.
    */
    ref string[string] mergeSubConfigurations(ref return string[string] output) const
    {
        foreach(dep; dependencies)
        {
            if(!dep.subConfiguration.isDefault && !(dep.name in output))
                output[dep.name] = dep.subConfiguration.name;
        }
        return output;
    }

    immutable(BuildRequirements) idup() inout
    {
        return immutable BuildRequirements(
            cfg.idup,
            dependencies.idup,
            version_,
            configuration,
            pending.idup,
            extra.idup
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

        vvlog("Merging dependencies: ", ret.name, " with ", other.name, " ", other.dependencies);
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
     * - Outputs on extra information the expected artifact
     * - Remove source libraries from projects to build
     *
     * Also receives an argument containing the collapsed reference of its unique nodes.
     */
    void finish(OS targetOS)
    {
        scope bool[ProjectNode] visitedBuffer;
        scope ProjectNode[] privatesToMerge;
        scope ProjectNode[] sourceLibrariesToRemove;
        privatesToMerge.reserve(128);
        sourceLibrariesToRemove.reserve(64);

        
        static bool hasPrivateRelationship(const ProjectNode parent, const ProjectNode child)
        {
            foreach(dep; parent.requirements.dependencies)
            {
                if(dep.visibility == Visibility.private_ && matches(dep.fullName, child.name))
                    return true;
            }
            return false;
        }
        static void finishSelfRequirements(ProjectNode node, OS targetOS)
        {
            //Finish self requirements
            import std.string:replace;
            node.requirements.cfg.name = node.requirements.cfg.name.replace(":", "_");
            node.requirements.cfg.versions.exclusiveMerge(["Have_"~node.requirements.cfg.name.replace("-", "_")]);
            if(node.requirements.cfg.targetType == TargetType.autodetect)
                node.requirements.cfg.targetType = inferTargetType(node.requirements.cfg);
            
            BuildConfiguration toMerge;
            foreach(dep; node.dependencies)
            {
                import std.string:replace;
                toMerge.versions~= "Have_"~dep.name.replace("-", "_");
            }
            node.requirements.cfg = node.requirements.cfg.mergeVersions(toMerge);
            import redub.command_generators.commons;
            node.requirements.extra.expectedArtifact = buildNormalizedPath(
                node.requirements.cfg.outputDirectory, 
                getOutputName(node.requirements.cfg.targetType, node.requirements.cfg.name, targetOS)
            );
        }
        static void finishMerging(ProjectNode target, const ProjectNode input)
        {
            vvlog("Merging ", input.name, " into ", target.name);
            target.requirements.cfg = target.requirements.cfg.mergeImport(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeStringImport(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeVersions(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeDFlags(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeLinkFilesFromSource(input.requirements.cfg);
            target.requirements.extra.librariesFullPath.exclusiveMerge(
                input.requirements.extra.librariesFullPath
            );
            final switch(input.requirements.cfg.targetType) with(TargetType)
            {
                case autodetect: throw new Error("Node should not be autodetect at this point");
                case library, staticLibrary:
                        BuildConfiguration other = input.requirements.cfg.clone;
                        other.libraries~= other.name;
                        other.libraryPaths~= other.outputDirectory;
                        target.requirements.extra.librariesFullPath.exclusiveMerge(
                            [buildNormalizedPath(other.outputDirectory, other.name)]
                        );
                        target.requirements.cfg = target.requirements.cfg.mergeLibraries(other);
                        target.requirements.cfg = target.requirements.cfg.mergeLibPaths(other);
                    break;
                case sourceLibrary: 
                    target.requirements.cfg = target.requirements.cfg.mergeLibraries(input.requirements.cfg);
                    target.requirements.cfg = target.requirements.cfg.mergeLibPaths(input.requirements.cfg);
                    target.requirements.cfg = target.requirements.cfg.mergeSourcePaths(input.requirements.cfg);
                    target.requirements.cfg = target.requirements.cfg.mergeSourceFiles(input.requirements.cfg);
                    break;
                case dynamicLibrary: throw new Error("Uninplemented support for shared libraries");
                case executable: break;
                case none: throw new Error("Invalid targetType: none");
            }
        }

        static void finishPublic(ProjectNode node, ref bool[ProjectNode] visited, ref ProjectNode[] privatesToMerge, ref ProjectNode[] sourceLibrariesToRemove, OS targetOS)
        {
            if(node in visited) return;
            foreach(dep; node.dependencies)
            {
                if(!(node in visited))
                    finishPublic(dep, visited, privatesToMerge, sourceLibrariesToRemove, targetOS);
            }
            finishSelfRequirements(node, targetOS);
            foreach(p; node.parent)
            {
                if(!hasPrivateRelationship(p, node))
                   finishMerging(p, node);
                else
                    privatesToMerge~= [p, node];
            }
            visited[node] = true;
            if(node.requirements.cfg.targetType == TargetType.sourceLibrary)
                sourceLibrariesToRemove~= node;
        }
        static void finishPrivate(ProjectNode[] privatesToMerge, ProjectNode[] sourceLibrariesToRemove)
        {
            for(int i = 0; i < privatesToMerge.length; i+= 2)
                finishMerging(privatesToMerge[0], privatesToMerge[1]);
            foreach(node; sourceLibrariesToRemove)
            {
                vlog("Project ", node.name, " is a sourceLibrary. Becoming independent.");
                node.becomeIndependent();
            }
        }
        finishPublic(this, visitedBuffer, privatesToMerge, sourceLibrariesToRemove, targetOS);
        finishPrivate(privatesToMerge, sourceLibrariesToRemove);

        visitedBuffer.clear();
        sourceLibrariesToRemove = null;
        privatesToMerge = null;
    }
    
    bool isUpToDate() const { return !shouldRebuild; }
    bool isUpToDate() const shared { return !shouldRebuild; }

    ///Invalidates self and parent caches
    void invalidateCache()
    {
        shouldRebuild = true;
        foreach(p; parent) p.invalidateCache();
    }
    
    /** 
     * This function basically invalidates the entire tree, forcing a rebuild
     */
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
        if(collapsedRef is null) 
        {
            collapsedRef = generateCollapsed();
            foreach(node; collapsedRef) node.collapsedRef = collapsedRef;
        }
        static struct CollapsedRange
        {
            private ProjectNode[] nodes;
            int index = 0;
            bool empty(){return index >= nodes.length; }
            void popFront(){index++;}
            alias popBack = popFront;
            size_t length(){return nodes.length;}
            inout(ProjectNode) front() inout {return nodes[index];}
            inout(ProjectNode) back() inout {return nodes[nodes.length - (index+1)];}
        }

        return CollapsedRange(collapsedRef);
    }

    private ProjectNode[] generateCollapsed()
    {
        ProjectNode[] collapsedList;
        scope bool[ProjectNode] visitedMap;
        static void generateCollapsedImpl(ProjectNode node, ref ProjectNode[] list, ref bool[ProjectNode] visited)
        {
            if(!(node in visited) && node.requirements.cfg.targetType != TargetType.sourceLibrary)
            {
                list~= node;
                visited[node] = true;
            }
            foreach(dep; node.dependencies)
                generateCollapsedImpl(dep, list, visited);
        }
        generateCollapsedImpl(this, collapsedList, visitedMap);
        return collapsedList;
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


pragma(inline, true)
private bool matches(string inputName, string toMatch) @nogc nothrow
{
    import std.ascii;
    if(inputName.length != toMatch.length) return false;
    foreach(i; 0..inputName.length)
    {
        ///Ignore if both is not alpha num (related to _ and :)
        if(inputName[i] != toMatch[i] && (inputName[i].isAlphaNum || toMatch[i].isAlphaNum))
            return false;
    }
    return true;
}