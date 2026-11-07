module redub.command_generators.ldc;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.command_generators.d_compilers;



string[] parseBuildConfiguration(const BuildConfiguration b, CompilationInfo s, string requirementCache, bool isRoot,
    bool singleCall = false, string moduleObject = null, string moduleSource = null)
{
    return redub.command_generators.d_compilers.parseBuildConfiguration(b, s, requirementCache, isRoot, singleCall,
        moduleObject, moduleSource);
}
