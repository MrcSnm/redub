module command_generators.ldc;
public import buildapi;
public import std.system;



string[] parseBuildConfiguration(immutable BuildConfiguration b, OS os)
{
    import std.algorithm.iteration:map;
    import std.array:array;
    
    string[] commands;
    with(b)
    {
        if(isDebug) commands~= "-debug";
        commands~= versions.map!((v) => "-version="~v).array;
        
    }

    return commands;
}

string[] parseLinkConfiguration(immutable BuildConfiguration b, OS os)
{
    return null;
}