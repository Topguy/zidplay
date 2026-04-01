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
    const data = std.fs.cwd().readFileAlloc(allocator, "Songlengths.md5", 10 * 1024 * 1024) catch {
        return try allocator.alloc(u32, 0);
    };
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
    track_start_time.* = std.time.timestamp();
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
        \\  --download-lengths   Show instructions to download Songlengths.md5 
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
    
    // Calculate MD5s for HVSC compatibility
    const sid_data = try std.fs.cwd().readFileAlloc(allocator, sid_file, 1024 * 1024);
    defer allocator.free(sid_data);
    
    var md5_full_buf: [16]u8 = undefined;
    Md5.hash(sid_data, &md5_full_buf, .{});
    
    var md5_headerless_buf: [16]u8 = undefined;
    if (sid_data.len > 124) {
        Md5.hash(sid_data[124..], &md5_headerless_buf, .{});
    } else {
        @memcpy(&md5_headerless_buf, &md5_full_buf);
    }
    
    var full_str_buf: [32]u8 = undefined;
    var hl_str_buf: [32]u8 = undefined;
    
    for (md5_full_buf, 0..) |b, j| {
        _ = std.fmt.bufPrint(full_str_buf[j * 2 .. j * 2 + 2], "{x:0>2}", .{b}) catch unreachable;
    }
    for (md5_headerless_buf, 0..) |b, j| {
        _ = std.fmt.bufPrint(hl_str_buf[j * 2 .. j * 2 + 2], "{x:0>2}", .{b}) catch unreachable;
    }

    const hl_str = &hl_str_buf;
    const full_str = &full_str_buf;

    // Try headerless first, then full-file
    var song_lengths = parseSongLengths(allocator, hl_str) catch &.{};
    var used_md5 = hl_str;
    if (song_lengths.len == 0) {
        song_lengths = parseSongLengths(allocator, full_str) catch &.{};
        used_md5 = full_str;
    }
    defer allocator.free(song_lengths);

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
    
    const start_time = std.time.timestamp();
    var track_start_time = std.time.timestamp();
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

        const now = std.time.timestamp();
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
        
        const status = if (context.is_paused) "PAUSED" else "PLAYING";
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
        
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    std.debug.print("\nStopped.\n", .{});
}

