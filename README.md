# UADE Docker Player

Docker containers for playing and converting Amiga music modules using UADE (Unix Amiga Delitracker Emulator).

**UADE:** <https://zakalwe.fi/uade/> - Emulates Amiga hardware to play 100+ music formats from the 1980s-90s

**Official UADE Repository:** <https://gitlab.com/uade-music-player/uade>

## Two Ways to Use

### 🖥️ Command-Line

Convert modules locally with Docker.

```powershell
docker pull ghcr.io/rib1/uade-player:latest
docker run --rm -v "$env:USERPROFILE\Music:/output" ghcr.io/rib1/uade-player -c -f /output/music.wav /music/module.mod
```

**[📖 Full Documentation](docs/CLI-USAGE.md)** - Examples, PowerShell integration, TFMX helpers

### 🌐 Web Player

Browser-based player with drag-and-drop interface.

**Live:** <https://uade-web-player-675650150969.us-central1.run.app>

Features: Drag & drop files, download from URLs, **LHA archive extraction**, TFMX support, convert to WAV/FLAC, format auto-detection

**[📖 Full Documentation](docs/WEB-PLAYER.md)**

## Architecture

- **[System Architecture](docs/ARCHITECTURE.md)** - High-level overview with Mermaid diagram
- **[Component Diagram](docs/COMPONENT-DIAGRAM.md)** - Detailed component structure

## Module Archives

- **Modland** - <https://modland.com/pub/modules/>
- **The Mod Archive** - <https://modarchive.org>
- **AMP** - <https://amp.dascene.net>

## Development

```bash
docker build -t uade-player .
docker build -f Dockerfile.web -t uade-web-player .
docker-compose up  # Run web player locally at http://localhost:5000
```

## License

UADE is maintained by the UADE team. This project provides Docker packaging.

## Repository

<https://github.com/rib1/uade-docker>
