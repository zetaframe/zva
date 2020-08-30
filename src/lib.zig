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
    block_id: vk.DeviceSize,
    span_id: vk.DeviceSize,
    memory_type_index: u32,

    memory: vk.DeviceMemory,

    offset: vk.DeviceSize,
    size: vk.DeviceSize,

    data: []align(8) u8,
};

pub const FunctionPointers = struct {
    getPhysicalDeviceProperties: vk.PfnGetPhysicalDeviceProperties,
    getPhysicalDeviceMemoryProperties: vk.PfnGetPhysicalDeviceMemoryProperties,

    allocateMemory: vk.PfnAllocateMemory,
    freeMemory: vk.PfnFreeMemory,
    mapMemory: vk.PfnMapMemory,
    unmapMemory: vk.PfnUnmapMemory,
};

const Block = struct {
    const Layout = struct { offset: vk.DeviceSize, size: vk.DeviceSize, alloc_type: AllocationType, id: usize };

    pfn: FunctionPointers,
    device: vk.Device,

    memory: vk.DeviceMemory,
    usage: MemoryUsage,
    size: vk.DeviceSize,
    allocated: vk.DeviceSize,

    data: []align(8) u8,

    layout: std.ArrayList(Layout),
    layout_id: usize,

    pub fn init(allocator: *mem.Allocator, pfn: FunctionPointers, device: vk.Device, size: vk.DeviceSize, usage: MemoryUsage, memory_type_index: u32) !Block {
        var layout = std.ArrayList(Layout).init(allocator);
        try layout.append(.{ .offset = 0, .size = size, .alloc_type = .Free, .id = 0 });

        const allocation_info = vk.MemoryAllocateInfo{
            .allocation_size = size,

            .memory_type_index = memory_type_index,
        };

        var memory: vk.DeviceMemory = undefined;
        if (pfn.allocateMemory(device, &allocation_info, null, &memory) != .success) return error.CannotMakeNewChunk;

        var data: []align(8) u8 = undefined;
        if (usage != .GpuOnly) if (pfn.mapMemory(device, memory, 0, size, 0, @ptrCast(*?*c_void, &data)) != .success) return error.MapMemoryFailed;

        return Block{
            .pfn = pfn,
            .device = device,

            .memory = memory,
            .usage = usage,
            .size = size,
            .allocated = 0,

            .data = data,

            .layout = layout,
            .layout_id = 1,
        };
    }

    pub fn deinit(self: Block) void {
        self.layout.deinit();

        if (self.usage != .GpuOnly) {
            self.pfn.unmapMemory(self.device, self.memory);
        }

        self.pfn.freeMemory(self.device, self.memory, null);
    }
};

const Pool = struct {
    allocator: *mem.Allocator,

    pfn: FunctionPointers,
    device: vk.Device,

    image_granularity: vk.DeviceSize,
    min_block_size: vk.DeviceSize,
    memory_type_index: u32,

    blocks: std.ArrayList(?*Block),

    pub fn init(allocator: *mem.Allocator, pfn: FunctionPointers, device: vk.Device, image_granularity: vk.DeviceSize, min_block_size: vk.DeviceSize, memory_type_index: u32) Pool {
        return Pool{
            .allocator = allocator,

            .pfn = pfn,
            .device = device,

            .image_granularity = image_granularity,
            .min_block_size = min_block_size,
            .memory_type_index = memory_type_index,

            .blocks = std.ArrayList(?*Block).init(allocator),
        };
    }

    pub fn deinit(self: Pool) void {
        for (self.blocks.items) |b| {
            if (b) |block| {
                block.deinit();
                self.allocator.destroy(block);
            }
        }
        self.blocks.deinit();
    }

    pub fn alloc(self: *Pool, size: vk.DeviceSize, alignment: vk.DeviceSize, usage: MemoryUsage, alloc_type: AllocationType) !Allocation {
        var found = false;
        var location: struct { bid: usize, sid: usize, offset: vk.DeviceSize, size: vk.DeviceSize } = undefined;
        outer: for (self.blocks.items) |b, i| if (b) |block| {
            if (block.usage == .GpuOnly and usage != .GpuOnly) continue;
            const block_free = block.size - block.allocated;

            var offset: vk.DeviceSize = 0;
            var aligned_size: vk.DeviceSize = 0;

            for (block.layout.items) |span, j| {
                if (span.alloc_type != .Free) continue;
                if (span.size < size) continue;

                offset = alignOffset(span.offset, alignment);

                if (j >= 1 and self.image_granularity > 1) {
                    const prev = block.layout.items[j - 1];
                    if ((prev.offset + prev.size - 1) & ~(self.image_granularity - 1) == offset & ~(self.image_granularity - 1)) {
                        const atype = if (@enumToInt(prev.alloc_type) > @enumToInt(alloc_type)) prev.alloc_type else alloc_type;

                        switch (atype) {
                            .Buffer => {
                                if (alloc_type == .Image or alloc_type == .ImageOptimal) offset = alignOffset(offset, self.image_granularity);
                            },
                            .Image => {
                                if (alloc_type == .Image or alloc_type == .ImageLinear or alloc_type == .ImageOptimal) offset = alignOffset(offset, self.image_granularity);
                            },
                            .ImageLinear => {
                                if (alloc_type == .ImageOptimal) offset = alignOffset(offset, self.image_granularity);
                            },
                            else => {},
                        }
                    }
                }

                var padding = offset - span.offset;
                aligned_size = padding + size;

                if (aligned_size > span.size) continue;
                if (aligned_size > block_free) continue :outer;

                if (j + 1 < block.layout.items.len and self.image_granularity > 1) {
                    const next = block.layout.items[j + 1];
                    if ((next.offset + next.size - 1) & ~(self.image_granularity - 1) == offset & ~(self.image_granularity - 1)) {
                        const atype = if (@enumToInt(next.alloc_type) > @enumToInt(alloc_type)) next.alloc_type else alloc_type;

                        switch (atype) {
                            .Buffer => if (alloc_type == .Image or alloc_type == .ImageOptimal) continue,
                            .Image => if (alloc_type == .Image or alloc_type == .ImageLinear or alloc_type == .ImageOptimal) continue,
                            .ImageLinear => if (alloc_type == .ImageOptimal) continue,
                            else => {},
                        }
                    }
                }

                found = true;
                location = .{ .bid = i, .sid = j, .offset = offset, .size = aligned_size };
                break :outer;
            }
        };

        if (!found) {
            var block_size: usize = 0;
            while (block_size < size) {
                block_size += self.min_block_size;
            }
            var block = try self.allocator.create(Block);
            block.* = try Block.init(self.allocator, self.pfn, self.device, block_size, usage, self.memory_type_index);
            try self.blocks.append(block);

            location = .{ .bid = self.blocks.items.len - 1, .sid = 0, .offset = 0, .size = size };
        }

        const allocation = Allocation{
            .block_id = location.bid,
            .span_id =  self.blocks.items[location.bid].?.layout.items[location.sid].id,
            .memory_type_index = self.memory_type_index,

            .memory = self.blocks.items[location.bid].?.memory,

            .offset = location.offset,
            .size = location.size,

            .data = if (usage != .GpuOnly) self.blocks.items[location.bid].?.data[location.offset .. location.offset + size] else undefined,
        };

        var block = self.blocks.items[location.bid].?;

        try block.layout.append(.{ .offset = block.layout.items[location.sid].offset + location.size, .size = block.layout.items[location.sid].size - location.size, .alloc_type = .Free, .id = block.layout_id });
        block.layout.items[location.sid].size = location.size;
        block.layout.items[location.sid].alloc_type = alloc_type;
        block.allocated += location.size;
        block.layout_id += 1;

        return allocation;
    }

    pub fn free(self: *Pool, allocation: Allocation) void {
        var block = self.blocks.items[allocation.block_id];
        for (block.?.layout.items) |*layout, i| {
            if (layout.id == allocation.span_id) {
                layout.alloc_type = .Free;
                break;
            }
        }
    }
};

pub const Allocator = struct {
    const Self = @This();
    allocator: *mem.Allocator,

    pfn: FunctionPointers,
    device: vk.Device,

    memory_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType,
    memory_type_count: u32,

    min_block_size: vk.DeviceSize,

    pools: []*Pool,

    pub fn init(allocator: *mem.Allocator, pfn: FunctionPointers, physical_device: vk.PhysicalDevice, device: vk.Device, min_block_size: vk.DeviceSize) !Self {
        var properties: vk.PhysicalDeviceProperties = undefined;
        pfn.getPhysicalDeviceProperties(physical_device, &properties);
        var mem_properties: vk.PhysicalDeviceMemoryProperties = undefined;
        pfn.getPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

        var pools = try allocator.alloc(*Pool, mem_properties.memory_type_count);
        var i: usize = 0;
        while (i < mem_properties.memory_type_count) : (i += 1) {
            var pool = try allocator.create(Pool);
            pool.* = Pool.init(allocator, pfn, device, properties.limits.buffer_image_granularity, min_block_size * 1024 * 1024, @intCast(u32, i));
            pools[i] = pool;
        }

        return Self{
            .allocator = allocator,

            .pfn = pfn,
            .device = device,

            .memory_types = mem_properties.memory_types,
            .memory_type_count = mem_properties.memory_type_count,

            .min_block_size = min_block_size * 1024 * 1024,

            .pools = pools,
        };
    }

    pub fn deinit(self: Self) void {
        for (self.pools) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
        self.allocator.free(self.pools);
    }

    pub fn alloc(self: *Self, size: vk.DeviceSize, alignment: vk.DeviceSize, memory_type_bits: u32, usage: MemoryUsage, alloc_type: AllocationType) !Allocation {
        var required_flags: vk.MemoryPropertyFlags = .{};
        var preferred_flags: vk.MemoryPropertyFlags = .{};

        switch (usage) {
            .GpuOnly => preferred_flags = preferred_flags.merge(vk.MemoryPropertyFlags{ .device_local_bit = true }),
            .CpuOnly => required_flags = required_flags.merge(vk.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true }),
            .GpuToCpu => {
                required_flags = required_flags.merge(vk.MemoryPropertyFlags{ .host_visible_bit = true });
                preferred_flags = preferred_flags.merge(vk.MemoryPropertyFlags{ .host_coherent_bit = true, .host_cached_bit = true });
            },
            .CpuToGpu => {
                required_flags = required_flags.merge(vk.MemoryPropertyFlags{ .host_visible_bit = true });
                preferred_flags = preferred_flags.merge(vk.MemoryPropertyFlags{ .device_local_bit = true });
            },
        }

        var memory_type_index: u32 = 0;
        var index_found = false;

        while (memory_type_index < self.memory_type_count) : (memory_type_index += 1) {
            if ((memory_type_bits >> @intCast(u5, memory_type_index)) & 1 == 0) {
                continue;
            }

            const properties = self.memory_types[memory_type_index].property_flags;

            if (!properties.contains(required_flags)) continue;
            if (!properties.contains(preferred_flags)) continue;

            index_found = true;
            break;
        }
        if (!index_found) {
            memory_type_index = 0;
            while (memory_type_index < self.memory_type_count) : (memory_type_index += 1) {
                if ((memory_type_bits >> @intCast(u5, memory_type_index)) & 1 == 0) {
                    continue;
                }

                const properties = self.memory_types[memory_type_index].property_flags;
                if (!properties.contains(required_flags)) continue;

                index_found = true;
                break;
            }
        }
        if (!index_found) return error.MemoryTypeIndexNotFound;

        var pool = self.pools[memory_type_index];
        return pool.alloc(size, alignment, usage, alloc_type);
    }

    pub fn free(self: *Self, allocation: Allocation) void {
        self.pools[allocation.memory_type_index].free(allocation);
    }
};

inline fn alignOffset(offset: vk.DeviceSize, alignment: vk.DeviceSize) vk.DeviceSize {
    return ((offset + (alignment - 1)) & ~(alignment - 1));
}
