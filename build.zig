const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zidplayer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    const mod = exe.root_module;


    // Include paths
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(b.path("libsidplayfp/src"));
    mod.addIncludePath(b.path("libsidplayfp/src/sidplayfp"));
    mod.addIncludePath(b.path("libsidplayfp/src/builders/residfp-builder"));
    mod.addIncludePath(b.path("libresidfp/src"));

    // Core C++ Source files
    const cpp_srcs = [_][]const u8{
        "libsidplayfp/src/EventScheduler.cpp",
        "libsidplayfp/src/player.cpp",
        "libsidplayfp/src/psiddrv.cpp",
        "libsidplayfp/src/reloc65.cpp",
        "libsidplayfp/src/sidemu.cpp",
        "libsidplayfp/src/simpleMixer.cpp",
        "libsidplayfp/src/c64/c64.cpp",
        "libsidplayfp/src/c64/mmu.cpp",
        "libsidplayfp/src/c64/VIC_II/mos656x.cpp",
        "libsidplayfp/src/c64/CPU/mos6510.cpp",
        "libsidplayfp/src/c64/CPU/mos6510debug.cpp",
        "libsidplayfp/src/c64/CIA/interrupt.cpp",
        "libsidplayfp/src/c64/CIA/mos652x.cpp",
        "libsidplayfp/src/c64/CIA/SerialPort.cpp",
        "libsidplayfp/src/c64/CIA/timer.cpp",
        "libsidplayfp/src/c64/CIA/tod.cpp",
        "libsidplayfp/src/sidplayfp/sidplayfp.cpp",
        "libsidplayfp/src/sidplayfp/sidbuilder.cpp",
        "libsidplayfp/src/sidplayfp/SidConfig.cpp",
        "libsidplayfp/src/sidplayfp/SidInfo.cpp",
        "libsidplayfp/src/sidplayfp/SidTune.cpp",
        "libsidplayfp/src/sidplayfp/SidTuneInfo.cpp",
        "libsidplayfp/src/sidtune/MUS.cpp",
        "libsidplayfp/src/sidtune/p00.cpp",
        "libsidplayfp/src/sidtune/prg.cpp",
        "libsidplayfp/src/sidtune/PSID.cpp",
        "libsidplayfp/src/sidtune/SidTuneBase.cpp",
        "libsidplayfp/src/sidtune/SidTuneTools.cpp",
        "libsidplayfp/src/utils/iniParser.cpp",
        "libsidplayfp/src/utils/SidDatabase.cpp",
        "libsidplayfp/src/utils/STILview/stil.cpp",
        "libsidplayfp/src/builders/residfp-builder/residfp-builder.cpp",
        "libsidplayfp/src/builders/residfp-builder/residfp-emu.cpp",
        "libresidfp/src/Dac.cpp",
        "libresidfp/src/EnvelopeGenerator.cpp",
        "libresidfp/src/ExternalFilter.cpp",
        "libresidfp/src/Filter.cpp",
        "libresidfp/src/Filter6581.cpp",
        "libresidfp/src/Filter8580.cpp",
        "libresidfp/src/FilterModelConfig.cpp",
        "libresidfp/src/FilterModelConfig6581.cpp",
        "libresidfp/src/FilterModelConfig8580.cpp",
        "libresidfp/src/Integrator6581.cpp",
        "libresidfp/src/Integrator8580.cpp",
        "libresidfp/src/OpAmp.cpp",
        "libresidfp/src/SID.cpp",
        "libresidfp/src/Spline.cpp",
        "libresidfp/src/WaveformCalculator.cpp",
        "libresidfp/src/WaveformGenerator.cpp",
        "libresidfp/src/resample/SincResampler.cpp",
        "libresidfp/src/residfp/residfp.cpp",
        "src/sid_wrapper.cpp",
    };

    mod.addCSourceFiles(.{
        .files = &cpp_srcs,
        .flags = &.{"-std=c++17", "-DHAVE_CONFIG_H", "-fno-sanitize=undefined", "-DNDEBUG"},
    });

    // Core C Source files
    const c_srcs = [_][]const u8{
        "src/audio_engine.c",
    };

    mod.addCSourceFiles(.{
        .files = &c_srcs,
        .flags = &.{"-DHAVE_CONFIG_H", "-DNDEBUG"},
    });

    // Link Windows system libraries for miniaudio
    exe.root_module.linkSystemLibrary("winmm", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
