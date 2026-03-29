# MySidPlayer

A high-fidelity Commodore 64 SID music player built with **Zig** and **libsidplayfp**. It uses the state-of-the-art **reSIDfp** engine for cycle-exact emulation.

## Features
- **Native Windows Build**: Compiled entirely from source using the Zig toolchain.
- **High Fidelity**: Cycle-accurate SID emulation using `libresidfp`.
- **Accurate Timing**: Correct PAL/NTSC speed detection.
- **Low Latency**: Audio output powered by `miniaudio`.
- **Metadata Support**: Displays Title, Author, and Release info from SID headers.

## Prerequisites
- **Zig 0.15.2** or newer.
- **C64 ROMs**: You need `Kernal.rom`, `Basic.rom`, and `Char.rom`. Place them in a folder named `rom/` in the project root.

## Setup & Build

### 1. Clone with Submodules
```bash
git clone --recursive <repo-url>
```
If you've already cloned without submodules:
```bash
git submodule update --init --recursive
```

### 2. Apply Patches
This project requires custom configuration and binary blobs for the submodules. Apply them using the helper script:
```bash
zig run apply_patches.zig
```

### 3. Build the Executable
```bash
# For a standard debug build
zig build

# For an optimized release build
zig build -Doptimize=ReleaseFast
```

## Usage
Run the player from the terminal by providing a `.sid` file:

```bash
.\zig-out\bin\mysidplayer.exe path/to/music.sid
```

### Audio Device Selection
If you have multiple audio outputs, you can list them by running the player and then restart it with a specific device index:
```bash
# Example: Use device index 3
.\zig-out\bin\mysidplayer.exe music.sid 3
```

## Technical Details
- **Language**: Zig (main logic and audio callback).
- **Core**: C++ (`libsidplayfp` and `libresidfp`).
- **Bridge**: Surgical C wrapper (`src/sid_wrapper.cpp`) for thread-safe interaction between Zig and C++.
- **Audio**: `miniaudio.h` (C).

## Credits
- [libsidplayfp](https://github.com/libsidplayfp/libsidplayfp): The main SID player engine.
- [libresidfp](https://github.com/libsidplayfp/libresidfp): The high-fidelity emulation engine.
- [miniaudio](https://github.com/mackron/miniaudio): Single-header audio playback library.
