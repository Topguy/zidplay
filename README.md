# ZidPlayer

A high-fidelity Commodore 64 SID music player and stem extractor built with **Zig** and **libsidplayfp**. It uses the state-of-the-art **reSIDfp** engine for cycle-exact emulation.

## Features
- **Native Windows Build**: Compiled entirely from source using the Zig 0.16.0 toolchain.
- **High Fidelity**: Cycle-accurate SID emulation using `libresidfp`.
- **Accurate Timing**: Correct PAL/NTSC speed detection.
- **Interactive TUI**: Live controls for Play/Pause, Next/Prev Song, and Volume.
- **Advanced Extractor**: Rip individual SID subsongs into perfectly timed, metadata-tagged, 4-channel WAV stems with automatic 5-second silence detection and trimming.
- **MD5 HVSC Support**: Automatically parses `Songlengths.md5` to display accurate track durations and automate track switching.

## Prerequisites
- **Zig 0.16.0**
- **C64 ROMs**: You need `Kernal.rom`, `Basic.rom`, and `Char.rom`. Place them in a folder named `rom/` in the project root.
- **Songlengths.md5**: For accurate track lengths, place this file in the project root. (Run `zidplayer --download-lengths` for instructions).

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
# For an optimized release build
zig build -Doptimize=ReleaseFast
```

## Usage
Run the player from the terminal by providing a `.sid` file:

```bash
.\zig-out\bin\zidplayer.exe path/to/music.sid
```

### CLI Options
```
  -h, --help           Show this help message
  -l, --list           List available audio devices and exit
  -d, --device <id>    Select audio device by ID (default: system default)
  -r, --roms <path>    Path to C64 ROMs directory (default: ./rom)
  --download-lengths   Show instructions to download Songlengths.md5 
  -t, --track <num>    Extract a specific subsong track (default: starting song)
  --extract <outfile>  Extract to multi-channel wav
  --duration <secs>    Extraction duration (overrides MD5 database)
```

### Interactive Controls
When playing a track normally in the terminal:
- `[Space]` Play/Pause
- `[N / P]` Next/Prev Song
- `[+ / -]` Adjust Volume
- `[Q / Esc]` Quit

## Oscilloscope Video Rendering
This repository also contains `render_oscilloscope.py`, a powerful Python utility that converts the multi-channel WAV stems extracted by `zidplayer` into visually stunning retro oscilloscope MP4 videos using `corrscope`.

### Render Features
- **Auto-Config Generation**: Automatically splits the master WAV into individual channels and generates a customized `yaml` configuration for `corrscope`.
- **Custom Retro Colors**: Automatically applies bright, neon retro colors to the separate audio channels.
- **Hardware-Accelerated FX**: Includes a `--fx crt` flag that adds retro CRT scanlines utilizing lightning-fast GPU-accelerated FFmpeg encoders (NVENC/AMF) with CPU fallbacks.
- **Backgrounds**: Supports placing a custom image behind the waveforms using the `--bg` flag (and dimming it with `--bg-dim`).

### Example Render Pipeline
1. **Extract the audio**:
```bash
.\zig-out\bin\zidplayer.exe Sanxion.sid --extract sanxion.wav -t 1
```
2. **Render the video** (with CRT effects and a background):
```bash
python render_oscilloscope.py sanxion.wav --out sanxion.mp4 --bg sanxion_bg.jpg --bg-dim 0.4 --fx crt
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
