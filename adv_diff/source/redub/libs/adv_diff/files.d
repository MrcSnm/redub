/**
 * This module aims to provide a smart and optimized way to check cache and up to date checks.
 * It uses file times for initial comparison and if it fails, content hash is checked instead.
 * Beyond that, it also provides a cache composition formula.
 */
module redub.libs.adv_diff.files;
public import std.int128;
public import hipjson;
// public import std.json;

import std.exception;

struct AdvFile
{
	///This will be used to compare before content hash
	ulong timeModified;
	ubyte[] contentHash;

	AdvFile dup() const
	{
		ubyte[] returnHash;
		if(contentHash.length) returnHash = contentHash.dup;
		return AdvFile(timeModified, returnHash);
	}

	void serialize(ref JSONValue output) const
	{
		import std.digest:toHexString;
		output = JSONValue([JSONValue(timeModified), JSONValue(contentHash.toHexString)]);
	}
	/**
	 * Specification:
	 * [TIME_LONG, CONTENT_HASH]
	 * Params:
	 *   input =
	 * Returns:
	 */
	static AdvFile deserialize(JSONValue input)
	{
		enforce(input.type == JSONType.array, "Input json for AdvFile deserialization is not an array.");
		enforce(input.array.length == 2, "Input json for AdvFile deserialization is an array with size different from 2.");
		return AdvFile(input.array[0].get!ulong, fromHexString(input.array[1].str));
	}
}

struct AdvDirectory
{
	Int128 total;
	ubyte[] contentHash;
	AdvFile[string] files;

	void serialize(ref JSONValue output, string dirName) const
	{
		JSONValue dir = JSONValue.emptyObject;
		foreach(fileName, advFile; files)
		{
			JSONValue v;
			advFile.serialize(v);
			dir[fileName] = v;
		}
		import std.digest;
		output[dirName] = JSONValue([JSONValue(total.data.hi), JSONValue(total.data.lo), JSONValue(toHexString(contentHash)), dir]);
	}

	pragma(inline, true) package void putContentHashInPlace(const ubyte[] newHash)
	{
		if(newHash.length != contentHash.length)
			contentHash = newHash.dup;
		else
			contentHash[] = newHash[];
	}

	/**
	 * Specification:
	 * [$INT128_HI, $INT128_LOW, $CONTENT_HASH, {[FILENAME] : ADV_FILE_SPEC}]
	 * Params:
	 *   input =
	 * Returns:
	 */
	static AdvDirectory deserialize(JSONValue input)
	{
		enforce(input.type == JSONType.array, "AdvDirectory input must be an array.");
		JSONValue[] v = input.array;
		enforce(v.length == 4, "AdvDirectory must contain 4 members.");
		enforce(v[0].type.isInteger && v[1].type.isInteger, "Input of AdvDirectory must be first 2 integers.");
		enforce(v[2].type == JSONType.string, "AdvDirectory index 2 must be a string");
		enforce(v[3].type.isObject, "AdvDirectory index 3 must be an object");
		AdvFile[string] files;

		if(!v[3].isNull) foreach(string fileName, JSONValue advFile; v[3].object)
		{
			files[fileName] = AdvFile.deserialize(advFile);
		}

		return AdvDirectory(Int128(v[0].get!ulong, v[1].get!ulong), fromHexString(v[2].str), files);
	}
}

struct DirectoriesWithFilter
{
	const string[] dirs;
	///Ends with filter, usually .d and .di. Since they are both starting with .d, function will use an optimized way to check
	bool usesDFilters;

	pragma(inline, true) bool shouldInclude(string target)
	{
		import std.path;
		if(usesDFilters)
		{
			string ext = target.extension;
			if(ext.length == 0 || ext.length > 3) return false;
			if(ext[1] == 'd') {
				return ext.length == 2 ||
					(ext.length == 3 && ext[2] == 'i');
			}
			return false;
		}
		return true;
	}
}



struct AdvCacheFormula
{
	Int128 total;
	AdvDirectory[string] directories;
	AdvFile[string] files;

	bool isEmptyFormula() const { return total == Int128(0, 0); }



	/**
	* JSON specification:
	* [$ADV_TOTAL_HI, $ADV_TOTAL_LO, {DIRS}, {FILES}]
	*
	* Returns: AdvCacheFormula
	*/
	static AdvCacheFormula deserialize(JSONValue input)
	{
		import std.conv:to;
		enforce(input.type == JSONType.array, "AdvCacheFormula input must be an array");
		JSONValue[] v = input.array;
		enforce(v.length == 4, "AdvCacheFormula must contain a tuple of 4 values");
		enforce(v[0].type.isInteger && v[1].type.isInteger, "AdvCacheFormula must contain 2 integers on its start, got types ["~v[0].type.to!string~", "~v[1].type.to!string~"]");
		enforce(v[2].type.isObject && v[3].type.isObject, "AdvCacheFormula must contain objects on index 2 and 3, got types ["~v[2].type.to!string~", "~v[3].type.to!string~"]");

		AdvDirectory[string] dirs;
		if(!v[2].isNull) foreach(string fileName, JSONValue advDir; v[2].object)
			dirs[fileName] = AdvDirectory.deserialize(advDir);

		AdvFile[string] files;
		if(!v[3].isNull) foreach(string fileName, JSONValue advFile; v[3].object)
			files[fileName] = AdvFile.deserialize(advFile);

		return AdvCacheFormula(Int128(v[0].get!ulong, v[1].get!ulong), dirs, files);
	}

	void serialize(ref JSONValue output) const
	{
		JSONValue dirsJson = JSONValue.emptyObject;
		foreach(string dirName, const AdvDirectory advDir; directories)
			advDir.serialize(dirsJson, dirName);

		JSONValue filesJson = JSONValue.emptyObject;
		foreach(string fileName, const AdvFile advFile; files)
		{
			JSONValue v;
			advFile.serialize(v);
			filesJson[fileName] = v;
		}
		output = JSONValue([JSONValue(total.data.hi), JSONValue(total.data.lo), dirsJson, filesJson]);
	}

	private static bool hashContent(string url, ref ubyte[] buffer, ref ubyte[] outputHash, ubyte[] function(ubyte[], ref ubyte[] output) contentHasher)
	{
		import std.file;
		import std.array;
		import std.stdio;
		try
		{
			size_t fSize;
			File f = File(url);
			//Does not exists
			if(!f.isOpen)
			{
				outputHash = null;
				return false;
			}
			fSize = f.size;
			if(fSize > buffer.length)
			{
				import core.memory;
				GC.free(buffer.ptr);
				buffer = uninitializedArray!(ubyte[])(fSize);
			}
			f.rawRead(buffer[0..fSize]);
			contentHasher(buffer[0..fSize], outputHash);
		}
		catch(Exception e) return false;
		return true;
	}

	/**
	 * It won't include hidden files in the formula
	 * Params:
	 *   contentHasher = Optional. If this input is given, it will read each file content and hash them
	 *   directories = Which directories it should put on this formula
	 *   files = Which files it should put on this formula
	 *	 existing = Optional. If this is given and exists, it will compare dates and if they have a difference, a content hash will be generated.
	 *   cacheHolder = Optional. If this is given, instead of looking into file system, it will use this cache holder instead. If no input is found on this cache holder, it will be populated with the new content.
	 * Returns: A completely new AdvCacheFormula which may reference or not the cacheHolder fields.
	 */
	static AdvCacheFormula make(DirRange, FileRange)(
		ubyte[] function(ubyte[], ref ubyte[] output) contentHasher,
		DirRange filteredDirectories,
		FileRange files,
		const(AdvCacheFormula)* existing = null,
		AdvCacheFormula* cacheHolder = null
	)
	{
		import std.file;
		import std.array;
		import std.stdio;
		import redub.command_generators.commons;
		AdvCacheFormula ret;
		Int128 totalTime;
		static ubyte[] fileBuffer;
		if(fileBuffer.length == 0)
			fileBuffer = uninitializedArray!(ubyte[])(1_000_000);
		ubyte[] hashedContent;


		foreach(filterDir; filteredDirectories)
		foreach(dir; filterDir.dirs)
		{
			if(cacheHolder !is null && dir in cacheHolder.directories)
			{
				ret.directories[dir] = cacheHolder.directories[dir];
				totalTime+= cacheHolder.directories[dir].total;
				continue;
			}
            Int128 dirTime;
			AdvDirectory advDir;
			const(AdvDirectory)* existingDir;
			if(existing) existingDir = dir in existing.directories;

			if(!std.file.exists(dir) ||isFileHidden(DirEntry(dir))) continue;
			enforce(std.file.isDir(dir), "Path sent is not a directory: "~dir);

			foreach(DirEntry e; dirEntries(dir, SpanMode.depth))
            {
				if(e.isDir || !filterDir.shouldInclude(e.name) || isFileHidden(e)) continue;

				long time = e.timeLastModified.stdTime;
                dirTime+= time;
				if(existingDir)
				{
					const(AdvFile)* existingFile = e.name in existingDir.files;
					if(existingFile)
					{
						if(existingFile.timeModified == time)
						{
							advDir.files[e.name] = existingFile.dup;
							advDir.putContentHashInPlace(contentHasher(joinFlattened(advDir.contentHash, existingFile.contentHash), hashedContent));
							continue;
						}
					}
				}
				if(!hashContent(e.name, fileBuffer, hashedContent, contentHasher)) continue;
				advDir.files[e.name] = AdvFile(time, hashedContent.dup);
				advDir.putContentHashInPlace(contentHasher(joinFlattened(advDir.contentHash, hashedContent), hashedContent));
            }
			totalTime+= advDir.total = dirTime;
			ret.directories[dir] = advDir;
			if(cacheHolder !is null)
				cacheHolder.directories[dir] = advDir;
		}
		foreach(file; files)
        {
			//Check if the file was read already for taking the time it was modified.
			if(cacheHolder !is null && file in cacheHolder.files)
			{
				ret.files[file] = cacheHolder.files[file];
				totalTime+= cacheHolder.files[file].timeModified;
				continue;
			}
			///May throw if it is a directory.
			scope(failure) continue;
			long time = std.file.timeLastModified(file).stdTime;
            totalTime+= time;

			if(existing)
			{
				const(AdvFile)* existingFile = file in existing.files;
				if(existingFile && existingFile.timeModified == time)
				{
					ret.files[file] = existingFile.dup;
					if(cacheHolder !is null)
						cacheHolder.files[file] = ret.files[file];
					continue;
				}
			}
			if(!hashContent(file, fileBuffer, hashedContent, contentHasher)) continue;
			ret.files[file] = AdvFile(time, hashedContent.dup);
			if(cacheHolder !is null)
				cacheHolder.files[file] = ret.files[file];
        }
		ret.total = totalTime;
		return ret;
	}

	/**
	 * Use this version when you want to store a significant amount of diffs while not allocating
	 * any memory.
	 * Params:
	 *   other = The other to compare
	 *   diffCount = How many actual differences exists.
	 * Returns: The buffer storing up to 64 diffs
	 */
	string[64] diffStatus(const ref AdvCacheFormula other, out size_t diffCount) const @nogc
	{
		string[64] ret;
		string[] outputSink = ret;
		diffStatus(other, outputSink, diffCount);
		return ret;
	}

	/**
	 * Since this function does not allocate memory, do not send an empty diff array if you wish to save how many
	 * diffs there are.
	 * Params:
	 *   other = The other cache formula to compare.
	 *   diffs = A variable to store the diffs. It's length is never increased, since this function is nogc
	 *   diffCount = How many diffs are there, you can do a double pass on this function to store every diff
	 * Returns: true if they're the same
	 */
	bool diffStatus(const ref AdvCacheFormula other, ref string[] diffs, out size_t diffCount) const @nogc
	{
		if(other.total == total) return true;

		static size_t diffFiles(
			const ref AdvFile[string] filesOther,
			const ref AdvFile[string] files,
			ref string[] diffs, size_t diffCount) @nogc
		{
			foreach(fileName, otherAdv; filesOther)
			{
				const(AdvFile)* advFile = fileName in files;
				if(advFile is null ||  (otherAdv.timeModified != advFile.timeModified &&
				otherAdv.contentHash != advFile.contentHash))
				{
					if(diffCount + 1 < diffs.length)
						diffs[diffCount++] = fileName;
				}
			}
			ptrdiff_t plainDiff = cast(ptrdiff_t)filesOther.length - cast(ptrdiff_t)files.length;
			if(plainDiff < 0)
			{
				foreach(fileName, currAdv; files)
					if(diffCount + 1 < diffs.length && !(fileName in filesOther))
						diffs[diffCount++] = fileName;
			}
			return diffCount;
		}

		diffCount = diffFiles(other.files, files, diffs, diffCount);
		foreach(dirName, otherAdvDir; other.directories)
		{
			const(AdvDirectory)* advDir = dirName in directories;
			if(advDir is null)
			{
				if(diffCount + 1 < diffs.length)
					diffs[diffCount++] = dirName;
			}
			else
			{
				if(otherAdvDir.contentHash != advDir.contentHash)
				{
					//If directory total is different, check per file
					diffCount = diffFiles(otherAdvDir.files, advDir.files, diffs, diffCount);
				}
			}
		}
		return diffCount == 0;
	}
}

ubyte[] fromHexString(string hexStr)
{
	import std.conv : parse;
	size_t sz = hexStr.length/2;
	size_t index = 0;
	ubyte[] ret;
	if(hexStr.length % 2 != 0)
	{
		ret = new ubyte[](sz + 1);
		string str = hexStr[0..1];
		ret[0] = str.parse!ubyte(16);
		hexStr = hexStr[1..$];
		index = 1;
	} else ret = new ubyte[](sz);
	foreach(i; 0..hexStr.length/2)
	{
		string str = hexStr[i*2..(i+1)*2];
		ret[index++] = str.parse!ubyte(16);
	}
	return ret;
}

T[] joinFlattened(T)(scope const T[][] args...)
{
	size_t length;
	foreach(a; args) length+= a.length;
	T[] ret = new T[](length);
	length = 0;
	foreach(a; args) ret[length..length+=a.length] = a[];
	return ret;
}

unittest
{
	static ubyte[] hasher(ubyte[] content, ref ubyte[] output)
	{
		import std.digest.md;
		return cast(ubyte[])toHexString(md5Of(content)).dup;
	};
	AdvCacheFormula formula = AdvCacheFormula.make(&hasher, [DirectoriesWithFilter(["source"], true)], string[].init);
	AdvCacheFormula formula2 = AdvCacheFormula.make(&hasher, [DirectoriesWithFilter(["source", "source/redub"], true)], string[].init);

	import std.stdio;
	size_t diffCount;
	writeln(formula.diffStatus(formula2, diffCount)[0..diffCount]);

	JSONValue v = JSONValue.emptyObject;
	formula.serialize(v);

	writeln(v.toString());
}

private bool isInteger(JSONType type){return type == JSONType.integer || type == JSONType.uinteger;}
private bool isObject(JSONType type){return type == JSONType.object || type == JSONType.null_;}