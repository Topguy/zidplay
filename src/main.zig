// MySidPlayer - A high-fidelity Zig SID player
// Copyright (C) 2026 Steinar Barbakken <topguyz@gmail.com>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.

const std = @import("std");
const Md5 = std.crypto.hash.Md5;

const c = @cImport({
    @cInclude("sid_wrapper.h");
    @cInclude("audio_engine.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cInclude("windows.h");
});

const VK_SPACE = 0x20;
const VK_ADD = 0x6B;
const VK_SUBTRACT = 0x6D;
const VK_OEM_PLUS = 0xBB;
const VK_OEM_MINUS = 0xBD;
const VK_P = 0x50;
const VK_N = 0x4E;
const VK_Q = 0x51;
const VK_ESCAPE = 0x1B;

const PlayerContext = struct {
    player: *c.sidplayfp_t,
    tune: *c.SidTune_t,
    sample_count: usize = 0,
    clock_speed: u32 = 985248,
    is_paused: bool = false,
    volume: f32 = 1.0,
    current_song: u32 = 0,
    total_songs: u32 = 0,
    song_lengths: []const u32 = &.{}, // Lengths in seconds for each sub-song
    silent_frames: u32 = 0,
    
    // Leftover buffer handling
    leftover_buf: [16384]i16 = undefined,
    leftover_count: u32 = 0,
};

fn printDownloadInstructions() void {
    const url = "https://www.hvsc.c64.org/download/C64Music/DOCUMENTS/Songlengths.md5";
    std.debug.print(
        \\
        \\To enable song length detection and auto-next:
        \\1. Download the MD5 database from: {s}
        \\2. Place the 'Songlengths.md5' file in the same folder as this executable.
        \\
    , .{url});
}

fn parseSongLengths(allocator: std.mem.Allocator, md5: []const u8) ![]u32 {
    const file = c.fopen("Songlengths.md5", "rb") orelse return try allocator.alloc(u32, 0);
    _ = c.fseek(file, 0, c.SEEK_END);
    const size = @as(usize, @intCast(c.ftell(file)));
    _ = c.fseek(file, 0, c.SEEK_SET);
    if (size > 10 * 1024 * 1024) {
        _ = c.fclose(file);
        return try allocator.alloc(u32, 0);
    }
    const data = try allocator.alloc(u8, size);
    _ = c.fread(data.ptr, 1, size, file);
    _ = c.fclose(file);
    defer allocator.free(data);

    var it = std.mem.splitSequence(u8, data, "\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r ");
        if (line.len < 33 or line[0] == ';' or line[0] == '[') continue;
        
        const eq_idx = std.mem.indexOf(u8, line, "=") orelse continue;
        const line_md5 = line[0..eq_idx];
        
        if (std.mem.eql(u8, line_md5, md5)) {
            const times_part = line[eq_idx + 1 ..];
            var time_it = std.mem.splitScalar(u8, times_part, ' ');
            
            var tmp_lengths: [256]u32 = undefined;
            var count: usize = 0;
            
            while (time_it.next()) |time_str| {
                const t = std.mem.trim(u8, time_str, " ");
                if (t.len < 3) continue;
                var part_it = std.mem.splitScalar(u8, t, ':');
                const mins_str = part_it.next() orelse continue;
                const secs_str = part_it.next() orelse continue;
                
                const mins = std.fmt.parseInt(u32, mins_str, 10) catch continue;
                const secs = std.fmt.parseInt(u32, secs_str, 10) catch continue;
                if (count < tmp_lengths.len) {
                    tmp_lengths[count] = mins * 60 + secs;
                    count += 1;
                }
            }
            const result = try allocator.alloc(u32, count);
            @memcpy(result, tmp_lengths[0..count]);
            return result;
        }
    }
    return try allocator.alloc(u32, 0);
}

fn switchSong(context: *PlayerContext, songNum: u32, track_start_time: *i64) void {
    if (songNum < 1 or songNum > context.total_songs) return;

    c.sid_lock(context.player);
    defer c.sid_unlock(context.player);

    _ = c.tune_select_song(context.tune, songNum);
    _ = c.sid_load(context.player, context.tune);
    c.sid_init_mixer(context.player);

    context.current_song = songNum;
    context.clock_speed = c.tune_get_clock_speed(context.tune);
    context.leftover_count = 0;
    context.silent_frames = 0;
    track_start_time.* = c.time(null);
}

fn sid_callback(buffer: [*c]i16, frameCount: u32, pUserData: ?*anyopaque) callconv(.c) void {
    const ctx: *PlayerContext = @ptrCast(@alignCast(pUserData));
    
    c.sid_lock(ctx.player);
    defer c.sid_unlock(ctx.player);

    if (ctx.is_paused) {
        @memset(buffer[0..(frameCount * 2)], 0);
        return;
    }

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

    // Silence detection (Check after mixing with low threshold)
    var is_silent = true;
    for (0..(frameCount * 2)) |i| {
        if (buffer[i] > 100 or buffer[i] < -100) {
            is_silent = false;
            break;
        }
    }
    if (is_silent) {
        ctx.silent_frames += frameCount;
    } else {
        ctx.silent_frames = 0;
    }
}

fn loadRom(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
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

fn writeRiffTag(file: *c.FILE, tag: []const u8, value: []const u8) u32 {
    if (value.len == 0) return 0;
    _ = c.fwrite(tag.ptr, 1, 4, file);
    const size_with_null = @as(u32, @intCast(value.len + 1));
    _ = c.fwrite(&size_with_null, 4, 1, file);
    _ = c.fwrite(value.ptr, 1, value.len, file);
    const zero: u8 = 0;
    _ = c.fwrite(&zero, 1, 1, file);
    var total_written: u32 = 4 + 4 + size_with_null;
    if (size_with_null % 2 != 0) {
        _ = c.fwrite(&zero, 1, 1, file);
        total_written += 1;
    }
    return total_written;
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
        \\  --download-lengths   Show instructions to download Songlengths.md5 
        \\  --extract <outfile>  Extract to multi-channel wav
        \\  --duration <secs>    Extraction duration
        \\
    , .{exe_name});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var filename: ?[]const u8 = null;
    var deviceIndex: i32 = -1;
    var extract_file: ?[:0]const u8 = null;
    var duration_sec: ?u32 = null;
    var track_arg: ?u32 = null;
    var rom_base: []const u8 = "rom";
    var list_devices = false;
    var download_lengths = false;

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0]);
            return;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_devices = true;
        } else if (std.mem.eql(u8, arg, "--download-lengths")) {
            download_lengths = true;
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
        } else if (std.mem.eql(u8, arg, "--extract")) {
            arg_i += 1;
            if (arg_i < args.len) extract_file = @ptrCast(args[arg_i]);
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--track")) {
            arg_i += 1;
            if (arg_i < args.len) track_arg = std.fmt.parseInt(u32, args[arg_i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--duration")) {
            arg_i += 1;
            if (arg_i < args.len) duration_sec = std.fmt.parseInt(u32, args[arg_i], 10) catch null;
        } else if (filename == null) {
            filename = arg;
        }
    }

    if (download_lengths) {
        printDownloadInstructions();
        if (filename == null) return;
    }

    if (list_devices) {
        c.audio_list_devices();
        return;
    }

    const sid_file = filename orelse {
        printUsage(args[0]);
        return;
    };

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

    // Calculate MD5s and parse lengths EARLY
    var song_lengths: []u32 = &.{};
    var used_md5: []const u8 = "";
    var hl_str_buf: [32]u8 = undefined;
    var full_str_buf: [32]u8 = undefined;
    {
        var sid_data: []u8 = undefined;
        const path_z = try allocator.dupeZ(u8, sid_file);
        defer allocator.free(path_z);
        if (c.fopen(path_z.ptr, "rb")) |f| {
            _ = c.fseek(f, 0, c.SEEK_END);
            const size = @as(usize, @intCast(c.ftell(f)));
            _ = c.fseek(f, 0, c.SEEK_SET);
            sid_data = try allocator.alloc(u8, size);
            _ = c.fread(sid_data.ptr, 1, size, f);
            _ = c.fclose(f);
            
            var md5_full_buf: [16]u8 = undefined;
            Md5.hash(sid_data, &md5_full_buf, .{});
            
            var md5_headerless_buf: [16]u8 = undefined;
            if (sid_data.len > 124) {
                Md5.hash(sid_data[124..], &md5_headerless_buf, .{});
            } else {
                @memcpy(&md5_headerless_buf, &md5_full_buf);
            }
            
            for (md5_full_buf, 0..) |b, j| {
                _ = std.fmt.bufPrint(full_str_buf[j * 2 .. j * 2 + 2], "{x:0>2}", .{b}) catch unreachable;
            }
            for (md5_headerless_buf, 0..) |b, j| {
                _ = std.fmt.bufPrint(hl_str_buf[j * 2 .. j * 2 + 2], "{x:0>2}", .{b}) catch unreachable;
            }
            
            song_lengths = parseSongLengths(allocator, &hl_str_buf) catch &.{};
            used_md5 = &hl_str_buf;
            if (song_lengths.len == 0) {
                song_lengths = parseSongLengths(allocator, &full_str_buf) catch &.{};
                used_md5 = &full_str_buf;
            }
            allocator.free(sid_data);
        }
    }
    defer allocator.free(song_lengths);

    if (extract_file) |outfile| {
        const tmp_tune = c.tune_new(sid_file.ptr) orelse return error.TuneLoadFailed;
        const start_song = if (track_arg) |t| t else c.tune_start_song(tmp_tune);
        
        // Save metadata strings
        const title = c.tune_info_string(tmp_tune, 0);
        const author = c.tune_info_string(tmp_tune, 1);
        const released = c.tune_info_string(tmp_tune, 2);
        
        var title_str: []const u8 = "";
        var author_str: []const u8 = "";
        var released_str: []const u8 = "";
        
        if (title != null) title_str = std.mem.span(title);
        if (author != null) author_str = std.mem.span(author);
        if (released != null) released_str = std.mem.span(released);

        c.tune_delete(tmp_tune);
        
        if (duration_sec == null and start_song > 0 and start_song <= song_lengths.len) {
            const length = song_lengths[start_song - 1];
            if (length > 0) duration_sec = length;
        }

        if (duration_sec == null) {
            std.debug.print("Error: No duration given and track length not found in database.\nUse --duration <secs> to specify extraction length.\n", .{});
            return;
        }

        const exact_duration = duration_sec.?;
        std.debug.print("Extracting track {d} to {s} (max {d} seconds)...\n", .{start_song, outfile, exact_duration});
        
        const file = c.fopen(outfile.ptr, "wb") orelse return error.FileCreateFailed;
        defer _ = c.fclose(file);

        const num_channels: u32 = 4;
        const sample_rate: u32 = 44100;
        const total_samples: usize = @as(usize, exact_duration) * sample_rate;
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
            c.sid_set_roms(players[i], 
                if (kernal) |k| k.ptr else null, 
                if (basic) |b| b.ptr else null, 
                if (chargen) |c_gen| c_gen.ptr else null
            );
            builders[i] = c.builder_new("ReSIDfp") orelse return error.BuilderInitFailed;
            tunes[i] = c.tune_new(sid_file.ptr) orelse return error.TuneLoadFailed;
            _ = c.tune_select_song(tunes[i], start_song); 
            if (!c.sid_config(players[i], builders[i], sample_rate)) return error.ConfigFailed;
            if (!c.sid_load(players[i], tunes[i])) return error.LoadFailed;
            c.sid_init_mixer(players[i]);

            var v: usize = 0;
            while (v < 4) : (v += 1) {
                c.sid_mute(players[i], 0, @intCast(v), v != i);
            }

            contexts[i] = PlayerContext{
                .player = players[i],
                .tune = tunes[i],
                .clock_speed = c.tune_get_clock_speed(tunes[i]),
            };
        }

        defer {
            for (players) |p| c.sid_delete(p);
            for (builders) |b| c.builder_delete(b);
            for (tunes) |t| c.tune_delete(t);
        }

        var frames_written: usize = 0;
        const chunk_size = 4096;
        
        var mix_bufs: [4][chunk_size * 2]i16 = undefined;
        var out_buf: [chunk_size * 4]i16 = undefined;

        while (frames_written < total_frames) {
            const frames_to_write: usize = @min(chunk_size, total_frames - frames_written);
            
            for (&contexts, 0..) |*ctx, p_idx| {
                @memset(&mix_bufs[p_idx], 0);
                sid_callback(@ptrCast(&mix_bufs[p_idx]), @intCast(frames_to_write), ctx);
            }

            var f: usize = 0;
            while (f < frames_to_write) : (f += 1) {
                out_buf[f * 4 + 0] = mix_bufs[0][f * 2];
                out_buf[f * 4 + 1] = mix_bufs[1][f * 2];
                out_buf[f * 4 + 2] = mix_bufs[2][f * 2];
                out_buf[f * 4 + 3] = mix_bufs[3][f * 2];
            }

            _ = c.fwrite(out_buf[0..(frames_to_write * 4)].ptr, 2, frames_to_write * 4, file);
            frames_written += frames_to_write;
            
            var all_silent = true;
            for (&contexts) |*ctx| {
                if (ctx.silent_frames < 44100 * 5) {
                    all_silent = false;
                    break;
                }
            }
            if (all_silent) {
                std.debug.print("\nExtraction stopped early (5 seconds of silence detected).\n", .{});
                break;
            }
            
            if (frames_written % (44100 * 2) < chunk_size) {
                std.debug.print("\rExtracted {d}/{d} seconds...", .{frames_written / 44100, exact_duration});
            }
        }
        
        var list_size: u32 = 4;
        var has_tags = false;
        if (title_str.len > 0) { list_size += @as(u32, @intCast(8 + title_str.len + 1 + (if ((title_str.len + 1) % 2 != 0) @as(u32, 1) else 0))); has_tags = true; }
        if (author_str.len > 0) { list_size += @as(u32, @intCast(8 + author_str.len + 1 + (if ((author_str.len + 1) % 2 != 0) @as(u32, 1) else 0))); has_tags = true; }
        if (released_str.len > 0) { list_size += @as(u32, @intCast(8 + released_str.len + 1 + (if ((released_str.len + 1) % 2 != 0) @as(u32, 1) else 0))); has_tags = true; }
        
        if (has_tags) {
            _ = c.fwrite("LIST", 1, 4, file);
            _ = c.fwrite(&list_size, 4, 1, file);
            _ = c.fwrite("INFO", 1, 4, file);
            _ = writeRiffTag(file, "INAM", title_str);
            _ = writeRiffTag(file, "IART", author_str);
            _ = writeRiffTag(file, "ICRD", released_str);
        }
        
        const final_data_size = @as(u32, @intCast(frames_written * num_channels * 2));
        const final_file_size = 36 + final_data_size + if (has_tags) (8 + list_size) else 0;
        
        header.data_size = final_data_size;
        header.file_size = final_file_size;
        
        _ = c.fseek(file, 0, c.SEEK_SET);
        _ = c.fwrite(&header, 1, @sizeOf(WavHeader), file);
        
        std.debug.print("\nExtraction complete!\n", .{});
        return;
    }

    const player = c.sid_new() orelse return error.SidInitFailed;
    defer c.sid_delete(player);

    c.sid_set_roms(player, 
        if (kernal) |k| k.ptr else null, 
        if (basic) |b| b.ptr else null, 
        if (chargen) |c_gen| c_gen.ptr else null
    );

    const builder = c.builder_new("ReSIDfp");
    defer c.builder_delete(builder);

    const tune = c.tune_new(sid_file.ptr) orelse return error.TuneLoadFailed;
    defer c.tune_delete(tune);

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
        .tune = tune,
        .clock_speed = c.tune_get_clock_speed(tune),
        .current_song = start_song,
        .total_songs = total_songs,
        .song_lengths = song_lengths,
    };

    const audio = c.audio_init(sid_callback, &context, deviceIndex) orelse return error.AudioInitFailed;
    defer c.audio_deinit(audio);

    const clock_type = if (context.clock_speed == 1022727) "NTSC" else "PAL";
    std.debug.print("System:   {s} ({d} Hz)\n", .{clock_type, context.clock_speed});
    std.debug.print("MD5:      {s}\n", .{used_md5});
    std.debug.print("Playing:  {s}\n", .{sid_file});
    
    if (song_lengths.len > 0) {
        std.debug.print("Lengths:  ", .{});
        for (song_lengths, 0..) |len, idx| {
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("{d}:{d:0>2}", .{@divTrunc(len, 60), @mod(len, 60)});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\nControls: [Space] Play/Pause | [N/P] Next/Prev Song | [+/-] Volume | [Q] Quit\n\n", .{});
    
    c.audio_start(audio);
    
    const start_time = c.time(null);
    var track_start_time = c.time(null);
    const hIn = c.GetStdHandle(c.STD_INPUT_HANDLE);
    
    var running = true;
    while (running) {
        // Handle Input
        var num_events: c.DWORD = 0;
        if (c.GetNumberOfConsoleInputEvents(hIn, &num_events) != 0 and num_events > 0) {
            var input_record: c.INPUT_RECORD = undefined;
            var events_read: c.DWORD = 0;
            if (c.ReadConsoleInputW(hIn, &input_record, 1, &events_read) != 0) {
                if (input_record.EventType == c.KEY_EVENT and input_record.Event.KeyEvent.bKeyDown != 0) {
                    const key = input_record.Event.KeyEvent.wVirtualKeyCode;
                    switch (key) {
                        VK_SPACE => {
                            context.is_paused = !context.is_paused;
                        },
                        VK_Q, VK_ESCAPE => {
                            running = false;
                        },
                        VK_ADD, VK_OEM_PLUS => {
                            context.volume = @min(1.0, context.volume + 0.1);
                            c.audio_set_volume(audio, context.volume);
                        },
                        VK_SUBTRACT, VK_OEM_MINUS => {
                            context.volume = @max(0.0, context.volume - 0.1);
                            c.audio_set_volume(audio, context.volume);
                        },
                        VK_N => {
                            switchSong(&context, context.current_song + 1, &track_start_time);
                        },
                        VK_P => {
                            switchSong(&context, context.current_song - 1, &track_start_time);
                        },
                        else => {},
                    }
                }
            }
        }

        const now = c.time(null);
        const elapsed = now - start_time;
        const track_elapsed = now - track_start_time;

        // Auto-advance logic
        var should_advance = false;
        
        // 1. Check song length if available
        if (context.current_song <= context.song_lengths.len) {
            const len = context.song_lengths[context.current_song - 1];
            if (len > 0 and track_elapsed >= len) {
                should_advance = true;
                std.debug.print("\rTrack finished (length reached).             \n", .{});
            }
        }
        
        // 2. Check silence (6 seconds)
        const silent_secs = @as(f32, @floatFromInt(context.silent_frames)) / 44100.0;
        if (silent_secs > 6.0) {
            should_advance = true;
            std.debug.print("\rTrack finished (silence detected).             \n", .{});
        }

        if (should_advance) {
            if (context.current_song < context.total_songs) {
                switchSong(&context, context.current_song + 1, &track_start_time);
            } else {
                running = false;
            }
        }

        const mins = @as(u32, @intCast(@max(0, @divFloor(elapsed, 60))));
        const secs = @as(u32, @intCast(@max(0, @mod(elapsed, 60))));
        
        const track_mins = @as(u32, @intCast(@max(0, @divFloor(track_elapsed, 60))));
        const track_secs = @as(u32, @intCast(@max(0, @mod(track_elapsed, 60))));
        
        const status = if (context.is_paused) "PAUSED " else "PLAYING";
        std.debug.print("\r[{s}] Song: {d}/{d} | Vol: {d: >3}% | Track: {d:0>2}:{d:0>2} | Time: {d:0>2}:{d:0>2} | Samples: {d}       ", .{
            status, 
            context.current_song, 
            context.total_songs,
            @as(u32, @intFromFloat(context.volume * 100)),
            track_mins,
            track_secs,
            mins, 
            secs, 
            context.sample_count
        });
        
        c.Sleep(50);
    }
    std.debug.print("\nStopped.\n", .{});
}
