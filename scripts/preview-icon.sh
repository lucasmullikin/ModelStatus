#!/usr/bin/env bash
# Generate a side-by-side preview of an app icon at every macOS UI-relevant size.
# Output: /tmp/icon-preview-<stem>.png — opened automatically.
#
# Usage:  ./scripts/preview-icon.sh path/to/icon-1024.png

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <path-to-1024-png>" >&2
    exit 1
fi

SRC="$1"
[[ -f "$SRC" ]] || { echo "source PNG not found: $SRC" >&2; exit 1; }

STEM=$(basename "$SRC" .png)
OUT="/tmp/icon-preview-${STEM}.png"
WORK=$(mktemp -d)

# Sizes the user will actually encounter:
declare -a PREVIEW_SIZES=(16 32 64 128 256 512 1024)

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }

bold "→ Rendering icon at ${#PREVIEW_SIZES[@]} sizes"
for size in "${PREVIEW_SIZES[@]}"; do
    sips -z "$size" "$size" "$SRC" --out "$WORK/${size}.png" >/dev/null
    ok "${size}x${size}"
done

bold "→ Composing preview montage"
PY_SCRIPT="$WORK/compose.py"
cat > "$PY_SCRIPT" <<'PYEOF'
import sys
from PIL import Image, ImageDraw, ImageFont

work = sys.argv[1]
out = sys.argv[2]
sizes = [int(x) for x in sys.argv[3:]]

# Two-row layout: row 1 = native size at each tier (true rendering at Finder /
# Spotlight / Dock sizes). row 2 = all upscaled to a uniform tile for
# apples-to-apples color + silhouette comparison.
tile = 320
pad = 36
label_h = 36
canvas_w = pad + sum(max(s, tile) + pad for s in sizes)
row1_h = max(sizes) + pad + label_h
row2_h = tile + pad + label_h
canvas_h = pad + row1_h + pad * 2 + row2_h + pad
canvas = Image.new("RGBA", (canvas_w, canvas_h), (242, 242, 245, 255))
draw = ImageDraw.Draw(canvas)
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22)
except Exception:
    font = ImageFont.load_default()

x = pad
y_row1 = pad
for s in sizes:
    img = Image.open(f"{work}/{s}.png").convert("RGBA")
    tile_w = max(s, tile)
    tx = x + (tile_w - s) // 2
    ty = y_row1 + (max(sizes) - s)
    canvas.paste(img, (tx, ty), img)
    label = f"{s}px"
    bbox = draw.textbbox((0, 0), label, font=font)
    tw, _ = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text((x + (tile_w - tw) // 2, y_row1 + max(sizes) + pad),
              label, fill=(60, 60, 70, 255), font=font)
    x += tile_w + pad

x = pad
y_row2 = y_row1 + row1_h + pad * 2
draw.text((pad, y_row2 - 30), "All scaled to uniform size (compare color + silhouette):",
          fill=(60, 60, 70, 255), font=font)
for s in sizes:
    img = Image.open(f"{work}/{s}.png").convert("RGBA")
    if s != tile:
        img = img.resize((tile, tile), Image.LANCZOS)
    tile_w = max(s, tile)
    tx = x + (tile_w - tile) // 2
    canvas.paste(img, (tx, y_row2), img)
    label = f"upscaled from {s}px" if s < tile else f"native {s}px"
    bbox = draw.textbbox((0, 0), label, font=font)
    tw, _ = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text((x + (tile_w - tw) // 2, y_row2 + tile + pad // 2),
              label, fill=(60, 60, 70, 255), font=font)
    x += tile_w + pad

canvas.save(out, "PNG")
print(f"wrote {out}")
PYEOF

if /usr/bin/python3 -c "import PIL" 2>/dev/null; then
    /usr/bin/python3 "$PY_SCRIPT" "$WORK" "$OUT" "${PREVIEW_SIZES[@]}"
else
    echo "(no PIL available — opening iconset folder for manual review)"
    cp -R "$WORK" "/tmp/icon-preview-${STEM}-iconset"
    OUT="/tmp/icon-preview-${STEM}-iconset"
fi

ok "preview at $OUT"
open "$OUT"
