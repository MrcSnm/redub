import std.path;

enum OutputType
{
    library,
    sharedLibrary,
    executable
}

struct BuildConfiguration
{
    bool isDebug;
    string name;
    string[] versions;
    string[] importDirectories;
    string[] libraryPaths;
    string[] libraries;
    string[] linkFlags;
    string[] dFlags;
    string sourceEntryPoint = "source/app.d";
    string outputDirectory  = "build";
    OutputType outputType;
}

struct Dependency{}

struct BuildRequirements
{
    BuildConfiguration cfg;
    Dependency[] dependencies;
}