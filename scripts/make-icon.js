#!/usr/bin/env node
// Generates the GitEnough app icon set (classic macOS slots, 16…1024 px)
// from the master artwork in media-sources/icon.png.
// Pure Node: PNG decode (zlib inflate + unfilter), exact area-average
// downscaling, PNG encode. No dependencies.
//
// Usage: node scripts/make-icon.js
//   reads  media-sources/icon.png
//   writes GitEnough/Resources/Assets.xcassets/AppIcon.appiconset/

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

// --- PNG decoder (8-bit RGB/RGBA, non-interlaced) -----------------------------
function decodePNG(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error("not a PNG");
  let pos = 8, width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString("ascii", pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      if (data[12] !== 0) throw new Error("interlaced PNGs not supported");
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") break;
    pos += 12 + len;
  }
  if (bitDepth !== 8 || (colorType !== 2 && colorType !== 6))
    throw new Error(`unsupported PNG: bitDepth ${bitDepth}, colorType ${colorType}`);
  const bpp = colorType === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * bpp;
  // Short of this and the unfilter below reads past the end: `line[x]` yields
  // undefined, the filter arithmetic goes NaN, and Buffer writes coerce that to
  // 0 — a truncated master would silently render as black icons, exit code 0.
  if (raw.length < height * (stride + 1))
    throw new Error(`corrupt PNG: expected ${height * (stride + 1)} inflated bytes, got ${raw.length}`);
  const out = Buffer.alloc(width * height * 4);
  const prev = Buffer.alloc(stride);
  let src = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[src++];
    const line = raw.subarray(src, src + stride);
    src += stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? line[x - bpp] : 0; // left (already unfiltered)
      const b = prev[x]; // up
      const c = x >= bpp ? prev[x - bpp] : 0; // up-left
      let v = line[x];
      if (filter === 1) v = (v + a) & 0xff;
      else if (filter === 2) v = (v + b) & 0xff;
      else if (filter === 3) v = (v + ((a + b) >> 1)) & 0xff;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v = (v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 0xff;
      } else if (filter !== 0) throw new Error(`bad filter ${filter}`);
      line[x] = v; // unfilter in place; safe, we read left-to-right
    }
    line.copy(prev);
    for (let x = 0; x < width; x++) {
      const s = x * bpp, d = (y * width + x) * 4;
      out[d] = line[s];
      out[d + 1] = line[s + 1];
      out[d + 2] = line[s + 2];
      out[d + 3] = bpp === 4 ? line[s + 3] : 255;
    }
  }
  return { width, height, rgba: out };
}

// --- Area-average downscale (exact box filter) --------------------------------
function resize(src, dstSize) {
  const { width: sw, height: sh, rgba } = src;
  const scaleX = sw / dstSize, scaleY = sh / dstSize;
  const out = Buffer.alloc(dstSize * dstSize * 4);
  for (let dy = 0; dy < dstSize; dy++) {
    const y0 = dy * scaleY, y1 = y0 + scaleY;
    const sy0 = Math.floor(y0), sy1 = Math.min(sh - 1, Math.floor(y1));
    for (let dx = 0; dx < dstSize; dx++) {
      const x0 = dx * scaleX, x1 = x0 + scaleX;
      const sx0 = Math.floor(x0), sx1 = Math.min(sw - 1, Math.floor(x1));
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = sy0; sy <= sy1; sy++) {
        const wy = Math.min(y1, sy + 1) - Math.max(y0, sy);
        for (let sx = sx0; sx <= sx1; sx++) {
          const w = wy * (Math.min(x1, sx + 1) - Math.max(x0, sx));
          const i = (sy * sw + sx) * 4;
          // Weight colour by alpha before averaging. Straight-RGBA averaging
          // pulls the (arbitrary) colour of fully transparent texels into edge
          // pixels at full weight, haloing the rounded corners at 16–32 px.
          // A no-op for today's opaque master; correct if it ever gains alpha.
          const al = rgba[i + 3] / 255;
          r += rgba[i] * al * w; g += rgba[i + 1] * al * w; b += rgba[i + 2] * al * w;
          a += rgba[i + 3] * w;
        }
      }
      const area = scaleX * scaleY;
      const o = (dy * dstSize + dx) * 4;
      const alpha = a / area;
      const an = alpha / 255;
      out[o] = an > 0 ? Math.round(r / area / an) : 0;
      out[o + 1] = an > 0 ? Math.round(g / area / an) : 0;
      out[o + 2] = an > 0 ? Math.round(b / area / an) : 0;
      out[o + 3] = Math.round(alpha);
    }
  }
  return out;
}

// --- Write the appiconset ------------------------------------------------------
const srcPath = path.join(__dirname, "..", "media-sources", "icon.png");
const master = decodePNG(fs.readFileSync(srcPath));
// resize() always emits a square, so a non-square master is silently stretched,
// and one below the largest slot is box-upscaled into a soft 1024 px icon.
// Both are easy to miss when every file still "generates successfully".
if (master.width !== master.height)
  throw new Error(`master icon must be square, got ${master.width}x${master.height}`);
if (master.width < 1024)
  throw new Error(`master icon must be at least 1024px (the largest slot), got ${master.width}px`);
console.log(`decoded ${path.relative(process.cwd(), srcPath)}: ${master.width}x${master.height}`);

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
  const name = `icon_${size}_${scale}.png`;
  fs.writeFileSync(path.join(outDir, name), encodePNG(px, px, resize(master, px)));
  images.push({ filename: name, idiom: "mac", scale, size });
  console.log("rendered", name, px + "px");
}
fs.writeFileSync(path.join(outDir, "Contents.json"),
  JSON.stringify({ images, info: { author: "xcode", version: 1 } }, null, 2) + "\n");
console.log("wrote", outDir);
