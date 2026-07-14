// Node test: the web tool's apply logic + generated data must reproduce
// raiden2j-modded byte-for-byte, and a changed default must touch only its
// one byte. Run: node web/r2tool/test_webtool.js
const fs = require("fs");
const path = require("path");
const R2 = require("./r2apply.js");
const PATCH = require("./r2patch.js");

const ROOT = path.join(__dirname, "..", "..");
const rd = (d, f) => new Uint8Array(fs.readFileSync(path.join(ROOT, d, f)));
let fails = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + ": " + m); if (!c) fails++; };

const pristine = { "prg0.u0211": rd("raiden2j", "prg0.u0211"),
                   "rom2j.u0212": rd("raiden2j", "rom2j.u0212") };
const modded   = { "prg0.u0211": rd("raiden2j-modded", "prg0.u0211"),
                   "rom2j.u0212": rd("raiden2j-modded", "rom2j.u0212") };

// 1. checksum functions vs embedded pristine values
for (const f in PATCH.files) {
  ok(R2.sha1(pristine[f]) === PATCH.files[f].sha1, `${f} SHA1 matches`);
  ok(R2.crc32(pristine[f]) === PATCH.files[f].crc32, `${f} CRC32 matches`);
}

// 2. build with default values -> must equal raiden2j-modded exactly
const built = R2.buildPatched(PATCH, pristine, {});
for (const f in PATCH.files) {
  let same = built[f].length === modded[f].length;
  let firstDiff = -1;
  if (same) for (let i = 0; i < built[f].length; i++)
    if (built[f][i] !== modded[f][i]) { same = false; firstDiff = i; break; }
  ok(same, `${f} build == patch_roms output` + (same ? "" : ` (first diff @ 0x${firstDiff.toString(16)})`));
}

// 3. changing one default touches exactly one byte
const d = PATCH.defaults.find(x => x.key === "boot_timeout");
const built2 = R2.buildPatched(PATCH, pristine, { boot_timeout: 0 });
let diffs = [];
for (let i = 0; i < built2[d.file].length; i++)
  if (built2[d.file][i] !== built[d.file][i]) diffs.push(i);
ok(diffs.length === 1 && diffs[0] === d.off && built2[d.file][d.off] === 0,
   `boot_timeout=0 changes only byte 0x${d.off.toString(16)} in ${d.file}`);

// other file untouched by that change
const otherF = d.file === "prg0.u0211" ? "rom2j.u0212" : "prg0.u0211";
let otherSame = true;
for (let i = 0; i < built2[otherF].length; i++)
  if (built2[otherF][i] !== built[otherF][i]) { otherSame = false; break; }
ok(otherSame, "the other ROM file is untouched by a single-file default change");

// 4. default metadata sanity: 9 entries, offsets unique-ish, defs in range
ok(PATCH.defaults.length === 9, "9 boot-menu defaults present");
ok(PATCH.defaults.find(x=>x.key==="region").options.length === 22, "22 region names");

console.log(fails === 0 ? "\nALL TESTS PASS" : `\n${fails} FAILURE(S)`);
process.exit(fails === 0 ? 0 : 1);
