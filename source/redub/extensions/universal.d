module redub.extensions.universal;

version(RedubCLI):


int buildUniversalMain(string[] args)
{
    import redub.api;
    ArgsDetails argsDetails = resolveArguments(args);
    foreach(d; buildProjectUniversal(argsDetails))
        if(d.error)
            return d.getReturnCode;
    return 0;
}
