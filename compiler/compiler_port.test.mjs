import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

if (!process.env.RUNFILES_DIR) throw new Error("RUNFILES_DIR is not set");
const runfile = (value) => value.startsWith("/") ? value : join(process.env.RUNFILES_DIR, value);
const sha256 = (bytes) => createHash("sha256").update(bytes).digest();
const frontendContract = Buffer.from("5a3d58d3990465626e841af673189462bab2039e22d16ad972891484ff1143d9", "hex");
const source = "return function(value, text) return value * 3 + 1, text .. ':' .. value end";
const maxRequestBytes = 16 * 1024 * 1024;

function canonicalRequest(text, profileDigest, packDigest, importCeiling = 64) {
  const name = Buffer.from("main");
  const sourceName = Buffer.from("@main.luau");
  const content = Buffer.from(text);
  const sized = (bytes) => {
    const size = Buffer.alloc(4);
    size.writeUInt32LE(bytes.length);
    return Buffer.concat([size, bytes]);
  };
  const manifestHeader = Buffer.alloc(8);
  manifestHeader.writeUInt32LE(1, 0);
  const contentDigest = sha256(content);
  const manifestDigest = sha256(Buffer.concat([
    manifestHeader, sized(name), sized(sourceName), contentDigest, Buffer.alloc(4),
  ]));
  const total = 240 + 64 + name.length + sourceName.length + content.length;
  const request = Buffer.alloc(total);
  Buffer.from("LUAUCS1\0", "binary").copy(request, 0);
  request.writeUInt16LE(1, 8);
  request.writeUInt16LE(240, 10);
  request.writeUInt32LE(total, 12);
  request.writeUInt32LE(1, 16);
  request.writeUInt32LE(64, 24);
  request.writeUInt32LE(importCeiling, 180);
  request.writeUInt32LE(1048576, 188);
  request.writeUInt32LE(4096, 192);
  request.writeUInt32LE(16777216, 196);
  const options = Buffer.alloc(32);
  options.writeUInt32LE(importCeiling, 4);
  options.writeUInt32LE(1048576, 12);
  options.writeUInt32LE(4096, 16);
  options.writeUInt32LE(16777216, 20);
  sha256(Buffer.concat([
    Buffer.from("luauc-source-request-v1\0"),
    Buffer.alloc(4),
    frontendContract,
    profileDigest,
    packDigest,
    manifestDigest,
    options,
    Buffer.alloc(4),
  ])).subarray(0, 16).copy(request, 32);
  frontendContract.copy(request, 48);
  profileDigest.copy(request, 80);
  packDigest.copy(request, 112);
  manifestDigest.copy(request, 144);
  let cursor = 304;
  request.writeUInt32LE(cursor, 240);
  request.writeUInt32LE(name.length, 244);
  name.copy(request, cursor);
  cursor += name.length;
  request.writeUInt32LE(cursor, 248);
  request.writeUInt32LE(sourceName.length, 252);
  sourceName.copy(request, cursor);
  cursor += sourceName.length;
  request.writeUInt32LE(cursor, 256);
  request.writeUInt32LE(content.length, 260);
  content.copy(request, cursor);
  contentDigest.copy(request, 264);
  return request;
}

function frame(body) {
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length);
  return Buffer.concat([header, body]);
}

function readFrame(buffer, offset) {
  if (offset + 8 > buffer.length) throw new Error(`truncated port header at ${offset}`);
  const status = buffer.readUInt32LE(offset);
  const diagnosticLength = buffer.readUInt32LE(offset + 4);
  const diagnosticStart = offset + 8;
  const diagnosticEnd = diagnosticStart + diagnosticLength;
  if (diagnosticEnd + 4 > buffer.length) throw new Error("truncated port diagnostic");
  const artifactLength = buffer.readUInt32LE(diagnosticEnd);
  const artifactStart = diagnosticEnd + 4;
  const artifactEnd = artifactStart + artifactLength;
  if (artifactEnd > buffer.length) throw new Error("truncated port artifact");
  return {
    status,
    diagnostic: buffer.subarray(diagnosticStart, diagnosticEnd).toString("utf8"),
    artifact: buffer.subarray(artifactStart, artifactEnd),
    next: artifactEnd,
  };
}

function runPort(stdin) {
  const result = spawnSync(runfile(process.env.LUAUC_COMPILER_PORT), [
    runfile(process.env.LUAUC_EMBED_PROFILE),
    runfile(process.env.LUAUC_EMBED_PACK),
  ], { input: stdin });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(`compiler port exited ${result.status}: ${result.stderr.toString("utf8")}`);
  return result.stdout;
}

const compilerBytes = readFileSync(runfile(process.env.LUAUC_COMPILER_WASM));
const api = new WebAssembly.Instance(new WebAssembly.Module(compilerBytes), {}).exports;
function allocation(bytes) {
  const pointer = api.luauc_v1_alloc(bytes.length);
  if (!pointer) throw new Error("compiler allocation failed");
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  return pointer;
}
const profile = readFileSync(runfile(process.env.LUAUC_EMBED_PROFILE));
const pack = readFileSync(runfile(process.env.LUAUC_EMBED_PACK));
const profilePointer = allocation(profile);
const packPointer = allocation(pack);
const context = allocation(Buffer.alloc(72));
if (api.luauc_v1_context_create(profilePointer, profile.length, packPointer, pack.length, context) !== 0)
  throw new Error("wasm context create failed");
const contextView = new DataView(api.memory.buffer, context, 72);
const profileDigest = Buffer.from(new Uint8Array(api.memory.buffer, context + 8, 32));
const packDigest = Buffer.from(new Uint8Array(api.memory.buffer, context + 40, 32));
const request = canonicalRequest(source, profileDigest, packDigest);
const requestPointer = allocation(request);
const wasmResult = allocation(Buffer.alloc(320));
if (api.luauc_v1_compile(contextView.getUint32(0, true), requestPointer, request.length, wasmResult) !== 0)
  throw new Error("wasm compile failed");
const wasmView = new DataView(api.memory.buffer, wasmResult, 320);
const wasmArtifact = Buffer.from(new Uint8Array(
  api.memory.buffer,
  wasmView.getUint32(0, true),
  wasmView.getUint32(4, true),
));

const stdout = runPort(Buffer.concat([
  frame(request),
  frame(canonicalRequest(source, profileDigest, packDigest, 0)),
]));
const compiled = readFrame(stdout, 0);
if (compiled.status !== 0 || compiled.diagnostic !== "" || !compiled.artifact.equals(wasmArtifact))
  throw new Error(`port compile diverged from wasm: ${compiled.status}/${compiled.diagnostic}/${compiled.artifact.length}/${wasmArtifact.length}`);
const limited = readFrame(stdout, compiled.next);
if (limited.status !== 6 || !limited.diagnostic.includes("ResourceLimit") || limited.artifact.length !== 0)
  throw new Error(`port resource ceiling diverged: ${limited.status}/${limited.diagnostic}/${limited.artifact.length}`);
if (limited.next !== stdout.length) throw new Error("port wrote trailing bytes");

const oversized = Buffer.alloc(4);
oversized.writeUInt32LE(maxRequestBytes + 1);
const rejected = readFrame(runPort(oversized), 0);
const rejectedLength = 8 + Buffer.byteLength("InvalidArgument") + 4;
if (rejected.status !== 1 || rejected.diagnostic !== "InvalidArgument" || rejected.artifact.length !== 0 || rejected.next !== rejectedLength)
  throw new Error(`oversized frame was compiled: ${rejected.status}/${rejected.diagnostic}/${rejected.artifact.length}/${rejected.next}`);

console.log(`compiler port matched wasm (${wasmArtifact.length} bytes) and rejected the resource ceiling`);
