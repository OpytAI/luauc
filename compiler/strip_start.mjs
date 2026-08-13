import { readFileSync, writeFileSync } from "node:fs";

const [inputPath, outputPath] = process.argv.slice(2);
if (!inputPath || !outputPath) throw new Error("usage: strip_start input.wasm output.wasm");
const input = readFileSync(inputPath);
if (!input.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]))) throw new Error("compiler is not Wasm v1");
function readUleb(bytes, state) { let value = 0, shift = 0; for (let count = 0; count < 5; count++) { if (state.at >= bytes.length) throw new Error("truncated ULEB"); const byte = bytes[state.at++]; value |= (byte & 0x7f) << shift; if (!(byte & 0x80)) return value >>> 0; shift += 7; } throw new Error("overlong ULEB"); }
function writeUleb(value) { const bytes = []; do { let byte = value & 0x7f; value >>>= 7; if (value) byte |= 0x80; bytes.push(byte); } while (value); return Buffer.from(bytes); }
function readName(bytes, state) { const size = readUleb(bytes, state), finish = state.at + size; if (finish > bytes.length) throw new Error("truncated name"); const value = bytes.subarray(state.at, finish); state.at = finish; return value; }
const output = [input.subarray(0, 8)];
for (const state = { at: 8 }; state.at < input.length;) {
  const id = input[state.at++], size = readUleb(input, state), finish = state.at + size;
  if (finish > input.length) throw new Error("truncated section");
  let payload = input.subarray(state.at, finish);
  if (id === 7) {
    const exportState = { at: 0 }, count = readUleb(payload, exportState), entries = [];
    for (let index = 0; index < count; index++) {
      const name = readName(payload, exportState), kind = payload[exportState.at++], itemIndex = readUleb(payload, exportState);
      if (name.toString("utf8") !== "_start") entries.push(Buffer.concat([writeUleb(name.length), name, Buffer.from([kind]), writeUleb(itemIndex)]));
    }
    if (exportState.at !== payload.length || entries.length !== count - 1) throw new Error("compiler must contain exactly one _start export");
    payload = Buffer.concat([writeUleb(entries.length), ...entries]);
  }
  output.push(Buffer.from([id]), writeUleb(payload.length), payload);
  state.at = finish;
}
const result = Buffer.concat(output);
new WebAssembly.Module(result);
writeFileSync(outputPath, result);
