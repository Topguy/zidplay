const std = @import("std");
pub fn main() void {
    var al = std.ArrayList(u32).init(std.heap.page_allocator);
    _ = al;
}
