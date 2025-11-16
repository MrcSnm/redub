module redub.linker_identification;


enum AcceptedLinker : ubyte
{
    unknown,
    gnuld,
    ld64,
    ///I know there a plenty more, but still..
}

enum UsesGnuLinker
{
    unknown,
    yes,
    no
}

AcceptedLinker acceptedLinkerfromString(string str)
{
    switch(str)
    {
        static foreach(mem; __traits(allMembers, AcceptedLinker))
        {
            case mem:
                return __traits(getMember, AcceptedLinker, mem);
        }
        default:
            return AcceptedLinker.unknown;
    }
}

AcceptedLinker getDefaultLinker()
{
    with(AcceptedLinker)
    {
        version(Posix)
        {
            import std.process;
            import std.string;
            auto res = executeShell("ld -v");
            if(res.status == 0)
            {
                if(res.output.startsWith("GNU ld"))
                    return gnuld;
                else if(res.output.startsWith("@(#)PROGRAM:ld"))
                    return ld64;
            }
        }
        return unknown;
    }
}


/**
 * Used for determining whether it is running on gnu ld or not
 * Params:
 *   ldcPath = Ldc path for finding the ldc.conf file
 *   arch = Which architecture this compiler run is running with
 * Returns: -1 for can't tell. 0 if false and 1 if true
 */
// private UsesGnuLinker isUsingGnuLinker(string ldcPath, string arch)
// {
//     import redub.misc.ldc_conf_parser;
//     import std.file;
//     import std.algorithm.searching;
//     ConfigSection section = getLdcConfig(std.file.getcwd(), ldcPath, arch);
//     if(section == ConfigSection.init)
//         return UsesGnuLinker.unknown;
//     string* switches = "switches" in section.values;
//     if(!switches)
//         return UsesGnuLinker.unknown;
//     string s = *switches;
//     ptrdiff_t linkerStart = s.countUntil("-link");
//     if(linkerStart == -1)
//         return UsesGnuLinker.unknown;
//     s = s[linkerStart..$];

//     if(countUntil(s, "-link-internally") != -1 || countUntil(s, "-linker=lld"))
//         return UsesGnuLinker.no;

//     return countUntil(s, "-linker=ld") != -1 ? UsesGnuLinker.yes : UsesGnuLinker.unknown;
// }