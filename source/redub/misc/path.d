module redub.misc.path;

string buildNormalizedPath(scope string[] paths...)
{
	char[] buffer;
	string output  = normalizePath(buffer, paths);
	return output;
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
					if(path.length > 1 && path[1] == ':') //Path has drive letter is absolute
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

    size_t totalLength = (length - start) - 1;
    for(int i = cast(int)start; i < length; i++)
        totalLength+= normalized[i].length;

	if(output.length == 0)
		output = (cast(char*)GC.malloc(totalLength, GC.BlkAttr.NO_SCAN))[0..totalLength];

    totalLength = 0;
    for(int i = cast(int)start; i < length; i++)
    {
        output[totalLength..totalLength+normalized[i].length] = normalized[i];
		totalLength+= normalized[i].length;
        if(i + 1 < length)
            output[totalLength++] = pathSeparator;
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
version(Windows)
{
    enum pathSeparator = '\\';
    enum otherSeparator = '/';
}
else
{
    enum pathSeparator = '/';
    enum otherSeparator = '\\';
}