# Redub - Dub Based Build System


## Running redub without having it on path
- Change directory to the project you want to build and enter in terminal `dub run redub`
- You may also get help by running `dub run redub -- --help`

## Building redub
- Enter in terminal and execute `dub`
- Highly recommended that you build it with `dub -b debug-release --compiler=ldc2` since this will also improve its speed on dependency resolution
- I would also add redub/bin to the environment variables, with that, you'll be able to simply execute `redub` in the folder you're in and get your project built and running

## Using its library API

The usage of the library APIispretty straightforward. You get mainly 2 functions
1. `resolveDependencies` which will parse the project and its dependencies, after that, you got all the project information
2. `buildProject` which will get the project information and build in parallel

```d
import redub.api;
import redub.logging;

void main()
{
  import std.file;
  //Enables logging on redub
  setLogLevel(LogLevel.verbose);

  //Gets the project information
  ProjectDetails d = resolveDependencies(
    invalidateCache: false,
    std.system.os,
    CompilationDetails("dmd", "arch not yet implemented", "dmd v[2.105.0]"),
    ProjectToParse("configuration", getcwd(), "subPackage", "path/to/dub/recipe.json (optional)")
  );

  /** Optionally, you can change some project information by accessing the details.tree (a ProjectNode), from there, you can freely modify the BuildRequirements of the project
  * d.tree.requirements.cfg.outputDirectory = "some/path";
  * d.tree.requirements.cfg.dFlags~= "-gc";
  */

  //Execute the build process
  buildProject(d);
}
```



# Project Meta


## Making it faster
Have you ever wondered why [dub](https://github.com/dlang/dub) was slow? I tried solving it, but its codebase was fairly unreadable. After building this project, I've implemented features that dub don't use

- Lazy build project configuration evaluation
- Parallelization on build sorted by dependency
- Faster JSON parsing
- Fully parallelized build when only link is waiting for dependencies

### Philosophy

- Separate build system from package manager.
- Have total backward compatibility on dub for initial versions.
- On initial versions, develop using phobos only
- Make it less stateful. 
- Achieve at least 90% of what dub does.
- Isolate each process. This will make easier for adding and future contributors

## Achieving it

### Legend
- api -> Can be freely be imported from any module
- module -> Needs to be isolated as much as possible from each module. If one needs to communicate with other, a bridge/api may be created after the initial idea

### How it works
Here are described the modules which do most of the work if someone wants to contribute.

- buildapi: Defines the contents of build configurations, tree of projects and commons for them
- parsers.json: Parse dub.json into a build configuration
- parsers.automatic: Parse using an automatic parser identification
- cli.dub + app: Parse CLI to get the build root and an initial build configuration
- parsers.environment: Merge environment variables into build configuration
- tree_generators.dub: Output build dependency tree while merging their configurations
- command_generator.automatic: Convert build configuration into compilation flags
- buildapi + building.compile: Transform build tree into dependency order tree
- building.compile: Spawn build processes for the dependencies until it links


### Contributor Attracting
- Isolate module as much as possible to attract contributors working on self contained modules which only gets input and returns an output

### Starting small
- No need to handle edge cases in the beginning. They may become even separate modules.

### A week project
- This project had a small start. I gave one week for doing it, but since it was very succesful on its
achievements, I decided to extend a little the deadline for achieving support.
Right now, it has been tested with

### Working examples
Those projects were fairly tested while building this one
- dub 
- glui
- dplug
- arsd-official
- Hipreme Engine

## Package manager
- Will be implemented as a hook in the build system. I'm accepting PRs, but I'm not implementing myself.
