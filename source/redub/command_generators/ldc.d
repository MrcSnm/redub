module redub.command_generators.ldc;
public import redub.buildapi;
public import std.system;
import redub.command_generators.commons;
import redub.command_generators.d_compilers;



string[] parseBuildConfiguration(const BuildConfiguration b, OS os, Compiler compiler, string requirementCache)
{
    return redub.command_generators.d_compilers.parseBuildConfiguration(AcceptedCompiler.ldc2, b, os, compiler, requirementCache);
}
