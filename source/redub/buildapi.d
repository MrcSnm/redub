module redub.buildapi;

public import std.system:OS, ISA, instructionSetArchitecture;
public import redub.compiler_identification: Compiler;
public import redub.plugin.api;
import redub.logging;
import redub.package_searching.api;

///vX.X.X
enum RedubVersionOnly = "v1.14.3";
///Redub vX.X.X
enum RedubVersionShort = "Redub "~RedubVersionOnly;
///Redub vX.X.X - Description
enum RedubVersion = RedubVersionShort ~ " - A reimagined DUB";

/**
 * CompilingSession is important for the hash calculation and thus is passed all around while building.
 * This guarantees that if any of its configuration changes, a build can be retriggered or recovered
 */
struct CompilingSession
{
    Compiler compiler;
    OS os;
    ISA isa;
}

enum TargetType
{
    invalid = 0, //Bug
    none,
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
    compiler_verbose = "compiler-verbose",
    codegen_verbose = "codegen-verbose",
    time_trace = "time-trace",
    mixin_check = "mixin-check",
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
        default: throw new Exception("Could not find build type for string "~bt);
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

enum excludeRoot;
enum cacheExclude;

struct PluginExecution
{
    string name;
    string[] args;


    immutable(PluginExecution) idup() const
    {
        return PluginExecution(name, args.dup);
    }
}

struct BuildConfiguration
{
    bool isDebug;
    string name;
    string[] versions;
    string[] debugVersions;
    string[] importDirectories;
    string[] libraryPaths;
    string[] stringImportPaths;
    string[] libraries;
    string[] linkFlags;
    string[] dFlags;
    string[] sourcePaths;
    string[] sourceFiles;
    string[] excludeSourceFiles;
    string[] extraDependencyFiles;
    string[] filesToCopy;
    string[] preGenerateCommands;
    string[] postGenerateCommands;
    string[] preBuildCommands;
    PluginExecution[] preBuildPlugins;
    string[] postBuildCommands;
    ///Unused
    string sourceEntryPoint;
    @cacheExclude string targetName;

    ///When having those files, the build will use them instead of sourcePaths + sourceFiles
    @cacheExclude string[] changedBuildFiles;
    @excludeRoot string outputDirectory;
    ///Whenever present, --deps= will be pased to the compiler for using advanced compilation mode
    @cacheExclude bool outputsDeps;
    ///Uses --oq on ldc, -op on dmd (rename+move while bug exists)
    @cacheExclude bool preservePath = true;
    @cacheExclude bool compilerVerbose;
    @cacheExclude bool compilerVerboseCodeGen;

    string workingDir;
    string arch;
    TargetType targetType;

    static BuildConfiguration defaultInit(string workingDir)
    {
        import std.path;
        import std.file;
        static immutable inferredSourceFolder = ["source", "src"];
        static immutable inferredStringImportFolder = ["views"];
        string initialSource;
        string initialStringImport;
        foreach(sourceFolder; inferredSourceFolder)
        {
            if(exists(buildNormalizedPath(workingDir, sourceFolder)))
            {
                initialSource = sourceFolder;
                break;
            }
        }

        foreach(striFolder; inferredStringImportFolder)
        {
            if(exists(buildNormalizedPath(workingDir, striFolder)))
            {
                initialStringImport = striFolder;
                break;
            }
        }

        
        BuildConfiguration ret;
        if(initialSource)
        {
            ret.sourcePaths = [initialSource];
            ret.importDirectories = [initialSource];
        }
        if(initialStringImport) ret.stringImportPaths = [initialStringImport];
        ret.targetType = TargetType.autodetect;
        ret.sourceEntryPoint = "source/app.d";
        ret.outputDirectory = ".";
        return ret;
    }

    RedubPluginData toRedubPluginData() const
    {
        RedubPluginData ret;
        static foreach(mem; __traits(allMembers, RedubPluginData))
            __traits(getMember, ret, mem) = __traits(getMember, this, mem).dup;
        return ret;
    }

    BuildConfiguration mergeRedubPlugin(RedubPluginData pluginData) const
    {
        BuildConfiguration ret = clone;
        static foreach(mem; __traits(allMembers, RedubPluginData))
            __traits(getMember, ret, mem) = __traits(getMember, pluginData, mem);
        return ret;
    }

    immutable(BuildConfiguration) idup() const
    {
        import std.algorithm;
        import std.array;
        BuildConfiguration ret;
        static foreach(i, value; BuildConfiguration.tupleof)
        {
            static if(is(typeof(ret.tupleof[i]) == string[]))
                ret.tupleof[i] = cast(string[])this.tupleof[i].idup;
            else static if(is(typeof(ret.tupleof[i]) == PluginExecution[]))
            {
                ret.tupleof[i] = cast(PluginExecution[])this.tupleof[i].map!((const PluginExecution p) => p.idup).array;
            }
            else
                ret.tupleof[i] = this.tupleof[i];
        }
        return cast(immutable)ret;
    }

    BuildConfiguration clone() const{return cast()this;}

    /** 
     * This function is mainly used to merge a default configuration + a subConfiguration.
     * It does not execute a parent<-child merging, this step is done at the ProjectNode.
     * So, almost every property should be merged with each other here.
     * Params:
     *   other = The other configuration to merge
     * Returns: 
     */
    BuildConfiguration merge(BuildConfiguration other) const
    {
        import std.algorithm.comparison:either;
        BuildConfiguration ret = clone;
        ret.targetType = either(other.targetType, ret.targetType);
        ret.outputDirectory = either(other.outputDirectory, ret.outputDirectory);
        ret = ret.mergeCommands(other);
        ret.compilerVerbose = other.compilerVerbose;
        ret.compilerVerboseCodeGen = other.compilerVerboseCodeGen;
        ret.extraDependencyFiles.exclusiveMergePaths(other.extraDependencyFiles);
        ret.filesToCopy.exclusiveMergePaths(other.filesToCopy);
        ret.stringImportPaths.exclusiveMergePaths(other.stringImportPaths);
        ret.sourceFiles.exclusiveMerge(other.sourceFiles);
        ret.excludeSourceFiles.exclusiveMerge(other.excludeSourceFiles);
        ret.sourcePaths.exclusiveMergePaths(other.sourcePaths);
        ret.importDirectories.exclusiveMergePaths(other.importDirectories);
        ret.versions.exclusiveMerge(other.versions);
        ret.debugVersions.exclusiveMerge(other.debugVersions);
        ret.dFlags.exclusiveMerge(other.dFlags);
        ret.libraries.exclusiveMerge(other.libraries);
        ret.libraryPaths.exclusiveMergePaths(other.libraryPaths);
        ret.linkFlags.exclusiveMerge(other.linkFlags);
        return ret;
    }

    BuildConfiguration mergeCommands(BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.preBuildPlugins~= other.preBuildPlugins;
        ret.preBuildCommands~= other.preBuildCommands;
        ret.postBuildCommands~= other.postBuildCommands;
        ret.preGenerateCommands~= other.preGenerateCommands;
        ret.postGenerateCommands~= other.postGenerateCommands;
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

    BuildConfiguration mergeLinkFlags(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.linkFlags.exclusiveMerge(other.linkFlags);
        return ret;
    }

    BuildConfiguration mergeFilteredDflags(const BuildConfiguration other) const
    {
        immutable string[] filterDflags = [
            "-betterC",
            "-mixin=",
            "-ftime-trace",
            "-ftime-trace-file=",
            "-ftime-trace-granularity=",
            "-preview="
        ];

        BuildConfiguration ret = clone;
        ret.dFlags.exclusiveMerge(other.dFlags, filterDflags);
        return ret;
    }
    
    BuildConfiguration mergeVersions(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.versions.exclusiveMerge(other.versions);
        return ret;
    }

    BuildConfiguration mergeDebugVersions(const BuildConfiguration other) const
    {
        BuildConfiguration ret = clone;
        ret.debugVersions.exclusiveMerge(other.debugVersions);
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



private auto save(TRange)(TRange input)
{
    import std.traits:isArray;
    static if(isArray!TRange)
        return input;
    else
        return input.save;
}

/**
*   Optimized for direct memory allocation.
*/
ref string[] exclusiveMerge(StringRange)(return scope ref string[] a, StringRange b, scope const string[] excludeFromMerge = null)
{
    import std.algorithm.searching:countUntil;

    size_t notFoundCount;
    foreach(bV; save(b))
    {
        bool found = false;
        if(bV.length == 0) continue;
        if(countUntil(excludeFromMerge, bV) != -1) continue;
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
        foreach(bV; save(b))
        {
            bool found = false;
            if(bV.length == 0) continue;
            if(countUntil(excludeFromMerge, bV) != -1) continue;
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
ref string[] exclusiveMergePaths(StringRange)(return scope ref string[] a, StringRange b)
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
    foreach(bPath; save(b))
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
        foreach(bPath; save(b) )
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

ref string[] inPlaceFilter(return scope ref string[] a, bool function(string obj) shouldInclude)
{
    size_t includeLength = 0;
    for(int i = 0; i < a.length; i++)
    {
        if(!shouldInclude(a[i]))
        {
            a[i] = a[i+1];
            i++;
        }
        else
            includeLength++;
    }
    a.length = includeLength;
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
    ///This package info is used internally for keeping all the required versions in sync, so an additional pass for changing their versions isn't needed.
    PackageInfo* pkgInfo;
    bool isOptional;

    bool isSameAs(string name, string subPackage) const
    {
        return this.name == name && this.subPackage == subPackage;
    }
    bool isSubConfigurationOnly() const
    {
        return path.length == 0 && subConfiguration.name.length != 0;
    }

    bool isSameAs(Dependency other) const{return isSameAs(other.name, other.subPackage);}
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
    string[] expectedArtifacts;

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

    immutable(ThreadBuildData) buildData() inout
    {
        return immutable ThreadBuildData(
            cfg.idup,
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


/**
 * Used as a final piece of information that the Threads will use.
 * It uses build configuration and has all the extra data needed here.
 * Since the requirement needs to be immutable, it can't have any pointers (Dependency).PackageInfo
 */
struct ThreadBuildData
{
    BuildConfiguration cfg;
    ExtraInformation extra;
}

class ProjectNode
{
    BuildRequirements requirements;
    ProjectNode[] parent;
    ProjectNode[] dependencies;
    private bool shouldRebuild = false;
    private bool needsCopyOnly = false;
    private ProjectNode[] collapsedRef;
    private bool _isOptional = false;
    private string[] dirtyFiles;

    string name() const { return requirements.name; }
    string targetName() const { return requirements.cfg.targetName; }

    string getOutputName(OS targetOS, ISA isa = instructionSetArchitecture) const
    {
        return getOutputName(requirements.cfg.targetType, targetOS, isa);
    }

    string getOutputName(TargetType targetType, OS targetOS, ISA isa = instructionSetArchitecture) const
    {
        import redub.command_generators.commons;
        import std.path;
        return buildNormalizedPath(
            requirements.cfg.outputDirectory,
            redub.command_generators.commons.getOutputName(targetType, requirements.cfg.targetName, targetOS, isa)
        );
    }

    this(BuildRequirements req, bool isOptional)
    {
        this.requirements = req;
        this._isOptional = isOptional;
    }

    bool isOptional() const { return this._isOptional; }
    void makeRequired(){this._isOptional = false;}

    ProjectNode debugFindDep(string depName)
    {
        foreach(pack; collapse)
            if(pack.name == depName)
                return pack;
        return null;
    }

    bool isRoot() const { return this.parent.length == 0; }
    bool isRoot() const shared { return this.parent.length == 0; }

    ProjectNode addDependency(ProjectNode dep)
    {
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
    void finish(OS targetOS, ISA isa)
    {
        scope bool[ProjectNode] visitedBuffer;
        scope ProjectNode[] privatesToMerge;
        scope ProjectNode[] dependenciesToRemove;
        privatesToMerge.reserve(128);
        dependenciesToRemove.reserve(64);

        static void mergeParentInDependencies(ProjectNode root)
        {
            foreach(dep; root.dependencies)
            {
                dep.requirements.cfg = dep.requirements.cfg.mergeDFlags(root.requirements.cfg)
                    .mergeVersions(root.requirements.cfg)
                    .mergeDebugVersions(root.requirements.cfg);
            }
            foreach(dep; root.dependencies)
                mergeParentInDependencies(dep);
        }


        
        static bool hasPrivateRelationship(const ProjectNode parent, const ProjectNode child)
        {
            foreach(dep; parent.requirements.dependencies)
            {
                if(dep.visibility == Visibility.private_ && matches(dep.name, child.name))
                    return true;
            }
            return false;
        }

        /**
         * This function will transfer its dependencies if they are none or sourceLibrary. Which means they aren't "compiled", but
         * they are a container of dependencies inside their parent.
         *
         * If the dependency is none or sourceLibrary, they will be transferred.
         * Params:
         *   node = The root node
         *   removedOptionals = String container for printing later warnings
         */
        static void transferDependenciesAndClearOptional(ProjectNode node, ref string[] removedOptionals)
        {
            ///Enters in the deepest node
            for(int i = 0; i < node.dependencies.length; i++)
            {
                if(node.dependencies[i].isOptional)
                {
                    if(hasLogLevel(LogLevel.warn))
                        removedOptionals~= node.dependencies[i].name;
                    node.dependencies[i].becomeIndependent();
                    i--;
                    continue;
                }
                transferDependenciesAndClearOptional(node.dependencies[i], removedOptionals);
            }
            ///If the node is none or sourceLibrary, transfer all of its dependencies to all of its parents
            bool shouldTransfer = node.requirements.cfg.targetType == TargetType.none || node.requirements.cfg.targetType == TargetType.sourceLibrary;
            if(shouldTransfer)
            {
                for(int i = 0; i < node.parent.length; i++)
                {
                    ProjectNode p = node.parent[i];
                    foreach(dep; node.dependencies)
                        p.addDependency(dep);
                }
                node.dependencies = null;

                ///Node is only independent when == none. It can't be independent on sourceLibrary since it needs to transfer its build commands.
                if(node.requirements.cfg.targetType == TargetType.none)
                    node.becomeIndependent();
            }
            
        }

        static void finishSelfRequirements(ProjectNode node, OS targetOS, ISA isa)
        {
            //Finish self requirements
            import std.path;
            import std.string:replace;
            ///Format from Have_project:subpackage to Have_project_subpackage
            node.requirements.cfg.name = node.requirements.cfg.name.replace(":", "_");
            node.requirements.cfg.targetName = node.requirements.cfg.targetName.replace(":", "_");

            ///Format from projects such as match-3 into Have_match_3
            node.requirements.cfg.versions.exclusiveMerge(["Have_"~node.requirements.cfg.name.replace("-", "_")]);
            if(node.requirements.cfg.targetType == TargetType.autodetect)
                node.requirements.cfg.targetType = inferTargetType(node);

            ///Transforms every dependency into Have_dependency
            BuildConfiguration toMerge;
            foreach(dep; node.dependencies)
            {
                import std.string:replace;
                toMerge.versions~= "Have_"~dep.name.replace("-", "_");
            }
            node.requirements.cfg = node.requirements.cfg.mergeVersions(toMerge);

            
            ///Adds the output to the expectedArtifact. Those files will be considered on the cache formula.
            node.requirements.extra.expectedArtifacts~= node.getOutputName(targetOS, isa);

            ///Execute pkg-config for Posix
            version(Posix)
            {
                if(node.requirements.cfg.targetType.isLinkedSeparately && node.requirements.cfg.libraries.length)
                {
                    import redub.command_generators.commons: getConfigurationFromLibsWithPkgConfig;
                    string[] mod;
                    BuildConfiguration pkgCfgLib = getConfigurationFromLibsWithPkgConfig(node.requirements.cfg.libraries, mod);
                    node.requirements.cfg.libraries = pkgCfgLib.libraries;
                    node.requirements.cfg = node.requirements.cfg.mergeDFlags(pkgCfgLib).mergeLinkFlags(pkgCfgLib);
                }
            }

            import redub.command_generators.commons;

            ///When windows builds shared libraries and they aren't root, it also generates a static library (import library)
            ///This library will enter on the cache formula
            if(!node.isRoot && node.requirements.cfg.targetType == TargetType.dynamicLibrary && targetOS.isWindows)
            {
                node.requirements.extra.expectedArtifacts~= node.getOutputName(TargetType.staticLibrary, targetOS, isa);
            }
        }
        static void finishMerging(ProjectNode target, ProjectNode input)
        {
            import std.path;
            vvlog("Merging ", input.name, " into ", target.name);
            target.requirements.cfg = target.requirements.cfg.mergeImport(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeStringImport(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeVersions(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeFilteredDflags(input.requirements.cfg);
            target.requirements.cfg = target.requirements.cfg.mergeLinkFlags(input.requirements.cfg);

            target.requirements.cfg = target.requirements.cfg.mergeLinkFilesFromSource(input.requirements.cfg);

            target.requirements.extra.librariesFullPath.exclusiveMerge(
                input.requirements.extra.librariesFullPath
            );
            final switch(input.requirements.cfg.targetType) with(TargetType)
            {
                case autodetect: throw new Exception("Node should not be autodetect at this point");
                case library, staticLibrary, dynamicLibrary:
                        BuildConfiguration other = input.requirements.cfg.clone;
                        ///Add the artifact full path to the target
                        target.requirements.extra.librariesFullPath.exclusiveMerge(
                            [buildNormalizedPath(other.outputDirectory, other.targetName)]
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
                case executable: break;
                case none: throw new Exception("TargetType: none as a root project: nothing to do");
                case invalid: throw new Exception("No targetType was found.");
            }
        }

        static void finishPublic(ProjectNode node, ref bool[ProjectNode] visited, ref ProjectNode[] privatesToMerge, ref ProjectNode[] dependenciesToRemove, OS targetOS, ISA isa)
        {
            if(node in visited) return;
            ///Enters in the deepest node
            for(int i = 0; i < node.dependencies.length; i++)
            {
                ProjectNode dep = node.dependencies[i];
                if(!(node in visited))
                    finishPublic(dep, visited, privatesToMerge, dependenciesToRemove, targetOS, isa);
            }
            ///Finish defining its self requirements so they can be transferred to its parents
            finishSelfRequirements(node, targetOS, isa);
            ///If this has a private relationship, no merge occurs with parent. 
            for(int i = 0; i < node.parent.length; i++)
            {
                ProjectNode p = node.parent[i];
                if(!hasPrivateRelationship(p, node))
                   finishMerging(p, node);
                else
                    privatesToMerge~= [p, node];
            }
            visited[node] = true;
            if(node.requirements.cfg.targetType == TargetType.sourceLibrary || node.requirements.cfg.targetType == TargetType.none)
                dependenciesToRemove~= node;
        }
        static void finishPrivate(ProjectNode[] privatesToMerge, ProjectNode[] dependenciesToRemove)
        {
            for(int i = 0; i < privatesToMerge.length; i+= 2)
                finishMerging(privatesToMerge[i], privatesToMerge[i+1]);
            foreach(node; dependenciesToRemove)
            {
                vlog("Project ", node.name, " is a ", node.requirements.cfg.targetType == TargetType.sourceLibrary ? "sourceLibrary" : "none",". Becoming independent.");
                if(node.requirements.cfg.targetType == TargetType.none && node.parent.length != 0)
                    node.dependencies = null;
                node.becomeIndependent();
            }
        }


        mergeParentInDependencies(this);
        string[] removedOptionals;
        transferDependenciesAndClearOptional(this, removedOptionals);
        if(removedOptionals.length)
            warn("Optional Dependencies ", removedOptionals, " not included since they weren't requested as non optional from other places.");
        finishPublic(this, visitedBuffer, privatesToMerge, dependenciesToRemove, targetOS, isa);
        finishPrivate(privatesToMerge, dependenciesToRemove);
        visitedBuffer.clear();

        dependenciesToRemove = null;
        privatesToMerge = null;
    }

    
    bool isUpToDate() const { return !shouldRebuild; }
    bool isUpToDate() const shared { return !shouldRebuild; }

    bool isCopyEnough() const { return needsCopyOnly; }
    bool isCopyEnough() const shared { return needsCopyOnly; }

    bool shouldEnterCompilationThread() const
    {
        return !isUpToDate || isCopyEnough;
    }


    void setCopyEnough(const string[] files)
    {
        if(hasLogLevel(LogLevel.verbose))
            warnTitle("Project "~ name ~ " copy files: ", files);
        needsCopyOnly = true;
    }

    void setFilesDirty(const string[] files)
    {
        import redub.logging;
        if(hasLogLevel(LogLevel.verbose))
            warnTitle("Project "~ name ~ " Dirty Files: ", files);
        this.dirtyFiles = files.dup;
    }
    const(string[]) getDirtyFiles() const { return cast(const)this.dirtyFiles; }

    ///Invalidates self and parent caches
    void invalidateCache()
    {
        needsCopyOnly = false;
        shouldRebuild = true;
        foreach(p; parent) p.invalidateCache();
    }
    
    /** 
     * This function basically invalidates the entire tree, forcing a rebuild
     */
    void invalidateCacheOnTree()
    {
        foreach(ProjectNode node; collapse)
        {
            node.shouldRebuild = true;
            node.needsCopyOnly = false;
        }
    }

    /** 
     * Can only be independent if no dependency is found.
     */
    void becomeIndependent()
    {
        import std.exception;
        enforce(dependencies.length == 0 || this.isOptional, "Dependency "~this.name~" can't be independent when having dependencies.");

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

    /** 
     * This function will try to build the entire project in a single compilation run
     */
    void combine()
    {
        ProjectNode[] leaves;

        while(true)
        {
            leaves = findLeavesNodes();
            if(leaves[0] is this)
                break;
            foreach(leaf; leaves)
            {
                foreach(ref leafParent; leaf.parent)
                {
                    ///Keep the old target type.
                    TargetType oldTargetType = leafParent.requirements.cfg.targetType;
                    leafParent.requirements.cfg = leafParent.requirements.cfg.merge(leaf.requirements.cfg);
                    leafParent.requirements.cfg.targetType = oldTargetType;
                }
                leaf.parent[0].requirements.cfg = leaf.parent[0].requirements.cfg.mergeCommands(leaf.requirements.cfg);
                leaf.becomeIndependent();
            }
        }
        this.requirements.extra.librariesFullPath = null;
    }
}

void putLinkerFiles(const ProjectNode tree, out string[] dataContainer)
{
    import std.algorithm.iteration;
    import redub.command_generators.commons;
    import std.range;
    import std.path;
    
    if(tree.requirements.cfg.targetType.isStaticLibrary)
        dataContainer~= tree.getOutputName(os);

    dataContainer = dataContainer.append(tree.requirements.extra.librariesFullPath.map!((string libPath)
    {
        return buildNormalizedPath(dirName(libPath), getOutputName(TargetType.staticLibrary, baseName(libPath), os));
    }).retro);
}

void putSourceFiles(const ProjectNode tree, out string[] dataContainer)
{
    import redub.command_generators.commons;
    redub.command_generators.commons.putSourceFiles(dataContainer, 
        tree.requirements.cfg.workingDir,
        tree.requirements.cfg.sourcePaths,
        tree.requirements.cfg.sourceFiles,
        tree.requirements.cfg.excludeSourceFiles,
        ".d"
    );
}


enum ProjectType
{
    D,
    C,
    CPP
}

private TargetType inferTargetType(const ProjectNode node)
{
    static immutable string[] filesThatInfersExecutable = ["app.d", "main.d", "app.c", "main.c"];
    import std.path;
    if(node.parent.length == 0) foreach(p; node.requirements.cfg.sourcePaths)
    {
        static import std.file;
        foreach(f; filesThatInfersExecutable)
        if(std.file.exists(buildNormalizedPath(node.requirements.cfg.workingDir, p,f)))
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