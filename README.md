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
- [**Executable Icons**](#redub-executable-icons) - Include an icon in your .exe by simply defining the images on your recipe. 
- [**MacOS Bundle**](#macos-bundle) - Redub can also generate .app for your macOS builds.
- [**Library API**](#using-its-library-api) - Integrate redub directly in your application
- **Watching Directories** - `redub watch`- Builds dependents automatically on changes. Add  `--run` to run the program after building.
- **MacOS Universal Builds** - `redub build-universal` - Generates a single binary containing arm64 and x86_64 architectures on MacOS
- [**Redub Executable Icons**](#redub-executable-icons) - Adds inside the recipe file a way to define how your program icon will look
- [**Linker Diagnostics**](#redub-linker-diagnostics) - Experimental support to improve linker message errors.
- [**Cross Compilation Targets**](#redub-cross-compile) - Adds support to build targets, selecting a compiler, architecture and other configuration by just calling `redub --target=PSVita`
- [**LDC Addon**](#redub-ldc-addon) - Since `v1.35.2`: Adds support to installing LDC addon, together with target presets
- **Auto PATH setup** - Since `v1.32.0`: Adds a way to auto setup redub paths in your system. Call `redub setup` and it will install redub, redub's ldc and redub's dmd in the PATH.
- **Cache Sharing** - Since `v1.33.2`: Whenever you build a library which has the same versions and flags between parallel projects, the built library will be reused.
- [**Incremental Compilation**](#redub-incremental-compilation) - Since `v1.34.0`: Redub is able to parse your root project and detect whether it is better to use a single compilation unit vs per module in parallel
- **Build Time Regression Warn** - Since `v1.35.0`: Redub now also warns you if you've done some change that done a big regression in the build time, allowing you to be aware of your own changes.
- [**Built-in Cross Runner**](#built-in-targets) - Since `v1.36.1`: It is now possible to use redub to run D on android and web without any modification: `redub --target=android --bundle=android`|`redub --target=wasm` - builds and runs a server loading your executable


## Redub Help
- [Original Dub Documentation](https://dub.pm/)
- You may also get help by running `dub run redub -- --help` or simply `redub --help`



## Compiler Management
- Install with `redub install` (run `redub install --help` for targets, versions, addons and examples):
  ```
  redub install <target> [<version>|help] [options]

  Targets: ldc, dmd, opend, wasi-sdk, emsdk
  ```
  Examples:
  ```
  redub install ldc
  redub install ldc 1.43.0 --addon=wasi
  redub install dmd 2.112.0
  redub install wasi-sdk
  redub install emsdk
  ```
  Use `<target> help` to list available versions where supported.
- Select an installed compiler with `redub use` (it installs if needed):
  ```
  redub use <dmd|ldc|opend|reset> <version?|help>
  ```
  `reset` makes redub use the first compiler found in `PATH` again.


## Redub Plugins

Redub has now new additions, starting from v1.14.0. Those are called **plugins**.
For using it, on the JSON, you **must** specify first the plugins that are usable. For doing that, you need to add:

```json
"plugins": {
  "getmodules": "C:\\Users\\Hipreme\\redub\\plugins\\getmodules"
}
```

That line will both build that project and load it inside the registered plugins (That means the same name can't be specified twice)

The path may be either a .d module or a dub project. Built-in plugins are referenced with the `redub:` prefix, for example `"cmake": "redub:cmake"` or `"fetchlib": "redub:fetchlib"`. Run `redub plugins` to list them.
> WARNING: This may be a subject of change and may also only support redub projects in the future, since that may only complicate code with a really low gain

Redub ships some build plugins as built-ins. Currently, `redub:cmake` is available for libraries that build with CMake, and `redub:fetchlib` fetches sources from git and injects them into the build. The getmodules plugin inside this repo is an example of an external plugin.
Plugins can run in two phases: `preGenerate` while a package is being parsed (before its dependencies are resolved, ideal for injecting sources) and `postGenerate` after the project tree is resolved but before cache validation and compilation (ideal for generating headers or libraries). `postGenerate` plugins run once per build, before Redub checks which packages are up to date.
For it to be considered a redub plugin to be built, that is the minimal code:

```d
module getmodules;
import redub.plugin.api;

class GetModulePlugin : RedubPlugin {}
mixin PluginEntrypoint!(GetModulePlugin);
```

For using it, specify the module and its arguments in the phase you need:
```json
"postGeneratePlugins": {
  "getmodules": ["source/imports.txt"]
}
```

**Useful links regarding plugins:**
- [**GetModule plugin**](./plugins/getmodules/source/getmodules.d)
- [**Example Usage**](./tests/plugin_test/dub.json)

## Redub Executable Icons

- **v1.27.4**: Added Windows support

Specify one or more .png paths to your icon (only .png is supported), and it will be the icon of your project. This feature is already in use on redub itself.
```json
"icon": [
  "logo.png",
  "logo16.png"
]
```
The first icon path is where redub will output the .res

## MacOS Bundle

- **1.28.0**: Added --bundle=macos support

This feature was first supposed to add icons to apple applications, but macOS relies on you distributing bundles. You can use the icons in the same way mentioned above. Just use `redub build --bundle=macos` and it will generate a complete macOS bundle for you instead of the raw terminal one.

## Linux AppImages
- **v1.28.2** -- Added --bundle=linux support

This feature provides building AppImages to Linux. This is only supported running on linux, if no icon is provided, it will use the following icon:

  <img src="source/redub_program.png" width="128px" height="128px"/>

You can also control the bundle configurations by using. Failing to use a valid category will show all available categories.
```json
"bundleConfiguration": {
  "categories": [
    "Game"
  ],
  "terminal": false //Control whether the terminal should show up
}
```


## Redub Linker Diagnostics
- **1.29.0**: Added Windows Linker Diagnostics.

Sometimes people may get cryptic error messages regarding anundefined __ModuleInitZ symbol. Since Redub already had information on how each module imports each other, I've ended up adding support to improve the linker messages as that may reduce by a lot iteration time. Example:

```
hipreme_engine.obj : error LNK2001: unresolved external symbol _D3hip3api12__ModuleInfoZ
C:\Users\Hipreme\AppData\Local\.dub\.redub\1AB9D53797DC3516\1AB9D53797DC3516\hipreme_engine.exe : fatal error LNK1120: 1 unresolved external symbol
Error: C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\HostX64\x64\link.exe failed
with status: 1120
```
This gets one additional message

```
Redub Help Message: Module hip.api is imported by:
        hip.view.load_scene (C:\Users\Hipreme\Documents\D\HipremeEngine\source\hip\view\load_scene.d)
```

## Redub Cross Compile
- **1.30.0**: Added cross compilation definition support via the `--target` flag.

Ever wanted to configure a default compiler/arch based on the configuration? Now you can (mostly). This is an example on how a `target` will look in your recipe JSON:

```json
{
  "name": "my-project",
  "targets": {
    "wasm": {
      "compiler": "ldc2",
      "arch": "wasm32-unknown-unknown-wasm"
    },
    "PSVita": {
      "compiler": "ldc2",
      "arch": "armv7a-unknown-unknown-eabi",
      "dflags": [
        "--revert=dtorfields",
        "-mcpu=cortex-a9",
        "-mattr=+neon,+neonfp,+thumb-mode",
        "-fvisibility=hidden",
        "-gcc=$VITASDK/bin/arm-vita-eabi-gcc",
        "--relocation-model=static"
      ],
      "versions": ["PSVita"],
      "dependencies": {
        "custom-rt": {"path": "my/custom/runtime"}
      },
      "runCommand": ["nxlink", "${DUB_ROOT_PACKAGE}.nro"] //New addition to redub. If you're cross-compiling, you can define a specific run command that will be used instead of just launching from shell the executable.
    }
  }
}
```
Now you can just call `redub --target=wasm` or `redub --target=PSVita` and every dependency will inherit this configuration.

### Built-in targets
Since `v1.36.1`: use `redub --target=<name>`; a recipe target with the same name overrides the preset. Addons require LDC 1.43+ (`redub install ldc --addon=<group>`).

| Target | Addon | SDK | Environment | Run |
| --- | --- | --- | --- | --- |
| `windows`, `windows-i686`, `windows-arm64` | `windows` | N/A | N/A | native |
| `macos`, `macos-arm64` | N/A | Apple tooling to link | N/A | native |
| `android`, `android-armv7a`, `android-x86_64`, `android-i686` | `android` | NDK + SDK build-tools/platform | `ANDROID_NDK_HOME`, `CC`, `PATH` | `adb` push/run; APK via `--bundle=android` |
| `wasi`, `wasi-p2` | `wasi` | WASI SDK | `WASI_SDK_PATH`, `CC`, `PATH` | `redub serve` (p2 needs `jco`) |
| `emscripten` | `emscripten` | Emscripten SDK | `EMSDK`, `PATH`, `EMSDK_NODE`, `EMSDK_PYTHON` | `redub serve` with its `.js` glue |
| `wasm`, `web` | N/A | N/A | N/A | `redub serve` |

**Remarks**
- **macOS:** compiles everywhere; linking needs Apple tooling. Use `--build=syntax` for a pure syntax check.
- **Android – setup:** redub finds the NDK via env/Android Studio paths or `redub install android-ndk`. For APK packaging, `redub install android-sdk` installs platform-tools, build-tools, a platform and a JDK 17 when none is found (all in the workspace and found automatically). `adb` (platform-tools) is auto-downloaded and `ANDROID_SERIAL` selects a device.
- **Android – run on a device:** `redub run --target=android` pushes and runs the `.so`; with `--bundle=android` it builds the APK, installs it, starts the launcher activity and streams `logcat`.
- **Android – build an APK:** `redub build --target=android --bundle=android` requires `extern(C) void android_d_main(void*)`; the APK uses the redub icon and permissions go in `"bundleConfiguration": { "permissions": ["INTERNET"] }`.
- **Android – start a project:** `redub init --android <dir>` creates an OpenGL ES + touch template (`bundleConfiguration.opengl = true`, callbacks `redub_android_init/draw/touch/destroy`).
- **Android – customize the glue:** the selected bridge lives in `android/glue/source/redub_{minimal,opengl}_bridge.c`; the glue C project is created in `android/glue` (edit its `dub.json` flags or add sources under `source/`); redub builds it only for Android bundles and caches the result.
- **Android – example:** see `tests/android`.
- **WASI:** install the SDK with `redub install wasi-sdk`; p1 runs in the browser via `redub serve`; p2 outputs are components, transpile with `jco`.
- **Emscripten:** install with `redub install emsdk`; no system Python needed.
- **wasm/web:** no SDK; links with `--no-entry` and `--allow-undefined`, so use `-betterC` or provide an entry point/runtime. `env.js` can provide JS imports for `extern(C)`; builds create a template in the project root.
- **serve:** `redub serve [<artifact|dir>] [--port=8080] [--host=127.0.0.1] [--no-open]` serves the build directory, opens the browser (unless `--no-open`), and generates `index.html`/`redub.js` when missing.

## Multi language

Redub has also an experimental support for building and linking C/C++ code together with D code. For that, you need to define a dub.json:
```json
{
  "language": "C"
}
```

## Redub Incremental Compilation
Depending on the project size, it may be more useful to build it in parallel per module vs in a single command how it is done by default. Note that this is only valid for the root project.

The `auto` option will parse your D source and identify whether it is cheaper to use incremental-prallel or full-once, which is the default behavior. It is also possible to override that in 2 ways: 
`auto` also execute multiple compilation strategies and collect in its cache the build timings to get which strategy is faster and better decide.

- **Project Configuration**:
```json
"redub": {
  "buildStrategy": "incremental-parallel",
  "buildStats": false, //Do not collect build stats. Since we're not using auto, there's not much gain by doing that.
  "trustedNoImportMixins": [ //Mixins that can't be resolved but you guarantee they do not import anything.
    "my.NoImportMixin"
  ]
}
```
- **Command Line**:

```
  --build-strategy Root build strategy: |auto|full-once|incremental-once|incremental-parallel|full-parallel|. Overrides the project's redub config.
  strategy              incremental  processes                          link
  full-once             no           1 compiler                         same invocation
  incremental-once      yes          1 compiler + 1 linker              separate
  incremental-parallel  yes          N compilers (1 per module) + link  separate
  full-parallel         no           N compilers (1 per module) + link  separate
  auto(default)         picks full-once or incremental-parallel from module count/weight;
                         fewer than 4 cores picks incremental-once.
  link is separate whenever per-module objects are reused
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

A C library can also be compiled directly from its own sources, without a Makefile or CMake: [**Direct C Library Example**](./tests/direct_c_lib/dub.json)

Source-less wrappers can use `"targetType": "external"`. Redub keeps the package in the build, runs its build commands and plugins, and propagates its libraries, library paths, frameworks and link flags to dependents without producing an artifact of its own. This lets you wrap CMake/Make builds without a stub source file.

If a dependency only ships Makefile/CMake files, the built-in [**fetchlib plugin**](./source/redub/plugins/fetchlib.d) (`redub:fetchlib`) fetches it from git and injects its sources in `preGenerate` based on a JSON config (URL, ref, source globs, include paths and defines). The [**Fetch Zlib Example**](./tests/fetch_zlib_plugin/zlib/fetch.json) builds zlib this way through `plugins`/`preGeneratePlugins`, using `FETCHLIB_SRC` for an existing checkout or a plain `git clone` fallback. Packages without source files are kept when they declare any plugin phase, so the plugin can inject the sources without a stub file.

For libraries that need their own CMake build, the built-in [**cmake plugin**](./source/redub/plugins/cmake.d) (`redub:cmake`) clones the repository, runs `cmake` out-of-tree, installs it into the package's `vendor` directory, and reuses the cached build on later runs. The [**SDL3 Example**](./tests/sdl3/sdl3/cmake.json) declares SDL3 as an `external` target and links it into a small C app. Its `postGeneratePlugins` entry runs CMake before any compilation starts, so the normal parallel build can use the generated headers. Build it with [`tests/sdl3/build.sh`](./tests/sdl3/build.sh), which uses `--force` when the generated `vendor` directory is missing.


[**Project Meta**](META.md)