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

ARCHIVE_BUILD_DIR="${INVALID_DIR}/archive-build"
case "$INVALID_DIR" in
  /*) ARCHIVE_OUTPUT_DIR="$INVALID_DIR" ;;
  *) ARCHIVE_OUTPUT_DIR="$(pwd)/${INVALID_DIR}" ;;
esac
mkdir -p "${ARCHIVE_BUILD_DIR}/no-module"
printf 'archive contains no playable module\n' > "${ARCHIVE_BUILD_DIR}/no-module/README.txt"

if [ ! -s "${INVALID_DIR}/archive-no-module.zip" ]; then
  echo "Creating archive-no-module.zip fixture..."
  (cd "${ARCHIVE_BUILD_DIR}/no-module" && zip -q -j "${ARCHIVE_OUTPUT_DIR}/archive-no-module.zip" README.txt)
fi

if [ ! -s "${INVALID_DIR}/archive-no-module.lha" ]; then
  echo "Creating archive-no-module.lha fixture..."
  (cd "${ARCHIVE_BUILD_DIR}/no-module" && lha a -q "${ARCHIVE_OUTPUT_DIR}/archive-no-module.lha" README.txt)
fi

# Keep this archive deliberately hand-crafted: archive tools sanitize traversal
# names, while the application must reject malicious metadata before extraction.
python3 - "${INVALID_DIR}" <<'PY'
import sys
import zipfile
from pathlib import Path

invalid_dir = Path(sys.argv[1])
no_module = invalid_dir / "archive-no-module.zip"
unsafe_member = invalid_dir / "archive-unsafe-member.zip"

if not unsafe_member.exists():
    with zipfile.ZipFile(unsafe_member, "w") as archive:
        archive.writestr("../../outside.txt", "must never be extracted\n")
PY

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

CUSTOM_ARCHIVE_BUILD_DIR="${ARCHIVE_BUILD_DIR}/custom-module"
CUSTOM_ARCHIVE_PATH="${INVALID_DIR}/archive-custom-multi.lha"
if [ ! -s "$CUSTOM_ARCHIVE_PATH" ]; then
  echo "Creating archive-custom-multi.lha fixture..."
  mkdir -p "$CUSTOM_ARCHIVE_BUILD_DIR"
  download_fixture \
    "${CUSTOM_ARCHIVE_BUILD_DIR}/cust.WingsOfDeath-Levels1-7" \
    "https://zakalwe.fi/uade/amiga-music/customs/WingsOfDeath-Levels1-7/cust.WingsOfDeath-Levels1-7"
  printf 'archive contains a README and one playable Custom module\n' \
    > "${CUSTOM_ARCHIVE_BUILD_DIR}/README.txt"
  (
    cd "$CUSTOM_ARCHIVE_BUILD_DIR"
    lha a -q "$ARCHIVE_OUTPUT_DIR/archive-custom-multi.lha" README.txt cust.WingsOfDeath-Levels1-7
  )
fi
