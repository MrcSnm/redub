module redub.command_generators.d_compilers;
import redub.buildapi;
import redub.command_generators.commons;
import redub.compiler_identification;
import redub.command_generators.ldc;

string[] parseBuildConfiguration(AcceptedCompiler comp, immutable BuildConfiguration b, OS target)
{
    import std.path;
    string function(ValidDFlags) mapper = getFlagMapper(comp);

    
    string[] commands = [mapper(ValidDFlags.enableColor)];
    with(b)
    {
        commands~= dFlags;
        if(isDebug) commands~= "-debug";
        if(b.arch) commands~= mapper(ValidDFlags.arch) ~ b.arch;
        commands = mapAppendPrefix(commands, versions, mapper(ValidDFlags.versions));
        commands = mapAppendPrefix(commands, importDirectories, mapper(ValidDFlags.importPaths));

        if(targetType.isLinkedSeparately)
            commands~= mapper(ValidDFlags.compileOnly);
        commands = mapAppendPrefix(commands, stringImportPaths, mapper(ValidDFlags.stringImportPaths));


        if(targetType.isStaticLibrary)
            commands~= mapper(ValidDFlags.buildAsLibrary);
        else if(targetType == TargetType.dynamicLibrary)
            commands~= mapper(ValidDFlags.buildAsShared);

        commands~= mapper(ValidDFlags.objectDir)~getObjectDir(b.workingDir);
        commands~= mapper(ValidDFlags.outputFile) ~ getConfigurationOutputDir(b, os);
        
        putSourceFiles(commands, workingDir, sourcePaths, sourceFiles, excludeSourceFiles, ".d");
    }

    return commands;
}

string getTargetTypeFlag(TargetType t, AcceptedCompiler c)
{
    auto mapper = getFlagMapper(c);
    switch(t) with(TargetType)
    {
        case executable, autodetect: return null;
        case library, staticLibrary: return mapper(ValidDFlags.buildAsLibrary);
        case dynamicLibrary: return mapper(ValidDFlags.buildAsShared);
        default: throw new Error("Unsupported target type");
    }
}


/** 
 * 
 * Params:
 *   dflags = The dFlags which should contain link flags
 * Returns: Only the link flags.
 */
string[] filterLinkFlags(const string[] dflags)
{
    import std.algorithm.iteration:filter;
    import std.array;
    auto filtered = dflags.filter!((df => df.length >= 2 && df[0..2] == "-L"));
    return cast(string[])(filtered.array);
}

string function(ValidDFlags) getFlagMapper(AcceptedCompiler comp)
{
    switch(comp)
    {
        case AcceptedCompiler.dmd: return &dmdFlags;
        case AcceptedCompiler.ldc2: return &ldcFlags;
        default: throw new Error("Compiler sent is not a D compiler.");
    }
}

string dmdFlags(ValidDFlags flag)
{
    final switch(flag) with (ValidDFlags)
    {
        case enableColor: return "-color=on";
        case stringImportPaths: return "-J=";
        case versions: return "-version=";
        case importPaths: return "-I";
        case objectDir: return "-od";
        case outputFile: return "-of";
        case buildAsLibrary: return "-lib";
        case buildAsShared: return "-shared";
        case compileOnly: return "-c";
        case arch: throw new Error("arch not supported by dmd.");
    }
}
string ldcFlags(ValidDFlags flag)
{
    final switch(flag) with (ValidDFlags)
    {
        case enableColor: return "--enable-color=true";
        case stringImportPaths: return "-J=";
        case versions: return "--d-version=";
        case importPaths: return "-I";
        case objectDir: return "--od=";
        case outputFile: return "--of=";
        case buildAsLibrary: return "--lib";
        case buildAsShared: return "--shared";
        case compileOnly: return "-c";
        case arch: return "--mtriple=";
    }
}


enum ValidDFlags
{
    enableColor,
    stringImportPaths,
    versions,
    importPaths,
    objectDir,
    outputFile,
    buildAsLibrary,
    buildAsShared,
    compileOnly,
    arch
}
