# Project: ZidPlayer (Zig + libsidplayfp)

## Current Status
We have successfully implemented a **native Windows build** using Zig's internal C++ toolchain (Zig 0.16.0). We are no longer using precompiled `.a` libraries from WSL2, which has resolved all ABI and linking issues.

### Files & Structure:
- `src/main.zig`: Entry point for the player (includes TUI and Extraction pipeline).
- `src/sid_wrapper.cpp / .h`: C wrapper for the `libsidplayfp` C++ API.
- `build.zig`: Modern Zig build script that compiles the entire `libsidplayfp` source tree and the player.
- `libsidplayfp/`: Source code for the library, including required `.bin` blobs (psiddrv, sidplayer1/2).

### Build Command:
```powershell
zig build
```
The executable is generated at `zig-out/bin/zidplayer.exe`.

### Key Features Implemented:
1. **Interactive TUI**: Space to pause, N/P to skip tracks, +/- for volume.
2. **Advanced WAV Extractor**: `--extract <outfile.wav>`
   - Automatically checks `Songlengths.md5` for precise durations.
   - Trims dead air automatically (5-second silence detector).
   - Allows specific track extractions with `--track <num>`.
   - Injects RIFF `INFO` metadata directly into the WAV.
3. **HVSC Metadata Parser**: Hashes incoming `.sid` files and matches lengths against the HVSC database.

## How to Initialize as a Git Repo
If you want to move this project to a clean Git repository with submodules:

1. **Delete current folders**: `rm -Recurse libsidplayfp, libresidfp`
2. **Add Submodules**:
   ```bash
   git submodule add https://github.com/libsidplayfp/libsidplayfp.git libsidplayfp
   git submodule add https://github.com/libsidplayfp/libresidfp.git libresidfp
   ```
3. **Lock to working versions**:
   - `libsidplayfp`: `616d2e7e2da618ef29f2a4044a9a4d58e790bf20`
   - `libresidfp`: `24f204e684e5cecf909fc77b72835d489ad85b4a`
4. **Apply Patches**: `zig run apply_patches.zig`
5. **Build**: `zig build`

## Git Guidelines
- The user uses a local forgejo repository at `http://192.168.10.98:3333/topguy/zidplay.git`.
- Always use `git commit -F commit_msg.txt; Remove-Item commit_msg.txt` for commits.
