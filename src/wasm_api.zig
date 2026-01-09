/// WebAssembly API for perfect-tetris PC solver
/// Exports functions callable from JavaScript via WASM
const std = @import("std");
const pt = @import("perfect-tetris");
const engine = @import("engine");

const BoardMask = engine.bit_masks.BoardMask;
const PieceKind = engine.pieces.PieceKind;
const Facing = engine.pieces.Facing;
const GameState = engine.GameState;

const Allocator = std.mem.Allocator;

// Use a simple allocator for WASM
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// Output buffer for results (JSON string)
var output_buffer: [8192]u8 = undefined;

/// Parse a piece character to PieceKind
fn parsePiece(c: u8) ?PieceKind {
    return switch (c) {
        'I', 'i' => .i,
        'O', 'o' => .o,
        'T', 't' => .t,
        'S', 's' => .s,
        'Z', 'z' => .z,
        'L', 'l' => .l,
        'J', 'j' => .j,
        else => null,
    };
}

/// Parse field string (X=filled, _=empty) to BoardMask
fn parseField(field_ptr: [*]const u8, field_len: u32, height: u32) BoardMask {
    var mask = BoardMask{};
    const field = field_ptr[0..field_len];

    var x: u32 = 0;
    var y: u32 = height - 1; // Start from top row

    for (field) |c| {
        if (c == 'X' or c == 'x') {
            if (y < BoardMask.HEIGHT) {
                mask.rows[y] |= @as(u16, 1) << @intCast(x);
            }
        }
        x += 1;
        if (x >= 10) {
            x = 0;
            if (y > 0) y -= 1;
        }
    }

    return mask;
}

/// Format a placement to JSON
fn formatPlacement(buf: []u8, placement: pt.Placement) ![]const u8 {
    const piece_char: u8 = switch (placement.piece.kind) {
        .i => 'I',
        .o => 'O',
        .t => 'T',
        .s => 'S',
        .z => 'Z',
        .l => 'L',
        .j => 'J',
    };
    const rotation: []const u8 = switch (placement.piece.facing) {
        .up => "Spawn",
        .right => "Right",
        .down => "Reverse",
        .left => "Left",
    };

    var fbs = std.io.fixedBufferStream(buf);
    var writer = fbs.writer();
    try writer.print("{{\"piece\":\"{c}\",\"rotate\":\"{s}\",\"x\":{d},\"y\":{d}}}", .{
        piece_char,
        rotation,
        placement.pos.x,
        placement.pos.y,
    });
    return fbs.getWritten();
}

/// Main PC solver function - exported to WASM
/// Returns pointer to JSON result string
export fn findPath(
    field_ptr: [*]const u8,
    field_len: u32,
    pieces_ptr: [*]const u8,
    pieces_len: u32,
    height: u32,
) [*]const u8 {
    // Parse field
    const playfield = parseField(field_ptr, field_len, height);

    // Parse pieces into queue
    const pieces = pieces_ptr[0..pieces_len];
    var queue: [16]PieceKind = undefined;
    var queue_len: usize = 0;

    for (pieces) |c| {
        if (parsePiece(c)) |piece| {
            if (queue_len < 16) {
                queue[queue_len] = piece;
                queue_len += 1;
            }
        }
    }

    if (queue_len == 0) {
        const err = "{\"success\":false,\"error\":\"No valid pieces provided\"}";
        @memcpy(output_buffer[0..err.len], err);
        output_buffer[err.len] = 0;
        return &output_buffer;
    }

    // Create game state with the pieces
    // Using SevenBag as placeholder - we'll manually set the queue
    var game: GameState(engine.bags.SevenBag) = .init(
        engine.bags.SevenBag.init(0),
        &engine.kicks.srsPlus,
    );
    game.playfield = playfield;
    game.current.kind = queue[0];
    if (queue_len > 1) {
        game.hold_kind = queue[1];
    }

    // Try to find PC
    const nn = pt.defaultNN(allocator) catch {
        const err = "{\"success\":false,\"error\":\"Failed to load neural network\"}";
        @memcpy(output_buffer[0..err.len], err);
        output_buffer[err.len] = 0;
        return &output_buffer;
    };
    defer nn.deinit(allocator);

    const solution = pt.findPcAuto(
        engine.bags.SevenBag,
        allocator,
        game,
        nn,
        @intCast(height),
        queue_len,
        null,
    ) catch |e| {
        var fbs = std.io.fixedBufferStream(&output_buffer);
        var writer = fbs.writer();
        writer.print("{{\"success\":false,\"error\":\"{s}\"}}", .{@errorName(e)}) catch {
            const err = "{\"success\":false,\"error\":\"Unknown error\"}";
            @memcpy(output_buffer[0..err.len], err);
            output_buffer[err.len] = 0;
            return &output_buffer;
        };
        output_buffer[fbs.pos] = 0;
        return &output_buffer;
    };
    defer allocator.free(solution);

    // Format result as JSON
    var fbs = std.io.fixedBufferStream(&output_buffer);
    var writer = fbs.writer();

    writer.writeAll("{\"success\":true,\"solutions\":[{\"placements\":[") catch {
        const err = "{\"success\":false,\"error\":\"Buffer overflow\"}";
        @memcpy(output_buffer[0..err.len], err);
        output_buffer[err.len] = 0;
        return &output_buffer;
    };

    var placement_buf: [256]u8 = undefined;
    for (solution, 0..) |placement, i| {
        if (i > 0) {
            writer.writeAll(",") catch break;
        }
        const placement_json = formatPlacement(&placement_buf, placement) catch break;
        writer.writeAll(placement_json) catch break;
    }

    writer.writeAll("]}],\"solutionCount\":1}") catch {
        const err = "{\"success\":false,\"error\":\"Buffer overflow\"}";
        @memcpy(output_buffer[0..err.len], err);
        output_buffer[err.len] = 0;
        return &output_buffer;
    };

    output_buffer[fbs.pos] = 0;
    return &output_buffer;
}

/// Get the length of a null-terminated result string
export fn getResultLength(ptr: [*]const u8) u32 {
    var len: u32 = 0;
    while (ptr[len] != 0 and len < 8192) {
        len += 1;
    }
    return len;
}

/// Allocate memory for input strings
export fn alloc(len: u32) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free allocated memory
export fn dealloc(ptr: [*]u8, len: u32) void {
    allocator.free(ptr[0..len]);
}
