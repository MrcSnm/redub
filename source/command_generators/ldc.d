module command_generators.ldc;
import buildapi;



string parseBuildConfiguration(BuildConfiguration b)
{
    import std.algorithm.iteration:map;
    
    string[] commands;
    with(b)
    {
        if(isDebug) commands~= "-debug";
        commands~= versions.map!((v) => "-version="~v);
        
        
    
        
    }
}