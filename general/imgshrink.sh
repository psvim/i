#!/usr/bin/env bash
# Image Shrinker - Lossy-shrinks PNG and WEBP images in place, keeping filenames (backup first)

# imgshrink.sh: aggressive / lossy image shrinker (PNG + WEBP, in place)
#
# Shrinks every .png / .webp file in a folder IN PLACE, keeping the exact same
# filename and extension, so anything linking to these files by name keeps working.
#
# Why not just ffmpeg: its PNG encoder is lossless, so it can resize but not
# meaningfully shrink. This script pairs two tools:
#   ffmpeg   -> resizes both formats and does real lossy compression for .webp
#   pngquant -> real lossy color-quantization for .png (output is a valid .png)
#
# Run from the init.sh menu and you are asked for the folder, max width and
# quality (press Enter to accept the defaults). You can also pass flags.
#
# Safety: a full backup of the folder is made BEFORE anything is touched, and a
# file is only overwritten if the new version is actually smaller.

set -euo pipefail

SRC_DIR="."
MAX_WIDTH="1200"
QUALITY="65"

usage() {
  cat <<'EOF'
Usage: imgshrink.sh [-d DIR] [-o WIDTH:QUALITY] [-y] [-h]

  -d DIR            folder to process (default: current directory)
  -o WIDTH:QUALITY  max width in px and quality 1-100 (default: 1200:65)
                    lower quality = smaller file, more visible artifacts
  -y                skip the confirmation prompt
  -h                show this help and exit

With no flags in a terminal, you are prompted for each setting.

Examples:
  imgshrink.sh                         # prompts, defaults 1200:65
  imgshrink.sh -d ./assets             # other folder, default settings
  imgshrink.sh -d ./assets -o 900:40   # custom folder and settings

Requires: ffmpeg, pngquant
  Debian/Ubuntu : sudo apt-get update && sudo apt-get install -y ffmpeg pngquant
  Arch Linux    : sudo pacman -S --noconfirm ffmpeg pngquant
  Fedora        : sudo dnf install -y ffmpeg pngquant
  macOS         : brew install ffmpeg pngquant
EOF
  exit "${1:-0}"
}

ASSUME_YES=0
HAVE_ARGS=$#

while getopts ":d:o:yh" opt; do
  case "$opt" in
    d) SRC_DIR="$OPTARG" ;;
    o)
      OVERRIDE="$OPTARG"
      MAX_WIDTH="${OVERRIDE%%:*}"
      QUALITY="${OVERRIDE##*:}"
      if [ -z "$MAX_WIDTH" ] || [ -z "$QUALITY" ] || [ "$OVERRIDE" = "$MAX_WIDTH" ]; then
        echo "Error: -o needs WIDTH:QUALITY, e.g. -o 1000:50" >&2
        exit 1
      fi
      ;;
    y) ASSUME_YES=1 ;;
    h) usage 0 ;;
    \?) echo "Unknown flag: -$OPTARG" >&2; usage 1 ;;
    :)  echo "Flag -$OPTARG needs a value" >&2; usage 1 ;;
  esac
done

# Use the terminal for prompts, even when launched through a pipe
HAVE_TTY=0
( : </dev/tty ) 2>/dev/null && HAVE_TTY=1

ask() {
  # ask "Question" "default"
  local reply=""
  if [ "$HAVE_TTY" -eq 1 ]; then
    read -r -p "$1 [$2]: " reply </dev/tty || reply=""
  fi
  echo "${reply:-$2}"
}

# Interactive mode: no flags given and a terminal is available
if [ "$HAVE_ARGS" -eq 0 ] && [ "$HAVE_TTY" -eq 1 ]; then
  echo "Image Shrinker (press Enter to accept the default)"
  SRC_DIR=$(ask "Folder" "$SRC_DIR")
  MAX_WIDTH=$(ask "Max width in px" "$MAX_WIDTH")
  QUALITY=$(ask "Quality 1-100 (lower = smaller)" "$QUALITY")
fi

# Validate input
if [ ! -d "$SRC_DIR" ]; then
  echo "Error: $SRC_DIR is not a directory" >&2
  exit 1
fi
case "$MAX_WIDTH" in ''|*[!0-9]*) echo "Error: width must be a number" >&2; exit 1 ;; esac
case "$QUALITY"   in ''|*[!0-9]*) echo "Error: quality must be a number" >&2; exit 1 ;; esac
if [ "$MAX_WIDTH" -lt 1 ] || [ "$QUALITY" -lt 1 ] || [ "$QUALITY" -gt 100 ]; then
  echo "Error: width must be 1 or more and quality between 1 and 100" >&2
  exit 1
fi

install_hint() {
  local pkg="$1"
  if command -v pacman >/dev/null 2>&1; then
    echo "  sudo pacman -S --noconfirm ${pkg}" >&2
  elif command -v apt-get >/dev/null 2>&1; then
    echo "  sudo apt-get update && sudo apt-get install -y ${pkg}" >&2
  elif command -v dnf >/dev/null 2>&1; then
    echo "  sudo dnf install -y ${pkg}" >&2
  elif command -v brew >/dev/null 2>&1; then
    echo "  brew install ${pkg}" >&2
  else
    echo "  (install '${pkg}' using your system's package manager)" >&2
  fi
}

MISSING=0
for tool in ffmpeg pngquant; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool not found. Install it first:" >&2
    install_hint "$tool"
    MISSING=1
  fi
done
[ "$MISSING" -eq 1 ] && exit 1

# Count images before backing anything up
FILE_COUNT=$(find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.webp' \) | wc -l | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "No .png or .webp files found in '$SRC_DIR'. Nothing to do."
  exit 0
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$(cd "$SRC_DIR" && pwd)_backup_${TIMESTAMP}"

echo
echo "Folder   : $SRC_DIR  ($FILE_COUNT images)"
echo "Settings : max width ${MAX_WIDTH}px, quality ${QUALITY}"
echo "Backup   : $BACKUP_DIR"
if [ "$ASSUME_YES" -eq 0 ] && [ "$HAVE_TTY" -eq 1 ]; then
  go=$(ask "Proceed?" "Y")
  case "$go" in [Yy]*) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

echo "Backing up '$SRC_DIR' -> '$BACKUP_DIR' ..."
cp -r "$SRC_DIR" "$BACKUP_DIR"
echo "Backup done."

export MAX_WIDTH QUALITY

process_one() {
  local infile="$1"
  local dir base ext extlc tmpfile resized old_size new_size
  dir=$(dirname "$infile")
  base=$(basename "$infile")
  ext="${base##*.}"
  extlc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  tmpfile="${dir}/.tmp_${base}"
  resized="${dir}/.resized_${base}"

  old_size=$(stat -c%s "$infile" 2>/dev/null || stat -f%z "$infile")

  case "$extlc" in
    png)
      # 1) resize down first (cheap size win), 2) lossy-quantize with pngquant
      ffmpeg -y -loglevel error -i "$infile" \
        -vf "scale='min(${MAX_WIDTH},iw)':-2:flags=lanczos" "$resized"
      pngquant --force --quality=0-"${QUALITY}" --speed 1 \
        --output "$tmpfile" "$resized"
      rm -f "$resized"
      ;;
    webp)
      # real lossy webp encode, resized
      ffmpeg -y -loglevel error -i "$infile" \
        -vf "scale='min(${MAX_WIDTH},iw)':-2:flags=lanczos" \
        -lossless 0 -q:v "${QUALITY}" -compression_level 6 "$tmpfile"
      ;;
    *)
      echo "SKIP (unsupported ext): $infile"
      return
      ;;
  esac

  new_size=$(stat -c%s "$tmpfile" 2>/dev/null || stat -f%z "$tmpfile")

  if [ "$new_size" -gt 0 ] && [ "$new_size" -lt "$old_size" ]; then
    mv "$tmpfile" "$infile"
    echo "OK   $infile  (${old_size} -> ${new_size} bytes)"
  else
    rm -f "$tmpfile"
    echo "KEEP $infile  (already smaller, ${old_size} bytes)"
  fi
}
export -f process_one

JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.webp' \) -print0 \
  | xargs -0 -I{} -P "$JOBS" bash -c 'process_one "$@"' _ {}

echo
echo "All done. Filenames unchanged. Originals are safe in: $BACKUP_DIR"
echo "New total size:"
du -sh "$SRC_DIR"
