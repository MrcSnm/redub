module command_generators.ldc;
import buildapi;



string[] parseBuildConfiguration(BuildConfiguration b)
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