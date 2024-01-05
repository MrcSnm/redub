# Dub v2 - Build System

## Making it faster

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
- module -> Needs to be isolated as muhc as possible from each module. If one needs to communicate with other, a bridge/api may be created after the initial idea

### Build system base
- api: build configuration
- module: Parse dub.json into a build configuration
- module: Parse CLI to get the build root and an initial build configuration
- module: Merge environment variables into build configuration
- module: Output build dependency tree
- module: Merge a tree node build configurations and output them
- module: Convert build configuration into compilation flags
- module: Transform build tree into dependency order tree
- module: Spawn build processes for each tree level


### Contributor Attracting
- Isolate module as much as possible to attract contributors working on self contained modules which only gets input and returns an output

### Starting small
- No need to handle edge cases in the beginning. They may become even separate modules.

### A week project
- This project is very small. It is intended to be finished at most a week of work.

## Package manager
- Will be implemented as a hook in the build system 
