module redub.plugins.fetchlib;
import redub.plugin.api;
import redub.plugins.common;

private enum defaultCacheRoot = "~/.cache/redub/fetchlib";

private struct FetchConfig
{
	string url;
	string tag;
	string branch;
	string directory;
	string cacheRoot;
	string[] sourceFiles;
	string[] excludeSourceFiles;
	string[] importPaths;
	string[] versions;
	string[] dFlags;
}

private FetchConfig loadConfig(string path)
{
	auto reader = ConfigReader.fromFile(path, "fetchlib");
	FetchConfig cfg;
	cfg.url = reader.getString("url");
	cfg.tag = reader.getString("tag");
	cfg.branch = reader.getString("branch");
	cfg.directory = reader.getString("directory");
	cfg.cacheRoot = reader.getString("cacheRoot");
	cfg.sourceFiles = reader.getStringArray("sourceFiles");
	cfg.excludeSourceFiles = reader.getStringArray("excludeSourceFiles");
	cfg.importPaths = reader.getStringArray("importPaths");
	cfg.versions = reader.getStringArray("versions");
	cfg.dFlags = reader.getStringArray("dFlags");

	if(!cfg.url.length)
		throw new Exception("fetchlib: config is missing 'url'");
	if(!cfg.sourceFiles.length)
		throw new Exception("fetchlib: config is missing 'sourceFiles'");
	return cfg;
}

private bool matchesAny(string path, const string[] patterns)
{
	import std.path : globMatch;

	foreach(pattern; patterns)
		if(globMatch(path, pattern))
			return true;
	return false;
}

private string[] findSources(string root, const FetchConfig cfg)
{
	import std.algorithm.searching : startsWith;
	import std.algorithm.sorting : sort;
	import std.file : DirEntry, SpanMode, dirEntries, exists, isDir;
	import std.path : relativePath;

	string[] ret;
	if(!exists(root) || !isDir(root))
		return ret;

	foreach(DirEntry entry; dirEntries(root, SpanMode.depth, false))
	{
		if(entry.isDir)
			continue;
		string rel = relativePath(entry.name, root);
		version(Windows)
		{
			import std.array : replace;
			rel = rel.replace("\\", "/").idup;
		}
		if(rel == ".git" || rel.startsWith(".git/"))
			continue;
		if(matchesAny(rel, cfg.excludeSourceFiles))
			continue;
		if(matchesAny(rel, cfg.sourceFiles))
			ret ~= entry.name;
	}
	sort(ret);
	return ret;
}

private ref RedubPluginStatus handle(RedubPluginData input, out RedubPluginData output, const ref string[] args, ref return RedubPluginStatus status)
{
	import std.algorithm.searching : canFind;
	import std.conv : to;
	import std.file : exists, isDir;
	import std.path : absolutePath, buildNormalizedPath, expandTilde, isAbsolute;

	if(args.length != 1)
		return status = RedubPluginStatus(RedubPluginExitCode.error, "Usage: fetchlib <config.json>");
	if(args[0].length == 0)
		return status = RedubPluginStatus(RedubPluginExitCode.error, "fetchlib: empty config path");

	string configPath = args[0];
	if(!isAbsolute(configPath))
		configPath = absolutePath(expandTilde(configPath));

	FetchConfig cfg = loadConfig(configPath);

	bool local = exists(cfg.url) && isDir(cfg.url);
	bool overridden = false;
	string checkout;
	if(local)
		checkout = absolutePath(cfg.url);
	else
	{
		string overrideSrc = getEnvVar("FETCHLIB_SRC");
		if(overrideSrc.length)
		{
			checkout = absolutePath(expandTilde(overrideSrc));
			overridden = true;
		}
		else
		{
			string root = cfg.cacheRoot.length
				? absolutePath(expandTilde(cfg.cacheRoot))
				: expandTilde(defaultCacheRoot);
			string directory = repositoryCacheName(cfg.url, cfg.tag, cfg.branch, cfg.directory);
			checkout = buildNormalizedPath(root, directory);
		}
	}

	string[] sources = findSources(checkout, cfg);
	if(sources.length == 0 && !local && !overridden)
	{
		cloneGit(cfg.url, gitRevision(cfg.tag, cfg.branch), checkout, "fetchlib");
		sources = findSources(checkout, cfg);
	}
	if(sources.length == 0)
		return status = RedubPluginStatus(RedubPluginExitCode.error,
			"fetchlib: no sources matched "~cfg.sourceFiles.to!string~" in '"~checkout~"'");

	output = input;
	output.versions = input.versions.dup;
	output.dFlags = input.dFlags.dup;
	output.importDirectories = input.importDirectories.dup;
	output.sourceFiles = input.sourceFiles.dup;

	foreach(value; cfg.versions)
		if(!output.versions.canFind(value))
			output.versions ~= value;
	foreach(value; cfg.dFlags)
		if(!output.dFlags.canFind(value))
			output.dFlags ~= value;

	string[] importPaths = cfg.importPaths.length ? cfg.importPaths : ["."];
	foreach(importPath; importPaths)
	{
		string absolute = isAbsolute(importPath) ? importPath : buildNormalizedPath(checkout, importPath);
		if(!output.importDirectories.canFind(absolute))
			output.importDirectories ~= absolute;
	}
	foreach(source; sources)
		if(!output.sourceFiles.canFind(source))
			output.sourceFiles ~= source;

	return status = RedubPluginStatus(RedubPluginExitCode.success,
		"fetched '"~cfg.url~"' at '"~checkout~"' ("~sources.length.to!string~" sources)");
}

class FetchLibPlugin : RedubPlugin
{
	extern(C) ref RedubPluginStatus preGenerate(RedubPluginData input, out RedubPluginData output, const ref string[] args, ref return RedubPluginStatus status)
	{
		try
			return handle(input, output, args, status);
		catch(Exception e)
			return status = RedubPluginStatus(RedubPluginExitCode.error, e.msg);
	}

	extern(C) ref RedubPluginStatus postGenerate(RedubPluginData input, out RedubPluginData output, const ref string[] args, ref return RedubPluginStatus status)
	{
		return status = RedubPluginStatus.success();
	}


	void postBuild()
	{
	}
}
