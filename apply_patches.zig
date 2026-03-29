const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = std.fs.cwd();
    
    std.debug.print("Applying patches...\n", .{});

    var patch_dir = try cwd.openDir("patch", .{ .iterate = true });
    defer patch_dir.close();

    try copyRecursive(allocator, patch_dir, cwd, ".");
    
    std.debug.print("All patches applied successfully.\n", .{});
}

fn copyRecursive(allocator: std.mem.Allocator, src_dir: std.fs.Dir, dest_root: std.fs.Dir, sub_path: []const u8) !void {
    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ sub_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                var sub_src = try src_dir.openDir(entry.name, .{ .iterate = true });
                defer sub_src.close();
                
                // Create directory in destination if it doesn't exist
                dest_root.makePath(full_path) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
                
                try copyRecursive(allocator, sub_src, dest_root, full_path);
            },
            .file => {
                std.debug.print("  -> {s}\n", .{full_path});
                try src_dir.copyFile(entry.name, dest_root, full_path, .{});
            },
            else => {},
        }
    }
}
