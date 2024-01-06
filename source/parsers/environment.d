module parsers.environment;
import buildapi;


/** 
 * Handles every environment variable related to this project.
 * Returns: 
 */
BuildConfiguration parse()
{
    import std.process;
    BuildConfiguration ret;

    string[] parsedEnvironmentVars = ["DFLAGS"];
    foreach(v; parsedEnvironmentVars)
    {
        if(v in environment)
        {

        }
    }
    

    return ret;
}