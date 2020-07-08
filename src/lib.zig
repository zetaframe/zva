const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const vk = @import("vk");

pub const AllocationType = enum {
    Free,
    Buffer,
    Image,
    ImageLinear,
    ImageOptimal,
};

pub const MemoryUsage = enum {
    GpuOnly,
    CpuOnly,
    CpuToGpu,
    GpuToCpu,
};

pub const Allocation = struct {
    chunk_id: vk.DeviceSize,
    block_id: vk.DeviceSize,

    memory: vk.DeviceMemory,

    offset: vk.DeviceSize,
    size: vk.DeviceSize,

    data: []align(8) u8,
};

pub const Allocator = struct {
    const Self = @This();
    allocator: *mem.Allocator,

    device: vk.Device,
    image_granularity: vk.DeviceSize,
    memory_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType,
    memory_type_count: u32,

    chunk_size: vk.DeviceSize,

    chunks: std.AutoHashMap(usize, *Chunk),
    chunk_id: usize = 0,
    chunk_count: usize = 0,

    pub fn init(allocator: *mem.Allocator, physicalDevice: vk.PhysicalDevice, device: vk.Device, chunkSize: vk.DeviceSize) Self {
        return Self{
            .allocator = allocator,

            .device = device,
            .image_granularity = vk.GetPhysicalDeviceProperties(physicalDevice).limits.bufferImageGranularity,
            .memory_types = vk.GetPhysicalDeviceMemoryProperties(physicalDevice).memoryTypes,
            .memory_type_count = vk.GetPhysicalDeviceMemoryProperties(physicalDevice).memoryTypeCount,

            .chunk_size = chunkSize * 1024 * 1024,

            .chunks = std.AutoHashMap(usize, *Chunk).init(allocator),
            .chunk_id = 0,
            .chunk_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.chunks.items()) |*chunk| {
            chunk.value.deinit();
        }
        self.chunks.deinit();
    }

    pub fn alloc(self: *Self, size: vk.DeviceSize, alignment: vk.DeviceSize, memoryTypeBits: u32, usage: MemoryUsage, allocType: AllocationType) !Allocation {
        var requiredFlags: vk.MemoryPropertyFlags = vk.MemoryPropertyFlags.fromInt(0);
        var preferredFlags: vk.MemoryPropertyFlags = vk.MemoryPropertyFlags.fromInt(0);

        switch (usage) {
            .GpuOnly => preferredFlags = preferredFlags.with(vk.MemoryPropertyFlags{ .deviceLocal = true }),
            .CpuOnly => requiredFlags = requiredFlags.with(vk.MemoryPropertyFlags{ .hostVisible = true, .hostCoherent = true }),
            .GpuToCpu => {
                requiredFlags = requiredFlags.with(vk.MemoryPropertyFlags{ .hostVisible = true });
                preferredFlags = preferredFlags.with(vk.MemoryPropertyFlags{ .hostCoherent = true, .hostCached = true });
            },
            .CpuToGpu => {
                requiredFlags = requiredFlags.with(vk.MemoryPropertyFlags{ .hostVisible = true });
                preferredFlags = preferredFlags.with(vk.MemoryPropertyFlags{ .deviceLocal = true });
            },
        }

        var memoryTypeIndex: u32 = 0;
        var indexFound = false;

        while (memoryTypeIndex < self.memory_type_count) : (memoryTypeIndex += 1) {
            if ((memoryTypeBits >> @intCast(u5, memoryTypeIndex)) & 1 == 0) {
                continue;
            }

            const properties = self.memory_types[memoryTypeIndex].propertyFlags;
            if (!properties.hasAllSet(requiredFlags)) continue;
            if (!properties.hasAllSet(preferredFlags)) continue;

            indexFound = true;
            break;
        }

        if (!indexFound) {
            memoryTypeIndex = 0;
            while (memoryTypeIndex < self.memory_type_count) : (memoryTypeIndex += 1) {
                if ((memoryTypeBits >> @intCast(u5, memoryTypeIndex)) & 1 == 0) {
                    continue;
                }

                const properties = self.memory_types[memoryTypeIndex].propertyFlags;
                if (!properties.hasAllSet(requiredFlags)) continue;

                indexFound = true;
                break;
            }
        }

        if (!indexFound) return error.MemoryTypeIndexNotFound;

        for (self.chunks.items()) |*chunk| {
            if (chunk.value.memory_type_index != memoryTypeIndex) continue;

            const allocation = try chunk.value.alloc(size, alignment, self.image_granularity, allocType);
            if (allocation == null) break else return allocation.?;
        }

        if (self.chunk_count >= vk.MAX_MEMORY_TYPES) return error.CannotMakeNewChunk;

        var chunk = try self.allocator.create(Chunk);
        chunk.* = try Chunk.init(self.allocator, self.device, self.chunk_size, usage, memoryTypeIndex, self.chunk_id);
        try self.chunks.put(self.chunk_id, chunk);
        self.chunk_id += 1;
        self.chunk_count += 1;

        const allocation = try self.chunks.get(self.chunk_id - 1).?.alloc(size, alignment, self.image_granularity, allocType);

        return allocation.?;
    }

    pub fn free(self: *Self, allocation: Allocation) void {
        var chunk = self.chunks.get(allocation.chunk_id).?;
        chunk.free(allocation);

        // if (chunk.allocated == 0) {
        //     chunk.deinit();
        //     self.allocator.destroy(chunk);
        //     self.chunks.removeAssertDiscard(allocation.chunk_id);
        //     self.chunk_count -= 1;
        // }
    }
};

const Block = struct {
    id: vk.DeviceSize,

    offset: vk.DeviceSize,
    size: vk.DeviceSize,

    atype: AllocationType,

    prev: ?*Block,
    next: ?*Block,
};

const Chunk = struct {
    id: vk.DeviceSize,

    allocator: *mem.Allocator,

    device: vk.Device,

    memory: vk.DeviceMemory,
    size: vk.DeviceSize,
    allocated: vk.DeviceSize,

    usage: MemoryUsage,
    memory_type_index: u32,

    data: []align(8) u8,

    block_id: vk.DeviceSize,
    head: *Block,

    pub fn init(allocator: *mem.Allocator, device: vk.Device, size: vk.DeviceSize, usage: MemoryUsage, memoryTypeIndex: u32, id: vk.DeviceSize) !Chunk {
        if (memoryTypeIndex == std.math.maxInt(u64)) {
            return error.InvalidAllocationTypeIndex;
        }

        const allocationInfo = vk.MemoryAllocateInfo{
            .allocationSize = size,

            .memoryTypeIndex = memoryTypeIndex,
        };

        const memory = try vk.AllocateMemory(device, allocationInfo, null);

        var data: []align(8) u8 = undefined;
        if (usage != .GpuOnly) {
            try vk.MapMemory(device, memory, 0, size, vk.MemoryMapFlags.fromInt(0), @ptrCast(?**c_void, &data));
        }

        var head = try allocator.create(Block);
        head.* = Block{
            .id = 0,

            .offset = 0,
            .size = size,

            .atype = .Free,

            .prev = null,
            .next = null,
        };

        return Chunk{
            .id = id,

            .allocator = allocator,

            .device = device,

            .memory = memory,
            .size = size,
            .allocated = 0,

            .usage = usage,
            .memory_type_index = memoryTypeIndex,

            .data = data,

            .block_id = 0,
            .head = head,
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.deinitBlock(self.head);

        if (self.usage != .GpuOnly) {
            vk.UnmapMemory(self.device, self.memory);
        }

        vk.FreeMemory(self.device, self.memory, null);
    }

    fn deinitBlock(self: Chunk, block: *Block) void {
        if (block.next) |next| {
            if (next.next != null) self.deinitBlock(next) else self.allocator.destroy(next);
        }
        self.allocator.destroy(block);
    }

    pub fn alloc(self: *Chunk, size: vk.DeviceSize, alignment: vk.DeviceSize, granularity: vk.DeviceSize, allocType: AllocationType) !?Allocation {
        const freeSize = self.size - self.allocated;

        var curr: ?*Block = self.head;

        var offset: vk.DeviceSize = 0;
        var alignedSize: vk.DeviceSize = 0;

        var best: *Block = while (curr != null) : (curr = curr.?.next) {
            if (curr.?.atype != .Free) continue;
            if (size > curr.?.size) continue;

            offset = alignOffset(curr.?.offset, alignment);

            if (curr.?.prev != null and granularity > 1) {
                var prev = curr.?.prev.?;
                if ((prev.offset + prev.size - 1) & ~(granularity - 1) == offset & ~(granularity - 1)) {
                    const atype = if (@enumToInt(prev.atype) > @enumToInt(allocType)) prev.atype else allocType;

                    switch (atype) {
                        .Buffer => {
                            if (allocType == .Image or allocType == .ImageOptimal) offset = alignOffset(offset, granularity);
                        },
                        .Image => {
                            if (allocType == .Image or allocType == .ImageLinear or allocType == .ImageOptimal) offset = alignOffset(offset, granularity);
                        },
                        .ImageLinear => {
                            if (allocType == .ImageOptimal) offset = alignOffset(offset, granularity);
                        },
                        else => {},
                    }
                }
            }

            var padding = offset - curr.?.offset;
            alignedSize = padding + size;

            if (alignedSize > curr.?.size) continue;
            if (alignedSize + self.allocated >= self.size) return error.OutOfMemory;

            if (granularity > 1 and curr.?.next != null) {
                const next = curr.?.next.?;
                if ((next.offset + next.size - 1) & ~(granularity - 1) == offset & ~(granularity - 1)) {
                    const atype = if (@enumToInt(next.atype) > @enumToInt(allocType)) next.atype else allocType;

                    switch (atype) {
                        .Buffer => if (allocType == .Image or allocType == .ImageOptimal) continue,
                        .Image => if (allocType == .Image or allocType == .ImageLinear or allocType == .ImageOptimal) continue,
                        .ImageLinear => if (allocType == .ImageOptimal) continue,
                        else => {},
                    }
                }
            }

            break curr.?;
        } else return null;

        if (best.size > size) {
            self.block_id += 1;

            var block = try self.allocator.create(Block);
            block.* = Block{
                .id = self.block_id,

                .size = best.size - alignedSize,
                .offset = offset + size,

                .atype = .Free,

                .prev = best,
                .next = best.next,
            };

            best.*.next = block;
        }

        best.*.atype = allocType;
        best.*.size = size;

        self.allocated += alignedSize;

        return Allocation{
            .chunk_id = self.id,
            .block_id = best.id,

            .memory = self.memory,

            .size = size,
            .offset = offset,

            .data = if (self.usage != .GpuOnly) self.data[offset .. offset + size] else undefined,
        };
    }

    pub fn free(self: *Chunk, allocation: Allocation) void {
        var curr: ?*Block = self.head;
        while (curr != null) : (curr = curr.?.next) {
            if (curr.?.id == allocation.block_id) break;
        } else return;

        curr.?.atype = .Free;

        if (curr.?.prev != null and curr.?.prev.?.atype == .Free) {
            var prev = curr.?.prev.?;

            prev.next = curr.?.next;
            if (curr.?.next != null) curr.?.next.?.prev = prev;

            prev.size += curr.?.size;

            self.allocator.destroy(curr);
        }

        if (curr.?.next != null and curr.?.next.?.atype == .Free) {
            var next = curr.?.next.?;

            if (next.next != null) next.next.?.prev = curr;

            curr.?.next = next.next;

            curr.?.size += next.size;

            self.allocator.destroy(next);
        }

        self.allocated -= allocation.size;
    }
};

inline fn alignOffset(offset: vk.DeviceSize, alignment: vk.DeviceSize) vk.DeviceSize {
    return ((offset + (alignment - 1)) & ~(alignment - 1));
}
