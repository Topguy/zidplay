# Project: MySidPlayer (Zig + libsidplayfp)

## Current Status
We have successfully implemented a **native Windows build** using Zig's internal C++ toolchain. We are no longer using precompiled `.a` libraries from WSL2, which has resolved all ABI and linking issues.

### Files & Structure:
- `src/main.zig`: Entry point for the player.
- `src/sid_wrapper.cpp / .h`: C wrapper for the `libsidplayfp` C++ API.
- `build.zig`: Modern Zig build script that compiles the entire `libsidplayfp` source tree and the player.
- `libsidplayfp/`: Source code for the library, including required `.bin` blobs (psiddrv, sidplayer1/2).

### Build Command:
```powershell
zig build
```
The executable is generated at `zig-out/bin/mysidplayer.exe`.

### How to Run:
```powershell
zig build run -- path/to/tune.sid
```

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

## Planned Next Steps
1. **Interactive UI**: Add a simple TUI or GUI to control playback (play, pause, skip).
