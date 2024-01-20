module command_generators.automatic;
public import std.system;
public import buildapi;
public import compiler_identification;
import std.process;

static import command_generators.gnu_based;
static import command_generators.gnu_based_ccplusplus;
static import command_generators.dmd;
static import command_generators.ldc;

string getCompileCommands(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    string[] flags;
    switch(compiler.compiler) with(AcceptedCompiler)
    {
        case gxx:
            flags = command_generators.gnu_based_ccplusplus.parseBuildConfiguration(cfg, os);
            break;
        case gcc:
            flags = command_generators.gnu_based.parseBuildConfiguration(cfg, os);
            break;
        case dmd:
            flags = command_generators.dmd.parseBuildConfiguration(cfg, os);
            break;
        case ldc2:
            flags = command_generators.ldc.parseBuildConfiguration(cfg, os);
            break;
        default:throw new Error("Unsupported compiler "~compiler.binOrPath);
    }

    return escapeShellCommand(compiler.binOrPath ~ flags);
}

string getLinkCommands(immutable BuildConfiguration cfg, OS os, Compiler compiler)
{
    import command_generators.linkers;
    string[] flags;
    
    version(Windows) {
        flags = parseLinkConfigurationMSVC(cfg, os, compiler);
    }
    else {
        flags = parseLinkConfiguration(cfg, os, compiler);
    }

    if(compiler.compiler == AcceptedCompiler.invalid)
        throw new Error("Unsupported compiler " ~ compiler.binOrPath);

    if (TargetType.library == cfg.targetType ||
        TargetType.staticLibrary == cfg.targetType)
        return escapeShellCommand(compiler.archiver ~ flags);

    return null;
}