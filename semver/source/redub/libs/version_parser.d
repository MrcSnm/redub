module redub.libs.version_parser;
import std.typecons;

package alias nint = Nullable!int;

nint[3] parseVersion(string verString, out ptrdiff_t currIndex)
{
    import std.ascii;
    import std.algorithm.iteration;
    import std.conv:to;
    nint[3] ret;
    
    
    ubyte retIndex = 0;
    ptrdiff_t i = -1;

    foreach(value; splitter(verString, '.'))
    {
        i = 0;
        while(i < value.length && isDigit(value[i]))
              i++;
        if(i != 0)
			ret[retIndex] = value[0..i].to!int;
        else
            return ret;

		retIndex++;
        if(retIndex == 3)
        {
            currIndex+= i;
            break;
        }
        else 
        {
            currIndex+= i;
            if(currIndex < verString.length) 
                currIndex+= 1; //Advance the dot
        }
    }
    return ret;
}

size_t versionsCount(nint[3] ver)
{
    if(ver[0].isNull) return 0;
    if(ver[1].isNull) return 1;
    if(ver[2].isNull) return 2;
    return 3;
}