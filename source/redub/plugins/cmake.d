module redub.plugins.cmake;
import redub.plugin.api;
import redub.plugins.common;

private enum markerName = ".redub-cmake-ok";

private struct CmakeConfig
{
	string url;
	string tag;
	string branch;
	string directory;
	string cacheRoot;
	string sourceSubdir;
	string target;
	string destination;
	string[] cmakeArgs;
	string[] buildArgs;
	string[] installArgs;
	bool force;
}

private CmakeConfig loadConfig(string path)
{
	auto reader = ConfigReader.fromFile(path, "cmake");
	CmakeConfig cfg;
	cfg.url = reader.getString("url");
	cfg.tag = reader.getString("tag");
	cfg.branch = reader.getString("branch");
	cfg.directory = reader.getString("directory");
	cfg.cacheRoot = reader.getString("cacheRoot");
	cfg.sourceSubdir = reader.getString("sourceSubdir");
	cfg.target = reader.getString("target");
	cfg.destination = reader.getString("destination");
	cfg.cmakeArgs = reader.getStringArray("cmakeArgs");
	cfg.buildArgs = reader.getStringArray("buildArgs");
	cfg.installArgs = reader.getStringArray("installArgs");
	cfg.force = reader.getBool("force");

	if(!cfg.url.length)
		throw new Exception("cmake: config is missing 'url'");
	return cfg;
}

private string fnv1a(string data)
{
	import std.format : format;

	uint hash = 2166136261u;
	foreach(byteValue; data)
	{
		hash ^= byteValue;
		hash *= 16777619u;
	}
	return format!"%08X"(hash);
}

private void copyTree(string from, string to)
{
	import std.file : SpanMode, copy, dirEntries, isDir, mkdirRecurse;
	import std.path : buildNormalizedPath, dirName, relativePath;

	mkdirRecurse(to);
	foreach(entry; dirEntries(from, SpanMode.depth, false))
	{
		string destination = buildNormalizedPath(to, relativePath(entry.name, from));
		if(entry.isDir)
		{
			mkdirRecurse(destination);
			continue;
		}
		mkdirRecurse(dirName(destination));
		removePath(destination);
		copy(entry.name, destination);
	}
}

private ref RedubPluginStatus handle(RedubPluginData input, out RedubPluginData output, const ref string[] args, ref return RedubPluginStatus status)
{
	import std.algorithm.searching : startsWith;
	import std.array : join;
	import std.file : exists, getcwd, isDir, readText, rename, write;
	import std.path : buildNormalizedPath, dirName;

	if(args.length != 1)
		return status = RedubPluginStatus(RedubPluginExitCode.error, "Usage: cmake <config.json>");
	if(args[0].length == 0)
		return status = RedubPluginStatus(RedubPluginExitCode.error, "cmake: empty config path");

	string packageDir = input.outputDirectory;
	if(!packageDir.length)
		packageDir = getcwd();
	packageDir = asAbsolutePath(packageDir);

	string configPath = expandHome(args[0]);
	if(!isAbsolutePath(configPath))
		configPath = buildNormalizedPath(packageDir, configPath);

	CmakeConfig cfg = loadConfig(configPath);

	string cacheRoot = cfg.cacheRoot.length ? cfg.cacheRoot : defaultPluginCacheRoot("cmake");
	cacheRoot = asAbsolutePath(expandHome(cacheRoot));

	string revision = gitRevision(cfg.tag, cfg.branch);
	string cacheName = repositoryCacheName(cfg.url, cfg.tag, cfg.branch, cfg.directory);

	string optionsKey = fnv1a([
		cfg.url,
		revision,
		cfg.sourceSubdir,
		cfg.target,
		cfg.cmakeArgs.join("\x1f"),
		cfg.buildArgs.join("\x1f"),
		cfg.installArgs.join("\x1f"),
	].join("\x1e"));

	string localCandidate = expandHome(cfg.url);
	if(!isAbsolutePath(localCandidate))
	{
		string configRelative = buildNormalizedPath(dirName(configPath), localCandidate);
		if(exists(configRelative))
			localCandidate = configRelative;
		else
		{
			string packageRelative = buildNormalizedPath(packageDir, localCandidate);
			if(exists(packageRelative))
				localCandidate = packageRelative;
		}
	}

	bool localSource = exists(localCandidate) && isDir(localCandidate);
	string overrideSource = getEnvVar("CMAKE_PLUGIN_SRC");
	if(overrideSource.length)
	{
		overrideSource = expandHome(overrideSource);
		if(!isAbsolutePath(overrideSource))
			overrideSource = buildNormalizedPath(packageDir, overrideSource);
	}

	string srcDir;
	if(localSource)
		srcDir = asAbsolutePath(localCandidate);
	else if(overrideSource.length)
		srcDir = asAbsolutePath(overrideSource);
	else
		srcDir = buildNormalizedPath(cacheRoot, cacheName, "src");

	string destination = cfg.destination.length ? cfg.destination : "vendor";
	if(!isAbsolutePath(destination))
		destination = buildNormalizedPath(packageDir, destination);
	if(destination == packageDir)
		throw new Exception("cmake: 'destination' must be a subdirectory of the package");

	string markerPath = buildNormalizedPath(destination, markerName);
	bool force = cfg.force;
	string forceEnv = getEnvVar("CMAKE_PLUGIN_FORCE");
	if(forceEnv.length && forceEnv != "0")
		force = true;

	if(!force && exists(markerPath))
	{
		string previous = readText(markerPath);
		if(previous.startsWith(optionsKey))
			return status = RedubPluginStatus(RedubPluginExitCode.success,
				"cmake: '"~cfg.url~"' ready at '"~destination~"'");
	}

	if(!exists(srcDir) || !isDir(srcDir))
	{
		if(localSource || overrideSource.length)
			throw new Exception("cmake: source directory not found: '"~srcDir~"'");
		cloneGit(cfg.url, revision, srcDir, "cmake");
	}

	string sourceRoot = buildNormalizedPath(srcDir, cfg.sourceSubdir.length ? cfg.sourceSubdir : ".");
	if(!exists(sourceRoot) || !isDir(sourceRoot))
		throw new Exception("cmake: 'sourceSubdir' does not exist: '"~sourceRoot~"'");

	string buildDir = buildNormalizedPath(cacheRoot, cacheName, "build-"~optionsKey);
	string installDir = buildNormalizedPath(cacheRoot, cacheName, "install-"~optionsKey);

	import redub.logging : info;
	info("cmake: source ", sourceRoot, " | build ", buildDir, " | install ", installDir);

	if(force || !exists(installDir))
	{
		string installTmp = installDir~".tmp";
		removePath(installTmp);

		runCommand(["cmake", "-S", commandPath(sourceRoot), "-B", commandPath(buildDir)] ~ cfg.cmakeArgs, "cmake configure", "cmake");

		string[] buildArgs = ["cmake", "--build", commandPath(buildDir)];
		if(cfg.target.length)
			buildArgs ~= ["--target", cfg.target];
		buildArgs ~= (cfg.buildArgs.length ? cfg.buildArgs : ["--parallel"]);
		runCommand(buildArgs, "cmake build", "cmake");

		runCommand(["cmake", "--install", commandPath(buildDir), "--prefix", commandPath(installTmp)] ~ cfg.installArgs, "cmake install", "cmake");

		removePath(installDir);
		rename(installTmp, installDir);
	}

	string destinationTmp = destination~".tmp";
	removePath(destinationTmp);
	copyTree(installDir, destinationTmp);
	removePath(destination);
	rename(destinationTmp, destination);
	write(markerPath, optionsKey~"\n"~cfg.url~"\n"~revision~"\n");

	return status = RedubPluginStatus(RedubPluginExitCode.success,
		"cmake: built '"~cfg.url~"' into '"~destination~"'");
}

class CmakePlugin : RedubPlugin
{
	extern(C) ref RedubPluginStatus preGenerate(RedubPluginData input, out RedubPluginData output, const ref string[] args, ref return RedubPluginStatus status)
	{
		return status = RedubPluginStatus.success();
	}

	extern(C) ref RedubPluginStatus postGenerate(RedubPluginData input, out RedubPluginData output, const ref string[] args, ref return RedubPluginStatus status)
	{
		try
			return handle(input, output, args, status);
		catch(Exception e)
			return status = RedubPluginStatus(RedubPluginExitCode.error, e.msg);
	}


	void postBuild()
	{
	}
}
