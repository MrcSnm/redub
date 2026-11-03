module redub.extensions.imports;

version(RedubCLI):

import redub.api;
import redub.extensions.cli : resolveCliDependencies = resolveDependencies;
import redub.logging;
import d_dependencies;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.stdio : writeln;

///Scans the current project's D sources (or explicit directories) and prints
///the import graph.
int importsMain(string[] args)
{
    import std.getopt;

    bool edges;
    bool stats;
    bool header;
    bool forceUnittest;
    string[] sources;
    string[] excludes;
    GetoptResult res;
    try
        res = getopt(args, config.passThrough,
            "edges", "Print the module/import edge list.", &edges,
            "stats", "Print one TSV summary line.", &stats,
            "header", "Include the TSV header with --stats.", &header,
            "unittest", "Scan unittest blocks even when the build type does not enable them.", &forceUnittest,
            "source", "Scan this directory instead of resolving a project. Repeatable.", &sources,
            "exclude", "Glob of source files to ignore. Repeatable.", &excludes);
    catch(GetOptException e)
    {
        setLogLevel(LogLevel.error);
        errorTitle("Argument Error: ", e.msg);
        return 1;
    }
    if(res.helpWanted)
    {
        defaultGetoptPrinter(
            "redub imports\n\tScans the project's D sources and prints the import graph.",
            res.options);
        return 0;
    }

    string packageName;
    string[] scanSources;
    string[] scanSourceFiles;
    string[] scanExcludes;
    ImportScanContext ctx;

    if(sources.length)
    {
        if(args.length > 1)
        {
            setLogLevel(LogLevel.error);
            errorTitle("Argument Error: ", "unexpected arguments with --source: ", args[1 .. $]);
            return 1;
        }
        scanSources = sources;
        scanExcludes = excludes;
        ctx = defaultImportScanContext();
        ctx.unittestMode = forceUnittest;
        import std.path : baseName, buildNormalizedPath;
        packageName = baseName(buildNormalizedPath(sources[0]));
    }
    else
    {
        ///Keep stdout clean for the graph output and do not run preGenerate hooks.
        args ~= "--quiet";
        ProjectDetails d = resolveCliDependencies(args, true);
        if(!d.tree)
            return d.getReturnCode();

        BuildConfiguration cfg = d.tree.requirements.cfg;
        CompilingSession session = CompilingSession(d.compiler, d.cDetails.targetOS, d.cDetails.isa);
        ctx = defaultImportScanContext(session.os, session.isa);
        foreach(version_; cfg.versions)
            ctx.addVersion(version_);
        foreach(version_; cfg.debugVersions)
            ctx.addDebugVersion(version_);
        ctx.debugMode = cfg.isDebug;
        ctx.unittestMode = forceUnittest || cfg.isUnittest;
        ctx.stringImportPaths = cfg.stringImportPaths;
        foreach(name; trustedNoImportMixinsFor(cfg.workingDir))
            ctx.addTrustedNoImportMixin(name);

        packageName = d.tree.name;
        scanSources = cfg.sourcePaths;
        scanSourceFiles = cfg.sourceFiles;
        scanExcludes = cfg.excludeSourceFiles ~ excludes;
    }

    StopWatch sw = StopWatch(AutoStart.yes);
    SourceImportGraph graph = parseSourceImportGraph(scanSources, scanSourceFiles,
        scanExcludes, ctx);
    const long parseMs = sw.peek.total!"msecs";

    size_t internalEdges;
    long doubtful;
    long importRisks;
    long unknownStaticIf;
    long unresolvedMixins;
    long unresolvedStringMixins;
    long unknownVersionIds;
    foreach(mod; graph.modules)
    {
        foreach(_, imp; mod.imports)
            if(!imp.isExternal) internalEdges++;
        if(mod.isDoubtful) doubtful++;
        if(mod.isImportRisk) importRisks++;
        if(mod.hasUnknownConditionals) unknownStaticIf++;
        if(mod.hasUnresolvedMixins) unresolvedMixins++;
        if(mod.hasUnresolvedStringMixins) unresolvedStringMixins++;
        if(mod.hasUnknownVersionIdentifiers) unknownVersionIds++;
    }

    if(edges)
    {
        foreach(mod; graph.modules)
            writeln("MODULE\t", mod.modPath, "\t", mod.modName);
        foreach(mod; graph.modules)
            foreach(_, imp; mod.imports)
                writeln("EDGE\t", mod.modPath, "\t", mod.modName, "\t", imp.modName);
        return 0;
    }

    if(stats)
    {
        if(header)
            writeln("package\tmodules\tinternalEdges\texternalImports\tdoubtful\t"
                ~ "unknownStaticIf\tunresolvedMixins\tunresolvedStringMixins\t"
                ~ "unknownVersionIds\tskippedFiles\tparseMs");
        writeln(packageName, '\t', graph.modules.length, '\t', internalEdges, '\t',
            graph.externalImports.length, '\t', doubtful, '\t', unknownStaticIf, '\t',
            unresolvedMixins, '\t', unresolvedStringMixins, '\t', unknownVersionIds,
            '\t', graph.skippedFiles.length, '\t', parseMs);
        return 0;
    }

    writeln("Package: ", packageName);
    writeln("Modules: ", graph.modules.length, " (internal edges: ", internalEdges, ")");
    writeln("External imports: ", graph.externalImports.length);
    writeln("Doubtful: ", doubtful, " (import risk: ", importRisks, ")");
    if(graph.skippedFiles.length)
        writeln("Skipped files: ", graph.skippedFiles.length);
    writeln("Parsed in ", parseMs, " ms");
    foreach(mod; graph.modules)
    {
        if(!mod.isDoubtful) continue;
        if(mod.doubts.length)
            writeln("  ", mod.modPath, ": ", mod.doubts[0]);
        else
            writeln("  ", mod.modPath, ": doubtful");
    }
    return 0;
}
