module app;

import std;


string parseStringWithEnvironment(string str)
{
    import std.ascii:isAlphaNum;
    struct VarPos
    {
        size_t start, end;
    }
    VarPos[] variables;
    size_t lengthToReduce;
    for(int i = 0; i < str.length; i++)
    {
        if(str[i] == '$')
        {
            size_t start = i+1;
            size_t end = start;
            while(end < str.length && (str[end].isAlphaNum || str[end] == '_')) end++;
            variables~= VarPos(i, end);
            lengthToReduce+= end - i;
            i = cast(int)end;
        }
    }
    if(variables.length == 0)
        return str;
    char[] ret;
    size_t lengthToIncrease;
    for(int i = 0; i < variables.length; i++)
    {
        VarPos v = variables[i];
        string strVar = str[v.start+1..v.end];
        if(strVar.length == 0) //$
            continue;
        else if(!(strVar in environment))
        {
            variables = variables[0..i] ~ variables[i+1..$];
            i--;
            continue;
        }
        lengthToIncrease+= environment[strVar].length;
    }
	// if(variables.length == 0) return str;
	
    ret = new char[]((str.length+lengthToIncrease)-lengthToReduce);

	size_t outStart;
	size_t srcStart;
	foreach(v; variables)
	{
		//Remove the $
		string envVar = str[v.start+1..v.end];
		envVar = envVar.length == 0 ? "$" : environment[envVar];

		ret[outStart..outStart+(v.start-srcStart)] = str[srcStart..v.start];
		outStart+= (v.start-srcStart);
		ret[outStart..outStart+envVar.length] = envVar[];
		outStart+= envVar.length;
		srcStart = v.end;
	}
	if(outStart != ret.length)
		ret[outStart..$] = str[srcStart..$];

    return cast(string)ret;
}
import std.stdio;

void main()
{
	// writeln("$PATH ".parseStringWithEnvironment);
    // writeln("$$PATH $PATH $$OPA".parseStringWithEnvironment);
writeln("
--$HOME-$HOME--$HOME".parseStringWithEnvironment);

}
