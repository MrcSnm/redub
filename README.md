# Redub - Dub Based Build System
[![Update release and nightly](https://github.com/MrcSnm/redub/actions/workflows/ci.yml/badge.svg)](https://github.com/MrcSnm/redub/actions/workflows/ci.yml)

## Redub for dub users
- Change directory to the project you want to build and enter in terminal `dub run redub`
  > To fully take advantage of redub speed, you might as well use redub directly.

## Building redub
- Enter in terminal and execute [`dub`](https://github.com/dlang/dub)
- Highly recommended that you build it with `dub build -b release-debug --compiler=ldc2` since this will also improve its speed on dependency resolution


# Redub Additions
Those are the additions I've made over dub
- **Self Update**: `redub update` will either sync to the latest repo (and build it) or replace it with latest release
- [**Compiler Management**](#compiler-management) - Support to change default compiler and install on command line
- [**Redub Plugins**](#redub-plugins) - Alternative to rdmd. Execute arbitrary D code in the build steps.
- [**Multi Language**](#multi-language) - Compile a C project together and include it on the linking step
- [**Library API**](#using-its-library-api) - Integrate redub directly in your application
- **Watching Directories** - `redub watch`- Builds dependents automatically on changes. Add  `--run` to run the program after building.
- **MacOS Universal Builds** - `redub build-universal` - Generates a single binary containing arm64 and x86_64 architectures on MacOS


## Redub Help
- [Original Dub Documentation](https://dub.pm/)
- You may also get help by running `dub run redub -- --help` or simply `redub --help`



## Compiler Management
- Installing new compilers, use `redub install`:
  ```
  redub install requires 1 additional argument:
          opend: installs opend
          ldc <version?|help>: installs ldc latest if version is unspecified.
                  help: Lists available ldc versions
          dmd <version?>: installs the dmd with the version 2.111.0 if version is unspecified
  ```
- Using the new compilers, use `redub use` - Redub use will also install if you don't already have it:
  ```
  redub use requires 1 additional argument:
        opend <dmd|ldc>: uses the wanted opend compiler as the default
        ldc <version?>: uses the latest ldc latest if version is unspecified.
        dmd <version?>: uses the 2.111.0 dmd if the version is unspecified.
        reset: removes the default compiler and redub will set it again by the first one found in the PATH environment variable
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

**Useful links regarding plugins:**
- [**GetModule plugin**](./plugins/getmodules/source/getmodules.d)
- [**Example Usage**](./tests/plugin_test/dub.json)

## Multi language

Redub has also an experimental support for building and linking C/C++ code together with D code. For that, you need to define a dub.json:
```json
{
  "language": "C"
}
```

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


With that, you'll be able to specify that your dependency is a C/C++ dependency. then, you'll be able to build it by calling `redub --cc=gcc`. You can also
specify both D and C at the same time `redub --cc=gcc --dc=dmd`. Which will use DMD to build D and GCC to C.

You can see that in the example project: [**Multi Language Redub Project**](./tests/multi_lang/dub.json)


[**Project Meta**](META.md)