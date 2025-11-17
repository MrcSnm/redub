module redub.misc.ldc_conf_parser;


struct ConfigSection 
{
    /// Name of the config section.
    string name;
    /// Maps keys to values (only string lists and strings supported)
    string[string] values; 
}

ConfigSection getLdcConfig(string cwd, string ldcBinPath, string triple)
{
    import std.file:readText;
    import std.algorithm.searching;
    if(triple is null)
        triple = "default";
    string confPath = getLdcConfPath(cwd,ldcBinPath);
    if(confPath is null)
        return ConfigSection.init;
    return parseLDCConfig(readText(confPath), triple);
}


/** 
 * Finds the ldc2.conf file, basing itself on "Configuration File" section at https://wiki.dlang.org/Using_LDC 
 * Params:
 *   cwd = Current Working Dir
 *   ldcBinPath = LDC path, ending with /bin
 * Returns: Path where ldc2.conf is located first
 */
private string getLdcConfPath(string cwd, string ldcBinPath)
{
    import std.path;
    import redub.parsers.environment;
    import std.array;
    import std.process;
    import std.system;
    import redub.command_generators.commons;
    static string ldc2InPath(string basePath)
    {
        import std.file;
        string p = buildNormalizedPath(basePath, "ldc2.conf");
        if(exists(p))
            return p;
        return null;
    }
    auto testPaths = [
        cwd,
        dirName(ldcBinPath),
        os.isWindows ? buildNormalizedPath(redubEnv["APPDATA"], ".ldc") : "~/.ldc",
        os.isWindows ? redubEnv["APPDATA"] : null,
        buildNormalizedPath(dirName(ldcBinPath), "..", "etc"),
        //6. and 7. not implemented since I didn't understand what <install-prefix> is supposed to mean
        os.isPosix ? "/etc" : null,
        os.isPosix ? "/etc/ldc" : null
    ].staticArray;

    foreach(t; testPaths)
    {
        if(t is null)
            continue;
        string ret = ldc2InPath(t);
        if(ret) return ret;
    }
    return null;
}


ConfigSection parseLDCConfig(string configText, string confToMatch) 
{
    import redub.misc.mini_regex;
    import std.string;
    import std.algorithm.searching;
    if(confToMatch.length == 0)
        confToMatch = "default";

    ConfigSection currentSection;
    bool foundSection;

    string lastKey;
    string valueBeingParsed;

    foreach (line; lineSplitter(configText))
    {
        line = line.strip; // Remove leading/trailing spaces
        if (line.empty || line.startsWith("//")) continue; // Skip empty lines and comments

        if (!foundSection && line.endsWith(":")) //New section
        {
            string sectionName = line[0 .. $ - 1].strip;
            if(sectionName.length && sectionName[0] == '"')
                sectionName = sectionName[1..$-1];
            if(matches(confToMatch, sectionName)) //If it didn't match the regex, continue
            {
                foundSection = true;
                currentSection.name = sectionName;
            }
        }
        else if(!foundSection)
            continue;
        else if (valueBeingParsed.length != 0)
        {
            if(line.endsWith(";"))
            {
                valueBeingParsed~= line[0..$-1];
                currentSection.values[lastKey] = valueBeingParsed;
                lastKey = valueBeingParsed = null;
            }
            else
                valueBeingParsed~= line;

        }
        else if (foundSection && line.canFind("=")) 
        {
            // Parse key-value pair
            auto parts = line.split("=");
            string key = parts[0].strip;
            string value = parts[1].strip;
            lastKey = key;
            valueBeingParsed = value;
            
            if (value.endsWith(";")) 
            {
                currentSection.values[key] = value[0..$-1];
                lastKey = valueBeingParsed = null;
            }
        }
    }
    return currentSection;
}


unittest
{
    string ldc2example =  q"EOS
// See comments in driver/config.d in ldc source tree for grammar description of
// this config file.

// For cross-compilation, you can add sections for specific target triples by
// naming the sections as (quoted) regex patterns. See LDC's `-v` output
// (`config` line) to figure out your normalized triple, depending on the used
// `-mtriple`, `-m32` etc. E.g.:
//
//     "^arm.*-linux-gnueabihf$": { … };
//     "86(_64)?-.*-linux": { … };
//     "i[3-6]86-.*-windows-msvc": { … };
//
// Later sections take precedence and override settings from previous matching
// sections while inheriting unspecified settings from previous sections.
// A `default` section always matches (treated as ".*") and is therefore usually
// the first section.
default:
{
    // default switches injected before all explicit command-line switches
    switches = [
        "-defaultlib=phobos2-ldc,druntime-ldc",
    ];
    // default switches appended after all explicit command-line switches
    post-switches = [
        "-I%%ldcbinarypath%%/../import",
    ];
    // default directories to be searched for libraries when linking
    lib-dirs = [
        "%%ldcbinarypath%%/../lib",
    ];
    // default rpath when linking against the shared default libs
    rpath = "%%ldcbinarypath%%/../lib";
};

"^wasm(32|64)-":
{
    switches = [
        "-defaultlib=",
        "-L-z", "-Lstack-size=1048576",
        "-L--stack-first",
        "-link-internally",
        "-L--export-dynamic",
    ];
    lib-dirs = [];
};

"i686-.*-linux-gnu":
{
    lib-dirs = [
        "%%ldcbinarypath%%/../lib32",
    ];
    rpath = "%%ldcbinarypath%%/../lib32";
};
EOS";

    assert(parseLDCConfig(ldc2example, "wasm32-unknown-unknown").values["switches"].length);
    assert(parseLDCConfig(ldc2example, "").values["rpath"].length);

}