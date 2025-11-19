module redub.command_generators.dmd;
import redub.buildapi;
import redub.command_generators.commons;
import redub.command_generators.d_compilers;

string[] parseBuildConfiguration(const BuildConfiguration b, CompilingSession s, string requirementCache, bool isRoot)
{
    return redub.command_generators.d_compilers.parseBuildConfiguration(b, s, requirementCache, isRoot);
}