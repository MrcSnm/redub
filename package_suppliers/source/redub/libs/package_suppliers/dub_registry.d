module redub.libs.package_suppliers.dub_registry;
import redub.libs.package_suppliers.utils;
import redub.libs.semver;
import core.sync.rwmutex;
import hip.data.json;
package enum PackagesPath = "packages";



/**
	Online registry based package supplier.

	This package supplier connects to an online registry (e.g.
	$(LINK https://code.dlang.org/)) to search for available packages.
*/
class RegistryPackageSupplier
{
	import std.uri : encodeComponent;
	string registryUrl;

 	this(string registryUrl = "https://code.dlang.org/")
	{
		this.registryUrl = registryUrl;
	}

	SemVer getBestVersion(string packageName, SemVer requirement)
	{
		JSONValue md = getMetadata(packageName);
		if (md.type == JSONType.null_)
			return requirement;
		SemVer ret;

		foreach (json; md["versions"].array)
		{
			SemVer cur = SemVer(json["version"].str);
			if(cur.satisfies(requirement) && cur >= ret)
				ret = cur;
		}
		return ret;
	}

	/**
	 * Used for diagnostics when the user typed a wrong version or inexistent packageName.
	 *
	 * Params:
	 *   packageName = The package to look for versions
	 * Returns: An array of versions found
	 */
	SemVer[] getExistingVersions(string packageName)
	{
		JSONValue md = getMetadata(packageName);
		if(md.type == JSONType.null_)
			return null;
		SemVer[] ret;

		foreach(json; md["versions"].array)
			ret~= SemVer(json["version"].str);
		return ret;
	}

	string getPackageDownloadURL(string packageName, string version_)
	{
		return registryUrl~"packages/"~packageName~"/"~version_~".zip";
	}

	string getBestPackageDownloadUrl(string packageName, SemVer requirement, out SemVer out_actualVersion)
	{
		JSONValue meta = getMetadata(packageName);
		if(meta.type == JSONType.null_)
			return null;
		out_actualVersion = getBestVersion(packageName, requirement);
		if(out_actualVersion == SemVer.init)
			return null;
		return getPackageDownloadURL(packageName, out_actualVersion.toString);
	}


	void loadPackagesMetadata(string[] packages)
	{
		import d_downloader;
		static string getMetadataUrl(string registryUrl, string[] packages)
		{
			import std.string:join;
			string packageName = packages.join(",");
			return  registryUrl ~ "api/packages/infos?packages="~
				encodeComponent(`["`~packageName~`"]`)~
				"&include_dependencies=true&minimize=true";
		}
		string data = cast(string)downloadToBuffer(getMetadataUrl(registryUrl, packages));
		JSONValue parsed = parseJSON(data, true);

		synchronized(metadataMutex.writer)
		{
			foreach(k, v; parsed.object)
			{
				if(!(k in metadataCache))
					metadataCache[k] = v;
			}
		}
	}

	JSONValue getMetadata(string packageName)
	{
		JSONValue* ret;
		synchronized(metadataMutex.reader)
		{
			ret = packageName in metadataCache;
		}
		if(ret)
			return *ret;
		string[1] thePkg = [packageName];
		string[] pkgs = thePkg;
		loadPackagesMetadata(pkgs);

		synchronized(metadataMutex.reader)
			ret = packageName in metadataCache;
		return *ret;
	}

}
unittest
{
	import d_downloader;
	import std.datetime.stopwatch;
	// assert(new RegistryPackageSupplier().getPackageDownloadURL("redub", "1.16.0") == "https://code.dlang.org/packages/redub/1.16.0.zip");
	// assert(new RegistryPackageSupplier().getBestPackageDownloadUrl("redub", SemVer("1.16.0")) == "https://code.dlang.org/packages/redub/1.16.0.zip");

	ubyte[] buffer;
	import hip.data.json;
	import std.stdio;

	StopWatch sw = StopWatch(AutoStart.yes);

	// parseJSON(cast(char[])downloadToBuffer(`https://code.dlang.org/api/packages/infos?packages=%5B%22redub%22%5D`));
	JSONValue json;
	JSONParseState state = JSONParseState.initialize(ushort.max);

	Duration timeSpentParsing;
	// char[] data = cast(char[])downloadToBuffer(`https://code.dlang.org/api/packages/dump`);
	import std.file;
	// char[] data = cast(char[])std.file.readText(`c:\Users\Marcelo\AppData\Local\dub\dump.json`);
	writeln("Time downloading: ", sw.peek.total!"msecs");
	sw = StopWatch(AutoStart.yes);
	// parseJSON(data);


	// // download(`https://code.dlang.org/api/packages/infos?packages=%5B%22redub%22%5D`, (size_t incomingBytes)
	download(`https://code.dlang.org/api/packages/dump`, (size_t incomingBytes, bool isIncomingContentLength)
	{
		if(incomingBytes > buffer.length)
			buffer.length = incomingBytes;
		return buffer[0..incomingBytes];
	}, (ubyte[] dataReceive)
	{
		StopWatch parse = StopWatch(AutoStart.yes);
		// JSONValue.parseStream(json, state, cast(char[])dataReceive);
		timeSpentParsing+= parse.peek;
	});

	writeln("JSON parsed in ", sw.peek, " time spent parsing: ", timeSpentParsing);
	// import core.memory;
	// writeln = GC.stats.usedSize;



}

//Speed test
unittest
{
	// import std.stdio;
	// import std.parallelism;
	// import std.datetime.stopwatch;

	// StopWatch sw = StopWatch(AutoStart.yes);
	// auto reg = new RegistryPackageSupplier();

	// string[] packages = ["bindbc-sdl", "bindbc-common", "bindbc-opengl", "redub"];
	// foreach(pkg; parallel(packages))
	// {
	// 	reg.downloadPackageTo("dub/packages/"~pkg, pkg, SemVer(">=0.0.0"));
	// }
	// writeln("Fetched packages ", packages, " in ", sw.peek.total!"msecs", "ms");
}

private __gshared JSONValue[string] metadataCache;
private __gshared ReadWriteMutex metadataMutex;

static this()
{
	metadataMutex = new ReadWriteMutex(ReadWriteMutex.Policy.PREFER_READERS);
}