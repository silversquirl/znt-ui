const std = @import("std");
const znt = @import("znt");
const gl = @import("zgl");

/// The Box component specifies a tree of nested boxes that can be laid out by the LayoutSystem
pub const Box = struct {
    parent: ?znt.EntityId, // Parent of this box
    sibling: ?znt.EntityId, // Previous sibling
    settings: Settings, // Box layout settings
    shape: RectShape = undefined, // Shape of the box, set by layout

    // Internal
    _visited: bool = false, // Has this box been processed yet?
    _extra: f32 = undefined, // Amount of extra space in the main axis
    _grow_total: f32 = undefined, // Total growth factor of all children
    _offset: f32 = undefined, // Current offset into the box

    pub const Relation = enum {
        parent,
        sibling,
    };
    pub const Settings = struct {
        direction: Direction = .row,
        grow: f32 = 1,
        fill_cross: bool = true,
        margins: Margins = .{},
        min_size: [2]usize = .{ 0, 0 },
        // TODO: minimum size function
    };
    pub const Direction = enum { row, col };
    pub const Margins = struct {
        l: usize = 0,
        b: usize = 0,
        r: usize = 0,
        t: usize = 0,
    };

    pub fn init(parent: ?znt.EntityId, sibling: ?znt.EntityId, settings: Settings) Box {
        return .{ .parent = parent, .sibling = sibling, .settings = settings };
    }
};

/// The Rect component displays a colored rectangle at a size and location specified by a callback
pub fn Rect(comptime Scene: type) type {
    return struct {
        color: [4]f32,
        shapeFn: fn (*Scene, znt.EntityId) RectShape,

        const Self = @This();

        pub fn init(color: [4]f32, shapeFn: fn (*Scene, znt.EntityId) RectShape) Self {
            return .{ .color = color, .shapeFn = shapeFn };
        }

        pub fn draw(self: Self, scene: *Scene, eid: znt.EntityId, ren: *Renderer) void {
            const rect = self.shapeFn(scene, eid);
            ren.drawRect(rect, self.color);
        }
    };
}
pub const RectShape = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    inline fn coord(self: *RectShape, axis: u1) *f32 {
        return switch (axis) {
            0 => &self.x,
            1 => &self.y,
        };
    }
    inline fn dim(self: *RectShape, axis: u1) *f32 {
        return switch (axis) {
            0 => &self.w,
            1 => &self.h,
        };
    }
};

const Renderer = struct {
    vao: gl.VertexArray,
    prog: gl.Program,
    u_color: ?u32,
    buf: gl.Buffer,

    pub fn init() Renderer {
        const vao = gl.VertexArray.create();
        vao.enableVertexAttribute(0);
        vao.attribFormat(0, 2, .float, false, 0);
        vao.attribBinding(0, 0);

        const buf = gl.Buffer.create();
        buf.storage([2]f32, 4, null, .{ .map_write = true });
        vao.vertexBuffer(0, buf, 0, @sizeOf([2]f32));

        const prog = createProgram();
        const u_color = prog.uniformLocation("u_color");

        return .{
            .vao = vao,
            .prog = prog,
            .u_color = u_color,
            .buf = buf,
        };
    }

    pub fn deinit(self: Renderer) void {
        self.vao.delete();
        self.prog.delete();
        self.buf.delete();
    }

    fn createProgram() gl.Program {
        const vert = gl.Shader.create(.vertex);
        defer vert.delete();
        vert.source(1, &.{
            \\  #version 330
            \\  layout(location = 0) in vec2 pos;
            \\  void main() {
            \\      gl_Position = vec4(pos, 0, 1);
            \\  }
        });
        vert.compile();
        if (vert.get(.compile_status) == 0) {
            std.debug.panic("Vertex shader compilation failed:\n{s}\n", .{vert.getCompileLog(std.heap.page_allocator)});
        }

        const frag = gl.Shader.create(.fragment);
        defer frag.delete();
        frag.source(1, &.{
            \\  #version 330
            \\  uniform vec4 u_color;
            \\  out vec4 f_color;
            \\  void main() {
            \\      f_color = u_color;
            \\  }
        });
        frag.compile();
        if (frag.get(.compile_status) == 0) {
            std.debug.panic("Fragment shader compilation failed:\n{s}\n", .{frag.getCompileLog(std.heap.page_allocator)});
        }

        const prog = gl.Program.create();
        prog.attach(vert);
        defer prog.detach(vert);
        prog.attach(frag);
        defer prog.detach(frag);
        prog.link();
        if (prog.get(.link_status) == 0) {
            std.debug.panic("Shader linking failed:\n{s}\n", .{frag.getCompileLog(std.heap.page_allocator)});
        }
        return prog;
    }

    // TODO: use multidraw
    // TODO: use persistent mappings

    pub fn drawRect(self: *Renderer, rect: RectShape, color: [4]f32) void {
        self.prog.uniform4f(self.u_color, color[0], color[1], color[2], color[3]);

        while (true) {
            const buf = self.buf.mapRange([2]gl.Float, 0, 4, .{ .write = true });
            buf[0] = .{ rect.x, rect.y };
            buf[1] = .{ rect.x, rect.y + rect.h };
            buf[2] = .{ rect.x + rect.w, rect.y };
            buf[3] = .{ rect.x + rect.w, rect.y + rect.h };
            if (self.buf.unmap()) break;
        }

        self.vao.bind();
        self.prog.use();
        gl.drawArrays(.triangle_strip, 0, 4);
    }
};

/// boxRect is a Rect callback that takes the size and location from a Box component
pub fn boxRect(comptime Scene: type) fn (*Scene, znt.EntityId) RectShape {
    return struct {
        const box_component = Scene.componentByType(Box);
        pub fn shape(scene: *Scene, eid: znt.EntityId) RectShape {
            const box = scene.getOne(box_component, eid).?;
            return box.shape;
        }
    }.shape;
}

/// The EventHandler component allows an entity to handle UI events of a certain type, such as mouse motion, button clicks and text input
pub fn EventHandler(comptime HandlerFunc: type) type {
    if (@typeInfo(HandlerFunc).Fn.args[0].type.? != znt.EntityId) {
        @compileError("Event handler function's first argument must be of type EntityId");
    }
    return struct { handler: HandlerFunc };
}

pub const EventType = enum {
    mouse_move,
    mouse_enter,
    mouse_leave,
    mouse_down,
    mouse_up,
    mouse_scroll,
    key_down,
    key_up,
    text,
};

// pub const Button = enum {
//     left,
//     right,
//     middle,
//     _,
// };

/// The LayoutSystem arranges a tree of nested boxes according to their constraints
pub fn LayoutSystem(comptime Scene: type) type {
    return struct {
        s: *Scene,
        boxes: std.ArrayList(*Box),
        view_scale: [2]f32, // Viewport scale

        const box_component = Scene.componentByType(Box);
        const Self = @This();

        // Viewport width and height should be in screen units, not pixels
        pub fn init(allocator: *std.mem.Allocator, scene: *Scene, viewport_size: [2]u31) Self {
            var self = Self{
                .s = scene,
                .boxes = std.ArrayList(*Box).init(allocator),
                .view_scale = undefined,
            };
            self.setViewport(viewport_size);
            return self;
        }
        pub fn deinit(self: Self) void {
            self.boxes.deinit();
        }

        pub fn setViewport(self: *Self, size: [2]u31) void {
            self.view_scale = .{
                2.0 / @intToFloat(f32, size[0]),
                2.0 / @intToFloat(f32, size[1]),
            };
        }

        pub fn layout(self: *Self) std.mem.Allocator.Error!void {
            // Collect all boxes, parents before children
            // We also reset every box to a zero shape during this process
            try self.resetAndCollectBoxes();

            // Compute minimum sizes
            // Iterate backwards so we compute child sizes before fitting parents around them
            var i = self.boxes.items.len;
            while (i > 0) {
                i -= 1;
                const box = self.boxes.items[i];
                self.layoutInternal(box, true);
            }

            // Compute layout
            // Iterate forwards so we compute parent capacities before fitting children to them
            for (self.boxes.items) |box| {
                self.layoutInternal(box, false);
                box._visited = false; // Reset the visited flag while we're here
            }
        }

        fn resetAndCollectBoxes(self: *Self) !void {
            self.boxes.clearRetainingCapacity();
            try self.boxes.ensureTotalCapacity(self.s.count(box_component));

            var have_root = false;

            var iter = self.s.iter(&.{box_component});
            var entity = iter.next() orelse return;
            while (true) {
                var box = @field(entity, @tagName(box_component));

                // Reset and append the box, followed by all siblings and parents
                const start = self.boxes.items.len;
                while (!box._visited) {
                    box._visited = true;
                    box.shape = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                    box._grow_total = 0;
                    self.boxes.appendAssumeCapacity(box);

                    if (box.sibling) |id| {
                        const sibling = self.s.getOne(box_component, id).?;
                        // TODO: cycle detection
                        std.debug.assert(sibling.parent.? == box.parent.?);
                        box = sibling;
                    } else if (box.parent) |id| {
                        // TODO: detect more than one first child
                        box = self.s.getOne(box_component, id).?;
                    } else {
                        std.debug.assert(!have_root); // There can only be one root box
                        have_root = true;
                        break;
                    }
                }

                // Then reverse the appended data to put the parents first
                std.mem.reverse(*Box, self.boxes.items[start..]);

                entity = iter.next() orelse break;
            }

            std.debug.assert(have_root); // There must be one root box if there are any boxes
            std.debug.assert(self.boxes.items[0].parent == null); // All boxes must be descendants of the root box
        }

        fn layoutInternal(self: Self, box: *Box, min: bool) void {
            if (box.parent) |parent_id| {
                const parent = self.s.getOne(box_component, parent_id).?;

                if (min) {
                    // Compute minimum size of current box
                    const minw = self.view_scale[0] * @intToFloat(f32, box.settings.min_size[0]);
                    const minh = self.view_scale[1] * @intToFloat(f32, box.settings.min_size[1]);
                    box.shape.w = std.math.max(box.shape.w, minw);
                    box.shape.h = std.math.max(box.shape.h, minh);

                    // Add minimum outer size to parent size
                    const outer = self.pad(.out, box.shape, box.settings.margins);
                    parent.shape.w += outer.w;
                    parent.shape.h += outer.h;

                    // Compute values for next pass
                    parent._grow_total += box.settings.grow;
                } else {
                    var shape = self.pad(.in, parent.shape, box.settings.margins);
                    if (parent._grow_total == 0) {
                        box._extra = 0;
                    } else {
                        // TODO: lift this division up a layer - should allow moving _grow_total into the temporary usage of shape
                        box._extra = box.settings.grow * parent._extra / parent._grow_total;
                    }

                    const main_axis = @enumToInt(box.settings.direction);
                    const cross_axis = 1 - main_axis;
                    shape.dim(main_axis).* = std.math.max(0, box.shape.dim(main_axis).* + box._extra);
                    shape.coord(main_axis).* += parent._offset;
                    if (!box.settings.fill_cross) {
                        shape.dim(cross_axis).* = box.shape.dim(cross_axis).*;
                    }
                    parent._offset += self.pad(.out, shape, box.settings.margins).dim(main_axis).*;

                    box.shape = shape;
                    box._offset = 0;
                }
            } else if (!min) {
                var shape = self.pad(.in, .{ .x = -1, .y = -1, .w = 2, .h = 2 }, box.settings.margins);
                const main_axis = @enumToInt(box.settings.direction);
                box._extra = std.math.max(0, shape.dim(main_axis).* - box.shape.dim(main_axis).*);
                box.shape = shape;
                box._offset = 0;
            }
        }

        const PaddingSide = enum { in, out };
        fn pad(self: Self, comptime side: PaddingSide, rect: RectShape, margins: Box.Margins) RectShape {
            const mx = self.view_scale[0] * @intToFloat(f32, margins.l);
            const my = self.view_scale[1] * @intToFloat(f32, margins.b);
            const mw = self.view_scale[0] * @intToFloat(f32, margins.l + margins.r);
            const mh = self.view_scale[1] * @intToFloat(f32, margins.b + margins.t);

            return switch (side) {
                .in => .{
                    .x = rect.x + mx,
                    .y = rect.y + my,
                    .w = std.math.max(0, rect.w - mw),
                    .h = std.math.max(0, rect.h - mh),
                },
                .out => .{
                    .x = rect.x - mx,
                    .y = rect.y - my,
                    .w = rect.w + mw,
                    .h = rect.h + mh,
                },
            };
        }
    };
}

/// The RenderSystem draws Rects to an OpenGL context
pub fn RenderSystem(comptime Scene: type) type {
    return struct {
        s: *Scene,
        renderer: Renderer,

        const rect_component = Scene.componentByType(Rect(Scene));
        const Self = @This();

        pub fn init(scene: *Scene) Self {
            return .{ .s = scene, .renderer = Renderer.init() };
        }
        pub fn deinit(self: Self) void {
            self.renderer.deinit();
        }

        pub fn render(self: *Self) void {
            var iter = self.s.iter(&.{rect_component});
            while (iter.next()) |entity| {
                const rect = @field(entity, @tagName(rect_component));
                rect.draw(self.s, entity.id, &self.renderer);
            }
        }
    };
}

// The EventSystem dispatches events to EventHandler components
// pub fn EventSystem(comptime Scene: type, comptime HandlerFunc: type) type {
//     return struct {
//         s: *Scene,

//         const box_component = Scene.componentByType( Box);
//         const event_component = Scene.componentByType( EventHandler);
//         const Self = @This();

//         pub const Args = blk: {
//             const args = @typeInfo(HandlerFunc).Fn.args[1..]; // Skip the first arg since that's the entity ID
//             var types: [args.len]type = undefined;
//             for (args) |arg, i| {
//                 types[i] = arg.arg_type.?;
//             }
//             break :blk std.meta.Tuple(&types);
//         };
//         pub const Return = @typeInfo(HandlerFunc).Fn.return_type.?;

//         pub fn init(scene: *Scene) Self {
//             return .{ .s = scene };
//         }

//         pub fn dispatch(self: Self, args: Args) Return {
//             for (self.s.iter(&.{ event_component, box_component })) |entity| {
//                 const box = @field(entity, @tagName(box_component));
//                 const event = @field(entity, @tagName(event_component));
//                 if (
//             }
//         }
//     };
// }