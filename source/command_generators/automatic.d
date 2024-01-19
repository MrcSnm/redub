module command_generators.automatic;
public import std.system;
public import buildapi;
import std.process;

static import command_generators.gnu_based;
static import command_generators.gnu_based_ccplusplus;
static import command_generators.dmd;
static import command_generators.ldc;

enum
{
    kGCC,
    kLDC,
    kGPP,
    kDMD,
    kLDC2,
    kTCC,
}

// our compilers list
static string[] kCompilerList = [ "gcc", "ldc", "g++", "dmd", "ldc2", "tcc" ];

string getCompileCommands(immutable BuildConfiguration cfg, OS os, string compiler)
{
    string[] flags;

    size_t index = 0;

    foreach (string compiler_name; kCompilerList)
    {
        if (compiler_name == compiler)
        {
            switch(index)
            {
                case kGPP:
                    flags = command_generators.gnu_based_ccplusplus.parseBuildConfiguration(cfg, os);
                    break;
                case kGCC, kTCC:
                    flags = command_generators.gnu_based.parseBuildConfiguration(cfg, os);
                    break;
                case kDMD:
                    flags = command_generators.dmd.parseBuildConfiguration(cfg, os);
                    break;
                case kLDC, kLDC2:
                    if (index == kLDC)
                        compiler = "ldc2";
                    
                    flags = command_generators.ldc.parseBuildConfiguration(cfg, os);
                    break;
                default: throw new Error("Unsupported compiler "~compiler);
            }     

            break;       
        }

        ++index;
    }


    return escapeShellCommand(compiler ~ flags);
}

string getLinkCommands(immutable BuildConfiguration cfg, OS os, string compiler)
{
    import command_generators.linkers;
    string[] flags;
    version(Windows) flags = parseLinkConfigurationMSVC(cfg, os, compiler);
    else flags = parseLinkConfiguration(cfg, os, compiler);

    switch(compiler)
    {
        case "dmd": break;
        case "ldc", "ldc2": compiler = "ldc2"; break;
        default: throw new Error("Unsupported compiler "~compiler);
    }
    return escapeShellCommand(compiler ~ flags);
}