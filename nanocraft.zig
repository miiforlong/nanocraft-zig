// ============================================================================
// NANOCRAFT - port Zig de RubyDung/Nanocraft (Python) - fichier unique
// Dépendance externe: raylib (fenêtre/GL/input/texte) — via @cImport.
// Simplifications assumées par rapport au Python (comportement identique,
// implémentation interne plus simple/rapide) :
//   - décodage de chunk fait sur UN thread réseau (pas de pool de threads,
//     Zig natif est largement assez rapide sans ça)
//   - pas de double-cache "chunk_blocks/visible_chunk_blocks" : on relit
//     directement la hashmap sparse au moment de reconstruire un mesh
//   - zlib compress/decompress réimplémenté à la main (header zlib 2 octets
//     + deflate std.compress.flate + adler32) pour ne pas dépendre d'une
//     API zlib.Compressor pas garantie stable entre versions de Zig
// ============================================================================

const std = @import("std");
const ray = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

// ============================================================================
// CONFIGURATION
// ============================================================================

var WIDTH: i32 = 1024;
var HEIGHT: i32 = 768;
const CHUNK_SIZE_RENDER: i32 = 16;
const MAP_W: i32 = 128;
const MAP_D: i32 = 64;
const MAP_H: i32 = 128;
const RENDER_DIST: f32 = 96.0;

const JAVA_RENDER_DIST_CHUNKS: i32 = 3;
const JAVA_VERTICAL_RENDER_CHUNKS: i32 = 2;
const JAVA_LOADING_MIN_CHUNKS: u32 = 96;
const JAVA_LOADING_IDLE_SECONDS: f64 = 3.0;
const JAVA_BLOCK_UPDATE_INTERVAL: f64 = 0.08;
const JAVA_BLOCK_BURST_SECONDS: f64 = 0.25;
const JAVA_VIEW_RECENTER_STEP: i32 = 2;
const JAVA_LAN_PORT_DEFAULT: u16 = 25565;
const JAVA_LAN_MULTICAST_GROUP = "224.0.2.60";
const JAVA_LAN_MULTICAST_PORT: u16 = 4445;
const PORT: u16 = 5555;

const STEVE_TOP_TILE = [2]i32{ 15, 7 };
const STEVE_BOTTOM_TILE = [2]i32{ 15, 6 };
const STEVE_SIDE_TOP_TILE = [2]i32{ 14, 7 };
const STEVE_SIDE_BOTTOM_TILE = [2]i32{ 14, 6 };

var gpa_impl = std.heap.DebugAllocator(.{}){};
const galloc = gpa_impl.allocator();

// ============================================================================
// PROTOCOLE MINECRAFT JAVA (1.8 / protocole 47)
// ============================================================================

fn readVarInt(data: []const u8, offset_in: usize) !struct { value: i32, offset: usize } {
    var result: i32 = 0;
    var shift: u5 = 0;
    var offset = offset_in;
    while (true) {
        if (offset >= data.len) return error.VarIntTruncated;
        const b = data[offset];
        offset += 1;
        result |= @as(i32, b & 0x7F) << shift;
        shift += 7;
        if ((b & 0x80) == 0) break;
        if (shift >= 35) return error.VarIntTooLong;
    }
    return .{ .value = result, .offset = offset };
}

fn writeVarInt(list: *std.ArrayList(u8), value_in: i32) !void {
    var value: u32 = @bitCast(value_in);
    while (true) {
        var part: u8 = @truncate(value & 0x7F);
        value >>= 7;
        if (value != 0) {
            part |= 0x80;
            try list.append(part);
        } else {
            try list.append(part);
            break;
        }
    }
}

fn writeString(list: *std.ArrayList(u8), s: []const u8) !void {
    try writeVarInt(list, @intCast(s.len));
    try list.appendSlice(s);
}

fn readString(alloc: std.mem.Allocator, data: []const u8, offset_in: usize) !struct { value: []u8, offset: usize } {
    const r = try readVarInt(data, offset_in);
    const len: usize = @intCast(r.value);
    const out = try alloc.dupe(u8, data[r.offset .. r.offset + len]);
    return .{ .value = out, .offset = r.offset + len };
}

fn readAngle(data: []const u8, offset: usize) struct { value: f32, offset: usize } {
    const v: f32 = @as(f32, @floatFromInt(data[offset])) * 360.0 / 256.0;
    return .{ .value = v, .offset = offset + 1 };
}

fn packBlockPosition(x: i64, y: i64, z: i64) [8]u8 {
    const value: u64 = (@as(u64, @bitCast(x)) & 0x3FFFFFF) << 38 |
        (@as(u64, @bitCast(y)) & 0xFFF) << 26 |
        (@as(u64, @bitCast(z)) & 0x3FFFFFF);
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, value, .big);
    return out;
}

fn unpackBlockPosition(v: i64) struct { x: i64, y: i64, z: i64 } {
    var bx: i64 = v >> 38;
    const by: i64 = (v >> 26) & 0xFFF;
    var bz: i64 = (v << 38) >> 38;
    if (bx >= (1 << 25)) bx -= (1 << 26);
    if (bz >= (1 << 25)) bz -= (1 << 26);
    return .{ .x = bx, .y = by, .z = bz };
}

fn writeSlot(list: *std.ArrayList(u8), item_id: i16, count: u8, damage: i16) !void {
    if (item_id < 0) {
        try list.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i16, -1)));
        return;
    }
    try list.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i16, item_id)));
    try list.append(count);
    try list.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i16, damage)));
    try list.append(0);
}

// --- zlib minimal (header 2 bytes + deflate + adler32), pour compression MC ---

fn zlibCompress(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    try out.append(0x78);
    try out.append(0x9C);
    var comp = try std.compress.flate.compressor(out.writer(), .{});
    try comp.writer().writeAll(data);
    try comp.finish();
    const adler = std.hash.Adler32.hash(data);
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler, .big);
    try out.appendSlice(&adler_bytes);
    return out.toOwnedSlice();
}

fn zlibDecompress(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    // skip 2-byte zlib header, ignore trailing adler32
    var fbs = std.io.fixedBufferStream(data[2..]);
    var decomp = std.compress.flate.decompressor(fbs.reader());
    return decomp.reader().readAllAlloc(alloc, 64 * 1024 * 1024);
}

fn writePacket(alloc: std.mem.Allocator, packet_id: i32, payload: []const u8, compression_threshold: i32) ![]u8 {
    var id_and_payload = std.ArrayList(u8).init(alloc);
    defer id_and_payload.deinit();
    try writeVarInt(&id_and_payload, packet_id);
    try id_and_payload.appendSlice(payload);

    var out = std.ArrayList(u8).init(alloc);
    if (compression_threshold < 0) {
        try writeVarInt(&out, @intCast(id_and_payload.items.len));
        try out.appendSlice(id_and_payload.items);
        return out.toOwnedSlice();
    }

    var inner = std.ArrayList(u8).init(alloc);
    defer inner.deinit();
    if (id_and_payload.items.len >= @as(usize, @intCast(compression_threshold))) {
        const compressed = try zlibCompress(alloc, id_and_payload.items);
        defer alloc.free(compressed);
        try writeVarInt(&inner, @intCast(id_and_payload.items.len));
        try inner.appendSlice(compressed);
    } else {
        try writeVarInt(&inner, 0);
        try inner.appendSlice(id_and_payload.items);
    }
    try writeVarInt(&out, @intCast(inner.items.len));
    try out.appendSlice(inner.items);
    return out.toOwnedSlice();
}

fn recvExact(stream: std.net.Stream, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const n = try stream.read(buf[read..]);
        if (n == 0) return error.ConnectionClosed;
        read += n;
    }
}

fn recvVarIntFromStream(stream: std.net.Stream) !i32 {
    var raw: [5]u8 = undefined;
    var len: usize = 0;
    while (true) {
        var b: [1]u8 = undefined;
        const n = try stream.read(&b);
        if (n == 0) return error.ConnectionClosed;
        raw[len] = b[0];
        len += 1;
        if ((b[0] & 0x80) == 0) break;
        if (len > 5) return error.VarIntTooLong;
    }
    const r = try readVarInt(raw[0..len], 0);
    return r.value;
}

const RecvPacketResult = struct { packet_id: i32, data: []u8, offset: usize };

fn recvPacket(alloc: std.mem.Allocator, stream: std.net.Stream, compression_threshold: i32) !RecvPacketResult {
    const packet_len = try recvVarIntFromStream(stream);
    const raw = try alloc.alloc(u8, @intCast(packet_len));
    try recvExact(stream, raw);

    var data = raw;
    if (compression_threshold >= 0) {
        const r = try readVarInt(data, 0);
        if (r.value > 0) {
            const decompressed = try zlibDecompress(alloc, data[r.offset..]);
            alloc.free(raw);
            data = decompressed;
        } else {
            data = try alloc.dupe(u8, data[r.offset..]);
            alloc.free(raw);
        }
    }
    const idr = try readVarInt(data, 0);
    return .{ .packet_id = idr.value, .data = data, .offset = idr.offset };
}

// ============================================================================
// BLOCS
// ============================================================================

const BlockColor = struct { has: bool = false, r: f32 = 0, g: f32 = 0, b: f32 = 0 };

fn bc(r: f32, g: f32, b: f32) BlockColor {
    return .{ .has = true, .r = r, .g = g, .b = b };
}

var BLOCK_COLORS: [256]BlockColor = blk: {
    var arr: [256]BlockColor = [_]BlockColor{.{}} ** 256;
    arr[1] = bc(0.5, 0.5, 0.5);
    arr[2] = bc(0.3, 0.6, 0.2);
    arr[3] = bc(0.55, 0.35, 0.1);
    arr[4] = bc(0.6, 0.6, 0.6);
    arr[5] = bc(0.7, 0.5, 0.3);
    arr[7] = bc(0.2, 0.2, 0.2);
    arr[8] = bc(0.2, 0.3, 0.8);
    arr[9] = bc(0.2, 0.3, 0.8);
    arr[10] = bc(0.9, 0.4, 0.0);
    arr[11] = bc(0.9, 0.4, 0.0);
    arr[12] = bc(0.85, 0.8, 0.55);
    arr[13] = bc(0.5, 0.5, 0.5);
    arr[14] = bc(0.5, 0.5, 0.3);
    arr[15] = bc(0.5, 0.5, 0.5);
    arr[16] = bc(0.3, 0.3, 0.3);
    arr[17] = bc(0.5, 0.35, 0.15);
    arr[18] = bc(0.2, 0.6, 0.2);
    arr[24] = bc(0.85, 0.8, 0.55);
    arr[31] = bc(0.3, 0.7, 0.2);
    arr[35] = bc(0.9, 0.9, 0.9);
    arr[41] = bc(0.9, 0.8, 0.2);
    arr[42] = bc(0.7, 0.7, 0.7);
    arr[43] = bc(0.6, 0.6, 0.6);
    arr[44] = bc(0.6, 0.6, 0.6);
    arr[45] = bc(0.7, 0.4, 0.3);
    arr[48] = bc(0.3, 0.4, 0.3);
    arr[49] = bc(0.15, 0.1, 0.25);
    arr[52] = bc(0.1, 0.1, 0.3);
    arr[53] = bc(0.7, 0.5, 0.3);
    arr[56] = bc(0.4, 0.7, 0.8);
    arr[57] = bc(0.5, 0.9, 0.9);
    arr[60] = bc(0.55, 0.35, 0.1);
    arr[64] = bc(0.7, 0.5, 0.3);
    arr[73] = bc(0.5, 0.2, 0.2);
    arr[74] = bc(0.5, 0.2, 0.2);
    arr[78] = bc(0.95, 0.95, 1.0);
    arr[79] = bc(0.7, 0.85, 0.95);
    arr[80] = bc(0.95, 0.95, 1.0);
    arr[82] = bc(0.6, 0.6, 0.7);
    arr[85] = bc(0.7, 0.5, 0.3);
    arr[86] = bc(0.85, 0.45, 0.1);
    arr[87] = bc(0.7, 0.3, 0.2);
    arr[89] = bc(0.9, 0.8, 0.5);
    arr[98] = bc(0.6, 0.6, 0.6);
    arr[116] = bc(0.3, 0.2, 0.5);
    break :blk arr;
};

fn getBlockColor(id: u16) [3]f32 {
    if (id < 256 and BLOCK_COLORS[id].has) {
        const c = BLOCK_COLORS[id];
        return .{ c.r, c.g, c.b };
    }
    return .{ 0.55, 0.55, 0.55 };
}

const NON_CUBE_LIST = [_]u16{ 6, 8, 9, 10, 11, 27, 28, 30, 31, 32, 37, 38, 39, 40, 50, 51, 55, 59, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 75, 76, 77, 78, 83, 85, 90, 93, 94, 96, 104, 105, 106, 107, 108, 109, 111, 113, 114, 115, 117, 118, 119, 120, 127, 131, 141, 142, 143 };

var JAVA_NON_CUBE: [4096]bool = blk: {
    var arr: [4096]bool = [_]bool{false} ** 4096;
    for (NON_CUBE_LIST) |id| arr[id] = true;
    break :blk arr;
};

fn isNonCube(id: u16) bool {
    return id < 4096 and JAVA_NON_CUBE[id];
}

const TerrainTile = struct { id: u16, tx: i32, ty: i32 };
const JAVA_TERRAIN_TILES = [_]TerrainTile{
    .{ .id = 1, .tx = 0, .ty = 0 },
    .{ .id = 2, .tx = 1, .ty = 0 },
    .{ .id = 3, .tx = 2, .ty = 0 },
    .{ .id = 4, .tx = 7, .ty = 0 },
    .{ .id = 5, .tx = 4, .ty = 0 },
    .{ .id = 7, .tx = 7, .ty = 0 },
    .{ .id = 12, .tx = 6, .ty = 0 },
    .{ .id = 17, .tx = 3, .ty = 0 },
    .{ .id = 18, .tx = 5, .ty = 0 },
    .{ .id = 43, .tx = 7, .ty = 0 },
    .{ .id = 44, .tx = 0, .ty = 0 },
    .{ .id = 48, .tx = 7, .ty = 0 },
    .{ .id = 53, .tx = 4, .ty = 0 },
    .{ .id = 60, .tx = 2, .ty = 0 },
    .{ .id = 64, .tx = 4, .ty = 0 },
    .{ .id = 85, .tx = 4, .ty = 0 },
    .{ .id = 98, .tx = 7, .ty = 0 },
};

fn findTerrainTile(id: u16) ?TerrainTile {
    for (JAVA_TERRAIN_TILES) |t| {
        if (t.id == id) return t;
    }
    return null;
}

fn blockCoord(v: f64) i64 {
    return @intFromFloat(@floor(v));
}

fn getNibble(arr: []const u8, index: usize) u8 {
    const byte = arr[index >> 1];
    if ((index & 1) != 0) return (byte >> 4) & 0xF;
    return byte & 0xF;
}

// ============================================================================
// DECODAGE CHUNK 1.8
// ============================================================================

const Pos3 = struct { x: i32, y: i32, z: i32 };

fn decodeChunkData18(
    alloc: std.mem.Allocator,
    data: []const u8,
    primary_bitmask: u16,
    add_bitmask: u16,
    ground_up: bool,
    overworld: bool,
    chunk_x: i32,
    chunk_z: i32,
    out_blocks: *std.AutoHashMap(Pos3, u16),
) !void {
    _ = ground_up;
    var offset: usize = 0;
    var present_sections = std.ArrayList(u4).init(alloc);
    defer present_sections.deinit();
    var sy: u5 = 0;
    while (sy < 16) : (sy += 1) {
        if (((primary_bitmask >> @intCast(sy)) & 1) != 0) try present_sections.append(@intCast(sy));
    }

    var section_payloads = std.AutoHashMap(u4, []const u8).init(alloc);
    defer section_payloads.deinit();
    for (present_sections.items) |section_y| {
        try section_payloads.put(section_y, data[offset .. offset + 8192]);
        offset += 8192;
    }

    offset += present_sections.items.len * 2048; // block light
    if (overworld) offset += present_sections.items.len * 2048; // sky light

    var add_arrays = std.AutoHashMap(u4, []const u8).init(alloc);
    defer add_arrays.deinit();
    sy = 0;
    while (sy < 16) : (sy += 1) {
        if (((add_bitmask >> @intCast(sy)) & 1) != 0) {
            try add_arrays.put(@intCast(sy), data[offset .. offset + 2048]);
            offset += 2048;
        }
    }
    // biomes (256) suivent si ground_up, on n'en a pas besoin ensuite.

    for (present_sections.items) |section_y| {
        const packed_blocks = section_payloads.get(section_y).?;
        const add_arr = add_arrays.get(section_y);
        var i: usize = 0;
        while (i < 4096) : (i += 1) {
            const low = packed_blocks[i * 2];
            const high = packed_blocks[i * 2 + 1];
            var bid: u16 = (@as(u16, high) << 4) | (@as(u16, (low >> 4) & 0x0F));
            if (add_arr) |arr| {
                bid |= @as(u16, getNibble(arr, i)) << 8;
            }
            if (bid == 0) continue;

            const bx_local: i32 = @intCast(i & 0xF);
            const bz_local: i32 = @intCast((i >> 4) & 0xF);
            const by_local: i32 = @intCast(i >> 8);
            const world_x = chunk_x * 16 + bx_local;
            const world_y = @as(i32, section_y) * 16 + by_local;
            const world_z = chunk_z * 16 + bz_local;
            try out_blocks.put(.{ .x = world_x, .y = world_y, .z = world_z }, bid);
        }
    }
}

// ============================================================================
// AABB
// ============================================================================

const AABB = struct {
    x0: f64,
    y0: f64,
    z0: f64,
    x1: f64,
    y1: f64,
    z1: f64,
    eps: f64 = 0.01,

    fn init(x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) AABB {
        return .{ .x0 = x0, .y0 = y0, .z0 = z0, .x1 = x1, .y1 = y1, .z1 = z1 };
    }

    fn clipX(self: AABB, c: AABB, xa_in: f64) f64 {
        var xa = xa_in;
        if (c.y1 <= self.y0 or c.y0 >= self.y1 or c.z1 <= self.z0 or c.z0 >= self.z1) return xa;
        if (xa > 0 and c.x1 <= self.x0) {
            const v = self.x0 - c.x1 - self.eps;
            if (v < xa) xa = v;
        }
        if (xa < 0 and c.x0 >= self.x1) {
            const v = self.x1 - c.x0 + self.eps;
            if (v > xa) xa = v;
        }
        return xa;
    }

    fn clipY(self: AABB, c: AABB, ya_in: f64) f64 {
        var ya = ya_in;
        if (c.x1 <= self.x0 or c.x0 >= self.x1 or c.z1 <= self.z0 or c.z0 >= self.z1) return ya;
        if (ya > 0 and c.y1 <= self.y0) {
            const v = self.y0 - c.y1 - self.eps;
            if (v < ya) ya = v;
        }
        if (ya < 0 and c.y0 >= self.y1) {
            const v = self.y1 - c.y0 + self.eps;
            if (v > ya) ya = v;
        }
        return ya;
    }

    fn clipZ(self: AABB, c: AABB, za_in: f64) f64 {
        var za = za_in;
        if (c.x1 <= self.x0 or c.x0 >= self.x1 or c.y1 <= self.y0 or c.y0 >= self.y1) return za;
        if (za > 0 and c.z1 <= self.z0) {
            const v = self.z0 - c.z1 - self.eps;
            if (v < za) za = v;
        }
        if (za < 0 and c.z0 >= self.z1) {
            const v = self.z1 - c.z0 + self.eps;
            if (v > za) za = v;
        }
        return za;
    }

    fn move(self: *AABB, xa: f64, ya: f64, za: f64) void {
        self.x0 += xa;
        self.y0 += ya;
        self.z0 += za;
        self.x1 += xa;
        self.y1 += ya;
        self.z1 += za;
    }
};

// ============================================================================
// LEVEL
// ============================================================================

const Level = struct {
    w: i32,
    d: i32,
    h: i32,
    blocks: []u8,
    java_mode: bool = false,
    java_blocks: std.AutoHashMap(Pos3, u16),
    java_lock: std.Thread.Mutex = .{},
    java_terrain_tex: ?ray.Texture2D = null,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, w: i32, d: i32, h: i32) !Level {
        const blocks = try alloc.alloc(u8, @intCast(w * d * h));
        @memset(blocks, 0);
        var lvl = Level{ .w = w, .d = d, .h = h, .blocks = blocks, .java_blocks = std.AutoHashMap(Pos3, u16).init(alloc), .alloc = alloc };
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            var z: i32 = 0;
            while (z < h) : (z += 1) {
                var y: i32 = 0;
                while (y < 30) : (y += 1) lvl.setSolo(x, y, z, 1);
                y = 30;
                while (y < 32) : (y += 1) lvl.setSolo(x, y, z, 2);
            }
        }
        return lvl;
    }

    fn deinit(self: *Level) void {
        self.alloc.free(self.blocks);
        self.java_blocks.deinit();
    }

    fn idx(self: *const Level, x: i32, y: i32, z: i32) usize {
        return @intCast((x * self.d + y) * self.h + z);
    }

    fn setSolo(self: *Level, x: i32, y: i32, z: i32, v: u8) void {
        if (x < 0 or x >= self.w or y < 0 or y >= self.d or z < 0 or z >= self.h) return;
        self.blocks[self.idx(x, y, z)] = v;
    }

    fn getSolo(self: *const Level, x: i32, y: i32, z: i32) u8 {
        if (x < 0 or x >= self.w or y < 0 or y >= self.d or z < 0 or z >= self.h) return 0;
        return self.blocks[self.idx(x, y, z)];
    }

    fn getBlock(self: *Level, x: f64, y: f64, z: f64) u16 {
        if (self.java_mode) {
            const p = Pos3{ .x = @intCast(blockCoord(x)), .y = @intCast(blockCoord(y)), .z = @intCast(blockCoord(z)) };
            return self.java_blocks.get(p) orelse 0;
        }
        return self.getSolo(@intFromFloat(@floor(x)), @intFromFloat(@floor(y)), @intFromFloat(@floor(z)));
    }

    fn isSolid(self: *Level, x: f64, y: f64, z: f64) bool {
        if (self.java_mode) {
            const bid = self.getBlock(x, y, z);
            return bid > 0 and !isNonCube(bid);
        }
        return self.getSolo(@intFromFloat(@floor(x)), @intFromFloat(@floor(y)), @intFromFloat(@floor(z))) > 0;
    }

    fn javaChunkKey(x: i32, y: i32, z: i32) Pos3 {
        return .{
            .x = @divFloor(x, CHUNK_SIZE_RENDER) * CHUNK_SIZE_RENDER,
            .y = @divFloor(y, CHUNK_SIZE_RENDER) * CHUNK_SIZE_RENDER,
            .z = @divFloor(z, CHUNK_SIZE_RENDER) * CHUNK_SIZE_RENDER,
        };
    }
};

// ============================================================================
// PLAYER
// ============================================================================

const Player = struct {
    x: f64 = 64.0,
    y: f64 = 35.0,
    z: f64 = 64.0,
    xd: f64 = 0,
    yd: f64 = 0,
    zd: f64 = 0,
    yRot: f64 = 0,
    xRot: f64 = 0,
    bb: AABB,
    onGround: bool = false,

    fn init() Player {
        var p = Player{ .bb = undefined };
        p.bb = AABB.init(p.x - 0.3, p.y - 1.6, p.z - 0.3, p.x + 0.3, p.y + 0.2, p.z + 0.3);
        return p;
    }

    fn tick(self: *Player, level: *Level, ignore_input: bool) void {
        var xa: f64 = 0;
        var za: f64 = 0;
        if (!ignore_input) {
            if (ray.IsKeyDown(ray.KEY_W) or ray.IsKeyDown(ray.KEY_Z)) za -= 1;
            if (ray.IsKeyDown(ray.KEY_S)) za += 1;
            if (ray.IsKeyDown(ray.KEY_A) or ray.IsKeyDown(ray.KEY_Q)) xa -= 1;
            if (ray.IsKeyDown(ray.KEY_D)) xa += 1;
            if (ray.IsKeyDown(ray.KEY_SPACE) and self.onGround) self.yd = 0.12;
        }
        const speed: f64 = if (self.onGround) 0.04 else 0.02;
        const m = @sqrt(xa * xa + za * za);
        if (m > 0.01) {
            xa *= speed / m;
            za *= speed / m;
            const s = @sin(std.math.degreesToRadians(self.yRot));
            const c = @cos(std.math.degreesToRadians(self.yRot));
            self.xd += xa * c - za * s;
            self.zd += za * c + xa * s;
        }
        self.yd -= 0.005;
        self.move(level, self.xd, self.yd, self.zd);
        self.xd *= 0.91;
        self.yd *= 0.98;
        self.zd *= 0.91;
        if (self.onGround) {
            self.xd *= 0.7;
            self.zd *= 0.7;
        }
    }

    fn move(self: *Player, level: *Level, xa_in: f64, ya_in: f64, za_in: f64) void {
        var xa = xa_in;
        var ya = ya_in;
        var za = za_in;
        const yO = ya;

        var cubes = std.ArrayList(AABB).init(galloc);
        defer cubes.deinit();

        var ix: i32 = @intFromFloat(@floor(self.bb.x0 - 1));
        const ix1: i32 = @intFromFloat(@floor(self.bb.x1 + 2));
        while (ix < ix1) : (ix += 1) {
            var iy: i32 = @intFromFloat(@floor(self.bb.y0 - 1));
            const iy1: i32 = @intFromFloat(@floor(self.bb.y1 + 2));
            while (iy < iy1) : (iy += 1) {
                var iz: i32 = @intFromFloat(@floor(self.bb.z0 - 1));
                const iz1: i32 = @intFromFloat(@floor(self.bb.z1 + 2));
                while (iz < iz1) : (iz += 1) {
                    if (level.isSolid(@floatFromInt(ix), @floatFromInt(iy), @floatFromInt(iz))) {
                        cubes.append(AABB.init(@floatFromInt(ix), @floatFromInt(iy), @floatFromInt(iz), @floatFromInt(ix + 1), @floatFromInt(iy + 1), @floatFromInt(iz + 1))) catch {};
                    }
                }
            }
        }

        for (cubes.items) |c| ya = c.clipY(self.bb, ya);
        self.bb.move(0, ya, 0);
        for (cubes.items) |c| xa = c.clipX(self.bb, xa);
        self.bb.move(xa, 0, 0);
        for (cubes.items) |c| za = c.clipZ(self.bb, za);
        self.bb.move(0, 0, za);

        self.onGround = (yO != ya and yO < 0);
        if (yO != ya) self.yd = 0;
        self.x = (self.bb.x0 + self.bb.x1) / 2;
        self.y = self.bb.y0 + 1.62;
        self.z = (self.bb.z0 + self.bb.z1) / 2;
    }
};

// ============================================================================
// CHUNK MESH (remplace les display lists OpenGL par un vrai vertex buffer)
// ============================================================================

const MeshBuilder = struct {
    positions: std.ArrayList(f32),
    texcoords: std.ArrayList(f32),
    colors: std.ArrayList(u8),
    indices: std.ArrayList(u16),
    vcount: u16 = 0,

    fn init(alloc: std.mem.Allocator) MeshBuilder {
        return .{
            .positions = std.ArrayList(f32).init(alloc),
            .texcoords = std.ArrayList(f32).init(alloc),
            .colors = std.ArrayList(u8).init(alloc),
            .indices = std.ArrayList(u16).init(alloc),
        };
    }

    fn deinit(self: *MeshBuilder) void {
        self.positions.deinit();
        self.texcoords.deinit();
        self.colors.deinit();
        self.indices.deinit();
    }

    fn pushQuad(self: *MeshBuilder, v: [4][3]f32, uv: [4][2]f32, shade: f32) !void {
        const base = self.vcount;
        const r: u8 = @intFromFloat(@min(255.0, shade * 255.0));
        for (0..4) |i| {
            try self.positions.appendSlice(&v[i]);
            try self.texcoords.appendSlice(&uv[i]);
            try self.colors.appendSlice(&[4]u8{ r, r, r, 255 });
        }
        try self.indices.appendSlice(&[6]u16{ base, base + 1, base + 2, base, base + 2, base + 3 });
        self.vcount += 4;
    }

    fn pushQuadColor(self: *MeshBuilder, v: [4][3]f32, col: [3]f32) !void {
        const base = self.vcount;
        const cr: u8 = @intFromFloat(@min(255.0, col[0] * 255.0));
        const cg: u8 = @intFromFloat(@min(255.0, col[1] * 255.0));
        const cb: u8 = @intFromFloat(@min(255.0, col[2] * 255.0));
        for (0..4) |i| {
            try self.positions.appendSlice(&v[i]);
            try self.texcoords.appendSlice(&[2]f32{ 0, 0 });
            try self.colors.appendSlice(&[4]u8{ cr, cg, cb, 255 });
        }
        try self.indices.appendSlice(&[6]u16{ base, base + 1, base + 2, base, base + 2, base + 3 });
        self.vcount += 4;
    }

    fn toModel(self: *MeshBuilder, texture: ?ray.Texture2D) ?ray.Model {
        if (self.vcount == 0) return null;
        var mesh: ray.Mesh = std.mem.zeroes(ray.Mesh);
        mesh.vertexCount = @intCast(self.vcount);
        mesh.triangleCount = @intCast(self.indices.items.len / 3);
        mesh.vertices = @ptrCast(@alignCast(ray.MemAlloc(@intCast(self.positions.items.len * @sizeOf(f32)))));
        @memcpy(mesh.vertices[0..self.positions.items.len], self.positions.items);
        mesh.texcoords = @ptrCast(@alignCast(ray.MemAlloc(@intCast(self.texcoords.items.len * @sizeOf(f32)))));
        @memcpy(mesh.texcoords[0..self.texcoords.items.len], self.texcoords.items);
        mesh.colors = @ptrCast(ray.MemAlloc(@intCast(self.colors.items.len)));
        @memcpy(mesh.colors[0..self.colors.items.len], self.colors.items);
        mesh.indices = @ptrCast(@alignCast(ray.MemAlloc(@intCast(self.indices.items.len * @sizeOf(u16)))));
        @memcpy(mesh.indices[0..self.indices.items.len], self.indices.items);
        ray.UploadMesh(&mesh, false);
        var model = ray.LoadModelFromMesh(mesh);
        if (texture) |t| {
            model.materials[0].maps[ray.MATERIAL_MAP_DIFFUSE].texture = t;
        }
        return model;
    }
};

const Chunk = struct {
    pos: Pos3,
    model: ?ray.Model = null,
    model_colored: ?ray.Model = null,
    dirty: bool = true,

    fn unload(self: *Chunk) void {
        if (self.model) |m| {
            ray.UnloadModel(m);
            self.model = null;
        }
    }

    // Reconstruit le mesh. Mode solo: lit level.blocks (array fixe).
    // Mode java: scanne level.java_blocks (hashmap sparse) sur les 16x16x16
    // locaux du chunk (remplace le double-cache Python par un scan direct).
    fn build(self: *Chunk, level: *Level, atlas: ray.Texture2D) void {
        self.unload();
        var mb = MeshBuilder.init(galloc);
        defer mb.deinit();
        var mb_col = MeshBuilder.init(galloc);
        defer mb_col.deinit();

        const x0 = self.pos.x;
        const y0 = self.pos.y;
        const z0 = self.pos.z;

        if (level.java_mode) {
            level.java_lock.lock();
            defer level.java_lock.unlock();
            var x: i32 = x0;
            while (x < x0 + CHUNK_SIZE_RENDER) : (x += 1) {
                var y: i32 = y0;
                while (y < y0 + CHUNK_SIZE_RENDER) : (y += 1) {
                    var z: i32 = z0;
                    while (z < z0 + CHUNK_SIZE_RENDER) : (z += 1) {
                        const bid = level.java_blocks.get(.{ .x = x, .y = y, .z = z }) orelse 0;
                        if (bid == 0 or isNonCube(bid)) continue;
                        emitJavaBlock(&mb, &mb_col, level, x, y, z, bid);
                    }
                }
            }
        } else {
            var x: i32 = x0;
            while (x < @min(x0 + CHUNK_SIZE_RENDER, level.w)) : (x += 1) {
                var y: i32 = y0;
                while (y < @min(y0 + CHUNK_SIZE_RENDER, level.d)) : (y += 1) {
                    var z: i32 = z0;
                    while (z < @min(z0 + CHUNK_SIZE_RENDER, level.h)) : (z += 1) {
                        const b = level.getSolo(x, y, z);
                        if (b == 0) continue;
                        emitSoloBlock(&mb, level, x, y, z, b);
                    }
                }
            }
        }

        // fusion: on dessine d'abord le mesh texturé puis le colorié, dans le
        // même Model via deux sous-meshes n'est pas trivial avec LoadModelFromMesh
        // (1 mesh = 1 matériau); on stocke donc 2 models par Chunk.
        self.model = mb.toModel(atlas);
        self.model_colored = mb_col.toModel(null);
        self.dirty = false;
    }

    fn unloadAll(self: *Chunk) void {
        self.unload();
        if (self.model_colored) |m| {
            ray.UnloadModel(m);
            self.model_colored = null;
        }
    }
};

fn faceUV(u_start: f32, v_start: f32, u_end: f32, v_end: f32) [4][2]f32 {
    return .{ .{ u_start, v_start }, .{ u_end, v_start }, .{ u_end, v_end }, .{ u_start, v_end } };
}

fn emitSoloBlock(mb: *MeshBuilder, level: *Level, x: i32, y: i32, z: i32, b: u8) void {
    const s: f32 = 0.0625;
    const u: f32 = @as(f32, @floatFromInt(b - 1)) * s;
    const v: f32 = 1.0 - s;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fz: f32 = @floatFromInt(z);

    if (!level.isSolid(fx, fy + 1, fz)) {
        mb.pushQuad(.{ .{ fx, fy + 1, fz }, .{ fx, fy + 1, fz + 1 }, .{ fx + 1, fy + 1, fz + 1 }, .{ fx + 1, fy + 1, fz } }, faceUV(u, v + s, u + s, v), 1.0) catch {};
    }
    if (!level.isSolid(fx, fy - 1, fz)) {
        mb.pushQuad(.{ .{ fx + 1, fy, fz }, .{ fx + 1, fy, fz + 1 }, .{ fx, fy, fz + 1 }, .{ fx, fy, fz } }, faceUV(u + s, v, u, v + s), 0.6) catch {};
    }
    if (!level.isSolid(fx, fy, fz + 1)) {
        mb.pushQuad(.{ .{ fx, fy, fz + 1 }, .{ fx + 1, fy, fz + 1 }, .{ fx + 1, fy + 1, fz + 1 }, .{ fx, fy + 1, fz + 1 } }, faceUV(u, v, u + s, v + s), 0.8) catch {};
    }
    if (!level.isSolid(fx, fy, fz - 1)) {
        mb.pushQuad(.{ .{ fx + 1, fy, fz }, .{ fx, fy, fz }, .{ fx, fy + 1, fz }, .{ fx + 1, fy + 1, fz } }, faceUV(u + s, v, u, v + s), 0.8) catch {};
    }
    if (!level.isSolid(fx + 1, fy, fz)) {
        mb.pushQuad(.{ .{ fx + 1, fy, fz + 1 }, .{ fx + 1, fy, fz }, .{ fx + 1, fy + 1, fz }, .{ fx + 1, fy + 1, fz + 1 } }, faceUV(u + s, v, u, v + s), 0.7) catch {};
    }
    if (!level.isSolid(fx - 1, fy, fz)) {
        mb.pushQuad(.{ .{ fx, fy, fz }, .{ fx, fy, fz + 1 }, .{ fx, fy + 1, fz + 1 }, .{ fx, fy + 1, fz } }, faceUV(u, v, u + s, v + s), 0.7) catch {};
    }
}

fn emitJavaBlock(mb: *MeshBuilder, mb_col: *MeshBuilder, level: *Level, x: i32, y: i32, z: i32, bid: u16) void {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fz: f32 = @floatFromInt(z);
    const col = getBlockColor(bid);
    const tile = findTerrainTile(bid);

    var uv: [4][2]f32 = undefined;
    if (tile) |t| {
        const u_start = @as(f32, @floatFromInt(t.tx)) / 16.0;
        const v_start = @as(f32, @floatFromInt(t.ty)) / 16.0;
        uv = faceUV(u_start, v_start, u_start + 1.0 / 16.0, v_start + 1.0 / 16.0);
    }

    const faces = struct {
        fn emit(mbt: *MeshBuilder, mbc: *MeshBuilder, useTex: bool, verts: [4][3]f32, shade: f32, c: [3]f32, u: [4][2]f32) void {
            if (useTex) {
                mbt.pushQuad(verts, u, shade) catch {};
            } else {
                mbc.pushQuadColor(verts, .{ c[0] * shade, c[1] * shade, c[2] * shade }) catch {};
            }
        }
    };

    const useTex = tile != null;

    if (!level.isSolid(fx, fy + 1, fz)) {
        faces.emit(mb, mb_col, useTex, .{ .{ fx, fy + 1, fz }, .{ fx, fy + 1, fz + 1 }, .{ fx + 1, fy + 1, fz + 1 }, .{ fx + 1, fy + 1, fz } }, 1.0, col, uv);
    }
    if (!level.isSolid(fx, fy - 1, fz)) {
        faces.emit(mb, mb_col, useTex, .{ .{ fx + 1, fy, fz }, .{ fx + 1, fy, fz + 1 }, .{ fx, fy, fz + 1 }, .{ fx, fy, fz } }, 0.5, col, uv);
    }
    if (!level.isSolid(fx, fy, fz + 1)) {
        faces.emit(mb, mb_col, useTex, .{ .{ fx, fy, fz + 1 }, .{ fx + 1, fy, fz + 1 }, .{ fx + 1, fy + 1, fz + 1 }, .{ fx, fy + 1, fz + 1 } }, 0.8, col, uv);
    }
    if (!level.isSolid(fx, fy, fz - 1)) {
        faces.emit(mb, mb_col, useTex, .{ .{ fx + 1, fy, fz }, .{ fx, fy, fz }, .{ fx, fy + 1, fz }, .{ fx + 1, fy + 1, fz } }, 0.8, col, uv);
    }
    if (!level.isSolid(fx + 1, fy, fz)) {
        faces.emit(mb, mb_col, useTex, .{ .{ fx + 1, fy, fz + 1 }, .{ fx + 1, fy, fz }, .{ fx + 1, fy + 1, fz }, .{ fx + 1, fy + 1, fz + 1 } }, 0.6, col, uv);
    }
    if (!level.isSolid(fx - 1, fy, fz)) {
        faces.emit(mb, mb_col, useTex, .{ .{ fx, fy, fz }, .{ fx, fy, fz + 1 }, .{ fx, fy + 1, fz + 1 }, .{ fx, fy + 1, fz } }, 0.6, col, uv);
    }
}

// ============================================================================
// CLIENT MINECRAFT JAVA 1.8
// ============================================================================

const RemotePlayer = struct { x: f64, y: f64, z: f64, yaw: f32, pitch: f32, head_yaw: f32 };

const DirtyChunkSet = std.AutoHashMap(Pos3, void);

const MinecraftJavaClient = struct {
    host: []const u8,
    port: u16,
    username: []const u8,
    level: *Level,
    player: *Player,
    alloc: std.mem.Allocator,

    stream: ?std.net.Stream = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    spawned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    compression_threshold: i32 = -1,
    entity_id: i32 = 0,
    gamemode: u8 = 0,
    held_slot: i16 = 0,
    chunks_received: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_chunk_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    entity_lock: std.Thread.Mutex = .{},
    remote_players: std.AutoHashMap(i32, RemotePlayer),

    dirty_lock: std.Thread.Mutex = .{},
    dirty_chunks: DirtyChunkSet,

    status_lock: std.Thread.Mutex = .{},
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,

    thread: ?std.Thread = null,

    fn init(alloc: std.mem.Allocator, host: []const u8, port: u16, username: []const u8, level: *Level, player: *Player) !*MinecraftJavaClient {
        const self = try alloc.create(MinecraftJavaClient);
        self.* = .{
            .host = try alloc.dupe(u8, host),
            .port = port,
            .username = try alloc.dupe(u8, username),
            .level = level,
            .player = player,
            .alloc = alloc,
            .remote_players = std.AutoHashMap(i32, RemotePlayer).init(alloc),
            .dirty_chunks = DirtyChunkSet.init(alloc),
        };
        self.setStatus("Not connected");
        return self;
    }

    fn setStatus(self: *MinecraftJavaClient, msg: []const u8) void {
        self.status_lock.lock();
        defer self.status_lock.unlock();
        const n = @min(msg.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], msg[0..n]);
        self.status_len = n;
        std.debug.print("[JAVA] {s}\n", .{msg});
    }

    fn getStatus(self: *MinecraftJavaClient, out: []u8) []u8 {
        self.status_lock.lock();
        defer self.status_lock.unlock();
        const n = @min(self.status_len, out.len);
        @memcpy(out[0..n], self.status_buf[0..n]);
        return out[0..n];
    }

    fn connect(self: *MinecraftJavaClient) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, runThread, .{self});
        self.thread.?.detach();
    }

    fn send(self: *MinecraftJavaClient, packet_id: i32, payload: []const u8) !void {
        const packet = try writePacket(self.alloc, packet_id, payload, self.compression_threshold);
        defer self.alloc.free(packet);
        try self.stream.?.writeAll(packet);
    }

    fn runThread(self: *MinecraftJavaClient) void {
        self.doRun() catch |e| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{@errorName(e)}) catch "Error";
            self.setStatus(msg);
            self.connected.store(false, .seq_cst);
        };
    }

    fn doRun(self: *MinecraftJavaClient) !void {
        var buf: [128]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "Connecting to {s}:{d}...", .{ self.host, self.port }) catch "Connecting...");

        const addr_list = try std.net.getAddressList(self.alloc, self.host, self.port);
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return error.NoAddress;
        const stream = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
        self.stream = stream;
        self.setStatus("Connected! Handshake...");

        try self.sendHandshake();
        try self.sendLoginStart();
        try self.loginLoop();
    }

    fn sendHandshake(self: *MinecraftJavaClient) !void {
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try writeVarInt(&payload, 47);
        try writeString(&payload, self.host);
        var port_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &port_bytes, self.port, .big);
        try payload.appendSlice(&port_bytes);
        try writeVarInt(&payload, 2);
        const packet = try writePacket(self.alloc, 0x00, payload.items, -1);
        defer self.alloc.free(packet);
        try self.stream.?.writeAll(packet);
    }

    fn sendLoginStart(self: *MinecraftJavaClient) !void {
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try writeString(&payload, self.username);
        const packet = try writePacket(self.alloc, 0x00, payload.items, -1);
        defer self.alloc.free(packet);
        try self.stream.?.writeAll(packet);
    }

    fn loginLoop(self: *MinecraftJavaClient) !void {
        while (true) {
            const pk = try recvPacket(self.alloc, self.stream.?, self.compression_threshold);
            defer self.alloc.free(pk.data);
            if (pk.packet_id == 0x03) {
                const r = try readVarInt(pk.data, pk.offset);
                self.compression_threshold = r.value;
                var b: [64]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&b, "Compression enabled (threshold={d})", .{r.value}) catch "Compression enabled");
            } else if (pk.packet_id == 0x02) {
                self.setStatus("Login OK");
                try self.playLoop();
                return;
            } else if (pk.packet_id == 0x01) {
                self.setStatus("ERROR: Server needs online-mode=false");
                return;
            } else if (pk.packet_id == 0x00) {
                const r = try readString(self.alloc, pk.data, pk.offset);
                defer self.alloc.free(r.value);
                var b: [128]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&b, "Rejected: {s}", .{r.value[0..@min(80, r.value.len)]}) catch "Rejected");
                return;
            }
        }
    }

    fn playLoop(self: *MinecraftJavaClient) !void {
        self.connected.store(true, .seq_cst);
        self.setStatus("In game! Loading chunks...");
        self.level.java_mode = true;


        var last_pos_send = std.time.milliTimestamp();

        while (self.running.load(.seq_cst)) {
            const pk = recvPacket(self.alloc, self.stream.?, self.compression_threshold) catch |e| {
                if (e == error.WouldBlock) {
                    self.tickPositionSend(&last_pos_send);
                    continue;
                }
                return e;
            };
            defer self.alloc.free(pk.data);
            self.handlePacket(pk) catch |e| {
                std.debug.print("[PLAY_LOOP ERROR] 0x{X}: {s}\n", .{ pk.packet_id, @errorName(e) });
            };
            self.tickPositionSend(&last_pos_send);
        }
    }

    fn tickPositionSend(self: *MinecraftJavaClient, last_pos_send: *i64) void {
        const now = std.time.milliTimestamp();
        if (self.spawned.load(.seq_cst) and (now - last_pos_send.*) > 100) {
            self.sendPosition(self.player.x, self.player.y, self.player.z, @floatCast(self.player.yRot), @floatCast(self.player.xRot)) catch {};
            last_pos_send.* = now;
        }
    }

    fn handlePacket(self: *MinecraftJavaClient, pk: RecvPacketResult) !void {
        var off = pk.offset;
        switch (pk.packet_id) {
            0x01 => { // Join Game
                self.entity_id = std.mem.readInt(i32, pk.data[off..][0..4], .big);
                off += 4;
                self.gamemode = pk.data[off] & 0x7;
                off += 1;
                off += 1; // dimension
                off += 1; // difficulty
                off += 1; // max players
                const r = try readString(self.alloc, pk.data, off);
                self.alloc.free(r.value);
                off = r.offset;
                off += 1; // reduced debug
                self.setStatus("Joined world");
                try self.sendClientSettings();
            },
            0x08 => { // Player Position And Look
                const feet_x = @as(f64, @bitCast(std.mem.readInt(u64, pk.data[off..][0..8], .big)));
                off += 8;
                const feet_y = @as(f64, @bitCast(std.mem.readInt(u64, pk.data[off..][0..8], .big)));
                off += 8;
                const feet_z = @as(f64, @bitCast(std.mem.readInt(u64, pk.data[off..][0..8], .big)));
                off += 8;
                const yaw = @as(f32, @bitCast(std.mem.readInt(u32, pk.data[off..][0..4], .big)));
                off += 4;
                const pitch = @as(f32, @bitCast(std.mem.readInt(u32, pk.data[off..][0..4], .big)));
                off += 4;
                const eyes_y = feet_y + 1.62;
                self.player.x = feet_x;
                self.player.y = eyes_y;
                self.player.z = feet_z;
                self.player.yRot = yaw;
                self.player.xRot = pitch;
                self.player.bb = AABB.init(feet_x - 0.3, feet_y, feet_z - 0.3, feet_x + 0.3, feet_y + 1.8, feet_z + 0.3);
                try self.sendPosition(feet_x, eyes_y, feet_z, yaw, pitch);
                self.spawned.store(true, .seq_cst);
            },
            0x0C => try self.handleSpawnPlayer(pk.data, off),
            0x13 => try self.handleDestroyEntities(pk.data, off),
            0x15 => try self.handleEntityRelativeMove(pk.data, off, false),
            0x16 => try self.handleEntityLook(pk.data, off),
            0x17 => try self.handleEntityRelativeMove(pk.data, off, true),
            0x18 => try self.handleEntityTeleport(pk.data, off),
            0x19 => try self.handleEntityHeadLook(pk.data, off),
            0x21 => {
                try self.handleChunkSingle(pk.data, off);
                _ = self.chunks_received.fetchAdd(1, .seq_cst);
                self.last_chunk_time.store(std.time.milliTimestamp(), .seq_cst);
            },
            0x26 => {
                const n = try self.handleChunkBulk(pk.data, off);
                _ = self.chunks_received.fetchAdd(n, .seq_cst);
                self.last_chunk_time.store(std.time.milliTimestamp(), .seq_cst);
            },
            0x06 => { // Update Health
                const health = @as(f32, @bitCast(std.mem.readInt(u32, pk.data[off..][0..4], .big)));
                off += 4;
                const r = try readVarInt(pk.data, off);
                off = r.offset;
                off += 4; // saturation
                if (health <= 0) {
                    var payload = std.ArrayList(u8).init(self.alloc);
                    defer payload.deinit();
                    try writeVarInt(&payload, 0);
                    try self.send(0x16, payload.items);
                }
            },
            0x22 => try self.handleMultiBlockChange(pk.data, off),
            0x23 => try self.handleBlockChange(pk.data, off),
            0x00 => { // Keep Alive
                const ka_id = std.mem.readInt(i32, pk.data[off..][0..4], .big);
                var payload: [4]u8 = undefined;
                std.mem.writeInt(i32, &payload, ka_id, .big);
                try self.send(0x00, &payload);
            },
            0x40 => {
                const r = try readString(self.alloc, pk.data, off);
                defer self.alloc.free(r.value);
                var b: [128]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&b, "Disconnected: {s}", .{r.value[0..@min(60, r.value.len)]}) catch "Disconnected");
                self.connected.store(false, .seq_cst);
                self.running.store(false, .seq_cst);
            },
            else => {},
        }
    }

    fn handleSpawnPlayer(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const r = try readVarInt(data, off);
        off = r.offset;
        const entity_id = r.value;
        if (entity_id == self.entity_id) return;
        off += 16; // uuid
        const x = @as(f64, @floatFromInt(std.mem.readInt(i32, data[off..][0..4], .big))) / 32.0;
        off += 4;
        const y = @as(f64, @floatFromInt(std.mem.readInt(i32, data[off..][0..4], .big))) / 32.0;
        off += 4;
        const z = @as(f64, @floatFromInt(std.mem.readInt(i32, data[off..][0..4], .big))) / 32.0;
        off += 4;
        const yawr = readAngle(data, off);
        off = yawr.offset;
        const pitchr = readAngle(data, off);
        off = pitchr.offset;

        self.entity_lock.lock();
        defer self.entity_lock.unlock();
        try self.remote_players.put(entity_id, .{ .x = x, .y = y + 1.62, .z = z, .yaw = yawr.value, .pitch = pitchr.value, .head_yaw = yawr.value });
    }

    fn handleDestroyEntities(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const r = try readVarInt(data, off);
        off = r.offset;
        self.entity_lock.lock();
        defer self.entity_lock.unlock();
        var i: i32 = 0;
        while (i < r.value) : (i += 1) {
            const er = try readVarInt(data, off);
            off = er.offset;
            _ = self.remote_players.remove(er.value);
        }
    }

    fn handleEntityRelativeMove(self: *MinecraftJavaClient, data: []const u8, off_in: usize, update_rotation: bool) !void {
        var off = off_in;
        const r = try readVarInt(data, off);
        off = r.offset;
        const dx = @as(f64, @floatFromInt(@as(i8, @bitCast(data[off])))) / 32.0;
        off += 1;
        const dy = @as(f64, @floatFromInt(@as(i8, @bitCast(data[off])))) / 32.0;
        off += 1;
        const dz = @as(f64, @floatFromInt(@as(i8, @bitCast(data[off])))) / 32.0;
        off += 1;
        var yaw: ?f32 = null;
        var pitch: ?f32 = null;
        if (update_rotation) {
            const yr = readAngle(data, off);
            off = yr.offset;
            const pr = readAngle(data, off);
            off = pr.offset;
            yaw = yr.value;
            pitch = pr.value;
        }
        self.entity_lock.lock();
        defer self.entity_lock.unlock();
        if (self.remote_players.getPtr(r.value)) |p| {
            p.x += dx;
            p.y += dy;
            p.z += dz;
            if (yaw) |yv| {
                p.yaw = yv;
                p.pitch = pitch.?;
            }
        }
    }

    fn handleEntityLook(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const r = try readVarInt(data, off);
        off = r.offset;
        const yr = readAngle(data, off);
        off = yr.offset;
        const pr = readAngle(data, off);
        off = pr.offset;
        self.entity_lock.lock();
        defer self.entity_lock.unlock();
        if (self.remote_players.getPtr(r.value)) |p| {
            p.yaw = yr.value;
            p.pitch = pr.value;
        }
    }

    fn handleEntityTeleport(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const r = try readVarInt(data, off);
        off = r.offset;
        const x = @as(f64, @floatFromInt(std.mem.readInt(i32, data[off..][0..4], .big))) / 32.0;
        off += 4;
        const y = @as(f64, @floatFromInt(std.mem.readInt(i32, data[off..][0..4], .big))) / 32.0;
        off += 4;
        const z = @as(f64, @floatFromInt(std.mem.readInt(i32, data[off..][0..4], .big))) / 32.0;
        off += 4;
        const yr = readAngle(data, off);
        off = yr.offset;
        const pr = readAngle(data, off);
        off = pr.offset;
        self.entity_lock.lock();
        defer self.entity_lock.unlock();
        if (self.remote_players.getPtr(r.value)) |p| {
            p.x = x;
            p.y = y + 1.62;
            p.z = z;
            p.yaw = yr.value;
            p.pitch = pr.value;
        }
    }

    fn handleEntityHeadLook(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const r = try readVarInt(data, off);
        off = r.offset;
        const hr = readAngle(data, off);
        self.entity_lock.lock();
        defer self.entity_lock.unlock();
        if (self.remote_players.getPtr(r.value)) |p| {
            p.head_yaw = hr.value;
            p.yaw = hr.value;
        }
    }

    fn handleChunkSingle(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const chunk_x = std.mem.readInt(i32, data[off..][0..4], .big);
        off += 4;
        const chunk_z = std.mem.readInt(i32, data[off..][0..4], .big);
        off += 4;
        const ground_up = data[off] != 0;
        off += 1;
        const primary_bitmask = std.mem.readInt(u16, data[off..][0..2], .big);
        off += 2;
        const r = try readVarInt(data, off);
        off = r.offset;
        const chunk_data = data[off .. off + @as(usize, @intCast(r.value))];
        try self.applyChunk(chunk_data, chunk_x, chunk_z, primary_bitmask, 0, ground_up, true);
    }

    fn handleChunkBulk(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !u32 {
        const body = data[off_in..];
        const sky_light = body[0] != 0;
        var cursor: usize = 1;
        const r = try readVarInt(body, cursor);
        cursor = r.offset;
        const n_chunks: usize = @intCast(r.value);

        var metas = try self.alloc.alloc(struct { cx: i32, cz: i32, pbm: u16 }, n_chunks);
        defer self.alloc.free(metas);
        for (0..n_chunks) |i| {
            const cx = std.mem.readInt(i32, body[cursor..][0..4], .big);
            cursor += 4;
            const cz = std.mem.readInt(i32, body[cursor..][0..4], .big);
            cursor += 4;
            const pbm = std.mem.readInt(u16, body[cursor..][0..2], .big);
            cursor += 2;
            metas[i] = .{ .cx = cx, .cz = cz, .pbm = pbm };
        }
        const raw = body[cursor..];
        var raw_off: usize = 0;
        for (metas) |m| {
            const n_primary: usize = @popCount(m.pbm);
            var sec_size = n_primary * (8192 + 2048);
            if (sky_light) sec_size += n_primary * 2048;
            sec_size += 256;
            const chunk_raw = raw[raw_off .. raw_off + sec_size];
            raw_off += sec_size;
            try self.applyChunk(chunk_raw, m.cx, m.cz, m.pbm, 0, true, sky_light);
        }
        return @intCast(n_chunks);
    }

    fn applyChunk(self: *MinecraftJavaClient, chunk_data: []const u8, chunk_x: i32, chunk_z: i32, primary_bitmask: u16, add_bitmask: u16, ground_up: bool, sky_light: bool) !void {
        var new_blocks = std.AutoHashMap(Pos3, u16).init(self.alloc);
        defer new_blocks.deinit();
        try decodeChunkData18(self.alloc, chunk_data, primary_bitmask, add_bitmask, ground_up, sky_light, chunk_x, chunk_z, &new_blocks);

        self.level.java_lock.lock();
        var it = new_blocks.iterator();
        while (it.next()) |e| {
            self.level.java_blocks.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }
        self.level.java_lock.unlock();

        self.dirty_lock.lock();
        defer self.dirty_lock.unlock();
        var it2 = new_blocks.keyIterator();
        while (it2.next()) |pos| {
            self.markDirtyAround(pos.*);
        }
    }

    fn markDirtyAround(self: *MinecraftJavaClient, p: Pos3) void {
        const key = Level.javaChunkKey(p.x, p.y, p.z);
        self.dirty_chunks.put(key, {}) catch {};
        self.dirty_chunks.put(.{ .x = key.x + CHUNK_SIZE_RENDER, .y = key.y, .z = key.z }, {}) catch {};
        self.dirty_chunks.put(.{ .x = key.x - CHUNK_SIZE_RENDER, .y = key.y, .z = key.z }, {}) catch {};
        self.dirty_chunks.put(.{ .x = key.x, .y = key.y + CHUNK_SIZE_RENDER, .z = key.z }, {}) catch {};
        self.dirty_chunks.put(.{ .x = key.x, .y = key.y - CHUNK_SIZE_RENDER, .z = key.z }, {}) catch {};
        self.dirty_chunks.put(.{ .x = key.x, .y = key.y, .z = key.z + CHUNK_SIZE_RENDER }, {}) catch {};
        self.dirty_chunks.put(.{ .x = key.x, .y = key.y, .z = key.z - CHUNK_SIZE_RENDER }, {}) catch {};
    }

    fn handleBlockChange(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const pos_long = std.mem.readInt(i64, data[off..][0..8], .big);
        off += 8;
        const pos = unpackBlockPosition(pos_long);
        const r = try readVarInt(data, off);
        const block_id: u16 = @intCast(@as(u32, @bitCast(r.value)) >> 4);

        const p = Pos3{ .x = @intCast(pos.x), .y = @intCast(pos.y), .z = @intCast(pos.z) };
        self.level.java_lock.lock();
        if (block_id == 0) {
            _ = self.level.java_blocks.remove(p);
        } else {
            self.level.java_blocks.put(p, block_id) catch {};
        }
        self.level.java_lock.unlock();

        self.dirty_lock.lock();
        self.markDirtyAround(p);
        self.dirty_lock.unlock();
    }

    fn handleMultiBlockChange(self: *MinecraftJavaClient, data: []const u8, off_in: usize) !void {
        var off = off_in;
        const chunk_x = std.mem.readInt(i32, data[off..][0..4], .big);
        off += 4;
        const chunk_z = std.mem.readInt(i32, data[off..][0..4], .big);
        off += 4;
        const record_count = std.mem.readInt(u16, data[off..][0..2], .big);
        off += 2;

        var i: u16 = 0;
        while (i < record_count) : (i += 1) {
            const horiz = data[off];
            off += 1;
            const y = data[off];
            off += 1;
            const r = try readVarInt(data, off);
            off = r.offset;

            const bx = chunk_x * 16 + @as(i32, horiz >> 4);
            const bz = chunk_z * 16 + @as(i32, horiz & 0xF);
            const block_id: u16 = @intCast(@as(u32, @bitCast(r.value)) >> 4);
            const p = Pos3{ .x = bx, .y = y, .z = bz };

            self.level.java_lock.lock();
            if (block_id == 0) {
                _ = self.level.java_blocks.remove(p);
            } else {
                self.level.java_blocks.put(p, block_id) catch {};
            }
            self.level.java_lock.unlock();

            self.dirty_lock.lock();
            self.markDirtyAround(p);
            self.dirty_lock.unlock();
        }
    }

    fn sendPosition(self: *MinecraftJavaClient, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) !void {
        const feet_y = y - 1.62;
        var server_yaw = @mod(yaw + 180.0, 360.0);
        if (server_yaw < 0) server_yaw += 360.0;
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(x))));
        try payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(feet_y))));
        try payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(z))));
        try payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(server_yaw))));
        try payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(pitch))));
        try payload.append(0); // on_ground = false
        try self.send(0x06, payload.items);
    }

    fn sendClientSettings(self: *MinecraftJavaClient) !void {
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try writeString(&payload, "fr_FR");
        try payload.append(10);
        try writeVarInt(&payload, 0);
        try payload.append(1);
        try payload.append(127);
        try self.send(0x15, payload.items);
    }

    fn sendHeldItemChange(self: *MinecraftJavaClient, slot: i16) !void {
        self.held_slot = @max(0, @min(8, slot));
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, self.held_slot, .big);
        try self.send(0x09, &b);
    }

    fn sendCreativeInventoryAction(self: *MinecraftJavaClient, slot: i16, item_id: i16, count: u8, damage: i16) !void {
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i16, slot)));
        try writeSlot(&payload, item_id, count, damage);
        try self.send(0x10, payload.items);
    }

    fn sendDigStatus(self: *MinecraftJavaClient, status: i8, pos: Pos3, face: u8) !bool {
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try payload.append(@bitCast(status));
        const packed_pos = packBlockPosition(pos.x, pos.y, pos.z);
        try payload.appendSlice(&packed_pos);
        try payload.append(face);
        try self.send(0x07, payload.items);
        return true;
    }

    fn sendDigBlock(self: *MinecraftJavaClient, pos: Pos3, face: u8) !bool {
        _ = try self.sendDigStatus(0, pos, face);
        return self.sendDigStatus(2, pos, face);
    }

    fn sendPlaceBlock(self: *MinecraftJavaClient, target: Pos3, face: u8, item_id: i16) !bool {
        if (self.gamemode == 1) {
            self.sendCreativeInventoryAction(36 + self.held_slot, item_id, 64, 0) catch {};
        }
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        const packed_pos = packBlockPosition(target.x, target.y, target.z);
        try payload.appendSlice(&packed_pos);
        try payload.append(face);
        try writeSlot(&payload, item_id, 1, 0);
        try payload.appendSlice(&[3]u8{ 8, 8, 8 });
        try self.send(0x08, payload.items);
        return true;
    }

    fn sendChatMessage(self: *MinecraftJavaClient, message: []const u8) !bool {
        if (message.len == 0) return false;
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try writeString(&payload, message[0..@min(256, message.len)]);
        try self.send(0x01, payload.items);
        return true;
    }

    fn disconnect(self: *MinecraftJavaClient) void {
        self.running.store(false, .seq_cst);
        self.connected.store(false, .seq_cst);
        if (self.stream) |s| s.close();
    }
};

// ============================================================================
// SERVEUR JAVA LAN MINIMAL
// ============================================================================

const JavaLanServer = struct {
    level: *Level,
    alloc: std.mem.Allocator,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    server: ?std.net.Server = null,
    port: u16 = 0,
    clients: std.ArrayList(std.net.Stream),
    clients_lock: std.Thread.Mutex = .{},
    entity_seq: i32 = 1000,

    fn init(alloc: std.mem.Allocator, level: *Level) JavaLanServer {
        return .{ .level = level, .alloc = alloc, .clients = std.ArrayList(std.net.Stream).init(alloc) };
    }

    fn start(self: *JavaLanServer, preferred_port: u16) !u16 {
        var port = preferred_port;
        var i: u16 = 0;
        while (i < 20) : (i += 1) {
            const addr = try std.net.Address.parseIp("0.0.0.0", port);
            const srv = addr.listen(.{ .reuse_address = true }) catch {
                port += 1;
                continue;
            };
            self.server = srv;
            self.port = port;
            break;
        }
        if (self.server == null) return error.NoPortAvailable;
        self.running.store(true, .seq_cst);
        const t1 = try std.Thread.spawn(.{}, acceptLoop, .{self});
        t1.detach();
        const t2 = try std.Thread.spawn(.{}, announceLoop, .{self});
        t2.detach();
        std.debug.print("[JAVA LAN] server on port {d}\n", .{self.port});
        return self.port;
    }

    fn stop(self: *JavaLanServer) void {
        self.running.store(false, .seq_cst);
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    fn acceptLoop(self: *JavaLanServer) void {
        while (self.running.load(.seq_cst)) {
            const conn = self.server.?.accept() catch continue;
            const t = std.Thread.spawn(.{}, handleClient, .{ self, conn.stream }) catch continue;
            t.detach();
        }
    }

    fn announceLoop(self: *JavaLanServer) void {
        const udp = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP) catch return;
        defer std.posix.close(udp);
        while (self.running.load(.seq_cst)) {
            var buf: [128]u8 = undefined;
            const motd = std.fmt.bufPrint(&buf, "[MOTD]Nanocraft LAN[/MOTD][AD]{d}[/AD]", .{self.port}) catch continue;
            const addr = std.net.Address.parseIp4(JAVA_LAN_MULTICAST_GROUP, JAVA_LAN_MULTICAST_PORT) catch continue;
            _ = std.posix.sendto(udp, motd, 0, &addr.any, addr.getOsSockLen()) catch {};
            std.time.sleep(1_500_000_000);
        }
    }

    fn handleClient(self: *JavaLanServer, stream: std.net.Stream) void {
        self.doHandleClient(stream) catch {};
        stream.close();
    }

    fn doHandleClient(self: *JavaLanServer, stream: std.net.Stream) !void {
        const pk = try recvPacket(self.alloc, stream, -1);
        defer self.alloc.free(pk.data);
        if (pk.packet_id != 0x00) return;
        var off = pk.offset;
        const r = try readVarInt(pk.data, off);
        off = r.offset;
        const hr = try readString(self.alloc, pk.data, off);
        defer self.alloc.free(hr.value);
        off = hr.offset;
        off += 2; // server_port
        const nsr = try readVarInt(pk.data, off);

        if (nsr.value == 1) {
            try self.handleStatus(stream);
        } else if (nsr.value == 2) {
            try self.handleLogin(stream);
        }
    }

    fn handleStatus(self: *JavaLanServer, stream: std.net.Stream) !void {
        const pk = try recvPacket(self.alloc, stream, -1);
        defer self.alloc.free(pk.data);
        if (pk.packet_id == 0x00) {
            const json = "{\"version\":{\"name\":\"1.8\",\"protocol\":47},\"players\":{\"max\":8,\"online\":0,\"sample\":[]},\"description\":{\"text\":\"Nanocraft LAN\"}}";
            var payload = std.ArrayList(u8).init(self.alloc);
            defer payload.deinit();
            try writeString(&payload, json);
            const packet = try writePacket(self.alloc, 0x00, payload.items, -1);
            defer self.alloc.free(packet);
            try stream.writeAll(packet);
        }
        const pk2 = try recvPacket(self.alloc, stream, -1);
        defer self.alloc.free(pk2.data);
        if (pk2.packet_id == 0x01) {
            const packet = try writePacket(self.alloc, 0x01, pk2.data[pk2.offset..], -1);
            defer self.alloc.free(packet);
            try stream.writeAll(packet);
        }
    }

    fn handleLogin(self: *JavaLanServer, stream: std.net.Stream) !void {
        const pk = try recvPacket(self.alloc, stream, -1);
        defer self.alloc.free(pk.data);
        if (pk.packet_id != 0x00) return;
        const ur = try readString(self.alloc, pk.data, pk.offset);
        defer self.alloc.free(ur.value);

        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        try writeString(&payload, "00000000-0000-0000-0000-000000000000");
        try writeString(&payload, ur.value);
        const packet = try writePacket(self.alloc, 0x02, payload.items, -1);
        defer self.alloc.free(packet);
        try stream.writeAll(packet);

        try self.enterPlay(stream, ur.value);
    }

    fn enterPlay(self: *JavaLanServer, stream: std.net.Stream, username: []const u8) !void {
        _ = username;
        const entity_id = self.entity_seq;
        self.entity_seq += 1;

        self.clients_lock.lock();
        try self.clients.append(stream);
        self.clients_lock.unlock();

        const spawn_x: i32 = @divTrunc(self.level.w, 2);
        const spawn_z: i32 = @divTrunc(self.level.h, 2);
        var top_y: i32 = 0;
        var y: i32 = self.level.d - 1;
        while (y >= 0) : (y -= 1) {
            if (self.level.getSolo(spawn_x, y, spawn_z) != 0) {
                top_y = y;
                break;
            }
        }
        const feet_y: f64 = @floatFromInt(top_y + 2);

        var join_payload = std.ArrayList(u8).init(self.alloc);
        defer join_payload.deinit();
        try join_payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i32, entity_id)));
        try join_payload.append(1); // creative
        try join_payload.append(0); // overworld
        try join_payload.append(2); // difficulty
        try join_payload.append(8); // max players
        try writeString(&join_payload, "default");
        try join_payload.append(0);
        try self.sendPacket(stream, 0x01, join_payload.items);

        const posbytes = packBlockPosition(spawn_x, top_y + 1, spawn_z);
        try self.sendPacket(stream, 0x05, &posbytes);

        var abilities = std.ArrayList(u8).init(self.alloc);
        defer abilities.deinit();
        try abilities.append(0x07);
        try abilities.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(@as(f32, 0.05)))));
        try abilities.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(@as(f32, 0.1)))));
        try self.sendPacket(stream, 0x39, abilities.items);

        var poslook = std.ArrayList(u8).init(self.alloc);
        defer poslook.deinit();
        try poslook.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(@as(f64, @floatFromInt(spawn_x)) + 0.5))));
        try poslook.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(feet_y))));
        try poslook.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(@as(f64, @floatFromInt(spawn_z)) + 0.5))));
        try poslook.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(@as(f32, 0.0)))));
        try poslook.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(@as(f32, 0.0)))));
        try poslook.append(0);
        try self.sendPacket(stream, 0x08, poslook.items);

        try self.sendAllChunks(stream);

        while (self.running.load(.seq_cst)) {
            const pk = recvPacket(self.alloc, stream, -1) catch break;
            defer self.alloc.free(pk.data);
            self.handlePlayPacket(pk.packet_id, pk.data, pk.offset) catch {};
        }

        self.clients_lock.lock();
        for (self.clients.items, 0..) |c, idx| {
            if (c.handle == stream.handle) {
                _ = self.clients.swapRemove(idx);
                break;
            }
        }
        self.clients_lock.unlock();
    }

    fn sendPacket(self: *JavaLanServer, stream: std.net.Stream, packet_id: i32, payload: []const u8) !void {
        const packet = try writePacket(self.alloc, packet_id, payload, -1);
        defer self.alloc.free(packet);
        try stream.writeAll(packet);
    }

    fn offsetFromFace(face: u8) Pos3 {
        return switch (face) {
            0 => .{ .x = 0, .y = -1, .z = 0 },
            1 => .{ .x = 0, .y = 1, .z = 0 },
            2 => .{ .x = 0, .y = 0, .z = -1 },
            3 => .{ .x = 0, .y = 0, .z = 1 },
            4 => .{ .x = -1, .y = 0, .z = 0 },
            5 => .{ .x = 1, .y = 0, .z = 0 },
            else => .{ .x = 0, .y = 0, .z = 0 },
        };
    }

    fn handlePlayPacket(self: *JavaLanServer, pid: i32, data: []const u8, off_in: usize) !void {
        var off = off_in;
        if (pid == 0x07) {
            const status = @as(i8, @bitCast(data[off]));
            off += 1;
            const pos_long = std.mem.readInt(i64, data[off..][0..8], .big);
            off += 8;
            const face = data[off];
            const pos = unpackBlockPosition(pos_long);
            if (status == 0 or status == 2) {
                self.applyBlockUpdate(.{ .x = @intCast(pos.x), .y = @intCast(pos.y), .z = @intCast(pos.z) }, 0);
            }
            _ = face;
        } else if (pid == 0x08) {
            const pos_long = std.mem.readInt(i64, data[off..][0..8], .big);
            off += 8;
            const face = data[off];
            off += 1;
            const item_id = std.mem.readInt(i16, data[off..][0..2], .big);
            off += 2;
            const pos = unpackBlockPosition(pos_long);
            if (face <= 5) {
                const d = offsetFromFace(face);
                const block_id: u8 = if (item_id == 1 or item_id == 2) @intCast(item_id) else 1;
                self.applyBlockUpdate(.{ .x = @intCast(pos.x + d.x), .y = @intCast(pos.y + d.y), .z = @intCast(pos.z + d.z) }, block_id);
            }
        }
    }

    fn applyBlockUpdate(self: *JavaLanServer, pos: Pos3, block_id: u8) void {
        self.level.setSolo(pos.x, pos.y, pos.z, block_id);
        self.broadcastBlockChange(pos, block_id);
    }

    fn sendAllChunks(self: *JavaLanServer, stream: std.net.Stream) !void {
        const max_cx = @divTrunc(self.level.w, 16);
        const max_cz = @divTrunc(self.level.h, 16);
        var cx: i32 = 0;
        while (cx < max_cx) : (cx += 1) {
            var cz: i32 = 0;
            while (cz < max_cz) : (cz += 1) {
                if (try self.buildChunkPayload(cx, cz)) |payload| {
                    defer self.alloc.free(payload);
                    try self.sendPacket(stream, 0x21, payload);
                }
            }
        }
    }

    fn buildChunkPayload(self: *JavaLanServer, chunk_x: i32, chunk_z: i32) !?[]u8 {
        var primary_bitmask: u16 = 0;
        var data = std.ArrayList(u8).init(self.alloc);
        defer data.deinit();

        var section_y: i32 = 0;
        while (section_y < 16) : (section_y += 1) {
            const y0 = section_y * 16;
            if (y0 >= self.level.d) break;
            var has_blocks = false;
            var packed_blocks: [8192]u8 = [_]u8{0} ** 8192;
            var by_local: i32 = 0;
            while (by_local < 16) : (by_local += 1) {
                const wy = y0 + by_local;
                if (wy >= self.level.d) continue;
                var bz_local: i32 = 0;
                while (bz_local < 16) : (bz_local += 1) {
                    const wz = chunk_z * 16 + bz_local;
                    if (wz >= self.level.h) continue;
                    var bx_local: i32 = 0;
                    while (bx_local < 16) : (bx_local += 1) {
                        const wx = chunk_x * 16 + bx_local;
                        if (wx >= self.level.w) continue;
                        const bid = self.level.getSolo(wx, wy, wz);
                        if (bid == 0) continue;
                        has_blocks = true;
                        const i: usize = @intCast(bx_local | (bz_local << 4) | (by_local << 8));
                        packed_blocks[i * 2] = (bid & 0xF) << 4;
                        packed_blocks[i * 2 + 1] = (bid >> 4) & 0xFF;
                    }
                }
            }
            if (!has_blocks) continue;
            primary_bitmask |= (@as(u16, 1) << @intCast(section_y));
            try data.appendSlice(&packed_blocks);
            try data.appendNTimes(0, 2048);
            try data.appendNTimes(0xFF, 2048);
        }

        if (primary_bitmask == 0) return null;
        try data.appendNTimes(1, 256);

        var out = std.ArrayList(u8).init(self.alloc);
        try out.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i32, chunk_x)));
        try out.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i32, chunk_z)));
        try out.append(1);
        try out.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, primary_bitmask)));
        try writeVarInt(&out, @intCast(data.items.len));
        try out.appendSlice(data.items);
        return try out.toOwnedSlice();
    }

    fn broadcastBlockChange(self: *JavaLanServer, pos: Pos3, block_id: u8) void {
        var payload = std.ArrayList(u8).init(self.alloc);
        defer payload.deinit();
        const posb = packBlockPosition(pos.x, pos.y, pos.z);
        payload.appendSlice(&posb) catch return;
        writeVarInt(&payload, @as(i32, block_id) << 4) catch return;

        self.clients_lock.lock();
        defer self.clients_lock.unlock();
        for (self.clients.items) |c| {
            self.sendPacket(c, 0x23, payload.items) catch {};
        }
    }
};

// ============================================================================
// IP INPUT SCREEN
// ============================================================================

const IPInputScreen = struct {
    ip_buf: [64]u8 = undefined,
    ip_len: usize = 0,
    port_buf: [8]u8 = undefined,
    port_len: usize = 0,
    user_buf: [16]u8 = undefined,
    user_len: usize = 0,
    active_field: u8 = 0,
    done: bool = false,
    cancelled: bool = false,

    fn init() IPInputScreen {
        var s = IPInputScreen{};
        const ip_default = "localhost";
        @memcpy(s.ip_buf[0..ip_default.len], ip_default);
        s.ip_len = ip_default.len;
        const port_default = "25565";
        @memcpy(s.port_buf[0..port_default.len], port_default);
        s.port_len = port_default.len;
        const user_default = "Player";
        @memcpy(s.user_buf[0..user_default.len], user_default);
        s.user_len = user_default.len;
        return s;
    }

    fn curBuf(self: *IPInputScreen) struct { buf: []u8, len: *usize, cap: usize } {
        return switch (self.active_field) {
            0 => .{ .buf = &self.ip_buf, .len = &self.ip_len, .cap = self.ip_buf.len },
            1 => .{ .buf = &self.port_buf, .len = &self.port_len, .cap = self.port_buf.len },
            else => .{ .buf = &self.user_buf, .len = &self.user_len, .cap = self.user_buf.len },
        };
    }

    fn handleInput(self: *IPInputScreen) void {
        if (ray.IsKeyPressed(ray.KEY_ESCAPE)) {
            self.cancelled = true;
            return;
        }
        if (ray.IsKeyPressed(ray.KEY_ENTER) or ray.IsKeyPressed(ray.KEY_KP_ENTER)) {
            if (self.active_field < 2) {
                self.active_field += 1;
            } else {
                self.done = true;
            }
            return;
        }
        if (ray.IsKeyPressed(ray.KEY_TAB)) {
            self.active_field = @intCast((@as(u32, self.active_field) + 1) % 3);
            return;
        }
        const cur = self.curBuf();
        if (ray.IsKeyPressed(ray.KEY_BACKSPACE)) {
            if (cur.len.* > 0) cur.len.* -= 1;
            return;
        }
        var ch = ray.GetCharPressed();
        while (ch > 0) : (ch = ray.GetCharPressed()) {
            if (ch >= 32 and ch < 127 and cur.len.* < cur.cap) {
                cur.buf[cur.len.*] = @intCast(ch);
                cur.len.* += 1;
            }
        }
    }

    fn draw(self: *IPInputScreen) void {
        ray.ClearBackground(.{ .r = 13, .g = 13, .b = 26, .a = 255 });
        drawTextCentered("JOIN JAVA SERVER", @divTrunc(WIDTH, 2), 150, 32, .{ .r = 255, .g = 200, .b = 50, .a = 255 });

        const labels = [_][]const u8{ "IP Address:", "Port:", "Username:" };
        const values = [_][]const u8{ self.ip_buf[0..self.ip_len], self.port_buf[0..self.port_len], self.user_buf[0..self.user_len] };
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const y: i32 = 280 + @as(i32, @intCast(i)) * 90;
            const cx = @divTrunc(WIDTH, 2) - 200;
            const col: ray.Color = if (i == self.active_field) .{ .r = 255, .g = 255, .b = 100, .a = 255 } else .{ .r = 100, .g = 200, .b = 255, .a = 255 };
            drawTextC(labels[i], cx, y, 28, .{ .r = 200, .g = 200, .b = 200, .a = 255 });
            var buf: [80]u8 = undefined;
            const cursor: []const u8 = if (i == self.active_field and @mod(@as(i64, @intFromFloat(ray.GetTime() * 2)), 2) == 0) "_" else "";
            const txt = std.fmt.bufPrint(&buf, "{s}{s}", .{ values[i], cursor }) catch values[i];
            drawTextC(txt, cx, y + 40, 28, col);
        }

        const cxw = @divTrunc(WIDTH, 2);
        drawTextCentered("TAB / ENTER: next field", cxw, 590, 20, .{ .r = 150, .g = 150, .b = 150, .a = 255 });
        drawTextCentered("ENTER (last field): connect", cxw, 630, 20, .{ .r = 150, .g = 255, .b = 150, .a = 255 });
        drawTextCentered("ESC: back", cxw, 670, 20, .{ .r = 200, .g = 100, .b = 100, .a = 255 });
        drawTextCentered("[Offline mode - online-mode=false required]", cxw, 720, 16, .{ .r = 120, .g = 120, .b = 120, .a = 255 });
    }
};

fn drawTextC(text: []const u8, x: i32, y: i32, size: i32, color: ray.Color) void {
    var buf: [256]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    ray.DrawText(@ptrCast(&buf), x, y, size, color);
}

fn drawTextCentered(text: []const u8, cx: i32, y: i32, size: i32, color: ray.Color) void {
    var buf: [256]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    const w = ray.MeasureText(@ptrCast(&buf), size);
    ray.DrawText(@ptrCast(&buf), cx - @divTrunc(w, 2), y, size, color);
}

// ============================================================================
// GAME (RubyDung)
// ============================================================================

const GameState = enum { menu, game, ip_input, java_game };

const HotbarEntry = struct { name: []const u8, block_id: u16, color: [3]u8 };

const Game = struct {
    state: GameState = .menu,
    level: *Level,
    player: *Player,
    tex: ray.Texture2D = undefined,
    chunks: std.ArrayList(Chunk),

    java_client: ?*MinecraftJavaClient = null,
    java_chunks: std.AutoHashMap(Pos3, Chunk),
    java_status_buf: [256]u8 = undefined,
    java_loading: bool = false,
    java_loading_start: f64 = 0,
    last_java_block_refresh: f64 = 0,
    java_block_burst_until: f64 = 0,
    java_last_ip: [64]u8 = undefined,
    java_last_ip_len: usize = 0,
    java_last_port: u16 = 0,
    java_last_username: [16]u8 = undefined,
    java_last_username_len: usize = 0,
    java_lan_server: ?*JavaLanServer = null,
    java_view_anchor: ?Pos3 = null,

    hotbar: [2]HotbarEntry = .{
        .{ .name = "Stone", .block_id = 1, .color = .{ 120, 120, 120 } },
        .{ .name = "Grass", .block_id = 2, .color = .{ 80, 170, 80 } },
    },
    selected_hotbar: usize = 0,
    hotbar_counts: [2]u32 = .{ 999, 999 },
    last_java_break_time: f64 = 0,
    pending_java_break: ?struct { pos: Pos3, face: u8, block_id: u16, ready_time: f64 } = null,
    java_chat_active: bool = false,
    java_chat_buf: [256]u8 = undefined,
    java_chat_len: usize = 0,
    ip_screen: ?IPInputScreen = null,
    remote_player_pos: ?struct { x: f64, y: f64, z: f64, r: f64 } = null,

    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !*Game {
        const level = try alloc.create(Level);
        level.* = try Level.init(alloc, MAP_W, MAP_D, MAP_H);
        const player = try alloc.create(Player);
        player.* = Player.init();

        const self = try alloc.create(Game);
        self.* = .{
            .level = level,
            .player = player,
            .chunks = std.ArrayList(Chunk).init(alloc),
            .java_chunks = std.AutoHashMap(Pos3, Chunk).init(alloc),
            .alloc = alloc,
        };

        var x: i32 = 0;
        while (x < MAP_W) : (x += CHUNK_SIZE_RENDER) {
            var y: i32 = 0;
            while (y < MAP_D) : (y += CHUNK_SIZE_RENDER) {
                var z: i32 = 0;
                while (z < MAP_H) : (z += CHUNK_SIZE_RENDER) {
                    try self.chunks.append(.{ .pos = .{ .x = x, .y = y, .z = z } });
                }
            }
        }

        // IMPORTANT: on charge la texture ICI, mais main() a déjà appelé
        // InitWindow() avant Game.init() (sinon: crash "GPU is not ready").
        self.tex = ray.LoadTexture("terrain.png");
        ray.SetTextureFilter(self.tex, ray.TEXTURE_FILTER_POINT);
        return self;
    }

    fn isJavaSurvival(self: *Game) bool {
        return self.java_client != null and self.java_client.?.gamemode == 0;
    }

    fn visibleHotbarCount(self: *Game) usize {
        if (self.isJavaSurvival()) return 1; // slot 0 (stone) caché
        return 2;
    }

    fn visibleHotbarEntry(self: *Game, i: usize) HotbarEntry {
        if (self.isJavaSurvival()) return self.hotbar[i + 1];
        return self.hotbar[i];
    }

    fn selectedBlockId(self: *Game) u16 {
        return self.visibleHotbarEntry(self.selected_hotbar).block_id;
    }

    fn selectHotbarSlot(self: *Game, slot: usize) void {
        const n = self.visibleHotbarCount();
        self.selected_hotbar = @min(n - 1, slot);
        if (self.java_client) |jc| {
            jc.sendHeldItemChange(@intCast(self.selected_hotbar)) catch {};
            if (jc.gamemode == 1) {
                jc.sendCreativeInventoryAction(36 + @as(i16, @intCast(self.selected_hotbar)), @intCast(self.selectedBlockId()), 64, 0) catch {};
            }
        }
    }

    fn addHotbarResource(self: *Game, block_id: u16, amount: u32) void {
        for (&self.hotbar, 0..) |h, i| {
            if (h.block_id == block_id) self.hotbar_counts[i] += amount;
        }
    }

    fn consumeHotbarResource(self: *Game, block_id: u16, amount: u32) bool {
        if (!self.isJavaSurvival()) return true;
        for (&self.hotbar, 0..) |h, i| {
            if (h.block_id == block_id) {
                if (self.hotbar_counts[i] < amount) return false;
                self.hotbar_counts[i] -= amount;
                return true;
            }
        }
        return false;
    }

    fn javaSurvivalBreakTime(block_id: u16) f64 {
        if (block_id == 1 or block_id == 2) return 4.0;
        return 0.75;
    }

    // ---- LAN classique ----
    fn startHostLanServices(self: *Game) void {
        const srv = self.alloc.create(JavaLanServer) catch return;
        srv.* = JavaLanServer.init(self.alloc, self.level);
        self.java_lan_server = srv;
        _ = srv.start(JAVA_LAN_PORT_DEFAULT) catch |e| {
            std.debug.print("[HOST] Java LAN server error: {s}\n", .{@errorName(e)});
        };
    }

    fn stopHostLanServices(self: *Game) void {
        if (self.java_lan_server) |s| {
            s.stop();
            self.java_lan_server = null;
        }
    }

    // ---- Connexion Java ----
    fn startJavaConnection(self: *Game, ip: []const u8, port: u16, username: []const u8) void {
        @memcpy(self.java_last_ip[0..ip.len], ip);
        self.java_last_ip_len = ip.len;
        self.java_last_port = port;
        @memcpy(self.java_last_username[0..username.len], username);
        self.java_last_username_len = username.len;

        if (self.java_client) |jc| jc.disconnect();

        self.level.deinit();
        self.level.* = Level.init(self.alloc, MAP_W, MAP_D, MAP_H) catch return;
        self.level.java_mode = true;
        self.level.java_terrain_tex = self.tex;
        self.player.* = Player.init();

        var it = self.java_chunks.valueIterator();
        while (it.next()) |c| c.unloadAll();
        self.java_chunks.clearRetainingCapacity();
        self.java_view_anchor = null;
        self.hotbar_counts = .{ 0, 0 };
        self.last_java_break_time = 0;
        self.pending_java_break = null;
        self.java_loading = true;
        self.java_loading_start = ray.GetTime();
        self.last_java_block_refresh = 0;
        self.java_block_burst_until = 0;

        self.java_client = MinecraftJavaClient.init(self.alloc, ip, port, username, self.level, self.player) catch return;
        self.java_client.?.connect() catch {};
    }

    fn reloadJavaNearbyChunks(self: *Game) void {
        if (self.java_last_ip_len == 0) return;
        self.startJavaConnection(self.java_last_ip[0..self.java_last_ip_len], self.java_last_port, self.java_last_username[0..self.java_last_username_len]);
    }

    fn getOrCreateJavaChunk(self: *Game, key: Pos3) *Chunk {
        const gop = self.java_chunks.getOrPut(key) catch unreachable;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .pos = key };
        }
        return gop.value_ptr;
    }

    fn updateJavaChunks(self: *Game) void {
        const jc = self.java_client orelse return;
        const now = ray.GetTime();
        if (now - self.last_java_block_refresh < JAVA_BLOCK_UPDATE_INTERVAL) return;
        self.last_java_block_refresh = now;

        jc.dirty_lock.lock();
        var dirty = std.ArrayList(Pos3).init(self.alloc);
        var it = jc.dirty_chunks.keyIterator();
        while (it.next()) |k| dirty.append(k.*) catch {};
        jc.dirty_chunks.clearRetainingCapacity();
        jc.dirty_lock.unlock();

        if (dirty.items.len > 0) self.java_block_burst_until = now + JAVA_BLOCK_BURST_SECONDS;
        for (dirty.items) |key| {
            const c = self.getOrCreateJavaChunk(key);
            c.dirty = true;
        }
        dirty.deinit();
    }

    fn getJavaViewAnchor(self: *Game) Pos3 {
        const step = JAVA_VIEW_RECENTER_STEP * CHUNK_SIZE_RENDER;
        const pcx = @divFloor(@as(i32, @intFromFloat(@floor(self.player.x))), CHUNK_SIZE_RENDER) * CHUNK_SIZE_RENDER;
        const pcy = @divFloor(@as(i32, @intFromFloat(@floor(self.player.y))), CHUNK_SIZE_RENDER) * CHUNK_SIZE_RENDER;
        const pcz = @divFloor(@as(i32, @intFromFloat(@floor(self.player.z))), CHUNK_SIZE_RENDER) * CHUNK_SIZE_RENDER;
        const player_chunk = Pos3{ .x = pcx, .y = pcy, .z = pcz };

        if (self.java_view_anchor) |anchor| {
            if (@abs(player_chunk.x - anchor.x) >= step or @abs(player_chunk.z - anchor.z) >= step) {
                self.java_view_anchor = player_chunk;
            }
            return self.java_view_anchor.?;
        }
        self.java_view_anchor = player_chunk;
        return player_chunk;
    }

    fn getJavaVisibleChunks(self: *Game, extra: i32, out: *std.ArrayList(*Chunk)) void {
        out.clearRetainingCapacity();
        const anchor = self.getJavaViewAnchor();
        const horiz = (JAVA_RENDER_DIST_CHUNKS + extra) * CHUNK_SIZE_RENDER;
        const vert = (JAVA_VERTICAL_RENDER_CHUNKS + extra) * CHUNK_SIZE_RENDER;
        var cx = anchor.x - horiz;
        while (cx <= anchor.x + horiz) : (cx += CHUNK_SIZE_RENDER) {
            var cy = anchor.y - vert;
            while (cy <= anchor.y + vert) : (cy += CHUNK_SIZE_RENDER) {
                var cz = anchor.z - horiz;
                while (cz <= anchor.z + horiz) : (cz += CHUNK_SIZE_RENDER) {
                    if (self.java_chunks.getPtr(.{ .x = cx, .y = cy, .z = cz })) |c| {
                        out.append(c) catch {};
                    }
                }
            }
        }
    }

    fn javaLoadingDone(self: *Game) bool {
        const jc = self.java_client orelse return false;
        if (jc.chunks_received.load(.seq_cst) < JAVA_LOADING_MIN_CHUNKS) return false;
        const last = jc.last_chunk_time.load(.seq_cst);
        if (last == 0) return false;
        if (@as(f64, @floatFromInt(std.time.milliTimestamp() - last)) / 1000.0 < JAVA_LOADING_IDLE_SECONDS) return false;
        var buf = std.ArrayList(*Chunk).init(self.alloc);
        defer buf.deinit();
        self.getJavaVisibleChunks(0, &buf);
        for (buf.items) |c| {
            if (c.dirty or c.model == null) return false;
        }
        return true;
    }

    fn respawnLocalPlayerToCenter(self: *Game) void {
        const center_x: f64 = @as(f64, MAP_W) / 2.0;
        const center_z: f64 = @as(f64, MAP_H) / 2.0;
        var spawn_y: f64 = 33.0;
        var y: i32 = MAP_D - 1;
        while (y >= 0) : (y -= 1) {
            if (self.level.getSolo(@intFromFloat(center_x), y, @intFromFloat(center_z)) > 0) {
                spawn_y = @as(f64, @floatFromInt(y)) + 3.62;
                break;
            }
        }
        self.player.x = center_x;
        self.player.y = spawn_y;
        self.player.z = center_z;
        self.player.xd = 0;
        self.player.yd = 0;
        self.player.zd = 0;
        const feet_y = spawn_y - 1.62;
        self.player.bb = AABB.init(center_x - 0.3, feet_y, center_z - 0.3, center_x + 0.3, feet_y + 1.8, center_z + 0.3);
        self.player.onGround = false;
    }

    fn setBlock(self: *Game, pos: Pos3, b: u8) void {
        if (pos.x < 0 or pos.x >= MAP_W or pos.y < 0 or pos.y >= MAP_D or pos.z < 0 or pos.z >= MAP_H) return;
        if (self.level.getSolo(pos.x, pos.y, pos.z) == b) return;
        self.level.setSolo(pos.x, pos.y, pos.z, b);
        if (self.java_lan_server) |s| s.broadcastBlockChange(pos, b);
        for (self.chunks.items) |*c| {
            if (pos.x >= c.pos.x and pos.x < c.pos.x + 16 and pos.y >= c.pos.y and pos.y < c.pos.y + 16 and pos.z >= c.pos.z and pos.z < c.pos.z + 16) {
                c.dirty = true;
            }
        }
    }

    fn applyLocalJavaBlockChange(self: *Game, pos: Pos3, block_id: u16) void {
        const jc = self.java_client orelse return;
        self.level.java_lock.lock();
        if (block_id == 0) {
            _ = self.level.java_blocks.remove(pos);
        } else {
            self.level.java_blocks.put(pos, block_id) catch {};
        }
        self.level.java_lock.unlock();
        jc.dirty_lock.lock();
        jc.markDirtyAround(pos);
        jc.dirty_lock.unlock();
    }

    fn processPendingJavaBreak(self: *Game) void {
        const pending = self.pending_java_break orelse return;
        if (ray.GetTime() < pending.ready_time) return;
        self.pending_java_break = null;
        const jc = self.java_client orelse return;
        if (jc.sendDigStatus(2, pending.pos, pending.face) catch false) {
            self.applyLocalJavaBlockChange(pending.pos, 0);
            if (self.isJavaSurvival() and pending.block_id != 1) {
                self.addHotbarResource(pending.block_id, 1);
            }
        }
    }

    fn getRay(self: *Game) struct { target: ?Pos3, adjacent: ?Pos3 } {
        var x = self.player.x;
        var y = self.player.y;
        var z = self.player.z;
        const ry = std.math.degreesToRadians(self.player.yRot);
        const rx = std.math.degreesToRadians(self.player.xRot);
        const dx = @sin(ry) * @cos(rx);
        const dy = -@sin(rx);
        const dz = -@cos(ry) * @cos(rx);
        var i: u32 = 0;
        while (i < 120) : (i += 1) {
            x += dx * 0.05;
            y += dy * 0.05;
            z += dz * 0.05;
            if (self.level.isSolid(x, y, z)) {
                return .{
                    .target = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)), .z = @intFromFloat(@floor(z)) },
                    .adjacent = .{ .x = @intFromFloat(@floor(x - dx * 0.05)), .y = @intFromFloat(@floor(y - dy * 0.05)), .z = @intFromFloat(@floor(z - dz * 0.05)) },
                };
            }
        }
        return .{ .target = null, .adjacent = null };
    }

    fn getBlockFace(target: ?Pos3, adjacent: ?Pos3) u8 {
        if (target == null or adjacent == null) return 1;
        const t = target.?;
        const a = adjacent.?;
        const dx = a.x - t.x;
        const dy = a.y - t.y;
        const dz = a.z - t.z;
        if (dy > 0) return 1;
        if (dy < 0) return 0;
        if (dz < 0) return 2;
        if (dz > 0) return 3;
        if (dx < 0) return 4;
        if (dx > 0) return 5;
        return 1;
    }

    // ---- boucle principale ----
    fn run(self: *Game) void {
        // NOTE: InitWindow()/SetTargetFPS()/SetExitKey() sont désormais
        // appelés dans main() AVANT Game.init(), pour que le contexte GL
        // existe déjà quand on charge la texture "terrain.png".
        var visible_buf = std.ArrayList(*Chunk).init(self.alloc);
        defer visible_buf.deinit();

        while (!ray.WindowShouldClose()) {
            if (ray.IsWindowResized()) {
                WIDTH = ray.GetScreenWidth();
                HEIGHT = ray.GetScreenHeight();
            }

            self.handleInput(&visible_buf);

            switch (self.state) {
                .menu => self.drawMenu(),
                .ip_input => self.drawIpInput(),
                .game => self.renderGameWorld(false, &visible_buf),
                .java_game => self.renderGameWorld(true, &visible_buf),
            }
        }

        if (self.java_client) |jc| jc.disconnect();
        self.stopHostLanServices();
        ray.CloseWindow();
    }

    fn handleInput(self: *Game, visible_buf: *std.ArrayList(*Chunk)) void {
        if (self.state == .java_game and self.java_chat_active) {
            self.handleJavaChatInput();
        }

        if (ray.IsKeyPressed(ray.KEY_ESCAPE)) {
            if (self.state == .game or self.state == .java_game) {
                if (self.state == .java_game and self.java_chat_active) {
                    self.closeJavaChat();
                } else {
                    ray.EnableCursor();
                    self.state = .menu;
                    if (self.java_client) |jc| {
                        jc.disconnect();
                        self.java_client = null;
                        self.level.deinit();
                        self.level.* = Level.init(self.alloc, MAP_W, MAP_D, MAP_H) catch unreachable;
                        self.player.* = Player.init();
                    }
                    self.stopHostLanServices();
                }
            } else if (self.state == .ip_input) {
                self.state = .menu;
                self.ip_screen = null;
            }
        }

        if (self.state == .game or self.state == .java_game) {
            if (ray.IsKeyPressed(ray.KEY_ONE) or ray.IsKeyPressed(ray.KEY_KP_1)) self.selectHotbarSlot(0);
            if (ray.IsKeyPressed(ray.KEY_TWO) or ray.IsKeyPressed(ray.KEY_KP_2)) self.selectHotbarSlot(1);
        }

        if (self.state == .menu) {
            if (ray.IsKeyPressed(ray.KEY_ONE) or ray.IsKeyPressed(ray.KEY_KP_1)) {
                self.state = .game;
                ray.DisableCursor();
            } else if (ray.IsKeyPressed(ray.KEY_TWO) or ray.IsKeyPressed(ray.KEY_KP_2)) {
                self.state = .game;
                self.startHostLanServices();
                ray.DisableCursor();
            } else if (ray.IsKeyPressed(ray.KEY_THREE) or ray.IsKeyPressed(ray.KEY_KP_3)) {
                self.state = .game;
                ray.DisableCursor();
            } else if (ray.IsKeyPressed(ray.KEY_FOUR) or ray.IsKeyPressed(ray.KEY_KP_4)) {
                self.state = .ip_input;
                self.ip_screen = IPInputScreen.init();
            }
        } else if (self.state == .ip_input) {
            if (self.ip_screen) |*scr| scr.handleInput();
        } else if (self.state == .java_game) {
            if (ray.IsKeyPressed(ray.KEY_T) and self.java_client != null) self.openJavaChat();
            if (ray.IsKeyPressed(ray.KEY_R)) self.reloadJavaNearbyChunks();
        }

        if (self.state == .game and ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_LEFT)) {
            const r = self.getRay();
            if (r.target) |t| self.setBlock(t, 0);
        }
        if (self.state == .game and ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_RIGHT)) {
            const r = self.getRay();
            if (r.adjacent) |p| self.setBlock(p, @intCast(self.selectedBlockId()));
        }

        if (self.state == .java_game and self.java_client != null and !self.java_chat_active) {
            if (ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_LEFT)) {
                const r = self.getRay();
                const jc = self.java_client.?;
                if (r.target) |t| {
                    const broken_block = self.level.getBlock(@floatFromInt(t.x), @floatFromInt(t.y), @floatFromInt(t.z));
                    const face = getBlockFace(r.target, r.adjacent);
                    if (self.isJavaSurvival()) {
                        if (broken_block != 0) {
                            if (jc.sendDigStatus(0, t, face) catch false) {
                                self.last_java_break_time = ray.GetTime();
                                const bt = javaSurvivalBreakTime(broken_block);
                                self.pending_java_break = .{ .pos = t, .face = face, .block_id = broken_block, .ready_time = self.last_java_break_time + bt };
                            }
                        }
                    } else if (jc.sendDigBlock(t, face) catch false) {
                        self.applyLocalJavaBlockChange(t, 0);
                    }
                }
            }
            if (ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_RIGHT)) {
                const r = self.getRay();
                const jc = self.java_client.?;
                if (r.target != null and r.adjacent != null) {
                    const selected_block = self.selectedBlockId();
                    if (self.isJavaSurvival() and !self.consumeHotbarResource(selected_block, 1)) {
                        // pas de bloc disponible
                    } else {
                        const face = getBlockFace(r.target, r.adjacent);
                        if (jc.sendPlaceBlock(r.target.?, face, @intCast(selected_block)) catch false) {
                            self.applyLocalJavaBlockChange(r.adjacent.?, selected_block);
                        } else if (self.isJavaSurvival()) {
                            self.addHotbarResource(selected_block, 1);
                        }
                    }
                }
            }
        }

        if (self.state == .ip_input) {
            if (self.ip_screen) |scr| {
                if (scr.cancelled) {
                    self.state = .menu;
                    self.ip_screen = null;
                } else if (scr.done) {
                    const ip = scr.ip_buf[0..scr.ip_len];
                    const port_str = scr.port_buf[0..scr.port_len];
                    const username = scr.user_buf[0..scr.user_len];
                    const port = std.fmt.parseInt(u16, port_str, 10) catch 25565;
                    self.ip_screen = null;
                    self.state = .java_game;
                    self.startJavaConnection(ip, port, username);
                    ray.DisableCursor();
                }
            }
        }
        _ = visible_buf;
    }

    fn openJavaChat(self: *Game) void {
        self.java_chat_active = true;
        self.java_chat_len = 0;
    }

    fn closeJavaChat(self: *Game) void {
        self.java_chat_active = false;
        self.java_chat_len = 0;
    }

    fn submitJavaChat(self: *Game) void {
        if (self.java_client) |jc| {
            const msg = self.java_chat_buf[0..self.java_chat_len];
            if (msg.len > 0) _ = jc.sendChatMessage(msg) catch false;
        }
        self.closeJavaChat();
    }

    fn handleJavaChatInput(self: *Game) void {
        if (ray.IsKeyPressed(ray.KEY_ESCAPE)) {
            self.closeJavaChat();
            return;
        }
        if (ray.IsKeyPressed(ray.KEY_ENTER) or ray.IsKeyPressed(ray.KEY_KP_ENTER)) {
            self.submitJavaChat();
            return;
        }
        if (ray.IsKeyPressed(ray.KEY_BACKSPACE)) {
            if (self.java_chat_len > 0) self.java_chat_len -= 1;
            return;
        }
        var ch = ray.GetCharPressed();
        while (ch > 0) : (ch = ray.GetCharPressed()) {
            if (ch >= 32 and ch < 127 and self.java_chat_len < self.java_chat_buf.len) {
                self.java_chat_buf[self.java_chat_len] = @intCast(ch);
                self.java_chat_len += 1;
            }
        }
    }

    fn drawMenu(self: *Game) void {
        _ = self;
        ray.BeginDrawing();
        ray.ClearBackground(.{ .r = 26, .g = 26, .b = 26, .a = 255 });
        drawTextCentered("NANOCRAFT", @divTrunc(WIDTH, 2), 200, 40, ray.YELLOW);
        drawTextCentered("[1] SOLO", @divTrunc(WIDTH, 2), 350, 28, ray.WHITE);
        drawTextCentered("[2] HOST LAN", @divTrunc(WIDTH, 2), 420, 28, ray.WHITE);
        drawTextCentered("[3] JOIN LAN", @divTrunc(WIDTH, 2), 490, 28, ray.WHITE);
        drawTextCentered("[4] JOIN JAVA SERVER", @divTrunc(WIDTH, 2), 560, 28, ray.WHITE);
        ray.EndDrawing();
    }

    fn drawIpInput(self: *Game) void {
        ray.BeginDrawing();
        if (self.ip_screen) |*scr| scr.draw();
        ray.EndDrawing();
    }

    fn drawHud(self: *Game, is_java: bool) void {
        if (is_java) {
            var buf: [256]u8 = undefined;
            const status = if (self.java_client) |jc| jc.getStatus(&buf) else "Not connected";
            drawTextC(status, 10, 30, 18, .{ .r = 255, .g = 255, .b = 100, .a = 255 });
            drawTextC("R - reload chunks", WIDTH - 230, 30, 18, ray.WHITE);
            var chat_buf: [300]u8 = undefined;
            const chat_txt = if (self.java_chat_active)
                std.fmt.bufPrint(&chat_buf, "T - chat: {s}_", .{self.java_chat_buf[0..self.java_chat_len]}) catch "T - chat"
            else
                "T - chat";
            drawTextC(chat_txt, WIDTH - 230, 55, 18, ray.WHITE);

            var info_buf: [256]u8 = undefined;
            const nc = self.java_chunks.count();
            const info = std.fmt.bufPrint(&info_buf, "Chunks: {d}  Pos: ({d:.1}, {d:.1}, {d:.1})", .{ nc, self.player.x, self.player.y, self.player.z }) catch "";
            drawTextC(info, 10, 55, 18, .{ .r = 200, .g = 200, .b = 200, .a = 255 });

            var nb_buf: [128]u8 = undefined;
            self.level.java_lock.lock();
            const nb = self.level.java_blocks.count();
            self.level.java_lock.unlock();
            const nb_txt = std.fmt.bufPrint(&nb_buf, "Blocks in memory: {d}", .{nb}) catch "";
            drawTextC(nb_txt, 10, 80, 18, .{ .r = 200, .g = 200, .b = 200, .a = 255 });

            var fps_buf: [64]u8 = undefined;
            const fps_txt = std.fmt.bufPrint(&fps_buf, "FPS: {d}", .{ray.GetFPS()}) catch "";
            drawTextC(fps_txt, 10, 110, 18, ray.WHITE);
        } else {
            var fps_buf: [64]u8 = undefined;
            const fps_txt = std.fmt.bufPrint(&fps_buf, "FPS: {d}", .{ray.GetFPS()}) catch "";
            drawTextC(fps_txt, 10, 45, 18, ray.WHITE);
        }
    }

    fn drawCrosshair(self: *Game) void {
        const cx: f32 = @floatFromInt(@divTrunc(WIDTH, 2));
        const cy: f32 = @floatFromInt(@divTrunc(HEIGHT, 2));
        const size: f32 = 8;
        ray.DrawLine(@intFromFloat(cx - size), @intFromFloat(cy), @intFromFloat(cx + size), @intFromFloat(cy), ray.WHITE);
        ray.DrawLine(@intFromFloat(cx), @intFromFloat(cy - size), @intFromFloat(cx), @intFromFloat(cy + size), ray.WHITE);
        _ = self;
    }

    fn drawHotbar(self: *Game) void {
        const n = self.visibleHotbarCount();
        const slot_w: i32 = 90;
        const slot_h: i32 = 54;
        const gap: i32 = 10;
        const total_w = @as(i32, @intCast(n)) * slot_w + (@as(i32, @intCast(n)) - 1) * gap;
        const x0 = @divTrunc(WIDTH - total_w, 2);
        const y0 = HEIGHT - slot_h - 18;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const entry = self.visibleHotbarEntry(i);
            const sx = x0 + @as(i32, @intCast(i)) * (slot_w + gap);
            const selected = i == self.selected_hotbar;
            const border: ray.Color = if (selected) .{ .r = 255, .g = 255, .b = 150, .a = 255 } else .{ .r = 64, .g = 64, .b = 64, .a = 255 };
            ray.DrawRectangle(sx, y0, slot_w, slot_h, border);
            ray.DrawRectangle(sx + 3, y0 + 3, slot_w - 6, slot_h - 6, .{ .r = 20, .g = 20, .b = 20, .a = 255 });
            ray.DrawRectangle(sx + 18, y0 + 10, 26, 26, .{ .r = entry.color[0], .g = entry.color[1], .b = entry.color[2], .a = 255 });

            var num_buf: [4]u8 = undefined;
            const num_txt = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "";
            drawTextC(num_txt, sx + 8, y0 + 10, 16, ray.WHITE);

            if (self.isJavaSurvival()) {
                var count_buf: [16]u8 = undefined;
                const real_index: usize = if (self.isJavaSurvival()) i + 1 else i;
                const count_txt = std.fmt.bufPrint(&count_buf, "{d}", .{self.hotbar_counts[real_index]}) catch "";
                drawTextC(count_txt, sx + 48, y0 + 28, 16, .{ .r = 230, .g = 230, .b = 230, .a = 255 });
            }
        }
    }

    fn buildCamera(self: *Game) ray.Camera3D {
        const yaw = std.math.degreesToRadians(self.player.yRot);
        const pitch = std.math.degreesToRadians(self.player.xRot);
        const dx = @sin(yaw) * @cos(pitch);
        const dy = -@sin(pitch);
        const dz = -@cos(yaw) * @cos(pitch);
        const pos = ray.Vector3{ .x = @floatCast(self.player.x), .y = @floatCast(self.player.y), .z = @floatCast(self.player.z) };
        return .{
            .position = pos,
            .target = .{ .x = pos.x + @as(f32, @floatCast(dx)), .y = pos.y + @as(f32, @floatCast(dy)), .z = pos.z + @as(f32, @floatCast(dz)) },
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .fovy = 70,
            .projection = ray.CAMERA_PERSPECTIVE,
        };
    }

    fn javaPlayerTick(self: *Game) void {
        var xa: f64 = 0;
        var za: f64 = 0;
        var ya: f64 = 0;
        if (ray.IsKeyDown(ray.KEY_W) or ray.IsKeyDown(ray.KEY_Z)) za -= 1;
        if (ray.IsKeyDown(ray.KEY_S)) za += 1;
        if (ray.IsKeyDown(ray.KEY_A) or ray.IsKeyDown(ray.KEY_Q)) xa -= 1;
        if (ray.IsKeyDown(ray.KEY_D)) xa += 1;
        if (ray.IsKeyDown(ray.KEY_SPACE)) ya += 1;
        if (ray.IsKeyDown(ray.KEY_LEFT_SHIFT) or ray.IsKeyDown(ray.KEY_LEFT_CONTROL)) ya -= 1;

        const speed: f64 = 0.5;
        const m = @sqrt(xa * xa + za * za);
        if (m > 0.01) {
            xa /= m;
            za /= m;
        }
        const s = @sin(std.math.degreesToRadians(self.player.yRot));
        const c = @cos(std.math.degreesToRadians(self.player.yRot));
        self.player.x += (xa * c - za * s) * speed;
        self.player.z += (za * c + xa * s) * speed;
        self.player.y += ya * speed;
    }

    fn renderGameWorld(self: *Game, is_java: bool, visible_buf: *std.ArrayList(*Chunk)) void {
        if (is_java and self.java_loading) {
            self.updateJavaChunks();
            self.getJavaVisibleChunks(1, visible_buf);
            var built: u32 = 0;
            for (visible_buf.items) |c| {
                if (built >= 4) break;
                if (c.dirty or c.model == null) {
                    c.build(self.level, self.tex);
                    built += 1;
                }
            }
        }

        if (is_java and self.java_loading and !self.javaLoadingDone()) {
            ray.BeginDrawing();
            ray.ClearBackground(.{ .r = 13, .g = 20, .b = 31, .a = 255 });
            const loaded = if (self.java_client) |jc| jc.chunks_received.load(.seq_cst) else 0;
            var prepared: u32 = 0;
            self.getJavaVisibleChunks(0, visible_buf);
            for (visible_buf.items) |c| {
                if (!c.dirty and c.model != null) prepared += 1;
            }
            drawTextCentered("LOADING JAVA WORLD...", @divTrunc(WIDTH, 2), 260, 28, .{ .r = 255, .g = 220, .b = 120, .a = 255 });
            var buf1: [64]u8 = undefined;
            drawTextCentered(std.fmt.bufPrint(&buf1, "Chunks received: {d}", .{loaded}) catch "", @divTrunc(WIDTH, 2), 340, 22, .{ .r = 180, .g = 220, .b = 255, .a = 255 });
            var buf2: [64]u8 = undefined;
            drawTextCentered(std.fmt.bufPrint(&buf2, "Chunks ready: {d}/{d}", .{ prepared, visible_buf.items.len }) catch "", @divTrunc(WIDTH, 2), 380, 22, .{ .r = 180, .g = 255, .b = 180, .a = 255 });
            ray.EndDrawing();
            return;
        }

        if (is_java and self.java_loading) self.java_loading = false;

        if (!self.java_chat_active) {
            const delta = ray.GetMouseDelta();
            self.player.yRot += @as(f64, delta.x) * 0.15;
            self.player.xRot = @max(-90, @min(90, self.player.xRot + @as(f64, delta.y) * 0.15));
        }
        self.processPendingJavaBreak();

        if (!is_java) {
            self.player.tick(self.level, false);
            if (self.player.y < -10) self.respawnLocalPlayerToCenter();
        } else {
            if (self.java_client) |jc| {
                if (jc.gamemode == 0) {
                    self.player.tick(self.level, self.java_chat_active);
                } else if (!self.java_chat_active) {
                    self.javaPlayerTick();
                }
            }
        }

        const camera = self.buildCamera();

        ray.BeginDrawing();
        ray.ClearBackground(.{ .r = 128, .g = 204, .b = 255, .a = 255 });
        ray.BeginMode3D(camera);

        if (is_java) {
            self.updateJavaChunks();
            self.getJavaVisibleChunks(1, visible_buf);
            var rebuilds: u32 = 0;
            const burst = ray.GetTime() < self.java_block_burst_until;
            const budget: u32 = if (burst) 2 else 1;
            for (visible_buf.items) |c| {
                if (rebuilds >= budget) break;
                if (c.dirty or c.model == null) {
                    c.build(self.level, self.tex);
                    rebuilds += 1;
                }
            }
            for (visible_buf.items) |c| {
                if (c.model) |m| ray.DrawModel(m, .{ .x = 0, .y = 0, .z = 0 }, 1.0, ray.WHITE);
                if (c.model_colored) |m| ray.DrawModel(m, .{ .x = 0, .y = 0, .z = 0 }, 1.0, ray.WHITE);
            }

            if (self.java_client) |jc| {
                jc.entity_lock.lock();
                var it = jc.remote_players.valueIterator();
                while (it.next()) |p| {
                    self.drawSteve(p.x, p.y, p.z, p.head_yaw);
                }
                jc.entity_lock.unlock();
            }
        } else {
            for (self.chunks.items) |*c| {
                const dx = @as(f64, @floatFromInt(c.pos.x)) - self.player.x;
                const dz = @as(f64, @floatFromInt(c.pos.z)) - self.player.z;
                if (@abs(dx) < RENDER_DIST and @abs(dz) < RENDER_DIST) {
                    if (c.dirty or c.model == null) c.build(self.level, self.tex);
                    if (c.model) |m| ray.DrawModel(m, .{ .x = 0, .y = 0, .z = 0 }, 1.0, ray.WHITE);
                }
            }
            if (self.remote_player_pos) |p| self.drawSteve(p.x, p.y, p.z, @floatCast(p.r));
        }

        ray.EndMode3D();
        self.drawCrosshair();
        self.drawHud(is_java);
        self.drawHotbar();
        ray.EndDrawing();
    }

    fn drawSteve(self: *Game, x: f64, y: f64, z: f64, yaw: f32) void {
        // Cube simplifié texturé avec le skin terrain (tête = tuiles STEVE_*).
        const size: f32 = 0.75;
        const pos = ray.Vector3{ .x = @floatCast(x), .y = @floatCast(y - 0.9), .z = @floatCast(z) };
        _ = yaw;
        ray.DrawCube(pos, size, 1.75, size / 2.0, .{ .r = 200, .g = 170, .b = 130, .a = 255 });
        _ = self;
        _ = STEVE_TOP_TILE;
        _ = STEVE_BOTTOM_TILE;
        _ = STEVE_SIDE_TOP_TILE;
        _ = STEVE_SIDE_BOTTOM_TILE;
    }
};

pub fn main() !void {
    // InitWindow() DOIT être appelé avant tout chargement GPU (textures,
    // modèles...). C'était l'origine du "Segmentation fault" : Game.init()
    // appelait LoadTexture()/SetTextureFilter() alors que la fenêtre/le
    // contexte OpenGL n'existaient pas encore.
    ray.InitWindow(WIDTH, HEIGHT, "Nanocraft");
    ray.SetTargetFPS(60);
    ray.SetExitKey(0);

    const alloc = gpa_impl.allocator();
    const game = try Game.init(alloc);
    game.run();
}