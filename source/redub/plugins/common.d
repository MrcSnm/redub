module redub.plugins.common;

import hip.data.json : JSONType, JSONValue, parseJSON;

///Reads the JSON config shared by the built-in fetch plugins.
struct ConfigReader
{
	private string pluginName;
	private JSONValue root;

	static ConfigReader fromFile(string path, string pluginName)
	{
		import std.file : exists, readText;

		if(!exists(path))
			throw new Exception(pluginName~": config file not found: '"~path~"'");
		auto parsed = parseJSON(readText(path));
		if(parsed.hasErrorOccurred)
			throw new Exception(pluginName~": "~parsed.error);
		if(parsed.type != JSONType.object)
			throw new Exception(pluginName~": config must be a JSON object");
		return ConfigReader(pluginName, parsed);
	}

	string getString(string key)
	{
		auto value = key in root;
		if(value is null)
			return null;
		if(value.type != JSONType.string_)
			throw new Exception(pluginName~": '"~key~"' must be a string");
		return value.str;
	}

	string[] getStringArray(string key)
	{
		auto value = key in root;
		if(value is null)
			return null;
		if(value.type != JSONType.array)
			throw new Exception(pluginName~": '"~key~"' must be an array of strings");

		string[] ret;
		foreach(item; value.array)
		{
			if(item.type != JSONType.string_)
				throw new Exception(pluginName~": '"~key~"' must contain only strings");
			ret ~= item.str;
		}
		return ret;
	}

	bool getBool(string key, bool defaultValue = false)
	{
		auto value = key in root;
		if(value is null)
			return defaultValue;
		if(value.type != JSONType.bool_)
			throw new Exception(pluginName~": '"~key~"' must be a boolean");
		return value.boolean;
	}
}

string getEnvVar(string name)
{
	import core.stdc.stdlib : getenv;
	import std.string : fromStringz;

	auto value = getenv((name ~ "\0").ptr);
	return value is null ? null : value.fromStringz.idup;
}

///Cross-platform cache root for built-in plugins. `~` is a no-op on Windows,
///so the default must not rely on it.
string defaultPluginCacheRoot(string pluginName)
{
	import redub.api : getDubWorkspacePath;
	import redub.misc.path : buildNormalizedPath;
	return asAbsolutePath(buildNormalizedPath(getDubWorkspacePath(), "redub-plugins", pluginName));
}

///std.path.expandTilde is a no-op on Windows, so expand HOME/USERPROFILE here.
string expandHome(string path)
{
	import std.path : expandTilde;
	if(path.length == 0 || path[0] != '~')
		return path;
	version(Windows)
	{
		import redub.misc.path : buildNormalizedPath;
		string home = getEnvVar("USERPROFILE");
		if(!home.length)
		{
			string drive = getEnvVar("HOMEDRIVE");
			string rest = getEnvVar("HOMEPATH");
			if(drive.length)
				home = drive ~ rest;
		}
		if(!home.length)
			return path;
		size_t start = 1;
		if(path.length > 1 && (path[1] == '/' || path[1] == '\\'))
			start = 2;
		return start < path.length ? buildNormalizedPath(home, path[start .. $]) : home;
	}
	else
		return expandTilde(path);
}

///Recognizes POSIX and Windows absolute paths on any host, so a Windows path
///is never prefixed with a POSIX cwd (and vice versa).
bool isAbsolutePath(string path)
{
	import std.path : isAbsolute;
	if(path.length == 0)
		return false;
	if(isAbsolute(path))
		return true;
	if(path.length >= 2 && path[1] == ':'
		&& ((path[0] >= 'a' && path[0] <= 'z') || (path[0] >= 'A' && path[0] <= 'Z')))
		return true;
	if(path.length >= 2 && path[0] == '\\' && path[1] == '\\')
		return true;
	return false;
}

string asAbsolutePath(string path, string baseDir = null)
{
	import redub.misc.path : buildNormalizedPath;
	import std.path : absolutePath;
	if(isAbsolutePath(path))
		return path;
	return baseDir.length ? buildNormalizedPath(baseDir, path) : absolutePath(path);
}

///Backslashes break POSIX-like tools (MSYS/Cygwin cmake/git) that receive a
///native Windows path. Same-volume paths are passed relative to the process
///cwd, which every toolchain resolves identically; otherwise use forward
///slashes, accepted by native Windows tools too.
string commandPath(string path)
{
	version(Windows)
	{
		import std.array : replace;
		import std.file : getcwd;
		import std.path : relativePath;
		if(!isAbsolutePath(path))
			return path.replace("\\", "/");
		return relativePath(path, getcwd()).replace("\\", "/");
	}
	else
		return path;
}

string gitRevision(string tag, string branch)
{
	return tag.length ? tag : branch;
}

string sanitizePathComponent(string input)
{
	import std.ascii : isAlphaNum;

	string ret;
	foreach(ch; input)
		ret ~= (isAlphaNum(ch) || ch == '.' || ch == '_' || ch == '-') ? ch : '-';
	return ret;
}

string repositoryName(string url)
{
	import std.algorithm.searching : endsWith;
	import std.path : baseName;

	string name = baseName(url);
	if(name.endsWith(".git"))
		name = name[0 .. $ - 4];
	return name;
}

string repositoryCacheName(string url, string tag, string branch, string directory = null)
{
	if(directory.length)
		return directory;
	string revision = gitRevision(tag, branch);
	return repositoryName(url)~(revision.length ? "-"~sanitizePathComponent(revision) : "");
}

void removePath(string path)
{
	import std.file : exists, isDir, remove, rmdirRecurse;

	if(!exists(path))
		return;
	if(isDir(path))
		rmdirRecurse(path);
	else
		remove(path);
}

string runCommand(string[] command, string what, string pluginName)
{
	import redub.logging : info, vlog, flush;
	import std.array : appender;
	import std.conv : to;
	import std.process : Config, ProcessException, Redirect, pipeProcess, wait;
	import std.stdio : stdout;

	info(pluginName, ": ", what, "...");
	vlog(pluginName, ": ", command);
	flush();

	auto collected = appender!(ubyte[])();
	int status;
	try
	{
		auto pipes = pipeProcess(command, Redirect.stdout | Redirect.stderrToStdout, null, Config.none);
		foreach(ubyte[] chunk; pipes.stdout.byChunk(4096))
		{
			stdout.rawWrite(chunk);
			collected.put(chunk);
		}
		stdout.flush();
		status = wait(pipes.pid);
	}
	catch(ProcessException e)
	{
		throw new Exception(pluginName~": failed to start '"~command[0]~"' for "~what~": "~e.msg);
	}

	string output = cast(string) collected.data;
	if(status != 0)
		throw new Exception(pluginName~": "~what~" failed with exit code "~status.to!string~":\n"~output);
	return output;
}

void cloneGit(string url, string revision, string checkout, string pluginName)
{
	import std.file : mkdirRecurse, rename;
	import std.path : dirName;

	string tmp = checkout~".tmp";
	removePath(tmp);
	mkdirRecurse(dirName(checkout));

	string[] command = ["git", "clone", "--depth", "1"];
	if(revision.length)
		command ~= ["--branch", revision];
	command ~= [commandPath(url), commandPath(tmp)];

	try
		runCommand(command, "git clone '"~url~"' into '"~checkout~"'", pluginName);
	catch(Exception e)
	{
		removePath(tmp);
		throw e;
	}

	removePath(checkout);
	rename(tmp, checkout);
}
