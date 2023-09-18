const std = @import("std");

pub const FixedSizeFreeListAllocator = struct {
    const Self = @This();
    const AllocList = std.SinglyLinkedList(usize);

    buffer: []u8,
    stack_size: usize,
    free_list: AllocList,
    allocs: []AllocList.Node,
    bookkeeping_allocator: std.mem.Allocator,

    pub fn init(
        comptime stack_alignment: usize,
        buffer: []align(stack_alignment) u8,
        stack_size: usize,
        bookkeeping_allocator: std.mem.Allocator,
    ) !Self {
        std.debug.assert(buffer.len % stack_size == 0);
        const num_allocs = @divExact(buffer.len, stack_size);
        var allocs = try bookkeeping_allocator.alloc(AllocList.Node, num_allocs);
        var free_list = AllocList{};
        for (0..num_allocs) |i| {
            allocs[i] = .{ .data = i };
            free_list.prepend(&allocs[i]);
        }
        return .{
            .buffer = buffer,
            .stack_size = stack_size,
            .free_list = free_list,
            .allocs = allocs,
            .bookkeeping_allocator = bookkeeping_allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.bookkeeping_allocator.free(self.allocs);
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ra;
        _ = log2_ptr_align;
        if (n > self.stack_size) @panic("Request to FixedSizeFreeListAllocator exceeded provided stack size");
        const out = self.free_list.popFirst();
        if (out) |node| {
            return self.idxToBuf(node.data).ptr;
        } else {
            return null;
        }
    }

    fn idxToBuf(self: Self, idx: usize) []u8 {
        std.debug.assert(idx < self.allocs.len);
        const start = idx * self.stack_size;
        return self.buffer[start .. start + self.stack_size];
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        new_size: usize,
        return_address: usize,
    ) bool {
        _ = ctx;
        _ = buf;
        _ = log2_buf_align;
        _ = new_size;
        _ = return_address;
        return false;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = log2_buf_align;
        _ = return_address;
        std.debug.assert(self.ownsSlice(buf));
        const offset = @intFromPtr(buf.ptr) - @intFromPtr(self.buffer.ptr);
        self.free_list.prepend(&self.allocs[@divExact(offset, self.stack_size)]);
    }

    pub fn ownsSlice(self: *Self, slice: []u8) bool {
        const container = self.buffer;
        return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
            (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
    }
};

test "alloc" {
    const allocator = std.testing.allocator;
    const stack_alignment = 16;
    const block = try allocator.alignedAlloc(u8, stack_alignment, 2048);
    defer allocator.free(block);
    const stack_size = 32;

    var fla = try FixedSizeFreeListAllocator.init(stack_alignment, block, stack_size, allocator);
    defer fla.deinit();

    const salloc = fla.allocator();

    const buf = try salloc.alignedAlloc(u8, stack_alignment, stack_size);
    comptime std.debug.assert(@TypeOf(buf) == []align(stack_alignment) u8);
    try std.testing.expectEqual(buf.len, stack_size);

    var last: []align(stack_alignment) u8 = undefined;
    for (0..63) |_| {
        last = try salloc.alignedAlloc(u8, stack_alignment, stack_size);
    }

    try std.testing.expectError(error.OutOfMemory, salloc.alignedAlloc(u8, stack_alignment, stack_size));

    salloc.free(last);

    _ = try salloc.alignedAlloc(u8, stack_alignment, stack_size);
}
