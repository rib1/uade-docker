# UADE CLI Base Image v2.13-base.1
# Versioning: UADE_VERSION-base.BUILD_NUMBER
# This Dockerfile builds UADE 2.13 (stable) from source
# See: https://gitlab.com/uade-music-player/uade/-/releases/uade-2.13
#
# Version history maintained in: deployment/UADE_VERSIONS.md
# Image registry: docker.io/rib1/uade-cli
# Example tags: 2.13-base.1, 2.13-base, 2.13-base.latest, latest
#
# Use a lightweight Debian-based image
FROM debian:stable-slim

# 1. Install dependencies for building UADE (gcc, make, git, libao for audio, etc.)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        autoconf \
        automake \
        libtool \
        pkg-config \
        libao-dev \
        ca-certificates \
        python3 \
        meson \
        ninja-build \
        libsdl2-dev \
    && rm -rf /var/lib/apt/lists/*

# 2. Set working directory for source code
WORKDIR /usr/src/uade-build

# 3. Clone and install bencodetools
RUN git clone --depth 1 https://gitlab.com/heikkiorsila/bencodetools.git
WORKDIR /usr/src/uade-build/bencodetools
RUN ./configure && \
    make && \
    make install && \
    ldconfig

# 4. Clone and install libzakalwe
WORKDIR /usr/src/uade-build
RUN git clone --depth 1 https://gitlab.com/hors/libzakalwe.git
WORKDIR /usr/src/uade-build/libzakalwe
RUN ./configure && \
    make && \
    make install && \
    ldconfig

# 5. Clone and install UADE
WORKDIR /usr/src/uade-build
RUN git clone --depth 1 https://gitlab.com/uade-music-player/uade.git
WORKDIR /usr/src/uade-build/uade
RUN ./configure && \
    make && \
    make install

# 6. Clean up source code and build dependencies, but keep ca-certificates
RUN rm -rf /usr/src/uade-build && \
    apt-get purge -y build-essential git autoconf automake libtool python3 meson ninja-build && \
    apt-get autoremove -y && \
    apt-get install -y --no-install-recommends ca-certificates

# 7. Install curl, rsync, and unzip for downloading modules
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl rsync unzip && \
    rm -rf /var/lib/apt/lists/*

# 8. Create helper script for downloading and converting TFMX modules
RUN printf '#!/bin/sh\n\
if [ $# -lt 2 ]; then\n\
    echo "Usage: uade-convert <mdat-url> <smpl-url> <output-file>"\n\
    echo ""\n\
    echo "Example:"\n\
    echo "  uade-convert \\\\\n\
    \"https://modland.com/pub/modules/TFMX/Chris%%20Huelsbeck/mdat.turrican%%202%%20level%%200-intro\" \\\\\n\
    \"https://modland.com/pub/modules/TFMX/Chris%%20Huelsbeck/smpl.turrican%%202%%20level%%200-intro\" \\\\\n\
    /output/turrican2.wav"\n\
    exit 1\n\
fi\n\
\n\
MDAT_URL="$1"\n\
SMPL_URL="$2"\n\
OUTPUT="${3:-/output/output.wav}"\n\
BASENAME="module_$(date +%%s)"\n\
\n\
echo "Downloading mdat file..."\n\
curl -k -f -o "/tmp/mdat.$BASENAME" "$MDAT_URL" || exit 1\n\
\n\
echo "Downloading smpl file..."\n\
curl -k -f -o "/tmp/smpl.$BASENAME" "$SMPL_URL" || exit 1\n\
\n\
echo "Converting to WAV..."\n\
/usr/local/bin/uade123 -c -f "$OUTPUT" "/tmp/mdat.$BASENAME"\n\
' > /usr/local/bin/uade-convert && chmod +x /usr/local/bin/uade-convert


# 9. Create non-root user and set permissions
RUN useradd -m -s /bin/bash uadeuser && \
    mkdir -p /output /music /tmp && \
    chown -R uadeuser:uadeuser /output /music /tmp

# Workaround for UADE bug: some modules open audio device even in conversion mode.
# Setting SUID bit allows non-root user to run uade123 as root without sudo.
RUN chown root:uadeuser /usr/local/bin/uade123 && chmod 4750 /usr/local/bin/uade123

# Switch to non-root user
USER uadeuser

# The uade123 command-line player is the primary tool to run
ENTRYPOINT ["/usr/local/bin/uade123"]
