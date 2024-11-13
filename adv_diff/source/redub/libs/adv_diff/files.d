/**
 * This module aims to provide a smart and optimized way to check cache and up to date checks.
 * It uses file times for initial comparison and if it fails, content hash is checked instead.
 * Beyond that, it also provides a cache composition formula.
 */
module redub.libs.adv_diff.files;
public import hipjson;
import std.exception;

struct AdvFile
{
	///This will be used to compare before content hash
	ulong timeModified;
	ubyte[8] contentHash;

	AdvFile dup() const
	{
		return this;
		// ubyte[] returnHash;
		// if(contentHash.length) returnHash = contentHash.dup;
		// return AdvFile(timeModified, returnHash);
	}

	void serialize(ref JSONValue output) const
	{
		import std.digest:toHexString;
		output = JSONValue([JSONValue(timeModified), JSONValue(contentHash[].toHexString)]);
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
		return AdvFile(input.array[0].get!ulong, hashFromString(input.array[1].str));
	}
}

struct AdvDirectory
{
	ubyte[8] contentHash; //Since this structure is optimized for xxhash, it will use 8 bytes hash
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
		output[dirName] = JSONValue([JSONValue(toHexString(contentHash[])), dir]);
	}

	pragma(inline, true) package void putContentHashInPlace(const ubyte[8] newHash)
	{
		contentHash[] = newHash[];
	}

	/**
	 * Specification:
	 * [$CONTENT_HASH, {[FILENAME] : ADV_FILE_SPEC}]
	 * Params:
	 *   input =
	 * Returns:
	 */
	static AdvDirectory deserialize(JSONValue input)
	{
		enforce(input.type == JSONType.array, "AdvDirectory input must be an array.");
		JSONValue[] v = input.array;
		enforce(v.length == 2, "AdvDirectory must contain 2 members.");
		enforce(v[0].type == JSONType.string, "AdvDirectory index 0 must be a string");
		enforce(v[1].type.isObject, "AdvDirectory index 1 must be an object");
		AdvFile[string] files;

		if(!v[1].isNull) foreach(string fileName, JSONValue advFile; v[1].object)
		{
			files[fileName] = AdvFile.deserialize(advFile);
		}

		return AdvDirectory(hashFromString(v[0].str), files);
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
	ubyte[8] contentHash;
	AdvDirectory[string] directories;
	AdvFile[string] files;

	bool isEmptyFormula() const { return contentHash == ubyte[8].init; }



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
		enforce(v.length == 3, "AdvCacheFormula must contain a tuple of 3 values");
		enforce(v[0].type == JSONType.string, "AdvCacheFormula at index 0 must contain a string. got types ["~v[0].type.to!string);
		enforce(v[1].type.isObject && v[2].type.isObject, "AdvCacheFormula must contain objects on index 1 and 2, got types ["~v[1].type.to!string~", "~v[2].type.to!string~"]");

		AdvDirectory[string] dirs;
		if(!v[1].isNull) foreach(string fileName, JSONValue advDir; v[1].object)
			dirs[fileName] = AdvDirectory.deserialize(advDir);

		AdvFile[string] files;
		if(!v[2].isNull) foreach(string fileName, JSONValue advFile; v[2].object)
			files[fileName] = AdvFile.deserialize(advFile);


		return AdvCacheFormula(hashFromString(v[0].str), dirs, files);
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
		import std.digest;
		output = JSONValue([JSONValue(toHexString(contentHash[])), dirsJson, filesJson]);
	}

	/**
	 *
	 * Params:
	 *   url = The path of the file to hash
	 *   buffer = A generic buffer to hold file name + file content data
	 *   outputHash = Where the output will be sent
	 *   contentHasher = The hash function
	 *	 isSimplified = Hashes using file name + size + last modified time
	 * Returns: If it could hash the file or not
	 */
	private static bool hashContent(string url, ref ubyte[] buffer, ref ubyte[] outputHash, ubyte[] function(ubyte[], ref ubyte[] output) contentHasher, bool isSimplified)
	{
		import std.file;
		import std.array;
		import std.stdio;
		try
		{
			if(!isSimplified)
			{
				File f = File(url);
				size_t fSize = f.size;
				size_t bufferSize = fSize+url.length;
				if(bufferSize > buffer.length)
				{
					import core.memory;
					GC.free(buffer.ptr);
					buffer = uninitializedArray!(ubyte[])(bufferSize);
				}
				f.rawRead(buffer[0..fSize]);
				buffer[fSize..bufferSize] = cast(ubyte[])url[];
				contentHasher(buffer[0..bufferSize], outputHash);
			}
			else
			{
				DirEntry e = DirEntry(url);
				long timeMod = e.timeLastModified.stdTime;
				ulong size = e.size;

				contentHasher(
					joinFlattened(
						cast(ubyte[])url,
						(cast(ubyte*)&timeMod)[0..8],
						(cast(ubyte*)&size)[0..8],
					),
					outputHash
				);
			}
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
	 *   isSimplified = Optional. Generates a hash from the file name + size + lastTimeModified. This is useful when running for less relevant files that are also very big. Used for copy cache formula
	 * Returns: A completely new AdvCacheFormula which may reference or not the cacheHolder fields.
	 */
	static AdvCacheFormula make(DirRange, FileRange)(
		ubyte[] function(ubyte[], ref ubyte[] output) contentHasher,
		DirRange filteredDirectories,
		FileRange files,
		const(AdvCacheFormula)* existing = null,
		AdvCacheFormula* cacheHolder = null,
		bool isSimplified = false
	)
	{
		import std.file;
		import std.array;
		import std.stdio;
		import redub.command_generators.commons;
		AdvCacheFormula ret;
		static ubyte[] fileBuffer;
		if(fileBuffer.length == 0)
			fileBuffer = uninitializedArray!(ubyte[])(1_000_000);
		ubyte[] hashedContent;


		foreach(filterDir; filteredDirectories) foreach(dir; filterDir.dirs)
		{
			if(cacheHolder !is null && dir in cacheHolder.directories)
			{
				ret.directories[dir] = cacheHolder.directories[dir];
				continue;
			}
			AdvDirectory advDir;
			const(AdvDirectory)* existingDir;
			if(existing) existingDir = dir in existing.directories;

			if(!std.file.exists(dir) ||isFileHidden(DirEntry(dir))) continue;
			enforce(std.file.isDir(dir), "Path sent is not a directory: "~dir);

			foreach(DirEntry e; dirEntries(dir, SpanMode.depth))
            {
				if(e.isDir || !filterDir.shouldInclude(e.name) || isFileHidden(e)) continue;

				long time = e.timeLastModified.stdTime;
				if(existingDir)
				{
					const(AdvFile)* existingFile = e.name in existingDir.files;
					if(existingFile)
					{
						if(existingFile.timeModified == time)
						{
							advDir.files[e.name] = existingFile.dup;
							advDir.putContentHashInPlace(contentHasher(joinFlattened(advDir.contentHash, existingFile.contentHash), hashedContent)[0..8]);
							continue;
						}
					}
				}
				if(!hashContent(e.name, fileBuffer, hashedContent, contentHasher, isSimplified)) continue;
				advDir.files[e.name] = AdvFile(time, hashedContent[0..8]);
				advDir.putContentHashInPlace(contentHasher(joinFlattened(advDir.contentHash, hashedContent), hashedContent)[0..8]);
            }
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
				continue;
			}
			///May throw if it is a directory.
			scope(failure) continue;
			long time = std.file.timeLastModified(file).stdTime;

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
			if(!hashContent(file, fileBuffer, hashedContent, contentHasher, isSimplified)) continue;
			ret.files[file] = AdvFile(time, hashedContent[0..8]);
			if(cacheHolder !is null)
				cacheHolder.files[file] = ret.files[file];
        }

		if(hashedContent.length)
		{
			hashedContent[] = 0;
			foreach(AdvDirectory dir; ret.directories)
				hashedContent = contentHasher(joinFlattened(dir.contentHash, hashedContent), hashedContent)[0..8];
			foreach(AdvFile file; ret.files)
				hashedContent = contentHasher(joinFlattened(file.contentHash, hashedContent), hashedContent)[0..8];
			ret.contentHash = hashedContent[0..8];
		}

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
		if(other.contentHash == contentHash) return true;

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


pragma(inline, true)
private ubyte getNumFromHexChar(char a)
{
	if(a >= '0' && a <= '9')
		return cast(ubyte)(a - '0');
	return cast(ubyte)((a - 'A') + 10);
}


ubyte[8] hashFromString(const string hexStr)
{
	if(hexStr.length != 16)
	{
		char[16] ret = void;
		ret[0] = '0';
		ret[1..$] = hexStr[];
		return fromHexString2(ret);
	}
	return fromHexString2(cast(char[16])hexStr[0..16]);

}

ubyte[8] fromHexString2(const ref char[16] hexStr)
{
	ubyte[8] ret;
	foreach(i; 0..8)
		ret[i] = cast(ubyte)((getNumFromHexChar(hexStr[i*2])*16) + getNumFromHexChar(hexStr[i*2+1]));
	return ret;
}


ubyte[] fromHexString2(string hexStr)
{
	size_t sz = hexStr.length/2;
	ubyte[] ret;

	foreach(i; 0..sz)
		ret[i] = cast(ubyte)((getNumFromHexChar(hexStr[i*2])*16) + getNumFromHexChar(hexStr[i*2+1]));
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