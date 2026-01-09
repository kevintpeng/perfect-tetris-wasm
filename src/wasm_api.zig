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
/// Field string is expected in reading order: first char is top-left (row height-1, col 0)
/// Engine BoardMask bit layout: x=0 is bit 10, x=9 is bit 1 (bits 11-15 and bit 0 are padding)
fn parseField(field_ptr: [*]const u8, field_len: u32, height: u32) BoardMask {
    var mask = BoardMask{};
    const field = field_ptr[0..field_len];

    var x: u32 = 0;
    var y: u32 = height - 1; // Start from top row

    for (field) |c| {
        if (c == 'X' or c == 'x') {
            if (y < BoardMask.HEIGHT) {
                // Engine BoardMask: x=0 is bit 10, x=9 is bit 1
                // Formula: bit_position = WIDTH - x = 10 - x
                const bit_pos: u4 = @intCast(10 - x);
                mask.rows[y] |= @as(u16, 1) << bit_pos;
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
/// Outputs coordinates in sfinder format (rotation center position)
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

    // Convert from Zig's relative position to sfinder's rotation center position
    // Zig uses: pos + canonicalCenter = absolute position of piece's reference point
    // sfinder uses: (x, y) = position of the rotation center on the board
    //
    // The canonical position gives us the bottom-left of the piece's bounding box.
    // To match sfinder, we need to add the offset from bounding box to rotation center.
    const canon_pos = placement.piece.canonicalPosition(placement.pos);

    // sfinder's rotation center is offset from the bottom-left of the 4x4 bounding box
    // These offsets convert from canonical position to sfinder-compatible position
    const sfinder_offset = getSfinderOffset(placement.piece.kind, placement.piece.facing);

    const x: i32 = @as(i32, canon_pos.x) + sfinder_offset.x;
    const y: i32 = @as(i32, canon_pos.y) + sfinder_offset.y;

    var fbs = std.io.fixedBufferStream(buf);
    var writer = fbs.writer();
    try writer.print("{{\"piece\":\"{c}\",\"rotate\":\"{s}\",\"x\":{d},\"y\":{d}}}", .{
        piece_char,
        rotation,
        x,
        y,
    });
    return fbs.getWritten();
}

/// Get the offset to convert from Zig canonical position to sfinder position
/// sfinder defines rotation centers differently than Zig's canonical centers
fn getSfinderOffset(kind: PieceKind, facing: Facing) struct { x: i32, y: i32 } {
    // These offsets are derived from comparing Zig's canonical center positions
    // with sfinder's rotation center definitions.
    //
    // Zig canonical centers (from canonicalCenterRaw):
    //   I: up={1,2}, right={2,2}, down={2,1}, left={1,1}
    //   O: up={1,1}, right={1,2}, down={2,2}, left={2,1}
    //   T,S,Z,L,J: all facings={1,1}
    //
    // sfinder rotation centers (derived from Piece.java positions):
    //   All pieces use the center of the piece's 4 minos as the reference point
    //   For I piece: the center is between the 2nd and 3rd minos
    //   For O piece: the center is at the bottom-left corner
    //   For T,S,Z,L,J: the center is at the middle mino (the rotation point)

    return switch (kind) {
        .i => switch (facing) {
            // I piece horizontal: blocks at x-offsets -1,0,1,2 from center
            // Canonical pos is bottom-left of 4x4 box, sfinder is rotation center
            .up => .{ .x = 1, .y = 0 },    // Spawn: horizontal, center between 2nd/3rd block
            .right => .{ .x = 0, .y = 1 }, // Right: vertical, center between 2nd/3rd block
            .down => .{ .x = 1, .y = 0 },  // Reverse: horizontal (same as spawn for I)
            .left => .{ .x = 0, .y = 1 },  // Left: vertical (same as right for I)
        },
        .o => switch (facing) {
            // O piece: 2x2 square, sfinder puts center at bottom-left
            .up => .{ .x = 0, .y = 0 },
            .right => .{ .x = 0, .y = 0 },
            .down => .{ .x = 0, .y = 0 },
            .left => .{ .x = 0, .y = 0 },
        },
        // T, S, Z, L, J all have center at the middle mino
        // Canonical center is {1,1} for all facings, which matches sfinder's center
        else => .{ .x = 0, .y = 0 },
    };
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

    // Need at least 2 pieces (hold + current)
    if (queue_len < 2) {
        const err = "{\"success\":false,\"error\":\"Need at least 2 pieces\"}";
        @memcpy(output_buffer[0..err.len], err);
        output_buffer[err.len] = 0;
        return &output_buffer;
    }

    // Create game state with the pieces
    // Following the same pattern as solve.zig's gameWithPieces
    var game: GameState(engine.bags.SevenBag) = .init(
        engine.bags.SevenBag.init(0),
        &engine.kicks.srsPlus,
    );
    game.playfield = playfield;

    // First piece goes to hold, second is current
    game.hold_kind = queue[0];
    game.current.kind = queue[1];

    // Fill next preview (pieces starting at index 2)
    const next_count = @min(queue_len - 2, game.next_pieces.len);
    for (0..next_count) |i| {
        game.next_pieces[i] = queue[i + 2];
    }

    // Set up bag context for pieces beyond the preview
    game.bag.context.index = 0;
    if (queue_len > 9) {
        for (0..queue_len - 9) |i| {
            game.bag.context.pieces[i] = queue[i + 9];
        }
    }

    // Try to find PC
    const nn = pt.defaultNN(allocator) catch {
        const err = "{\"success\":false,\"error\":\"Failed to load neural network\"}";
        @memcpy(output_buffer[0..err.len], err);
        output_buffer[err.len] = 0;
        return &output_buffer;
    };
    defer nn.deinit(allocator);

    // max_len is the maximum number of placements in a solution
    // For a 4-line PC, you need at most height * 10 / 4 = 10 placements
    // But we can only use as many pieces as we have in the queue
    const max_placements = @min(queue_len, height * 10 / 4);

    const solution = pt.findPcAuto(
        engine.bags.SevenBag,
        allocator,
        game,
        nn,
        @intCast(height),
        max_placements,
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
