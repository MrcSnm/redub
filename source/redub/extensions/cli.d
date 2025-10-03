module redub.extensions.cli;

version(RedubCLI):
public import redub.api;

/**
 *
 * Params:
 *   args = All the arguments to parse
 *   isDescribeOnly = Used to not run the preGenerate commands
 * Returns:
 */
ProjectDetails resolveDependencies(string[] args, bool isDescribeOnly = false)
{
    import std.file;
    import redub.api;
    import redub.logging;

    ArgsDetails argsD = resolveArguments(args, isDescribeOnly);


    ProjectDetails ret =  redub.api.resolveDependencies(
        argsD.args.build.force,
        os,
        argsD.cDetails,
        argsD.proj,
        argsD.dubVars,
        argsD.buildType
    );

    if(argsD.args.targetPath)
        ret.tree.requirements.cfg.outputDirectory = argsD.args.targetPath;
    if(argsD.args.targetName)
        ret.tree.requirements.cfg.targetName = argsD.args.targetName;

    if(argsD.args.build.printBuilds)
    {
        import redub.parsers.build_type;
        info("\tAvailable build types:");
        foreach(string buildType, value; registeredBuildTypes)
            info("\t ", buildType);
        foreach(mem; __traits(allMembers, BuildType))
        {
            if(__traits(getMember, BuildType, mem) !in registeredBuildTypes)
                info("\t ", __traits(getMember, BuildType, mem));
        }
    }

    return ret;
}
