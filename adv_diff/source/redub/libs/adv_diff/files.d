/** 
 * This module aims to provide a smart and optimized way to check cache and up to date checks.
 * It uses file times for initial comparison and if it fails, content hash is checked instead.
 * Beyond that, it also provides a cache composition formula.
 */
module redub.libs.adv_diff.files;
public import std.int128;
public import std.json;

import std.exception;

struct AdvFile
{
	///This will be used to compare before content hash
	ulong timeModified;
	ubyte[] contentHash;

	void serialize(ref JSONValue output, string fileName) const
	{
		import std.digest:toHexString;
		output[fileName] = JSONValue([JSONValue(timeModified), JSONValue(contentHash.toHexString)]);
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
			advFile.serialize(dir, fileName);
		}
		import std.digest;
		output[dirName] = JSONValue([JSONValue(total.data.hi), JSONValue(total.data.lo), JSONValue(toHexString(contentHash)), dir]);
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



struct AdvCacheFormula
{
	Int128 total;
	AdvDirectory[string] directories;
	AdvFile[string] files;


	
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
		JSONValue dirsJson;
		foreach(string dirName, const AdvDirectory advDir; directories)
			advDir.serialize(dirsJson, dirName);
		
		JSONValue filesJson;
		foreach(string fileName, const AdvFile advFile; files)
			advFile.serialize(filesJson, fileName);
		output = JSONValue([JSONValue(total.data.hi), JSONValue(total.data.lo), dirsJson, filesJson]);
	}


	static AdvCacheFormula make(ubyte[] function(ubyte[]) contentHasher, scope const string[] directories, scope const string[] files = null)
	{
		import std.file;
		import std.stdio;
		AdvCacheFormula ret;
		Int128 totalTime;
		ubyte[] fileBuffer;
		ubyte[] hashedContent;
		foreach(dir; directories)
		{
            Int128 dirTime;
			AdvDirectory advDir;
			if(!std.file.exists(dir)) continue;
			enforce(std.file.isDir(dir), "Path sent is not a directory: "~dir);
			foreach(DirEntry e; dirEntries(dir, SpanMode.depth))
            {
				if(e.isDir) continue;
				long time = e.timeLastModified.stdTime;
				size_t fSize; 
				if(contentHasher !is null)
				{
					fSize = e.size;
					if(fSize > fileBuffer.length) fileBuffer.length = fSize;
					File(e.name).rawRead(fileBuffer[0..fSize]);
					hashedContent = contentHasher(fileBuffer[0..fSize]);
					advDir.contentHash = contentHasher(joinFlattened(advDir.contentHash, hashedContent));
				}
				advDir.files[e.name] = AdvFile(time, hashedContent);
                dirTime+= time;
            }
			totalTime+= advDir.total = dirTime;
			ret.directories[dir] = advDir;
		}
		foreach(file; files)
        {
			///May throw if it is a directory.
			scope(failure) continue;
			size_t fSize;
			File f = File(file);
			if(!f.isOpen) continue; //Does not exists
			if(contentHasher !is null)
			{
				fSize = f.size;
				if(fSize > fileBuffer.length) fileBuffer.length = fSize;
				f.rawRead(fileBuffer[0..fSize]);
				hashedContent = contentHasher(fileBuffer[0..fSize]);
			}
			long time = std.file.timeLastModified(file).stdTime;
            totalTime+= time;
            ret.files[file] = AdvFile(time, hashedContent);
        }
		ret.total = totalTime;
		fileBuffer = null;
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
						diffs[diffCount] = fileName;
					diffCount++;
				}
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
					diffs[diffCount] = dirName;
				diffCount++;
			}
			else
			{
				if(otherAdvDir.total != advDir.total && otherAdvDir.contentHash != advDir.contentHash)
				{
					//If directory total is different, check per file
					diffCount = diffFiles(otherAdvDir.files, advDir.files, diffs, diffCount);
				}
			}
		}
		return diffCount == 0;
	}
}

string hashFromTime(const scope Int128 input)
{
    import std.conv;
    char[2048] output;
    int i = 0;
    foreach(c; toChars(input.data.hi)) output[i++] = c;
    foreach(c; toChars(input.data.lo)) output[i++] = c;
    return (output[0..i]).dup;
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
	static hasher = cast(ubyte[] function(ubyte[]))(ubyte[] content)
	{
		import std.digest.md;
		return cast(ubyte[])toHexString(md5Of(content)).dup;
	};
	AdvCacheFormula formula = AdvCacheFormula.make(hasher, ["source"]);
	AdvCacheFormula formula2 = AdvCacheFormula.make(hasher, ["source", "source/redub"]);

	import std.stdio;
	size_t diffCount;
	writeln(formula.diffStatus(formula2, diffCount)[0..diffCount]);

	JSONValue v = JSONValue.emptyObject;
	formula.serialize(v);

	writeln(v.toPrettyString());
}

private bool isInteger(JSONType type){return type == JSONType.integer || type == JSONType.uinteger;}
private bool isObject(JSONType type){return type == JSONType.object || type == JSONType.null_;}