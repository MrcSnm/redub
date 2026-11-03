module redub.misc.path;
public import std.path: dirSeparator, pathSeparator;

string buildNormalizedPath(scope string[] paths...)
{
	char[] buffer;
	string output  = normalizePath(buffer, paths);
	return output;
}

///Whether two paths live on the same volume. Hardlinks cannot cross volumes.
bool sameVolume(string a, string b)
{
    version(Windows)
    {
        import std.path : rootName;
        import std.string : icmp;
        return icmp(rootName(a), rootName(b)) == 0;
    }
    else
    {
        import core.sys.posix.sys.stat : stat, stat_t;
        import core.sys.posix.sys.types : dev_t;

        static bool deviceOf(string path, out dev_t dev)
        {
            enum bufSize = 4096;
            char[bufSize] buf;
            size_t len = path.length;
            if(len == 0 || len >= bufSize)
                return false;
            buf[0 .. len] = path[];
            while(true)
            {
                buf[len] = '\0';
                stat_t st;
                if(stat(buf.ptr, &st) == 0)
                {
                    dev = st.st_dev;
                    return true;
                }
                while(len > 1 && buf[len - 1] == '/')
                    len--;
                size_t slash = len;
                while(slash > 0 && buf[slash - 1] != '/')
                    slash--;
                if(slash == 0)
                {
                    if(len == 1 && buf[0] == '.')
                        return false;
                    buf[0] = '.';
                    len = 1;
                }
                else
                    len = slash > 1 ? slash - 1 : 1;
            }
        }

        dev_t aDev, bDev;
        return deviceOf(a, aDev) && deviceOf(b, bDev) && aDev == bDev;
    }
}

string normalizePath(return ref char[] output, scope string[] paths...)
{
    size_t start, length;
    import std.ascii;
    static string[1024] normalized;

    foreach(path; paths)
    {
        foreach(p; pathSplitterRange(path))
        {
            if(p == ".")
                continue;
            else if(p == "..")
            {
                if(length > 0)
                    length--;
                else
                    start++;
            }
            else
            {
				version(Posix)
				{
					if(p.length == 0) //Path is a single slash
						length = start = 0;
				}
				else
				{
					if(p.length > 1 && p[1] == ':') //Path has drive letter is absolute
						length = start = 0;
				}
                normalized[length++] = p;
            }
        }
    }
   	import core.memory;
    if(length == 1)
	{
		if(output.length == 0)
			output = normalized[0].dup;
		else
			output[0..normalized[0].length] = normalized[0];
		return cast(string)output[0..normalized[0].length];
	}
    if(start >= length)
        return null;

    size_t totalLength = (length - start) - 1;
    for(int i = cast(int)start; i < length; i++)
        totalLength+= normalized[i].length;

	if(output.length == 0)
    {
		output = (cast(char*)GC.malloc(totalLength, GC.BlkAttr.NO_SCAN))[0..totalLength];
    }

    totalLength = 0;
    for(int i = cast(int)start; i < length; i++)
    {
        output[totalLength..totalLength+normalized[i].length] = normalized[i];
		totalLength+= normalized[i].length;
        if(i + 1 < length)
            output[totalLength++] = dirSeparator[0];
    }

    return cast(string)output[0..totalLength];
}




auto pathSplitterRange(string path) pure @safe nothrow @nogc
{
    struct PathRange
    {
        string path;
        size_t indexRight = 0;

        bool empty() @safe pure nothrow @nogc {return indexRight >= path.length;}
        bool hasNext() @safe pure nothrow @nogc {return indexRight + 1 < path.length;}
        string front() @safe pure nothrow @nogc
        {
            size_t i = indexRight;
            while(i < path.length && path[i] != '\\' && path[i] != '/')
                i++;
            indexRight = i;
            return path[0..indexRight];
        }
        void popFront() @safe pure nothrow @nogc
        {
            if(indexRight+1 < path.length)
            {
                path = path[indexRight+1..$];
                indexRight = 0;
            }
            else
                indexRight+= 1; //Guarantees empty
        }
    }

    return PathRange(path);
}

unittest
{
    assert(buildNormalizedPath("", "..") == null);
}