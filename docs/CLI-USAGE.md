# TL;DR

**Build the Docker image:**
```powershell
cd uade-docker
docker build -t uade-cli .
```

**Convert a module to WAV (works on Windows):**
```powershell
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/space-debris.mod 'https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod' && /usr/local/bin/uade123 -c -f /output/space-debris.wav /tmp/space-debris.mod"
```

_Output: `$env:USERPROFILE\Music\space-debris.wav`_

---

# UADE Docker Player

A Docker container for playing Amiga music modules using UADE (Unix Amiga Delitracker Emulator).

## About UADE

UADE is a music player for Unix that plays old Amiga music formats by emulating the Amiga hardware. It supports over 100 different Amiga music formats from the 1980s and 1990s, including Protracker, TFMX, AHX, and many more exotic formats.

**UADE Home Page:** <https://zakalwe.fi/uade/>
**Official UADE Repository:** <https://gitlab.com/uade-music-player/uade>

## Prerequisites

- Docker Desktop for Windows installed and running
- Amiga module files (`.mod`, `.ahx`, TFMX `mdat.*`/`smpl.*` pairs, etc.) on your Windows system

## Building the Image

Open PowerShell and navigate to the directory containing the Dockerfile:

```powershell
cd uade-docker
docker build -t uade-cli .
```

## Audio Output on Windows

Docker on Windows doesn't support direct audio passthrough. Here are working solutions:

### Option 1: Convert to WAV (Recommended)

Convert modules to WAV files that you can play on Windows:

```powershell
# Convert a single module to WAV (use -c for headless mode, no audio device needed)
docker run --rm -v "C:\path\to\your\modules:/music" uade-cli -c -f /music/output.wav /music/song.mod

# Convert multiple modules
docker run --rm -v "C:\path\to\your\modules:/music" uade-cli -c -f /music/output.wav /music/*.mod
```

Then play the WAV file with any Windows audio player.

### Option 2: UADEFS with FUSE (Advanced)

Use `uadefs` to mount modules as a virtual filesystem that converts them to WAV on-the-fly:

**Setup Requirements:**

- WSL2 with FUSE support
- WinFsp (FUSE for Windows) or access modules through WSL2

**Inside WSL2:**

```bash
# Mount modules as WAV files
uadefs /path/to/modules /mnt/uade-mount

# Now each .mod appears as .wav in /mnt/uade-mount
# Play them with any audio player
mpv /mnt/uade-mount/song.mod.wav
```

This allows real-time streaming without pre-converting files, but requires WSL2 setup.

### Option 3: Use WSL2 with PulseAudio

If you're using WSL2, you can set up PulseAudio for real-time playback:

1. Install PulseAudio in WSL2
2. Configure Docker to use WSL2 backend
3. Set the PULSE_SERVER environment variable

```powershell
docker run --rm -e PULSE_SERVER=unix:/tmp/pulseaudio.socket -v "C:\path\to\modules:/music" uade-cli /music/song.mod
```

### Basic Usage (No Audio)

To test without audio output:

```powershell
docker run --rm -v "C:\path\to\your\modules:/music" uade-cli /music/yourfile.mod
```

### Common Options

- `-v "C:\path\to\modules:/music"` - Mounts your Windows folder into the container
- `--rm` - Automatically removes the container after playback finishes
- `-i` - Interactive mode (allows you to stop playback with Ctrl+C)

### Additional UADE Options

You can pass any UADE command-line options:

```powershell
# Show help
docker run --rm uade-cli --help

# Play with specific subsong
docker run --rm -v "C:\path\to\modules:/music" uade-cli -s 2 /music/song.mod

# Set frequency
docker run --rm -v "C:\path\to\modules:/music" uade-cli -f 48000 /music/song.mod

# Shuffle playback
docker run --rm -v "C:\path\to\modules:/music" uade-cli -z /music/*.mod
```

## Downloading Modules from the Internet

You can download modules directly into the container and convert them to WAV in one command:

### Download and Convert with curl

```powershell
# Using curl to download (no extra packages needed)
# Note: Use -k flag if behind corporate proxy (ZScaler, etc.)
docker run --rm -v "C:\path\to\output:/music" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/module.mod 'https://modarchive.org/jsplayer.php?moduleid=12345#module.mod' && /usr/local/bin/uade123 -c -f /music/output.wav /tmp/module.mod"
```

### Popular Module Archives

- **The Mod Archive**: <https://modarchive.org> - Large collection of tracker music (use API for downloads)
- **Modland**: <https://modland.com/pub/modules/> - Comprehensive module database (HTTP access available)
- **Amiga Music Preservation**: <https://amp.dascene.net> - Amiga-specific modules

### Downloading from Modland

Modland provides HTTP access to their extensive Protracker module collection. Browse directories at `https://modland.com/pub/modules/Protracker/`.

**Example: Download and convert a Protracker module from Modland**

```powershell
# Browse Modland's Protracker collection to find a module, then download and convert
# Example: Download from 4-Mat's collection
docker run --rm -v "$env:USERPROFILE\Music:/music" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/module.mod 'https://modland.com/pub/modules/Protracker/4-Mat/enigma.mod' && /usr/local/bin/uade123 -c -f /music/enigma.wav /tmp/module.mod"
```

**Bulk download multiple modules with a script:**

```powershell
# Create a list of URLs in urls.txt, then download all:
docker run --rm -v "$env:USERPROFILE\Music:/music" -v "C:\path\to\urls.txt:/urls.txt" --entrypoint /bin/sh uade-cli -c "while read url; do filename=$(basename $url); curl -k -o /tmp/$filename $url && /usr/local/bin/uade123 -c -f /music/${filename%.mod}.wav /tmp/$filename; done < /urls.txt"
```

> **Note:** Modland's rsync server requires authentication, but their HTTP interface is open for browsing and downloading individual files.

## Helper Scripts & Shortcuts

### Built-in TFMX Converter Script

The Docker image includes a `uade-convert` helper script that simplifies downloading and converting TFMX modules:

```powershell
# Use the built-in uade-convert helper script
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint uade-convert uade-cli "<mdat-url>" "<smpl-url>" /output/output.wav

# Example:
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint uade-convert uade-cli "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro" /output/turrican2-intro.wav
```

### PowerShell Function (Recommended for Windows Users)

Add this function to your PowerShell profile (`$PROFILE`) for easy TFMX conversion:

```powershell
function Convert-TFMX {
    param(
        [string]$MdatUrl,
        [string]$SmplUrl,
        [string]$OutputFile = "C:\Users\$env:USERNAME\Music\output.wav"
    )
    docker run --rm -v "C:\Users\$env:USERNAME\Music:/output" --entrypoint uade-convert uade-cli "$MdatUrl" "$SmplUrl" "/output/$(Split-Path $OutputFile -Leaf)"
}
```

Then use it with clean syntax:

```powershell
Convert-TFMX -MdatUrl "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" -SmplUrl "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro" -OutputFile "$env:USERPROFILE\Music\turrican2.wav"
```

## Example: Famous Amiga Composers

All examples download and convert to WAV format ready to play on Windows.

**Chris Huelsbeck - TFMX format (Turrican, Apidya)**:

```powershell
# IMPORTANT: TFMX modules require BOTH files: mdat.* (music) AND smpl.* (samples)
# Download both files from Modland to your project directory first:
# Example: https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/
# You need BOTH: mdat.turrican2level0 AND smpl.turrican2level0

# Convert local TFMX module to WAV (both files must be in same directory):
docker run --rm -v "${PWD}:/music" -v "$env:USERPROFILE\Music:/output" uade-cli -c -f /output/turrican2.wav /music/mdat.turrican2level0
```

_Output: `$env:USERPROFILE\Music\turrican2.wav`_

**Using the helper script for TFMX:**

```powershell
# Download and convert TFMX directly (recommended method)
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint uade-convert uade-cli "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro" /output/turrican2-intro.wav
```

**Captain - "Space Debris" (Protracker):**

```powershell
# Download and convert Space Debris → space-debris.wav
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/space-debris.mod 'https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod' && /usr/local/bin/uade123 -c -f /output/space-debris.wav /tmp/space-debris.mod"
```

_Output: `$env:USERPROFILE\Music\space-debris.wav` (306 seconds)_

**More Captain modules:**

```powershell
# Other Captain classics available at: https://modland.com/pub/modules/Protracker/Captain/
# Examples: beyond music.mod, broken dreams.mod, starwars.mod

# Download "Beyond Music"
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/beyond-music.mod 'https://modland.com/pub/modules/Protracker/Captain/beyond%20music.mod' && /usr/local/bin/uade123 -c -f /output/beyond-music.wav /tmp/beyond-music.mod"
```

**Lizardking - "Doskpop" (Famous Amiga Tracker):**

```powershell
# Download and convert "L.K's Doskpop" → doskpop.wav
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/doskpop.mod 'https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod' && /usr/local/bin/uade123 -c -f /output/doskpop.wav /tmp/doskpop.mod"
```

_Output: `$env:USERPROFILE\Music\doskpop.wav` (146 seconds)_

_More Lizardking classics: <https://modland.com/pub/modules/Protracker/Lizardking/>_

**Rob Hubbard - C64 Legend (Amiga conversions):**

```powershell
# Download and convert "Populous" → populous.wav
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/populous.mod 'https://modland.com/pub/modules/Protracker/Rob%20Hubbard/populous.mod' && /usr/local/bin/uade123 -c -f /output/populous.wav /tmp/populous.mod"
```

_Rob Hubbard's work: <https://modland.com/pub/modules/Protracker/Rob%20Hubbard/>_

**Pink - "Stormlord" (AHX Chiptune - Synthesized):**

```powershell
# Download and convert "Stormlord" → stormlord.wav
# AHX is a pure synthesis format (no samples) - creates music from mathematical waveforms
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/stormlord.ahx 'https://modland.com/pub/modules/AHX/Pink/stormlord.ahx' && /usr/local/bin/uade123 -c -f /output/stormlord.wav /tmp/stormlord.ahx"
```

_Output: `$env:USERPROFILE\Music\stormlord.wav` (512 seconds / 8.5 minutes from only 12KB!)_

_More Pink AHX chiptunes: <https://modland.com/pub/modules/AHX/Pink/>_

> **Note:** AHX (Abyss' Highest eXperience) is a tracked chiptune format that uses pure synthesis instead of samples. This allows extremely small file sizes while producing complex, high-quality chip music.

> **Important:**
>
> - All URLs above are tested and working
> - Browse <https://modland.com/pub/modules/Protracker/> to find more artists
> - ModArchive API is unreliable (often returns XM/IT files instead of MOD)
> - Modland URLs are case-sensitive
> - For TFMX modules, use the `uade-convert` helper script (see above)

**Manual TFMX download (advanced):**

```powershell
# Download both mdat and smpl files manually, then convert to WAV
# Note: Use matching base filenames (e.g., both end with "turrican2level0")
docker run --rm -v "$env:USERPROFILE\Music:/output" --entrypoint /bin/sh uade-cli -c "curl -k -o /tmp/mdat.turrican2level0 'https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro' && curl -k -o /tmp/smpl.turrican2level0 'https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro' && /usr/local/bin/uade123 -c -f /output/turrican2-intro.wav /tmp/mdat.turrican2level0"
```

> **Note:** TFMX modules require TWO files with matching names:
>
> - `mdat.*` = the music data
> - `smpl.*` = the sample/instrument data
>
> Both files must be in the same directory for UADE to play them. Browse Modland's TFMX collection: <https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/>

## Supported Formats

UADE supports many Amiga music formats including:

- Protracker (.mod)
- Soundtracker
- Octamed
- TFMX (Chris Huelsbeck's format - requires both mdat and smpl files)
- AHX (Abyss' Highest eXperience - synthesized chiptune)
- And many more Amiga-specific formats

**Full list of supported formats:** <https://gitlab.com/uade-music-player/uade/-/tree/master/players>

## Notes

- Docker on Windows doesn't support direct audio output - use WAV conversion (see Audio Output section)
- The container runs as a command-line tool and exits after playback
- Use absolute paths when mounting Windows directories

## Troubleshooting

**No audio output:**

Docker on Windows doesn't support direct audio output. Use the WAV conversion method (Option 1 above) or set up PulseAudio with WSL2.

**Cannot find module files:**

- Check that your Windows path is correct and uses forward slashes or escaped backslashes
- Verify the path inside the container: `/music/` should contain your files

**Permission errors:**

- Ensure Docker Desktop has access to the drive containing your module files
