const std = @import("std");
const LibExeObjStep = std.build.LibExeObjStep;
const Package = std.build.Pkg;

pub fn Pkg(zva_path: comptime []const u8, vk_path: comptime []const u8) type {
    return struct {
        pub const pkg = Package{
            .name = "zva",
            .path = zva_path ++ "/src/lib.zig",
            .dependencies = &[_]Package{Package{
                .name = "vk",
                .path = vk_path,
            }},
        };

        pub fn add(step: *LibExeObjStep) void {
            step.addPackage(pkg);
        }
    };
}
