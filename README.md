# Redub - Dub Based Build System
[![Update release and nightly](https://github.com/MrcSnm/redub/actions/workflows/ci.yml/badge.svg)](https://github.com/MrcSnm/redub/actions/workflows/ci.yml)


## Running redub without having it on path
- Change directory to the project you want to build and enter in terminal `dub run redub`
- You may also get help by running `dub run redub -- --help`
- If you're unsure on how to update redub to the latest version using dub, you may also do `dub run redub -- update`

## Building redub
- Enter in terminal and execute `dub`
- Highly recommended that you build it with `dub build -b release-debug --compiler=ldc2` since this will also improve its speed on dependency resolution
- I would also add redub/bin to the environment variables, with that, you'll be able to simply execute `redub` in the folder you're in and get your project built and running
- After having your first redub version, you may also update redub by entering on terminal `redub update`. This will download the latest version, rebuild redub with optimizations and replace your current redub executable

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

## Redub Plugins

Redub has now new additions, starting from v1.14.0. Those are called **plugins**.
For using it, on the JSON, you **must** specify first the plugins that are usable. For doing that, you need to add:

```json
"plugins": {
  "getmodules": "C:\\Users\\Hipreme\\redub\\plugins\\getmodules"
}
```

That line will both build that project and load it inside the registered plugins (That means the same name can't be specified twice)

The path may be either a .d module or a dub project
> WARNING: This may be a subject of change and may also only support redub projects in the future, since that may only complicate code with a really low gain

Redub will start distributing some build plugins in the future. Currently, getmodules plugins is inside this repo as an example only but may be better used.
Only preBuild is currently supported since I haven't found situations yet to other cases.
For it to be considered a redub plugin to be built, that is the minimal code:

```d
module getmodules;
import redub.plugin.api;

class GetModulePlugin : RedubPlugin {}
mixin PluginEntrypoint!(GetModulePlugin);
```

For using it on prebuild, you simply specify the module and its arguments:
```json
"preBuildPlugins": {
  "getmodules": ["source/imports.txt"]
}
```

### Useful links regarding plugins:
- [**GetModule plugin**](./plugins/getmodules/source/getmodules.d)
- [**Example Usage**](./tests/plugin_test/dub.json)

## Multi language

Redub has also an experimental support for building and linking C/C++ code together with D code. For that, you need to define a dub.json:
```json
{
  "language": "C"
}
```

With that, you'll be able to specify that your dependency is a C/C++ dependency. then, you'll be able to build it by calling `redub --cc=gcc`. You can also
specify both D and C at the same time `redub --cc=gcc --dc=dmd`. Which will use DMD to build D and GCC to C.

You can see that in the example project: [**Multi Language Redub Project**](./tests/multi_lang/dub.json)


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
