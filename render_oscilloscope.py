import os
import sys
import argparse
import subprocess
import numpy as np
from scipy.io import wavfile
from ruamel.yaml import YAML

# Add ffmpeg to PATH manually since winget didn't update this session's PATH
os.environ["PATH"] += os.pathsep + r"C:\Users\topguy\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin"

def main():
    parser = argparse.ArgumentParser(description="Render oscilloscope video from multi-channel WAV.")
    parser.add_argument("input_wav", help="Input multi-channel wav file")
    parser.add_argument("--channels", type=int, default=4, help="Number of channels to render (default: 4)")
    parser.add_argument("--amp", type=float, default=1.0, help="Amplification factor for waveforms (default: 1.0)")
    parser.add_argument("--out", type=str, default="output.mp4", help="Output MP4 filename (default: output.mp4)")
    parser.add_argument("--thickness", type=float, default=1.5, help="Line thickness for waveforms (default: 1.5)")
    parser.add_argument("--bg", type=str, default="", help="Path to a background image file (e.g. bg.png)")
    parser.add_argument("--bg-dim", type=float, default=1.0, help="Brightness multiplier for the background image (e.g. 0.5 for 50%% brightness). Default is 1.0")
    parser.add_argument("--fx", type=str, default="none", choices=["none", "crt"], help="Post-processing effects to apply (none, crt). Default is none.")
    parser.add_argument("--duration", type=float, default=None, help="Optional duration in seconds to render (useful for testing).")
    args = parser.parse_args()
    
    input_wav = args.input_wav
    output_dir = "stems"
    
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"Reading {input_wav}...")
    sample_rate, data = wavfile.read(input_wav)
    
    if len(data.shape) != 2:
        print(f"Error: Expected multi-channel audio, got shape {data.shape}")
        sys.exit(1)
        
    if args.duration is not None:
        num_samples = int(args.duration * sample_rate)
        if num_samples < data.shape[0]:
            data = data[:num_samples]
        
    num_channels_to_render = min(args.channels, data.shape[1])
        
    stem_files = []
    for i in range(num_channels_to_render):
        stem_path = os.path.join(output_dir, f"channel_{i}.wav")
        print(f"Writing {stem_path}...")
        wavfile.write(stem_path, sample_rate, data[:, i])
        stem_files.append(stem_path)
        
    # Create a mono mix for master audio to avoid FFmpeg 4-channel encode errors
    print("Creating mono master mix...")
    # sum along channels, but avoid clipping by using float32, then cast back to int16
    mix = np.sum(data, axis=1, dtype=np.float32)
    # normalize
    max_val = np.max(np.abs(mix))
    if max_val > 0:
        mix = mix / max_val * 32767.0
    mix = mix.astype(np.int16)
    
    master_mix_path = os.path.join(output_dir, "master_mix.wav")
    wavfile.write(master_mix_path, sample_rate, mix)
    
    # Generate default corrscope yaml
    yaml_path = "project.yaml"
    cmd = ["python", "-m", "corrscope", *stem_files, "-a", master_mix_path, "-w"]
    print(f"Generating default config: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)
    
    # We need the generated yaml name, it defaults to the master_audio filename with .yaml
    default_yaml = "master_mix.yaml"
    if not os.path.exists(default_yaml):
        print(f"Cannot find generated yaml {default_yaml}")
        sys.exit(1)
        
    # Modify yaml
    print(f"Modifying {default_yaml}...")
    yaml = YAML()
    with open(default_yaml, "r") as f:
        config = yaml.load(f)
        
    # Global amplification
    config["amplification"] = args.amp
        
    # Custom Retro Colors and remove labels
    colors = ["#00ffff", "#ff2a6d", "#00ff00", "#ffff00", "#ff8800"]
    for i, ch in enumerate(config["channels"]):
        ch["line_color"] = colors[i % len(colors)]
        ch["label"] = "" # Blank label to remove redundancy
        
    config["layout"]["orientation"] = "v"
    
    # Remove channel separation lines/grids and set line thickness
    if "render" in config:
        config["render"]["h_midline"] = False
        config["render"]["v_midline"] = False
        config["render"]["grid_line_width"] = 0.0
        config["render"]["line_width"] = args.thickness
        config["render"]["grid_color"] = "#000000"
        config["render"]["midline_color"] = "#000000"
        config["render"]["stereo_bar_color"] = "#000000"
        config["render"]["stereo_grid_opacity"] = 0.0
        if args.bg:
            bg_path = args.bg
            if args.bg_dim != 1.0:
                print(f"Dimming background image by {args.bg_dim}...")
                try:
                    from PIL import Image, ImageEnhance
                    img = Image.open(args.bg)
                    enhancer = ImageEnhance.Brightness(img)
                    img_dimmed = enhancer.enhance(args.bg_dim)
                    dimmed_path = os.path.join(output_dir, "dimmed_bg.png")
                    img_dimmed.save(dimmed_path)
                    bg_path = dimmed_path
                except Exception as e:
                    print(f"Warning: Could not dim background image: {e}")
            
            # If we are doing the FX pass, we keep the background empty in Corrscope (rendering on black)
            # and compost it perfectly in FFmpeg later so the background image remains sharp and un-blurred!
            if args.fx == "none":
                config["render"]["bg_image"] = bg_path
            else:
                config["render"]["bg_image"] = ""
    
    with open(yaml_path, "w") as f:
        yaml.dump(config, f)
        
    # Hack to replace default label behavior safely without breaking yaml tags
    with open(yaml_path, "r") as f:
        yaml_text = f.read()
    yaml_text = yaml_text.replace("default_label: !DefaultLabel FileName", "default_label: !DefaultLabel NoLabel")
    yaml_text = yaml_text.replace("default_label: !DefaultLabel Number", "default_label: !DefaultLabel NoLabel")
    with open(yaml_path, "w") as f:
        f.write(yaml_text)
        
    print(f"Rendering video to {args.out}...")
    total_seconds = int(data.shape[0] / sample_rate)
    
    process = subprocess.Popen(["python", "-m", "corrscope", yaml_path, "-r", args.out], 
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    
    for line in process.stdout:
        line = line.strip()
        if line.isdigit():
            sec = int(line)
            percent = (sec / total_seconds) * 100 if total_seconds > 0 else 100
            bar_len = 40
            filled_len = int(bar_len * sec // total_seconds) if total_seconds > 0 else bar_len
            bar = '=' * filled_len + '-' * (bar_len - filled_len)
            sys.stdout.write(f"\r[{bar}] {percent:.1f}% ({sec}/{total_seconds}s)")
            sys.stdout.flush()
        elif line:
            # Clear the progress bar line before printing other info
            sys.stdout.write("\r" + " " * 80 + "\r")
            print(line)
            
    process.wait()
    sys.stdout.write("\n") # Newline after progress bar finishes
    if process.returncode != 0:
        print("Error: Corrscope rendering failed!")
        sys.exit(1)
    
    if args.fx == "crt":
        print(f"Applying lightning-fast GPU accelerated CRT/Glow FX to {args.out}...")
        fx_out = args.out.replace(".mp4", "_fx.mp4")
        
        # If a background image is provided, we compost it under the waveforms in FFmpeg.
        # We use a colorkey filter to make the waveforms' black background transparent,
        # and then overlay the glow and sharp waveforms over the background.
        # This keeps the background image 100% sharp and color-perfect, without any washing out!
        if args.bg:
            filtergraph = (
                "[0:v]colorkey=0x000000:0.1:0.1[waveforms_trans];"
                "[waveforms_trans]split[base][glow_src];"
                "[glow_src]scale=iw/4:ih/4,boxblur=5,scale=iw*4:ih*4[glow];"
                "[1:v]scale=1920:1080[bg];"
                "[bg][glow]overlay=format=auto[temp];"
                "[temp][base]overlay=format=auto[composed];"
                "[composed]drawgrid=w=10000:h=4:t=1:c=black@0.3[out]"
            )
            extra_inputs = ["-i", bg_path]
        else:
            filtergraph = (
                "[0:v]split[base][glow_src];"
                "[glow_src]scale=iw/4:ih/4,boxblur=5,scale=iw*4:ih*4[glow_blurred];"
                "[base][glow_blurred]blend=all_mode=screen[glowing];"
                "[glowing]drawgrid=w=10000:h=4:t=1:c=black@0.3[out]"
            )
            extra_inputs = []
        
        ffmpeg_bin = r"C:\Users\topguy\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin\ffmpeg.exe"
        
        encoders = [
            ("NVIDIA GPU (NVENC)", ["-c:v", "h264_nvenc", "-preset", "p1", "-cq", "18"]),
            ("AMD GPU (AMF)", ["-c:v", "h264_amf", "-quality", "speed", "-qp_i", "18", "-qp_p", "18"]),
            ("CPU (libx264)", ["-c:v", "libx264", "-preset", "fast", "-crf", "18", "-filter_threads", "2"])
        ]
        
        success = False
        for name, enc_args in encoders:
            print(f"Trying {name} encoder...")
            cmd = [
                ffmpeg_bin, "-y",
                "-i", args.out,
                *extra_inputs,
                "-filter_complex", filtergraph,
                "-map", "[out]", "-map", "0:a",
                *enc_args,
                "-c:a", "copy",
                "-progress", "-", "-nostats",
                fx_out
            ]
            try:
                # Use Popen to parse progress from stdout
                process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                
                for line in process.stdout:
                    line = line.strip()
                    if line.startswith("out_time_us="):
                        val = line.split("=")[1]
                        if val != "N/A" and val.lstrip('-').isdigit():
                            us = int(val)
                            sec = int(max(0, us) / 1000000)
                            percent = (sec / total_seconds) * 100 if total_seconds > 0 else 100
                            percent = min(100.0, percent)
                            sec_display = min(sec, total_seconds)
                            bar_len = 40
                            filled_len = int(bar_len * sec_display // total_seconds) if total_seconds > 0 else bar_len
                            bar = '=' * filled_len + '-' * (bar_len - filled_len)
                            sys.stdout.write(f"\r[{bar}] {percent:.1f}% ({sec_display}/{total_seconds}s)")
                            sys.stdout.flush()
                
                process.wait()
                if process.returncode == 0:
                    sys.stdout.write("\n")
                    success = True
                    print(f"Successfully encoded FX pass using {name}!")
                    break
                else:
                    sys.stdout.write("\n")
                    print(f"{name} encoding failed. Attempting next fallback...")
            except Exception as e:
                sys.stdout.write("\n")
                print(f"{name} encoding failed: {e}. Attempting next fallback...")
                
        if not success:
            print("Error: All video encoders failed!")
            sys.exit(1)
            
        print(f"Final FX video saved as {fx_out}!")
    
if __name__ == "__main__":
    main()
