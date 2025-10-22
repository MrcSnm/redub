## Packaging

This folder lists which versions are supported in Redub.
Currently I don't have an exhaustive list of which are supported, so, for clarity, the latest compilers are always tested with Redub and they will be listed inside this folder.

### Supported Compilers
- [clang](clang_version)
- [dmd](dmd_version)
- [ldc2](ldc2_version)
- OpenD: OpenD currently only uses 'latest', which means I can't pin its version. Since they don't plan on breaking anything, feel free to test it by using `redub use opend dmd` for example.
