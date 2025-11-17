/**
 * This module aims to provide a smart and optimized way to check cache and up to date checks.
 * It uses file times for initial comparison and if it fails, content hash is checked instead.
 * Beyond that, it also provides a cache composition formula.
 */
module redub.libs.adv_diff.files;
public import hip.data.json;
import std.exception;
import std.file;

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

enum DirectoryFilterType : ubyte
{
	none,
	d,
	c,
	cpp,
}

bool shouldIncludeByExt(DirectoryFilterType filter, string target)
{
	import std.path;
	string ext = target.extension;
	final switch(filter)
	{
		case DirectoryFilterType.c:
			return ext == ".c" || ext == ".i" || ext == ".h";
		case DirectoryFilterType.cpp:
			return ext == ".c" || ext == ".i" || ext == ".h" || ext == ".cpp" || ext == ".cc" || ext == ".cxx" || ext == ".c++" || ext == ".hpp";
		case DirectoryFilterType.d:
			if(ext.length == 0 || ext.length > 3) return false;
			if(ext[1] == 'd') {
				return ext.length == 2 ||
					(ext.length == 3 && ext[2] == 'i');
			}
			return false;
		case DirectoryFilterType.none: return true;
	}
}

struct DirectoriesWithFilter
{
	const string[] dirs;
	///Ends with filter, usually .d and .di. Since they are both starting with .d, function will use an optimized way to check
	DirectoryFilterType filterType;

	const string[] ignoreFiles;

	///Uses the simplified hashing whenever inside that dir. May be used on directories with bigger files
	bool useSimplifiedHashing;

	pragma(inline, true) bool shouldInclude(string target)
	{
		import redub.libs.adv_diff.helpers.index_of;
		return filterType.shouldIncludeByExt(target) && indexOf(ignoreFiles, target) == -1;
	}
}



struct AdvCacheFormula
{
	ubyte[8] contentHash;
	AdvDirectory[string] directories;
	AdvFile[string] files;

	bool isEmptyFormula() const { return directories.length == 0 && files.length == 0;}



	/**
	* JSON specification:
	* ["$CONTENT_HASH", {DIRS}, {FILES}]
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

	static AdvCacheFormula deserializeSimple(JSONValue input, AdvCacheFormula reference)
	{
		enforce(input.type == JSONType.array, "AdvCacheFormula input must be an array");
		JSONValue[] v = input.array;
		enforce(v.length == 3, "AdvCacheFormula must contain a tuple of 3 values");
		enforce(v[0].type == JSONType.string, "AdvCacheFormula at index 0 must contain a string. got types ["~v[0].getTypeName);
		enforce(v[1].type == JSONType.array && v[2].type == JSONType.array, "AdvCacheFormula simple must contain arrays on index 1 and 2, got types ["~v[1].getTypeName~", "~v[2].getTypeName~"]");

		AdvDirectory[string] dirs;
		foreach(JSONValue advDir; v[1].array)
		{
			AdvDirectory* d = advDir.str in reference.directories;
			if(!d)
				enforce(false, "Could not find directory '"~advDir.str~"' inside formula reference.");
			dirs[advDir.str] = *d;
		}

		AdvFile[string] files;
		foreach(JSONValue advFile; v[2].array)
		{
			AdvFile* f = advFile.str in reference.files;
			if(!f)
				enforce(false, "Could not find file '"~advFile.str~"' inside formula reference.");
			files[advFile.str] = *f;
		}


		return AdvCacheFormula(hashFromString(v[0].str), dirs, files);
	}

	/**
	 * Dumps the entire content of this AdvCacheFormula
	 * Params:
	 *   output = Target where to serialize this cache formula
	 */
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
	 * Dumps only the file names and dir names inside the json. This is useful whenever having a shared AdvCacheFormula
	 * Params:
	 *   output =
	 */
	void serializeSimple(ref JSONValue output) const
	{
		JSONValue dirsJson = JSONValue.emptyArray;
		foreach(string dirName, const AdvDirectory advDir; directories)
			dirsJson.jsonArray~= dirName;
		JSONValue filesJson = JSONValue.emptyArray;
		foreach(string fileName, const AdvFile advFile; files)
			filesJson.jsonArray~= fileName;
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
	private static bool hashContent(string url, ref ubyte[] buffer, ref ubyte[8] outputHash, ubyte[] function(ubyte[], ref ubyte[8] output) contentHasher, bool isSimplified)
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
					buffer.length = bufferSize;
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
	 *	 existing = Optional. If this is given and exists, it will use the same hash inside it if the dates are the same.
	 *   cacheHolder = Optional. If this is given, instead of looking into file system, it will use this cache holder instead. If no input is found on this cache holder, it will be populated with the new content.
	 *   isSimplified = Optional. Generates a hash from the file name + size + lastTimeModified. This is useful when running for less relevant files that are also very big. Used for copy cache formula
	 * Returns: A completely new AdvCacheFormula which may reference or not the cacheHolder fields.
	 */
	static AdvCacheFormula make(DirRange, FileRange)(
		ubyte[] function(ubyte[], ref ubyte[8] output) contentHasher,
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
		ubyte[8] hashedContent;
		ubyte[16] joinedHash;



		foreach(filterDir; filteredDirectories) foreach(dir; filterDir.dirs)
		{
			if(cacheHolder !is null)
			{
				AdvDirectory* cacheDir = dir in cacheHolder.directories;
				if(cacheDir !is null)
				{
					ret.directories[dir] = *cacheDir;
					continue;
				}
			}
			AdvDirectory advDir;
			const(AdvDirectory)* existingDir;
			if(existing) existingDir = dir in existing.directories;

			if(!existingDir)
			{
				bool dirExists;
				uint attr = getAttributesNothrow(dir, dirExists);
				if(!dirExists || .isFileHidden(dir, attr))
					continue;
				enforce(.isDir(attr), "Path sent is not a directory: "~dir);
			}

			foreach(DirEntry e; dirEntries(dir, SpanMode.depth))
            {
				if(e.isDir || redub.command_generators.commons.isFileHidden(e) || !filterDir.shouldInclude(e.name)) continue;
				///Move 1 since the last after length is a slash separator.
				string fName = e.name[dir.length+1..$];
				long time = e.timeLastModified.stdTime;
				if(existingDir)
				{
					const(AdvFile)* existingFile = fName in existingDir.files;
					if(existingFile)
					{
						if(existingFile.timeModified == time)
						{
							advDir.files[fName] = existingFile.dup;
							joinedHash[0..8] = advDir.contentHash;
							joinedHash[8..$] = existingFile.contentHash;
							advDir.putContentHashInPlace(contentHasher(joinedHash, hashedContent)[0..8]);
							continue;
						}
					}
				}
				if(!hashContent(e.name, fileBuffer, hashedContent, contentHasher, isSimplified || filterDir.useSimplifiedHashing)) continue;
				advDir.files[fName] = AdvFile(time, hashedContent[0..8]);
				joinedHash[0..8] = advDir.contentHash;
				joinedHash[8..$] = hashedContent;
				advDir.putContentHashInPlace(contentHasher(joinedHash, hashedContent)[0..8]);
            }
			ret.directories[dir] = advDir;
			if(cacheHolder !is null)
				cacheHolder.directories[dir] = advDir;
		}

		foreach(file; files)
        {
			//Check if the file was read already for taking the time it was modified.
			if(cacheHolder !is null)
			{
				AdvFile* fileInCache = file in cacheHolder.files;
				if(fileInCache)
				{
					ret.files[file] = *fileInCache;
					continue;
				}
			}
			///May throw if it is a directory.
			scope(failure) continue;

			DirEntry e = DirEntry(file);
			long time = e.timeLastModified.stdTime;

			if(existing)
			{
				const(AdvFile)* existingFile = file in existing.files;
				if(existingFile && existingFile.timeModified == time)
				{
					ret.files[file] = existingFile.dup;
					hashedContent = existingFile.contentHash;
					if(cacheHolder !is null)
						cacheHolder.files[file] = *existingFile;
					continue;
				}
			}

			if(!hashContent(file, fileBuffer, hashedContent, contentHasher, isSimplified || inferSimplifiedFile(e))) continue;
			AdvFile f = AdvFile(time, hashedContent[0..8]);
			ret.files[file] = f;
			if(cacheHolder !is null)
				cacheHolder.files[file] = f;
        }
		ret.recalculateHash(contentHasher);

		return ret;
	}

	ubyte[8] recalculateHash(ubyte[] function(ubyte[], ref ubyte[8] output) contentHasher)
	{
		ubyte[16] advCacheHashJoin;
		ubyte[8]  advCacheHash;

		foreach(AdvDirectory dir; directories)
		{
			advCacheHashJoin[0..8] = dir.contentHash;
			advCacheHashJoin[8..$] = advCacheHash;
			advCacheHash = contentHasher(advCacheHashJoin, advCacheHash)[0..8];
		}
		foreach(AdvFile f; files)
		{
			advCacheHashJoin[0..8] = f.contentHash;
			advCacheHashJoin[8..$] = advCacheHash;
			advCacheHash = contentHasher(advCacheHashJoin, advCacheHash)[0..8];
		}

		this.contentHash = advCacheHash[0..8];
		return contentHash;
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
				{
					diffs[diffCount++] = dirName;
				}
			}
			else
			{
				if(otherAdvDir.contentHash != advDir.contentHash)
				{
					//If directory total is different, check per file
					diffCount+= diffFiles(otherAdvDir.files, advDir.files, diffs, diffCount);
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

bool inferSimplifiedFile(DirEntry e)
{
	return e.size > 2_048_000;
}

T[] joinFlattened(T)(scope const T[][] args...)
{
	size_t length;
	import std.array;
	foreach(a; args) length+= a.length;
	T[] ret = uninitializedArray!(T[])(length);
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


uint getAttributesNothrow(string name, out bool exists) nothrow
{
	import std.internal.cstring;
	version(Windows)
	{
		import core.sys.windows.winbase;
		const wchar* fileName = name.tempCString!wchar();
		auto ret = GetFileAttributesW(fileName);
		exists = ret != 0xFFFFFFFF;
		return ret;
	}
	else version(Posix)
	{
		import core.sys.posix.sys.stat;
		const char* fileName = name.tempCString!char();
		stat_t statbuf = void;
		exists = stat(fileName, &statbuf) == 0;
		return statbuf.st_mode;
	}
	else assert(false, "No getAttributes support on that OS");
}


bool isDir(uint attr)
{
	version(Windows)
	{
		import core.sys.windows.winnt;
		return (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
	}
	else version(Posix)
	{
		import core.sys.posix.sys.stat;
		return (attr & S_IFMT) == S_IFDIR;
	}
}

bool isFileHidden(string name, uint attr)
{
	version(Windows)
	{
		import core.sys.windows.winnt;
		return (attr & FILE_ATTRIBUTE_HIDDEN) != 0;
	}
	else
	{
		return name.length == 0 || name[0] == '.';
	}
}


version(AsLibrary)
{
	ubyte[] fileBuffer;
	static this()
	{
		import std.array;
		fileBuffer = uninitializedArray!(ubyte[])(1_000_000);
	}
}
else
{
	import core.attribute;
	__gshared ubyte[] fileBuffer;
	@trusted @standalone shared static this()
	{
		import std.array;
		fileBuffer = uninitializedArray!(ubyte[])(1_000_000);
	}
}