module redub.command_generators.dmd;
import redub.buildapi;
import redub.command_generators.commons;
import redub.command_generators.d_compilers;

string[] parseBuildConfiguration(const BuildConfiguration b, OS os)
{
    return redub.command_generators.d_compilers.parseBuildConfiguration(AcceptedCompiler.dmd, b, os);
}