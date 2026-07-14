// r2apply.js — pure patch/checksum logic for the Raiden II web patcher.
// No DOM access, so it runs identically in the browser and under Node
// (the build test exercises this exact code). Exposes window.R2APPLY in the
// browser and module.exports under Node.
(function (root, factory) {
  var api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.R2APPLY = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // --- CRC32 (IEEE, table-driven) ----------------------------------------
  var CRC_TABLE = (function () {
    var t = new Uint32Array(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    return ((c ^ 0xFFFFFFFF) >>> 0).toString(16).padStart(8, "0");
  }

  // --- SHA-1 -------------------------------------------------------------
  function sha1(bytes) {
    function rotl(n, s) { return ((n << s) | (n >>> (32 - s))) >>> 0; }
    var ml = bytes.length * 8;
    // pad
    var withOne = bytes.length + 1;
    var total = withOne + ((56 - (withOne % 64) + 64) % 64) + 8;
    var msg = new Uint8Array(total);
    msg.set(bytes);
    msg[bytes.length] = 0x80;
    // 64-bit big-endian length (length < 2^32 bytes here, so high word 0)
    var lenLo = ml >>> 0;
    msg[total - 4] = (lenLo >>> 24) & 0xFF;
    msg[total - 3] = (lenLo >>> 16) & 0xFF;
    msg[total - 2] = (lenLo >>> 8) & 0xFF;
    msg[total - 1] = lenLo & 0xFF;
    var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    var w = new Uint32Array(80);
    for (var off = 0; off < total; off += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = (msg[off + i * 4] << 24) | (msg[off + i * 4 + 1] << 16) |
               (msg[off + i * 4 + 2] << 8) | (msg[off + i * 4 + 3]);
      }
      for (i = 16; i < 80; i++) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      var a = h0, b = h1, c = h2, d = h3, e = h4, f, k;
      for (i = 0; i < 80; i++) {
        if (i < 20)      { f = (b & c) | (~b & d);            k = 0x5A827999; }
        else if (i < 40) { f = b ^ c ^ d;                     k = 0x6ED9EBA1; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d);   k = 0x8F1BBCDC; }
        else             { f = b ^ c ^ d;                     k = 0xCA62C1D6; }
        var tmp = (rotl(a, 5) + f + e + k + w[i]) >>> 0;
        e = d; d = c; c = rotl(b, 30); b = a; a = tmp;
      }
      h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0;
      h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
    }
    function hex(n) { return (n >>> 0).toString(16).padStart(8, "0"); }
    return hex(h0) + hex(h1) + hex(h2) + hex(h3) + hex(h4);
  }

  function hexToBytes(s) {
    var out = new Uint8Array(s.length / 2);
    for (var i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
    return out;
  }

  // Apply the fixed mod diff to a clone of the pristine file bytes.
  function applyRuns(pristine, runs) {
    var out = new Uint8Array(pristine);          // clone
    for (var r = 0; r < runs.length; r++) {
      var off = runs[r][0], bytes = hexToBytes(runs[r][1]);
      out.set(bytes, off);
    }
    return out;
  }

  // values: { key -> integer }. Returns { "prg0.u0211": Uint8Array, ... }.
  function buildPatched(patch, pristineByName, values) {
    var out = {};
    for (var name in patch.files) {
      out[name] = applyRuns(pristineByName[name], patch.files[name].runs);
    }
    // overlay the user-chosen boot-menu defaults
    for (var i = 0; i < patch.defaults.length; i++) {
      var d = patch.defaults[i];
      var v = values[d.key];
      if (v === undefined) v = d.def;
      v = clampDefault(d, v);
      out[d.file][d.off] = v & 0xFF;
    }
    return out;
  }

  function clampDefault(d, v) {
    v = v | 0;
    if (d.type === "onoff") return v ? 1 : 0;
    if (d.type === "list") {
      // optvals lists store the BYTE value directly (e.g. timeout seconds);
      // plain lists store the option index (byte == index).
      if (d.optvals) return d.optvals.indexOf(v) >= 0 ? v : d.def;
      return Math.max(0, Math.min(d.options.length - 1, v));
    }
    if (d.type === "num") return Math.max(d.min, Math.min(d.max, v));
    return v;
  }

  return { crc32: crc32, sha1: sha1, applyRuns: applyRuns,
           buildPatched: buildPatched, clampDefault: clampDefault };
});
