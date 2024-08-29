const std = @import("std");

pub const Mesh = struct {
    const Self = @This();

    vertices: [][3] f32,
    faces: [][3] u32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, num_v: usize, num_f: usize) !Self {
        const vertices = try alloc.alloc([3]f32, num_v);
        const faces = try alloc.alloc([3]u32, num_f);

        return Mesh { .vertices = vertices, .faces = faces, .alloc = alloc};
    }

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.vertices);
        self.alloc.free(self.faces);
    }
};


pub const FiniteStateMachine = struct {
    const Self = @This();

    const State = enum { 
        HeaderStart, 
        ReadNextLine,
        Comment, 
        VertexCount,
        Property,
        FaceCount,
        ParseVertices,
        ParseFaces,
        EndHeader,
        Finished
    };

    const ParsingError = error {
        InvalidHeader,
        InvalidSequence,
        InvalidElement,
        InvalidElementCount,
    };

    state: State,
    num_v: usize,
    num_f: usize,

    pub fn init() Self {
        return FiniteStateMachine { .state = State.HeaderStart, .num_v = 0, .num_f = 0 };
    }

    pub fn deinit() void {

    }

    fn next_state(self: *Self, line: []const u8, element_idx: *usize) !State {
        if (std.mem.startsWith(u8, line, "ply")) {
            if (self.state != State.HeaderStart) return ParsingError.InvalidHeader;
            return State.ReadNextLine;
        } else if (std.mem.startsWith(u8, line, "format")) {
            if (self.state != State.ReadNextLine) return ParsingError.InvalidSequence;
            return State.ReadNextLine;
        } else if (std.mem.startsWith(u8, line, "comment")) {
            if (self.state != State.ReadNextLine) return ParsingError.InvalidSequence;
            return State.ReadNextLine;
        } else if (std.mem.startsWith(u8, line, "element")) {
            if (self.state == State.ReadNextLine) {
                return State.VertexCount;
            } else {
                return State.FaceCount;
            }
        } else if (std.mem.startsWith(u8, line, "property")) {
            switch (self.state) {
                State.VertexCount, State.FaceCount, State.Property => return State.Property,
                else => return ParsingError.InvalidSequence,
            }
        } else if (std.mem.startsWith(u8, line, "end_header")) {
            return State.EndHeader;
        } else {
            if (element_idx.* < self.num_v) {
                return State.ParseVertices;
            } else {
                return State.ParseFaces;
            }
            
        }
    }

    fn parse_value(comptime T: type, line: []const u8) ![3]T {
        var line_it = std.mem.splitSequence(u8, line, " ");
        var ret: [3]T = undefined;

        if (T == u32) _ = line_it.next();

        for (0..3) |i| {
            const num = line_it.next().?;
            ret[i] = try switch (T) {
                f32 => std.fmt.parseFloat(f32, num),
                u32 => std.fmt.parseInt(u32, num, 10),
                else => return ParsingError.InvalidSequence,
            };
        }
        return ret;
    }

    fn parse_num(line: []const u8) !usize {
        var line_it = std.mem.splitSequence(u8, line, " ");
        _ = line_it.next();
        _ = line_it.next();
        const num_token = line_it.next() orelse return ParsingError.InvalidElement;
        return std.fmt.parseInt(usize, num_token, 10) catch return ParsingError.InvalidElementCount;
    }

    pub fn parseAlloc(self: *Self, alloc: std.mem.Allocator, file_path: []const u8) !Mesh {
        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        var buf: [1024]u8 = undefined;
        var element_idx: usize = 0;
        var mesh: Mesh = undefined;
        
        outer: while (self.state != State.Finished) {
            const maybe_line = try in_stream.readUntilDelimiterOrEof(&buf, '\n');
            const line = maybe_line orelse {
                self.state = State.Finished;
                break :outer;
            };

            self.state = try self.next_state(line, &element_idx);
            
            switch (self.state) {
                State.HeaderStart => {
                    return ParsingError.InvalidHeader;
                },
                State.VertexCount => {  
                    self.num_v = try parse_num(line);
                },
                State.FaceCount => {  
                    self.num_f = try parse_num(line);
                    mesh = try Mesh.init(alloc, self.num_v, self.num_f);
                },
                State.ParseVertices => {
                    mesh.vertices[element_idx] = try parse_value(f32, line);
                    element_idx += 1;
                },
                State.ParseFaces => {
                    std.debug.assert(element_idx >= self.num_v);
                    mesh.faces[element_idx - self.num_v] = try parse_value(u32, line);
                    element_idx += 1;
                },
                State.Finished => {
                    break :outer;
                },
                else => {},
            }
        }

        return mesh;
    }
};

test "parse_simple" {
    const alloc = std.testing.allocator;

    const relative_path = "test/airplane.ply";
    const absolute_path = try std.fs.cwd().realpathAlloc(alloc, relative_path);
    defer alloc.free(absolute_path);

    var fsm = FiniteStateMachine.init();
    var mesh = try fsm.parseAlloc(alloc, absolute_path);
    defer mesh.deinit();
}