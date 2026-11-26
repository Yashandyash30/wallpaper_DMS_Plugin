#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[1/4] Validating plugin.json..."
python3 - "$ROOT_DIR/plugin.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
required = ["id", "name", "description", "version", "author", "type", "capabilities", "components"]
for k in required:
    assert k in data and data[k], f"Missing required field: {k}"
assert data["type"] == "composite"
assert "widget" in data["components"] and "daemon" in data["components"]
print("plugin.json valid:", data["id"], data["version"])
PY

echo "[2/4] Testing scripts/span.sh scan, probe, video thumbs/stills, split, and cache..."
IMG_DIR="$TMP_DIR/wallpapers"
SUB_DIR="$IMG_DIR/sub"
CACHE_DIR="$TMP_DIR/cache"
mkdir -p "$SUB_DIR"

magick -size 3840x1080 xc:navy "$IMG_DIR/wide image (32x9).png"
magick -size 1920x1080 xc:teal "$SUB_DIR/normal.jpg"
ffmpeg -loglevel error -f lavfi -i testsrc=duration=1.5:size=320x90:rate=10 -pix_fmt yuv420p -y "$IMG_DIR/wide_clip.mp4"

caps_out="$("$ROOT_DIR/scripts/span.sh" caps)"
[[ "$caps_out" == *"ffmpeg=1"*"ffprobe=1"* ]] || { echo "Expected ffmpeg/ffprobe in caps: $caps_out"; exit 1; }

scan_rec="$("$ROOT_DIR/scripts/span.sh" scan "$IMG_DIR" 1)"
[[ "$(printf '%s\n' "$scan_rec" | wc -l)" -eq 3 ]] || { echo "Expected 3 recursive items, got: $scan_rec"; exit 1; }
grep -q $'^image\t3840\t1080\t' <<< "$scan_rec" || { echo "Missing wide image scan line: $scan_rec"; exit 1; }
grep -q $'^video\t320\t90\t.*wide_clip\.mp4$' <<< "$scan_rec" || { echo "Missing video scan line: $scan_rec"; exit 1; }

scan_top="$("$ROOT_DIR/scripts/span.sh" scan "$IMG_DIR" 0)"
[[ "$(printf '%s\n' "$scan_top" | wc -l)" -eq 2 ]] || { echo "Expected 2 top-level items, got: $scan_top"; exit 1; }

probe_out="$("$ROOT_DIR/scripts/span.sh" probe "$IMG_DIR/wide image (32x9).png")"
[[ "$probe_out" == $'3840\t1080' ]] || { echo "Unexpected image probe output: $probe_out"; exit 1; }

vprobe_out="$("$ROOT_DIR/scripts/span.sh" probe "$IMG_DIR/wide_clip.mp4")"
[[ "$vprobe_out" == $'320\t90' ]] || { echo "Unexpected video probe output: $vprobe_out"; exit 1; }

vthumb_out="$("$ROOT_DIR/scripts/span.sh" video-thumb "$IMG_DIR/wide_clip.mp4" "$CACHE_DIR")"
[[ -s "$vthumb_out" ]] || { echo "Missing generated video thumb: $vthumb_out"; exit 1; }

vstill_out="$("$ROOT_DIR/scripts/span.sh" video-still "$IMG_DIR/wide_clip.mp4" "$CACHE_DIR" "160x90+160+0")"
[[ -s "$vstill_out" ]] || { echo "Missing generated video still: $vstill_out"; exit 1; }

split_out="$("$ROOT_DIR/scripts/span.sh" split "$IMG_DIR/wide image (32x9).png" "$CACHE_DIR" "cover|HDMI-A-1:0,0,1920x1080|DP-1:1920,0,1920x1080" "HDMI-A-1:1920x1080+0+0" "DP-1:1920x1080+1920+0")"
[[ "$(printf '%s\n' "$split_out" | wc -l)" -eq 2 ]] || { echo "Expected 2 slices, got: $split_out"; exit 1; }

while IFS=$'\t' read -r mon slice; do
    [[ -s "$slice" ]] || { echo "Missing slice for $mon: $slice"; exit 1; }
    dims="$(magick identify -ping -format '%w %h' "$slice")"
    [[ "$dims" == "1920 1080" ]] || { echo "Unexpected slice dims for $mon: $dims"; exit 1; }
done <<< "$split_out"

# Cache hit check: re-run split and confirm identical output paths
split_out_cached="$("$ROOT_DIR/scripts/span.sh" split "$IMG_DIR/wide image (32x9).png" "$CACHE_DIR" "cover|HDMI-A-1:0,0,1920x1080|DP-1:1920,0,1920x1080" "HDMI-A-1:1920x1080+0+0" "DP-1:1920x1080+1920+0")"
[[ "$split_out" == "$split_out_cached" ]] || { echo "Cache mismatch"; exit 1; }

"$ROOT_DIR/scripts/span.sh" clear-cache "$CACHE_DIR"
remaining="$(find "$CACHE_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' \) | wc -l)"
[[ "$remaining" -eq 0 ]] || { echo "Cache not cleared: $remaining files left"; exit 1; }

echo "[3/4] Testing SpanEngine.js geometry via Node..."
node - "$ROOT_DIR/SpanEngine.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const code = fs.readFileSync(process.argv[2], "utf8").replace(/^\s*\.pragma\s+library\s*/m, "");
const ctx = { Math, Object, Array, String, Number };
vm.createContext(ctx);
vm.runInContext(code, ctx);

const monitors = ctx.resolveMonitors(
    [{ name: "DP-1", x: 1920, y: 0, width: 1920, height: 1080 }, { name: "HDMI-A-1", x: 0, y: 0, width: 1920, height: 1080 }],
    true,
    {
        "DP-1": { logical: { x: 1920, y: 0, width: 1920, height: 1080 } },
        "HDMI-A-1": { logical: { x: 0, y: 0, width: 1920, height: 1080 } }
    },
    false,
    []
);
assert.strictEqual(monitors[0].name, "HDMI-A-1");
assert.strictEqual(monitors[1].name, "DP-1");

assert.strictEqual(ctx.isWideImage(3840, 1080, 2.2), true);
assert.strictEqual(ctx.isWideImage(1920, 1080, 2.2), false);

const norm = v => JSON.parse(JSON.stringify(v));

const cropsCover = norm(ctx.computeSpanCrops(3840, 1080, monitors, "cover"));
assert.deepStrictEqual(cropsCover, [
    { name: "HDMI-A-1", x: 0, y: 0, w: 1920, h: 1080 },
    { name: "DP-1", x: 1920, y: 0, w: 1920, h: 1080 }
]);

// 3840x2160 (16:9) forced span across two 1920x1080 (32:9 total) -> centered 3840x1080 band -> y=540
const cropsForced = norm(ctx.computeSpanCrops(3840, 2160, monitors, "cover"));
assert.deepStrictEqual(cropsForced, [
    { name: "HDMI-A-1", x: 0, y: 540, w: 1920, h: 1080 },
    { name: "DP-1", x: 1920, y: 540, w: 1920, h: 1080 }
]);

const cropsEqual = ctx.computeSpanCrops(3841, 1080, monitors, "equal");
assert.strictEqual(cropsEqual[0].w + cropsEqual[1].w, 3841);

// Vertical bezel alignment on zero-slack 3840x1080 (right monitor physically higher -> shift image down -30px)
const cropsAlignedZeroSlack = norm(ctx.computeSpanCrops(3840, 1080, monitors, "cover", { "DP-1": -30 }));
assert.strictEqual(cropsAlignedZeroSlack[0].w, cropsAlignedZeroSlack[1].w);
assert.strictEqual(cropsAlignedZeroSlack[0].h, cropsAlignedZeroSlack[1].h);
assert.strictEqual(cropsAlignedZeroSlack[0].x + cropsAlignedZeroSlack[0].w, cropsAlignedZeroSlack[1].x);
assert.ok(cropsAlignedZeroSlack[0].y > cropsAlignedZeroSlack[1].y);

// Vertical bezel alignment with vertical slack (3840x2160 -> no extra crop needed)
const cropsAlignedSlack = norm(ctx.computeSpanCrops(3840, 2160, monitors, "cover", { "DP-1": -30 }));
assert.deepStrictEqual(cropsAlignedSlack, [
    { name: "HDMI-A-1", x: 0, y: 540, w: 1920, h: 1080 },
    { name: "DP-1", x: 1920, y: 510, w: 1920, h: 1080 }
]);

// Cache signature must differ when offsets or bezel gap change
assert.notStrictEqual(
    ctx.layoutSignature(monitors, "cover", {}),
    ctx.layoutSignature(monitors, "cover", { "DP-1": -30 })
);
assert.notStrictEqual(
    ctx.layoutSignature(monitors, "physical", {}, { bezelGapMm: 0 }),
    ctx.layoutSignature(monitors, "physical", {}, { bezelGapMm: 20 })
);

// Spanright physical-space mode: mixed physical monitor sizes (24" 1080p vs 27" 1440p) + 20mm bezel gap + -30px right offset
const mixedMons = ctx.resolveMonitors(
    [
        { name: "HDMI-A-1", x: 0, y: 0, width: 1920, height: 1080 },
        { name: "DP-1", x: 1920, y: 0, width: 2560, height: 1440 }
    ],
    true,
    {
        "HDMI-A-1": { logical: { x: 0, y: 0, width: 1920, height: 1080 }, physical_size: [530, 300] },
        "DP-1": { logical: { x: 1920, y: 0, width: 2560, height: 1440 }, physical_size: [600, 340] }
    },
    false,
    []
);
const physNoGap = norm(ctx.computeSpanCrops(5120, 1440, mixedMons, "physical", {}, { bezelGapMm: 0 }));
assert.ok(physNoGap[1].w > physNoGap[0].w, "Larger 27in display should sample wider physical slice");
assert.strictEqual(physNoGap[0].x + physNoGap[0].w, physNoGap[1].x);

const physWithGap = norm(ctx.computeSpanCrops(5120, 1440, mixedMons, "physical", { "DP-1": -30 }, { bezelGapMm: 20 }));
assert.ok(physWithGap[1].x > physWithGap[0].x + physWithGap[0].w, "20mm bezel gap should skip pixels between displays");
assert.ok(physWithGap[1].y < physWithGap[0].y, "Negative right offset should sample higher on image (shift image down)");

// Video path detection & mpvpaper crop args
assert.strictEqual(ctx.isVideoPath("/home/user/clip.mp4"), true);
assert.strictEqual(ctx.isVideoPath("/home/user/CLIP.WEBM"), true);
assert.strictEqual(ctx.isVideoPath("/home/user/wall.png"), false);
assert.strictEqual(ctx.formatMpvCrop({ x: 1920, y: 12, w: 1920, h: 1080 }), "1920x1080+1920+12");

const mpvArgs = norm(ctx.buildMpvArgs("DP-1", "/tmp/video.mp4", { hwdec: "vaapi", panscan: 0.5, volume: 20 }, "1920x1080+1920+0"));
assert.strictEqual(mpvArgs[0], "mpvpaper");
assert.ok(mpvArgs[4].includes("--hwdec=vaapi"));
assert.ok(mpvArgs[4].includes("--panscan=0.5"));
assert.ok(mpvArgs[4].includes("--volume=20"));
assert.ok(mpvArgs[4].includes("--video-crop=1920x1080+1920+0"));
assert.strictEqual(mpvArgs[5], "DP-1");
assert.strictEqual(mpvArgs[6], "/tmp/video.mp4");

// Niri per-output column detection
const niriWs = [
    { id: 2, output: "HDMI-A-1", is_active: true },
    { id: 7, output: "DP-1", is_active: true },
    { id: 4, output: "DP-1", is_active: false }
];
const niriWins = [
    { id: 5, workspace_id: 2, is_floating: false, layout: { pos_in_scrolling_layout: [1, 1] } },
    { id: 8, workspace_id: 7, is_floating: true, layout: { pos_in_scrolling_layout: null } },
    { id: 9, workspace_id: 4, is_floating: false, layout: { pos_in_scrolling_layout: [1, 1] } }
];
assert.strictEqual(ctx.niriOutputHasColumn("HDMI-A-1", niriWs, niriWins), true);
assert.strictEqual(ctx.niriOutputHasColumn("DP-1", niriWs, niriWins), false);

console.log("SpanEngine.js assertions passed");
JS

echo "[4/4] Checking QML syntax (Qt6 qmllint)..."
QMLLINT_BIN=""
if [[ -x /usr/lib/qt6/bin/qmllint ]]; then
    QMLLINT_BIN="/usr/lib/qt6/bin/qmllint"
elif command -v qmllint6 >/dev/null 2>&1; then
    QMLLINT_BIN="qmllint6"
fi

if [[ -n "$QMLLINT_BIN" ]]; then
    for f in "$ROOT_DIR"/*.qml; do
        "$QMLLINT_BIN" "$f" 2>&1 | grep -E 'Error:|Syntax error' && { echo "QML syntax error in $f"; exit 1; } || true
    done
    echo "QML syntax checks passed"
else
    echo "Qt6 qmllint not found, skipping QML syntax check"
fi

echo "All tests passed!"
