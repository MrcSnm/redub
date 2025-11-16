module redub.archiver_identification;
import hip.data.json;
import redub.compiler_identification;
public import std.system : OS;
import redub.command_generators.commons;


enum AcceptedArchiver : string
{
    ar = "ar",
    llvmLib = "llvm-lib",
    llvmAr = "llvm-ar",
    libtool = "libtool",
    /**
     * D compiler will be used for creating the library
     */
    none = ""
}

struct Archiver
{
    AcceptedArchiver type;
    string bin;
}

/**
     * For generating libraries, redub might use dmd/ldc2 by default since that simplifies the logic.
     * Although it is slightly slower, this is also a compromise one takes by using integration with C
     */
AcceptedArchiver defaultArchiverFromCompiler(AcceptedCompiler compiler, OS target)
{
    if(compiler.isDCompiler || compiler == AcceptedCompiler.invalid)
        return AcceptedArchiver.none;
    if(target.isWindows)
        return AcceptedArchiver.llvmLib;
    if(compiler == AcceptedCompiler.clang)
        return AcceptedArchiver.llvmAr;
    return AcceptedArchiver.ar;
}


Archiver getArchiver(AcceptedArchiver archiver)
{
    import std.array:staticArray;
    import redub.misc.find_executable;
    import std.process;
    import redub.meta;
    if(archiver == AcceptedArchiver.none)
        return Archiver(AcceptedArchiver.none);

    JSONValue compilersInfo = getRedubMeta();
    JSONValue* archiversCache = "archivers" in compilersInfo;
    if(archiversCache)
    {
        JSONValue* binPath = archiver in *archiversCache;
        if(binPath)
            return Archiver(archiver, binPath.str);
    }
    string help = " --help";
    if(archiver == AcceptedArchiver.llvmLib) help = " /help";
    auto res = executeShell(archiver~help);
    if(res.status == 0)
    {
        Archiver arch = Archiver(archiver, findExecutable(archiver));
        saveArchiver(compilersInfo, arch);
        return arch;
    }
    return Archiver(AcceptedArchiver.none);
}

void saveArchiver(ref JSONValue v, Archiver arch)
{
    import redub.meta;
    if(arch.type != AcceptedArchiver.none)
    {
        JSONValue* archivers = "archivers" in v;
        if(!archivers)
        {
            v["archivers"] = JSONValue.emptyObject;
            archivers = "archivers" in v;
        }
        (*archivers)[cast(string)arch.type] = arch.bin;
        saveRedubMeta(v);
    }
}

private AcceptedArchiver acceptedArchiverFromString(string str)
{
    switch(str)
    {
        static foreach(mem; __traits(allMembers, AcceptedArchiver))
        {
            case mem:
                return __traits(getMember, AcceptedArchiver, mem);
        }
        default:
            return AcceptedArchiver.none;
    }
}