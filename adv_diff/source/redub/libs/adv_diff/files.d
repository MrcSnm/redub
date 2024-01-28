/** 
 * This module aims to provide a smart and optimized way to check cache and up to date checks.
 * It uses file times for initial comparison and if it fails, content hash is checked instead.
 * Beyond that, it also provides a cache composition formula.
 */
module redub.libs.adv_diff.files;
public import std.int128;

struct AdvFile
{
	///This will be used to compare before content hash
	long timeModified;
	ubyte[] contentHash;
}

struct AdvDirectory
{
	AdvFile[string] files;
	Int128 total;
}

struct AdvCacheFormula
{
	AdvDirectory[string] directories;
	AdvFile[string] files;
	Int128 total;


	static AdvCacheFormula make(ubyte[] function(ubyte[]) contentHasher, scope const string[] directories, scope const string[] files = null)
	{
		import std.file;
		import std.stdio;
		AdvCacheFormula ret;
		Int128 totalTime;
		ubyte[] fileBuffer;
		foreach(dir; directories)
		{
            Int128 dirTime;
			AdvDirectory advDir;
			if(!std.file.exists(dir)) continue;
			if(!std.file.isDir(dir)) assert(false, "Path sent is not a directory: "~dir);
			foreach(DirEntry e; dirEntries(dir, SpanMode.depth))
            {
				if(e.isDir) continue;
				long time = e.timeLastModified.stdTime;
				size_t fSize = e.size;
				if(fSize > fileBuffer.length) fileBuffer.length = fSize;
				File(e.name).rawRead(fileBuffer[0..fSize]);
				advDir.files[e.name] = AdvFile(time, contentHasher(fileBuffer[0..fSize]));
                dirTime+= time;
            }
			totalTime+= dirTime;
			ret.directories[dir] = advDir;
		}
		foreach(file; files)
        {
			///May throw if it is a directory.
			File f = File(file);
			if(!f.isOpen) continue; //Does not exists
			size_t fSize = f.size;
			if(fSize > fileBuffer.length) fileBuffer.length = fSize;
			f.rawRead(fileBuffer[0..fSize]);
			long time = std.file.timeLastModified(file).stdTime;
            totalTime+= time;
            ret.files[file] = AdvFile(time, fileBuffer[0..fSize]);
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
				if(otherAdvDir.total != advDir.total)
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
}