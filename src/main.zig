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
    @cInclude("stdio.h");
    @cInclude("time.h");
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

fn loadRom(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const file = c.fopen(path.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(file);
    _ = c.fseek(file, 0, c.SEEK_END);
    const size = @as(usize, @intCast(c.ftell(file)));
    _ = c.fseek(file, 0, c.SEEK_SET);
    const buffer = try allocator.alloc(u8, size);
    _ = c.fread(buffer.ptr, 1, size, file);
    return buffer;
}

const WavHeader = extern struct {
    riff_id: [4]u8 = "RIFF".*,
    file_size: u32 = 0,
    wave_id: [4]u8 = "WAVE".*,
    fmt_id: [4]u8 = "fmt ".*,
    fmt_size: u32 = 16,
    audio_format: u16 = 1,
    num_channels: u16 = 4,
    sample_rate: u32 = 44100,
    byte_rate: u32 = 44100 * 4 * 2,
    block_align: u16 = 4 * 2,
    bits_per_sample: u16 = 16,
    data_id: [4]u8 = "data".*,
    data_size: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var filename: ?[]const u8 = null;
    var deviceIndex: i32 = -1;
    var extract_file: ?[:0]const u8 = null;
    var duration_sec: u32 = 60;

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        if (std.mem.eql(u8, args[arg_idx], "--extract")) {
            arg_idx += 1;
            if (arg_idx < args.len) extract_file = args[arg_idx];
        } else if (std.mem.eql(u8, args[arg_idx], "--duration")) {
            arg_idx += 1;
            if (arg_idx < args.len) duration_sec = std.fmt.parseInt(u32, args[arg_idx], 10) catch 60;
        } else if (filename == null) {
            filename = args[arg_idx];
        } else if (deviceIndex == -1) {
            deviceIndex = std.fmt.parseInt(i32, args[arg_idx], 10) catch -1;
        }
    }

    if (filename == null) {
        std.debug.print("Usage: mysidplayer <sidfile> [deviceIndex] [--extract outfile.wav] [--duration seconds]\n", .{});
        return;
    }

    const fname = filename.?;

    // Load ROMs
    const kernal = try loadRom(allocator, "rom/Kernal.rom");
    defer allocator.free(kernal);
    const basic = try loadRom(allocator, "rom/Basic.rom");
    defer allocator.free(basic);
    const chargen = try loadRom(allocator, "rom/Char.rom");
    defer allocator.free(chargen);

    if (extract_file) |outfile| {
        std.debug.print("Extracting to {s} for {d} seconds...\n", .{outfile, duration_sec});
        
        const file = c.fopen(outfile.ptr, "wb") orelse return error.FileCreateFailed;
        defer _ = c.fclose(file);

        const num_channels: u32 = 4;
        const sample_rate: u32 = 44100;
        const total_samples: usize = @as(usize, duration_sec) * sample_rate;
        const total_frames: usize = total_samples;
        
        var header = WavHeader{
            .num_channels = @intCast(num_channels),
            .sample_rate = sample_rate,
            .byte_rate = sample_rate * num_channels * 2,
            .block_align = @intCast(num_channels * 2),
            .data_size = @intCast(total_frames * num_channels * 2),
            .file_size = @intCast(36 + total_frames * num_channels * 2),
        };
        
        _ = c.fwrite(&header, 1, @sizeOf(WavHeader), file);

        var players: [4]*c.sidplayfp_t = undefined;
        var builders: [4]*c.SIDLiteBuilder_c = undefined;
        var tunes: [4]*c.SidTune_c = undefined;
        var contexts: [4]PlayerContext = undefined;

        var i: usize = 0;
        while (i < 4) : (i += 1) {
            players[i] = c.sid_new() orelse return error.SidInitFailed;
            c.sid_set_roms(players[i], kernal.ptr, basic.ptr, chargen.ptr);
            builders[i] = c.builder_new("ReSIDfp") orelse return error.BuilderInitFailed;
            tunes[i] = c.tune_new(fname.ptr) orelse return error.TuneLoadFailed;
            if (!c.tune_status(tunes[i])) {
                std.debug.print("Error: Failed to load tune '{s}'\n", .{fname});
                return;
            }
            _ = c.tune_select_song(tunes[i], c.tune_start_song(tunes[i])); 
            if (!c.sid_config(players[i], builders[i], sample_rate)) return error.ConfigFailed;
            if (!c.sid_load(players[i], tunes[i])) return error.LoadFailed;
            c.sid_init_mixer(players[i]);

            // Mute logic: We want player `i` to play ONLY voice `i`. So we mute all others.
            var v: usize = 0;
            while (v < 4) : (v += 1) {
                // voice 0-2 are regular voices, voice 3 is samples
                // enable = false means mute
                c.sid_mute(players[i], 0, @intCast(v), v != i);
            }

            contexts[i] = PlayerContext{
                .player = players[i],
                .clock_speed = c.tune_get_clock_speed(tunes[i]),
            };
        }

        defer {
            for (players) |p| c.sid_delete(p);
            for (builders) |b| c.builder_delete(b);
            for (tunes) |t| c.tune_delete(t);
        }

        // Loop and write
        var frames_written: usize = 0;
        const chunk_size = 4096; // Frames per chunk
        
        var mix_bufs: [4][chunk_size * 2]i16 = undefined;
        var out_buf: [chunk_size * 4]i16 = undefined;

        while (frames_written < total_frames) {
            const frames_to_write: usize = @min(chunk_size, total_frames - frames_written);
            
            // Advance all players
            for (&contexts, 0..) |*ctx, p_idx| {
                @memset(&mix_bufs[p_idx], 0);
                sid_callback(@ptrCast(&mix_bufs[p_idx]), @intCast(frames_to_write), ctx);
            }

            // Interleave
            var f: usize = 0;
            while (f < frames_to_write) : (f += 1) {
                // mix_bufs contains stereo: L, R, L, R...
                // we want: v0, v1, v2, v3 for each frame
                out_buf[f * 4 + 0] = mix_bufs[0][f * 2]; // Player 0 (Voice 0) Left channel
                out_buf[f * 4 + 1] = mix_bufs[1][f * 2]; // Player 1 (Voice 1) Left channel
                out_buf[f * 4 + 2] = mix_bufs[2][f * 2]; // Player 2 (Voice 2) Left channel
                out_buf[f * 4 + 3] = mix_bufs[3][f * 2]; // Player 3 (Voice 3) Left channel
            }

            _ = c.fwrite(out_buf[0..(frames_to_write * 4)].ptr, 2, frames_to_write * 4, file);
            frames_written += frames_to_write;
            
            if (frames_written % (44100 * 2) < chunk_size) {
                std.debug.print("\rExtracted {d}/{d} seconds...", .{frames_written / 44100, duration_sec});
            }
        }
        std.debug.print("\nExtraction complete!\n", .{});
        return;
    }

    // Normal playback path
    const player = c.sid_new() orelse return error.SidInitFailed;
    defer c.sid_delete(player);

    c.sid_set_roms(player, kernal.ptr, basic.ptr, chargen.ptr);

    const builder = c.builder_new("ReSIDfp");
    defer c.builder_delete(builder);

    const tune = c.tune_new(fname.ptr) orelse return error.TuneLoadFailed;
    defer c.tune_delete(tune);

    if (!c.tune_status(tune)) {
        std.debug.print("Error: Failed to load tune '{s}'\n", .{fname});
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

    std.debug.print("Playing:  {s} ({d} Hz)\n", .{fname, context.clock_speed});
    std.debug.print("Control:  Press Ctrl+C to stop.\n\n", .{});
    c.audio_start(audio);
    
    std.debug.print("Initialization complete. Starting playback...\n", .{});
    
    const start_time = c.time(null);
    
    while (true) {
        try init.io.sleep(.fromMilliseconds(1000), .awake);
        const elapsed = c.time(null) - start_time;
        const mins = @as(u32, @intCast(@max(0, @divFloor(elapsed, 60))));
        const secs = @as(u32, @intCast(@max(0, @mod(elapsed, 60))));
        
        std.debug.print("\rTime: {d:0>2}:{d:0>2} | Samples: {d}   ", .{mins, secs, context.sample_count});
    }
}
