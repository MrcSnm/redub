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
	import std.conv : to;
	import std.process : Config, ProcessException, execute;

	int status;
	string output;
	try
	{
		auto result = execute(command, null, Config.none, size_t.max);
		status = result.status;
		output = result.output;
	}
	catch(ProcessException e)
	{
		throw new Exception(pluginName~": failed to start '"~command[0]~"' for "~what~": "~e.msg);
	}

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
	command ~= [url, tmp];

	try
		runCommand(command, "git clone '"~url~"'", pluginName);
	catch(Exception e)
	{
		removePath(tmp);
		throw e;
	}

	removePath(checkout);
	rename(tmp, checkout);
}
