module redub.libs.package_suppliers.dub_registry;
import redub.libs.package_suppliers.utils;
import redub.libs.semver;
import hipjson;
package enum PackagesPath = "packages";



/**
	Online registry based package supplier.

	This package supplier connects to an online registry (e.g.
	$(LINK https://code.dlang.org/)) to search for available packages.
*/
class RegistryPackageSupplier
{

	import std.uri : encodeComponent;
	import std.datetime : Clock, Duration, hours, SysTime, UTC;
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


	private ubyte[] fetchPackage(string packageName, SemVer requirement, out SemVer out_actualVersion, out string url)
	{
		url = getBestPackageDownloadUrl(packageName, requirement, out_actualVersion);
		if(!url)
			return null;
		return downloadFile(url);
	}

	/**
	 * Downloads the package to a specific folder and extract it.
	 * If no version actually matched existing versions, both out_actualVersionRequirement and url will be empty
	 *
	 * Params:
	 *   path = The path expected to extract the package to
	 *   packageName = Package name for assembling the link
	 *   requirement = Which is the requirement that it must attend
	 *   out_actualVersion = The version that matched the required
	 *   url = The URL that was built for downloading the package
	 * Returns: The path after the extraction
	 */
	string downloadPackageTo(return string path, string packageName, SemVer requirement, out SemVer out_actualVersion, out string url)
	{
		import std.zip;
		ubyte[] zipContent = fetchPackage(packageName, requirement, out_actualVersion, url);
		if(!extractZipToFolder(zipContent, path))
			throw new Exception("Error while trying to extract zip to path "~path);
		return path;
	}




	JSONValue getMetadata(string packageName)
	{
		import std.net.curl;
		static JSONValue[string] metadataCache;

		static string getMetadataUrl(string registryUrl, string packageName)
		{
			return  registryUrl ~ "api/packages/infos?packages="~
				encodeComponent(`["`~packageName~`"]`)~
				"&include_dependencies=true&minimize=true";
		}

		if(packageName in metadataCache)
			return metadataCache[packageName];
		string data = cast(string)downloadFile(getMetadataUrl(registryUrl, packageName));
		JSONValue parsed = parseJSON(data);
		foreach(k, v; parsed.object)
			metadataCache[k] = v;
		return metadataCache[packageName];
	}

}
unittest
{
	assert(new RegistryPackageSupplier().getPackageDownloadURL("redub", "1.16.0") == "https://code.dlang.org/packages/redub/1.16.0.zip");
	assert(new RegistryPackageSupplier().getBestPackageDownloadUrl("redub", SemVer("1.16.0")) == "https://code.dlang.org/packages/redub/1.16.0.zip");
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