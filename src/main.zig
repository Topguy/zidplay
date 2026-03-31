// MySidPlayer - A high-fidelity Zig SID player
// Copyright (C) 2026 Steinar Barbakken <topguyz@gmail.com>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
const std = @import("std");

const c = @cImport({
    @cInclude("sid_wrapper.h");
    @cInclude("audio_engine.h");
});

const PlayerContext = struct {
    player: *c.sidplayfp_t,
    sample_count: usize = 0,
    clock_speed: u32 = 985248,
    
    // Leftover buffer handling
    leftover_buf: [16384]i16 = undefined,
    leftover_count: u32 = 0,
};

fn sid_callback(buffer: [*c]i16, frameCount: u32, pUserData: ?*anyopaque) callconv(.c) void {
    const ctx: *PlayerContext = @ptrCast(@alignCast(pUserData));
    
    c.sid_lock(ctx.player);
    defer c.sid_unlock(ctx.player);

    var frames_done: u32 = 0;
    var out_ptr = buffer;

    // 1. Use leftovers
    if (ctx.leftover_count > 0) {
        const to_copy = @min(ctx.leftover_count, frameCount);
        @memcpy(out_ptr[0..(to_copy * 2)], ctx.leftover_buf[0..(to_copy * 2)]);
        
        if (to_copy < ctx.leftover_count) {
            const remaining = ctx.leftover_count - to_copy;
            std.mem.copyForwards(i16, ctx.leftover_buf[0..(remaining * 2)], ctx.leftover_buf[(to_copy * 2)..((to_copy + remaining) * 2)]);
            ctx.leftover_count = remaining;
        } else {
            ctx.leftover_count = 0;
        }
        
        frames_done += to_copy;
        out_ptr += to_copy * 2;
    }

    // 2. Fill the rest
    while (frames_done < frameCount) {
        const frames_needed = frameCount - frames_done;
        const cycles_to_run = @as(u32, @intFromFloat(@as(f32, @floatFromInt(frames_needed)) * (@as(f32, @floatFromInt(ctx.clock_speed)) / 44100.0)));
        
        const samples_produced = c.sid_play(ctx.player, @max(cycles_to_run, 1000));
        
        if (samples_produced > 0) {
            const prod_u32 = @as(u32, @intCast(samples_produced));
            const to_mix = @min(prod_u32, frames_needed);
            
            _ = c.sid_mix(ctx.player, out_ptr, to_mix);
            
            if (prod_u32 > to_mix) {
                const extra = prod_u32 - to_mix;
                const safe_extra = @min(extra, @as(u32, @intCast(ctx.leftover_buf.len / 2)));
                _ = c.sid_mix(ctx.player, &ctx.leftover_buf, safe_extra);
                ctx.leftover_count = safe_extra;
            }

            out_ptr += to_mix * 2;
            frames_done += to_mix;
            ctx.sample_count += to_mix;
        } else {
            @memset(out_ptr[0..((frameCount - frames_done) * 2)], 0);
            break;
        }
    }
}

fn loadRom(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| return err;
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn printUsage(exe_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [options] <sidfile>
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\  -l, --list           List available audio devices and exit
        \\  -d, --device <id>    Select audio device by ID (default: system default)
        \\  -r, --roms <path>    Path to C64 ROMs directory (default: ./rom)
        \\
    , .{exe_name});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var filename: ?[]const u8 = null;
    var deviceIndex: i32 = -1;
    var rom_base: []const u8 = "rom";
    var list_devices = false;

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0]);
            return;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_devices = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--device")) {
            arg_i += 1;
            if (arg_i < args.len) {
                deviceIndex = std.fmt.parseInt(i32, args[arg_i], 10) catch -1;
            }
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--roms")) {
            arg_i += 1;
            if (arg_i < args.len) {
                rom_base = args[arg_i];
            }
        } else if (filename == null) {
            filename = arg;
        }
    }

    if (list_devices) {
        c.audio_list_devices();
        return;
    }

    const sid_file = filename orelse {
        printUsage(args[0]);
        return;
    };

    const player = c.sid_new() orelse return error.SidInitFailed;
    defer c.sid_delete(player);

    // Load ROMs (Optional)
    const kernal_path = try std.fs.path.join(allocator, &.{ rom_base, "Kernal.rom" });
    defer allocator.free(kernal_path);
    const basic_path = try std.fs.path.join(allocator, &.{ rom_base, "Basic.rom" });
    defer allocator.free(basic_path);
    const chargen_path = try std.fs.path.join(allocator, &.{ rom_base, "Char.rom" });
    defer allocator.free(chargen_path);

    const kernal = loadRom(allocator, kernal_path) catch null;
    defer if (kernal) |k| allocator.free(k);
    const basic = loadRom(allocator, basic_path) catch null;
    defer if (basic) |b| allocator.free(b);
    const chargen = loadRom(allocator, chargen_path) catch null;
    defer if (chargen) |c_gen| allocator.free(c_gen);

    if (kernal == null or basic == null or chargen == null) {
        std.debug.print("Warning: C64 ROMs missing in '{s}' folder. RSID files may not play.\n", .{rom_base});
    }

    c.sid_set_roms(player, 
        if (kernal) |k| k.ptr else null, 
        if (basic) |b| b.ptr else null, 
        if (chargen) |c_gen| c_gen.ptr else null
    );

    const builder = c.builder_new("ReSIDfp");

    const tune = c.tune_new(sid_file.ptr) orelse return error.TuneLoadFailed;
    if (!c.tune_status(tune)) {
        std.debug.print("Error: Failed to load tune '{s}'\n", .{sid_file});
        return;
    }

    std.debug.print("\n--- SID Metadata ---\n", .{});
    const info_count = c.tune_info_count(tune);
    var i: u32 = 0;
    while (i < info_count) : (i += 1) {
        const label = switch (i) {
            0 => "Title:    ",
            1 => "Author:   ",
            2 => "Released: ",
            else => "Extra:    ",
        };
        std.debug.print("{s}{s}\n", .{ label, c.tune_info_string(tune, i) });
    }

    const total_songs = c.tune_songs(tune);
    const start_song = c.tune_start_song(tune);
    std.debug.print("Songs:    {d} (Starting at {d})\n", .{ total_songs, start_song });

    _ = c.tune_select_song(tune, start_song); 

    if (!c.sid_config(player, builder, 44100)) {
        std.debug.print("Error: Failed to configure player: {s}\n", .{c.sid_error(player)});
        return;
    }

    if (!c.sid_load(player, tune)) {
        std.debug.print("Error: Failed to load tune into player: {s}\n", .{c.sid_error(player)});
        return;
    }

    c.sid_init_mixer(player);
    
    var context = PlayerContext{ 
        .player = player,
        .clock_speed = c.tune_get_clock_speed(tune),
    };

    const audio = c.audio_init(sid_callback, &context, deviceIndex) orelse return error.AudioInitFailed;
    defer c.audio_deinit(audio);

    std.debug.print("Playing:  {s} ({d} Hz)\n", .{sid_file, context.clock_speed});
    std.debug.print("Control:  Press Ctrl+C to stop.\n\n", .{});
    c.audio_start(audio);
    
    std.debug.print("Initialization complete. Starting playback...\n", .{});
    
    const start_time = std.time.timestamp();
    
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        const elapsed = std.time.timestamp() - start_time;
        const mins = @as(u32, @intCast(@max(0, @divFloor(elapsed, 60))));
        const secs = @as(u32, @intCast(@max(0, @mod(elapsed, 60))));
        
        std.debug.print("\rTime: {d:0>2}:{d:0>2} | Samples: {d}   ", .{mins, secs, context.sample_count});
    }
}

