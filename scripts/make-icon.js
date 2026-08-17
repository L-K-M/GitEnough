#!/usr/bin/env node
// Generates the GitEnough app icon set (classic macOS slots, 16…1024 px).
// Pure Node: rasterizes a simple "branch graph" glyph over a vertical gradient
// with 2x supersampling, then encodes PNGs via zlib. No dependencies.
//
// Usage: node scripts/make-icon.js   → writes GitEnough/Resources/Assets.xcassets/AppIcon.appiconset/

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

// --- PNG encoder -------------------------------------------------------------
function crc32(buf) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function encodePNG(width, height, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0; // filter: none
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// --- Rasterizer (float RGBA canvas, drawn at 2x then downsampled) ------------
function makeCanvas(size) {
  return { size, px: new Float32Array(size * size * 4) };
}
function blend(c, x, y, r, g, b, a) {
  if (x < 0 || y < 0 || x >= c.size || y >= c.size) return;
  const i = (y * c.size + x) * 4;
  const na = a + c.px[i + 3] * (1 - a);
  if (na <= 0) return;
  c.px[i] = (r * a + c.px[i] * c.px[i + 3] * (1 - a)) / na;
  c.px[i + 1] = (g * a + c.px[i + 1] * c.px[i + 3] * (1 - a)) / na;
  c.px[i + 2] = (b * a + c.px[i + 2] * c.px[i + 3] * (1 - a)) / na;
  c.px[i + 3] = na;
}
function fillRect(c, x0, y0, x1, y1, colorFn) {
  for (let y = Math.max(0, Math.floor(y0)); y < Math.min(c.size, Math.ceil(y1)); y++)
    for (let x = Math.max(0, Math.floor(x0)); x < Math.min(c.size, Math.ceil(x1)); x++) {
      const [r, g, b, a] = colorFn(x / c.size, y / c.size);
      blend(c, x, y, r, g, b, a);
    }
}
// distance from point to segment
function segDist(px, py, x0, y0, x1, y1) {
  const dx = x1 - x0, dy = y1 - y0;
  const t = Math.max(0, Math.min(1, ((px - x0) * dx + (py - y0) * dy) / (dx * dx + dy * dy)));
  const cx = x0 + t * dx, cy = y0 + t * dy;
  return Math.hypot(px - cx, py - cy);
}
function strokeSeg(c, x0, y0, x1, y1, w, col) {
  const minX = Math.floor(Math.min(x0, x1) - w), maxX = Math.ceil(Math.max(x0, x1) + w);
  const minY = Math.floor(Math.min(y0, y1) - w), maxY = Math.ceil(Math.max(y0, y1) + w);
  for (let y = Math.max(0, minY); y < Math.min(c.size, maxY); y++)
    for (let x = Math.max(0, minX); x < Math.min(c.size, maxX); x++) {
      const d = segDist(x + 0.5, y + 0.5, x0, y0, x1, y1);
      const a = Math.max(0, Math.min(1, w - d));
      if (a > 0) blend(c, x, y, col[0], col[1], col[2], col[3] * a);
    }
}
function strokeQuadratic(c, x0, y0, cx1, cy1, x1, y1, w, col) {
  const steps = Math.ceil(Math.hypot(x1 - x0, y1 - y0) / (w * 0.5)) + 8;
  let px = x0, py = y0;
  for (let i = 1; i <= steps; i++) {
    const t = i / steps, mt = 1 - t;
    const x = mt * mt * x0 + 2 * mt * t * cx1 + t * t * x1;
    const y = mt * mt * y0 + 2 * mt * t * cy1 + t * t * y1;
    strokeSeg(c, px, py, x, y, w, col);
    px = x; py = y;
  }
}
function fillCircle(c, cx, cy, r, col) {
  for (let y = Math.max(0, Math.floor(cy - r - 1)); y < Math.min(c.size, Math.ceil(cy + r + 1)); y++)
    for (let x = Math.max(0, Math.floor(cx - r - 1)); x < Math.min(c.size, Math.ceil(cx + r + 1)); x++) {
      const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
      const a = Math.max(0, Math.min(1, r - d));
      if (a > 0) blend(c, x, y, col[0], col[1], col[2], col[3] * a);
    }
}

// --- The icon ----------------------------------------------------------------
function render(pixelSize) {
  const S = pixelSize * 2; // supersample
  const c = makeCanvas(S);
  // background: vertical gradient, deep indigo → violet
  const top = [0.259, 0.278, 0.812], bottom = [0.478, 0.247, 0.886];
  fillRect(c, 0, 0, S, S, (fx, fy) => {
    const t = fy;
    return [top[0] + (bottom[0] - top[0]) * t, top[1] + (bottom[1] - top[1]) * t,
            top[2] + (bottom[2] - top[2]) * t, 1];
  });
  // subtle radial light from top-left
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    const d = Math.hypot(x - S * 0.25, y - S * 0.18) / (S * 1.1);
    const a = Math.max(0, 0.22 * (1 - d));
    blend(c, x, y, 1, 1, 1, a * 0.5);
  }

  const u = S / 1024; // design units
  const white = [1, 1, 1, 1];
  const accent = [0.996, 0.765, 0.353, 1]; // warm amber branch
  const lineW = 34 * u, dotR = 52 * u;

  const x0 = 380 * u, x1 = 660 * u;           // main lane, branch lane
  const yTop = 218 * u, yMid = 512 * u, yBot = 806 * u, yJoin = 660 * u;

  // branch lane: leaves main at yJoin, curves right, runs up to yMid
  strokeSeg(c, x1, yMid, x1, yJoin - 60 * u, lineW, accent);
  strokeQuadratic(c, x1, yJoin - 60 * u, x1, yJoin, x0 + 60 * u, yJoin, lineW, accent);
  strokeSeg(c, x0 + 60 * u, yJoin, x0, yJoin, lineW, accent);
  // main lane
  strokeSeg(c, x0, yTop, x0, yBot, lineW, white);
  // nodes
  fillCircle(c, x0, yTop, dotR, white);
  fillCircle(c, x1, yMid, dotR, accent);
  fillCircle(c, x0, yBot, dotR, white);
  // small junction dot where branch leaves main
  fillCircle(c, x0, yJoin, dotR * 0.62, [0.9, 0.9, 1, 1]);

  // downsample 2x
  const out = Buffer.alloc(pixelSize * pixelSize * 4);
  for (let y = 0; y < pixelSize; y++) for (let x = 0; x < pixelSize; x++) {
    let r = 0, g = 0, b = 0, a = 0;
    for (let dy = 0; dy < 2; dy++) for (let dx = 0; dx < 2; dx++) {
      const i = ((y * 2 + dy) * S + (x * 2 + dx)) * 4;
      r += c.px[i]; g += c.px[i + 1]; b += c.px[i + 2]; a += c.px[i + 3];
    }
    const o = (y * pixelSize + x) * 4;
    out[o] = Math.round((r / 4) * 255);
    out[o + 1] = Math.round((g / 4) * 255);
    out[o + 2] = Math.round((b / 4) * 255);
    out[o + 3] = Math.round((a / 4) * 255);
  }
  return encodePNG(pixelSize, pixelSize, out);
}

// --- Write the appiconset ------------------------------------------------------
const slots = [
  ["16x16", "1x", 16], ["16x16", "2x", 32],
  ["32x32", "1x", 32], ["32x32", "2x", 64],
  ["128x128", "1x", 128], ["128x128", "2x", 256],
  ["256x256", "1x", 256], ["256x256", "2x", 512],
  ["512x512", "1x", 512], ["512x512", "2x", 1024],
];
const outDir = path.join(__dirname, "..", "GitEnough", "Resources", "Assets.xcassets", "AppIcon.appiconset");
fs.mkdirSync(outDir, { recursive: true });
const images = [];
for (const [size, scale, px] of slots) {
  const name = `icon_${size.replace("x", "x")}_${scale}.png`;
  fs.writeFileSync(path.join(outDir, name), render(px));
  images.push({ filename: name, idiom: "mac", scale, size });
  console.log("rendered", name, px + "px");
}
fs.writeFileSync(path.join(outDir, "Contents.json"),
  JSON.stringify({ images, info: { author: "xcode", version: 1 } }, null, 2) + "\n");
console.log("wrote", outDir);
