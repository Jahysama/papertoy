// Copyright (c) 2025, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const gl = @import("zgl");

const VERTEX_SHADER_SOURCE =
    \\#version 330 core
    \\
    \\layout(location = 0) in vec2 position;
    \\
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\}
;
const SHADERTOY_PREAMBLE = @embedFile("shadertoy_preamble.glsl");

/// A resolution for a shader program, defined by its width and height.
pub const Resolution = struct {
    width: u32,
    height: u32,
};

/// The vertices of a full-screen quad, used for rendering Shadertoy shaders.
// zig fmt: off
const SCREEN_VERTICES = [_]f32{
    -1.0, -1.0,
     1.0, -1.0,
     1.0,  1.0,
    -1.0,  1.0,
};
// zig fmt: on
const SCREEN_INDICES = [_]u8{
    0, 1, 2,
    2, 3, 0,
};

/// The data for Shadertoy uniforms.
const UniformData = extern struct {
    resolution: [3]f32 align(16) = .{ 0, 0, 0 },
    time: f32 align(4) = 1,
    time_delta: f32 align(4) = 1,
    frame_rate: f32 align(4) = 1,
    frame: i32 align(4) = 1,
    channel_time: [4]f32 align(16) = [_]f32{ 0, 0, 0, 0 },
    channel_resolution: [4][3]f32 align(16) = [1][3]f32{.{ 0, 0, 0 }} ** 4,
    mouse: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    date: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    sample_rate: f32 align(4) = 1,
};

/// Wrapper around the UBO for Shadertoy uniforms.
const Uniforms = struct {
    /// The uniform buffer object for Shadertoy uniforms.
    ubo: gl.Buffer,
    /// The data for the uniforms. This can be changed as needed; before rendering,
    /// call `bind` to upload the data to the GPU and bind the UBO.
    data: UniformData,

    /// Initialize the uniforms object.
    pub fn init(data: UniformData) Uniforms {
        const ubo = gl.Buffer.gen();
        ubo.bind(.uniform_buffer);
        gl.bufferData(.uniform_buffer, UniformData, &.{data}, .dynamic_draw);
        gl.bindBufferBase(.uniform_buffer, 0, ubo);

        return Uniforms{ .ubo = ubo, .data = data };
    }

    /// Delete the uniforms object.
    pub fn deinit(self: *Uniforms) void {
        self.ubo.delete();
    }

    /// Bind and update the uniforms for rendering.
    pub fn bind(self: *Uniforms) void {
        self.ubo.bind(.uniform_buffer);
        gl.bufferData(.uniform_buffer, UniformData, &.{self.data}, .dynamic_draw);
    }
};

/// A Shadertoy-based shader program that will be rendered to an output.
pub const Shader = struct {
    /// The actual shader program.
    program: gl.Program,
    /// Uniforms specific to this shader.
    uniforms: Uniforms,
    /// The resolution of the shader.
    resolution: Resolution,
    /// The frame rate the shader is expected to run at.
    frame_rate: u32,
    /// The current frame number. Increments by one each time the shader is rendered.
    frame: u32 = 0,
    /// The first time the shader was rendered.
    first_rendered: std.time.Instant = undefined,
    /// The last time the shader was rendered.
    last_rendered: std.time.Instant = undefined,

    pub const Error = Allocator.Error || error{
        /// Failed to compile the shader.
        ShaderFailedToCompile,
        /// Failed to link the program.
        ProgramFailedToLink,
    };

    /// Create the shader program with the given source code and parameters.
    pub fn create(allocator: Allocator, source: []const u8, resolution: Resolution, frame_rate: u32) Error!*Shader {
        const vert = gl.Shader.create(.vertex);
        defer vert.delete();
        vert.source(1, &.{VERTEX_SHADER_SOURCE[0..]});
        vert.compile();

        const frag = gl.Shader.create(.fragment);
        defer frag.delete();
        {
            frag.source(2, &.{ SHADERTOY_PREAMBLE[0..], source });
            frag.compile();

            const frag_compiled = frag.get(.compile_status) == gl.binding.TRUE;
            if (!frag_compiled) {
                const log = try frag.getCompileLog(allocator);
                defer allocator.free(log);

                std.log.err(
                    \\failed to compile shader!
                    \\This might mean the shader is broken, or that it uses features of GLSL
                    \\that are beyond 3.30 core.
                    \\
                    \\Shader log:
                    \\{s}
                , .{log});
                return error.ShaderFailedToCompile;
            }
        }

        const program = gl.Program.create();
        errdefer program.delete();

        program.attach(vert);
        program.attach(frag);
        program.link();
        const program_linked = program.get(.link_status) == gl.binding.TRUE;
        if (!program_linked) {
            const log = try program.getCompileLog(allocator);
            defer allocator.free(log);

            std.log.err(
                \\failed to link shader program!
                \\
                \\Program log:
                \\{s}
            , .{log});
            return error.ProgramFailedToLink;
        }

        const self = try allocator.create(Shader);
        errdefer allocator.destroy(self);

        self.* = .{
            .program = program,
            .uniforms = .init(.{
                .resolution = .{ @floatFromInt(resolution.width), @floatFromInt(resolution.height), 0 },
                .frame_rate = @floatFromInt(frame_rate),
            }),
            .resolution = resolution,
            .frame_rate = frame_rate,
        };

        return self;
    }

    /// Destroy the shader program and its resources.
    pub fn destroy(self: *Shader, allocator: Allocator) void {
        self.uniforms.deinit();
        self.program.delete();
        allocator.destroy(self);
    }

    /// Render the shader to the currently bound framebuffer.
    pub fn render(self: *Shader) !void {
        self.program.use();

        if (self.frame == 0) {
            self.first_rendered = try std.time.Instant.now();
            self.last_rendered = self.first_rendered;
        }

        const now = try std.time.Instant.now();
        const total_ns: f32 = @floatFromInt(now.since(self.first_rendered));
        const delta_ns: f32 = @floatFromInt(now.since(self.last_rendered));

        self.uniforms.data.resolution = .{ @floatFromInt(self.resolution.width), @floatFromInt(self.resolution.height), 0 };
        self.uniforms.data.frame_rate = @floatFromInt(self.frame_rate);
        self.uniforms.data.frame = @intCast(self.frame);
        self.uniforms.data.time = total_ns / std.time.ns_per_s;
        self.uniforms.data.time_delta = delta_ns / std.time.ns_per_s;
        self.uniforms.bind();

        self.last_rendered = now;
        self.frame += 1;

        gl.drawElements(.triangles, SCREEN_INDICES.len, .unsigned_byte, 0);
    }
};

/// OpenGL attributes common to all shaders. These only need to be created and used
/// once per thread.
pub const GlobalAttributes = struct {
    /// The vertex array object for the full-screen quad.
    vao: gl.VertexArray,
    /// The vertex buffer object for the full-screen quad.
    vbo: gl.Buffer,
    /// The Element Buffer Object for the full-screen quad, describing the indices
    /// of the vertices to draw.
    ebo: gl.Buffer,

    /// Initialize the global attributes for the current thread.
    /// An OpenGL context must be current when this is called.
    pub fn init() GlobalAttributes {
        const vao = gl.VertexArray.gen();
        errdefer vao.delete();

        const vbo = gl.Buffer.gen();
        errdefer vbo.delete();

        const ebo = gl.Buffer.gen();
        errdefer ebo.delete();

        vao.bind();
        vbo.bind(.array_buffer);
        ebo.bind(.element_array_buffer);

        // I'd like to use the glNamed* APIs here, but they are 4.5 only and we're
        // targeting 3.3 core. Too bad.
        gl.bufferData(.array_buffer, f32, &SCREEN_VERTICES, .static_draw);
        gl.vertexAttribPointer(0, 2, .float, false, 2 * @sizeOf(f32), 0);
        gl.enableVertexAttribArray(0);

        gl.bufferData(.element_array_buffer, u8, &SCREEN_INDICES, .static_draw);

        return GlobalAttributes{ .vao = vao, .vbo = vbo, .ebo = ebo };
    }

    /// Delete the global attributes.
    pub fn deinit(self: *GlobalAttributes) void {
        self.vbo.delete();
        self.vao.delete();
        self.ebo.delete();
    }

    /// Bind the global attributes for rendering.
    pub fn bind(self: GlobalAttributes) void {
        self.vao.bind();
        self.vbo.bind(.array_buffer);
        self.ebo.bind(.element_array_buffer);
    }
};
