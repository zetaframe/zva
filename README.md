# Zig Vulkan Allocator (zva)

A zig vulkan memory allocator for use in [zetaframe](https://github.com/zetaframe/zetaframe).

Uses Snektron's vulkan bindings.

## Usage

In `build.zig`:
```zig
const zva = @import(<path to pkg.zig>).Pkg(<path to zva root>, <path to generated vulkan bindings>);

step.addPackage(zva.pkg);
```
