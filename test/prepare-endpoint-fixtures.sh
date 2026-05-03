#!/bin/sh

set -eu

FIXTURES_DIR="${FIXTURES_DIR:-fixtures}"
MODULES_DIR="${FIXTURES_DIR}/modules"
INVALID_DIR="${FIXTURES_DIR}/invalid"
TOO_LARGE_BYTES=11534336

mkdir -p "$MODULES_DIR" "$INVALID_DIR"

: > "${INVALID_DIR}/empty.bin"

if [ ! -f "${INVALID_DIR}/too-large.bin" ] || [ "$(wc -c < "${INVALID_DIR}/too-large.bin")" -ne "$TOO_LARGE_BYTES" ]; then
  echo "Creating too-large.bin fixture..."
  head -c "$TOO_LARGE_BYTES" /dev/urandom > "${INVALID_DIR}/too-large.bin"
fi

if [ ! -s "${INVALID_DIR}/invalid-archive.zip" ]; then
  echo "Creating invalid-archive.zip fixture..."
  printf 'PKNOTAZIP\n' > "${INVALID_DIR}/invalid-archive.zip"
fi

download_fixture() {
  fixture_path="$1"
  fixture_url="$2"

  if [ -s "$fixture_path" ]; then
    echo "Fixture already present: $(basename "$fixture_path")"
    return
  fi

  tmp_path="${fixture_path}.tmp"
  rm -f "$tmp_path"

  echo "Downloading $(basename "$fixture_path")..."
  curl -fsS --insecure -o "$tmp_path" "$fixture_url"
  mv "$tmp_path" "$fixture_path"
}

download_fixture "${MODULES_DIR}/space_debris.mod" "https://modland.com/pub/modules/Protracker/Captain/space_debris.mod"
download_fixture "${MODULES_DIR}/stormlord.ahx" "https://modland.com/pub/modules/AHX/Pink/stormlord.ahx"
download_fixture "${MODULES_DIR}/gutenberg.txt" "https://www.gutenberg.org/files/1342/1342-0.txt"
download_fixture "${MODULES_DIR}/mdat.turrican_2_level_0-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro"
download_fixture "${MODULES_DIR}/smpl.turrican_2_level_0-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"
