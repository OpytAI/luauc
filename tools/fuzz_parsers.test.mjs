import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  compileFrontendSnapshot,
  instantiateZeroImport,
} from "./ir_ledger.mjs";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const direct = join(root, relative);
  try {
    readFileSync(direct);
    return direct;
  } catch {
    return join(root, "_main", relative);
  }
}

const compilerBytes = readFileSync(runfile(process.env.LUAUC_COMPILER_WASM, "LUAUC_COMPILER_WASM"));
const profileBytes = readFileSync(runfile(process.env.LUAUC_EMBED_PROFILE, "LUAUC_EMBED_PROFILE"));
const packBytes = readFileSync(runfile(process.env.LUAUC_EMBED_PACK, "LUAUC_EMBED_PACK"));
const linkerCli = runfile(process.env.LUAUC_LINKER_CLI, "LUAUC_LINKER_CLI");
const frontend = await instantiateZeroImport(
  runfile(process.env.LUAUC_FRONTEND_WASM, "LUAUC_FRONTEND_WASM"),
  "frontend",
);
const backend = await instantiateZeroImport(
  runfile(process.env.LUAUC_BACKEND_WASM, "LUAUC_BACKEND_WASM"),
  "backend",
);

const compilerModule = new WebAssembly.Module(compilerBytes);
if (WebAssembly.Module.imports(compilerModule).length !== 0) throw new Error("luauc.wasm is not zero-import");
const api = new WebAssembly.Instance(compilerModule, {}).exports;
const sha256 = (bytes) => createHash("sha256").update(bytes).digest();
const frontendContract = Buffer.from("ac5a7481f9904162f4bee7ea3a6e89a8815e197fc500ac74e1084abafca98157", "hex");

function allocation(bytesOrSize) {
  const size = typeof bytesOrSize === "number" ? bytesOrSize : bytesOrSize.length;
  const pointer = api.luauc_v1_alloc(size);
  if (!pointer) throw new Error(`compiler allocation failed for ${size} bytes`);
  if (typeof bytesOrSize !== "number") new Uint8Array(api.memory.buffer, pointer, size).set(bytesOrSize);
  return { pointer, size };
}
function release(item) { api.luauc_v1_dealloc(item.pointer, item.size); }

const description = allocation(32);
if (api.luauc_v1_describe(description.pointer) !== 0) throw new Error("compiler describe failed");
const compileResultSize = new DataView(api.memory.buffer, description.pointer, 32).getUint32(12, true);
release(description);

function createContext(profile, pack) {
  if (!profile.length || !pack.length) {
    return { ok: false, status: 2, resultStatus: 2 };
  }
  const profileInput = allocation(profile), packInput = allocation(pack), result = allocation(72);
  try {
    new Uint8Array(api.memory.buffer, result.pointer, result.size).fill(0);
    const status = api.luauc_v1_context_create(
      profileInput.pointer, profileInput.size, packInput.pointer, packInput.size, result.pointer,
    );
    const view = new DataView(api.memory.buffer, result.pointer, result.size);
    const resultStatus = view.getUint32(4, true);
    if (status !== 0 || resultStatus !== 0) {
      return { ok: false, status, resultStatus };
    }
    return {
      ok: true,
      handle: view.getUint32(0, true),
      profileDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 8, 32)),
      packDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 40, 32)),
    };
  } finally { release(result); release(packInput); release(profileInput); }
}

function canonicalRequest(source, profileDigest, packDigest) {
  const name = Buffer.from("main"), sourceName = Buffer.from("@main.luau"), content = Buffer.from(source);
  const contentDigest = sha256(content);
  const sized = (bytes) => { const size = Buffer.alloc(4); size.writeUInt32LE(bytes.length); return Buffer.concat([size, bytes]); };
  const manifestHeader = Buffer.alloc(8); manifestHeader.writeUInt32LE(1, 0);
  const zeroPlans = Buffer.alloc(4);
  const manifestDigest = sha256(Buffer.concat([manifestHeader, sized(name), sized(sourceName), contentDigest, zeroPlans]));
  const total = 240 + 64 + name.length + sourceName.length + content.length;
  const request = Buffer.alloc(total);
  Buffer.from("LUAUCS1\0", "binary").copy(request, 0);
  request.writeUInt16LE(1, 8); request.writeUInt16LE(240, 10); request.writeUInt32LE(total, 12);
  request.writeUInt32LE(1, 16); request.writeUInt32LE(0, 20); request.writeUInt32LE(64, 24);
  request.writeUInt32LE(0, 176); request.writeUInt32LE(32, 180); request.writeUInt32LE(0, 184);
  request.writeUInt32LE(1048576, 188); request.writeUInt32LE(4096, 192); request.writeUInt32LE(16777216, 196);
  const coverage = Buffer.alloc(4);
  const options = Buffer.alloc(32);
  options.writeUInt32LE(32, 4); options.writeUInt32LE(1048576, 12);
  options.writeUInt32LE(4096, 16); options.writeUInt32LE(16777216, 20);
  sha256(Buffer.concat([
    Buffer.from("luauc-source-request-v1\0"), coverage, frontendContract, profileDigest, packDigest, manifestDigest, options, zeroPlans,
  ])).subarray(0, 16).copy(request, 32);
  frontendContract.copy(request, 48);
  profileDigest.copy(request, 80);
  packDigest.copy(request, 112);
  manifestDigest.copy(request, 144);
  let cursor = 304;
  request.writeUInt32LE(cursor, 240); request.writeUInt32LE(name.length, 244); name.copy(request, cursor); cursor += name.length;
  request.writeUInt32LE(cursor, 248); request.writeUInt32LE(sourceName.length, 252); sourceName.copy(request, cursor); cursor += sourceName.length;
  request.writeUInt32LE(cursor, 256); request.writeUInt32LE(content.length, 260); content.copy(request, cursor); contentDigest.copy(request, 264);
  return request;
}

function compile(handle, request) {
  if (!request.length) {
    return { status: 2, resultStatus: 2, artifact: Buffer.alloc(0), diagnostic: "InvalidHeader" };
  }
  const requestInput = allocation(request), result = allocation(compileResultSize);
  try {
    new Uint8Array(api.memory.buffer, result.pointer, result.size).fill(0);
    const status = api.luauc_v1_compile(handle, requestInput.pointer, requestInput.size, result.pointer);
    const view = new DataView(api.memory.buffer, result.pointer, result.size);
    const dataPointer = view.getUint32(0, true), dataSize = view.getUint32(4, true);
    const diagnosticPointer = view.getUint32(8, true), diagnosticSize = view.getUint32(12, true);
    return {
      status,
      resultStatus: view.getUint32(16, true),
      artifact: dataPointer && dataSize ? Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize)) : Buffer.alloc(0),
      diagnostic: diagnosticPointer && diagnosticSize
        ? new TextDecoder().decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
        : "",
    };
  } finally { api.luauc_v1_result_free(result.pointer); release(result); release(requestInput); }
}

function backendStaticPackage(snapshot) {
  if (!snapshot.length) {
    return { status: 2, resultStatus: 2, diagnostic: "InvalidHeader", object: Buffer.alloc(0) };
  }
  const name = Buffer.from("fuzz");
  const sourceName = Buffer.from("@fuzz.luau");
  const headerSize = 24, recordSize = 24;
  const frame = Buffer.alloc(headerSize + recordSize + name.length + sourceName.length + snapshot.length);
  Buffer.from("LUAUCP1\0", "binary").copy(frame, 0);
  frame.writeUInt16LE(1, 8); frame.writeUInt16LE(headerSize, 10);
  frame.writeUInt32LE(1, 12); frame.writeUInt32LE(0, 16); frame.writeUInt32LE(recordSize, 20);
  let cursor = headerSize + recordSize;
  frame.writeUInt32LE(cursor, headerSize); frame.writeUInt32LE(name.length, headerSize + 4);
  name.copy(frame, cursor); cursor += name.length;
  frame.writeUInt32LE(cursor, headerSize + 16); frame.writeUInt32LE(sourceName.length, headerSize + 20);
  sourceName.copy(frame, cursor); cursor += sourceName.length;
  frame.writeUInt32LE(cursor, headerSize + 8); frame.writeUInt32LE(snapshot.length, headerSize + 12);
  snapshot.copy(frame, cursor);
  const apiBackend = backend.exports;
  const framePointer = apiBackend.luauc_backend_v1_alloc(frame.length);
  const resultPointer = apiBackend.luauc_backend_v1_alloc(24);
  new Uint8Array(apiBackend.memory.buffer, framePointer, frame.length).set(frame);
  new Uint8Array(apiBackend.memory.buffer, resultPointer, 24).fill(0);
  const status = apiBackend.luauc_backend_v1_compile_static_package(framePointer, frame.length, resultPointer);
  const view = new DataView(apiBackend.memory.buffer, resultPointer, 24);
  const dataPointer = view.getUint32(0, true), dataSize = view.getUint32(4, true);
  const resultStatus = view.getUint32(8, true);
  const diagnosticPointer = view.getUint32(16, true), diagnosticSize = view.getUint32(20, true);
  const diagnostic = diagnosticPointer && diagnosticSize
    ? new TextDecoder().decode(new Uint8Array(apiBackend.memory.buffer, diagnosticPointer, diagnosticSize))
    : "";
  const object = dataPointer && dataSize
    ? Buffer.from(new Uint8Array(apiBackend.memory.buffer, dataPointer, dataSize))
    : Buffer.alloc(0);
  apiBackend.luauc_backend_v1_free(resultPointer);
  apiBackend.luauc_backend_v1_dealloc(resultPointer, 24);
  apiBackend.luauc_backend_v1_dealloc(framePointer, frame.length);
  return { status, resultStatus, diagnostic, object };
}

function linkObject(objectBytes) {
  if (!objectBytes.length) return { status: 1, stderr: "InvalidMagic" };
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), "luauc-fuzz-"));
  const profilePath = join(directory, "embed.profile");
  const packPath = join(directory, "embed.pack.wasm");
  const objectPath = join(directory, "package.o");
  writeFileSync(profilePath, profileBytes);
  writeFileSync(packPath, packBytes);
  writeFileSync(objectPath, objectBytes);
  const linked = spawnSync(linkerCli, [profilePath, packPath, objectPath], { encoding: "buffer" });
  rmSync(directory, { recursive: true, force: true });
  return { status: linked.status, stderr: linked.stderr?.toString() ?? "" };
}

function mutateAt(bytes, offset, value) {
  const copy = Buffer.from(bytes);
  copy[offset % copy.length] = value & 0xff;
  return copy;
}

function flipAt(bytes, offset) {
  const copy = Buffer.from(bytes);
  copy[offset % copy.length] ^= 0xff;
  return copy;
}

function truncateTo(bytes, size) {
  return Buffer.from(bytes.subarray(0, Math.max(0, size)));
}

const source = "return function(value, text) return value * 3 + 1, text .. ':' .. value end";
const context = createContext(profileBytes, packBytes);
if (!context.ok) throw new Error("valid context create failed");
const request = canonicalRequest(source, context.profileDigest, context.packDigest);
const baseline = compile(context.handle, request);
if (baseline.status !== 0 || baseline.resultStatus !== 0 || !baseline.artifact.length) {
  throw new Error(`baseline compile failed: ${baseline.status}/${baseline.resultStatus}/${baseline.diagnostic}`);
}

function recover(label) {
  const recovered = compile(context.handle, request);
  if (recovered.status !== 0 || recovered.resultStatus !== 0 || !recovered.artifact.equals(baseline.artifact)) {
    throw new Error(`${label}: same-instance compile did not reproduce prior bytes (${recovered.status}/${recovered.diagnostic})`);
  }
}

let cases = 0;
function expectReject(label, compiled) {
  cases += 1;
  if (compiled.status === 0 && compiled.resultStatus === 0 && compiled.artifact.length) {
    throw new Error(`${label}: mutation was accepted`);
  }
  if (!compiled.diagnostic && compiled.status === 0 && compiled.resultStatus === 0) {
    throw new Error(`${label}: rejection had no structured status`);
  }
  recover(label);
}

function expectContextReject(label, profile, pack) {
  cases += 1;
  const rejected = createContext(profile, pack);
  if (rejected.ok) throw new Error(`${label}: malformed context was accepted`);
  recover(label);
}

function expectBackendReject(label, snapshot) {
  cases += 1;
  const compiled = backendStaticPackage(snapshot);
  if (compiled.status === 0 && compiled.resultStatus === 0 && compiled.object.length) {
    throw new Error(`${label}: malformed snapshot was accepted`);
  }
  recover(label);
}

function expectLinkReject(label, objectBytes) {
  cases += 1;
  const linked = linkObject(objectBytes);
  if (linked.status === 0) throw new Error(`${label}: malformed object was accepted`);
  recover(label);
}

const packageMutations = [
  ["package magic", flipAt(request, 0)],
  ["package version", mutateAt(request, 8, 2)],
  ["package header size 160", (() => { const copy = Buffer.from(request); copy.writeUInt16LE(160, 10); return copy; })()],
  ["package header size 0", (() => { const copy = Buffer.from(request); copy.writeUInt16LE(0, 10); return copy; })()],
  ["truncated package", truncateTo(request, 80)],
  ["empty package", Buffer.alloc(0)],
  ["request identity", flipAt(request, 32)],
  ["frontend contract", flipAt(request, 48)],
  ["profile digest", flipAt(request, 80)],
  ["pack digest", flipAt(request, 112)],
  ["manifest digest", flipAt(request, 144)],
  ["coverage level", (() => { const copy = Buffer.from(request); copy.writeUInt32LE(3, 28); return copy; })()],
  ["output kind", (() => { const copy = Buffer.from(request); copy.writeUInt32LE(99, 176); return copy; })()],
  ["module count", (() => { const copy = Buffer.from(request); copy.writeUInt32LE(0, 16); return copy; })()],
  ["content digest", flipAt(request, 264)],
  ["reserved header byte", mutateAt(request, 208, 1)],
];
for (const [label, malformed] of packageMutations) {
  expectReject(label, compile(context.handle, malformed));
}
for (let index = 0; index < 40; index++) {
  expectReject(`package identity byte ${index}`, flipAt(request, 32 + (index % 16)));
}

const profileMutations = [
  ["profile magic", flipAt(profileBytes, 0)],
  ["profile version", mutateAt(profileBytes, 8, 2)],
  ["profile length", (() => { const copy = Buffer.from(profileBytes); copy.writeUInt32LE(copy.length - 1, 12); return copy; })()],
  ["truncated profile", truncateTo(profileBytes, 100)],
  ["empty profile", Buffer.alloc(0)],
  ["profile reserved", mutateAt(profileBytes, 92, 1)],
];
for (const [label, malformed] of profileMutations) expectContextReject(label, malformed, packBytes);
for (let index = 0; index < 30; index++) {
  expectContextReject(`profile magic/id byte ${index}`, flipAt(profileBytes, index % 12), packBytes);
}

const packMutations = [
  ["pack magic", flipAt(packBytes, 0)],
  ["truncated pack", truncateTo(packBytes, 16)],
  ["empty pack", Buffer.alloc(0)],
  ["pack last byte", flipAt(packBytes, packBytes.length - 1)],
];
for (const [label, malformed] of packMutations) expectContextReject(label, profileBytes, malformed);
for (let index = 0; index < 30; index++) {
  expectContextReject(`pack magic/header byte ${index}`, profileBytes, flipAt(packBytes, index % 8));
}

const snapshot = compileFrontendSnapshot(frontend.exports, source, "@fuzz/main.luau");
const snapshotMutations = [
  ["snapshot magic", flipAt(snapshot, 0)],
  ["snapshot version", mutateAt(snapshot, 8, 2)],
  ["snapshot header size", mutateAt(snapshot, 10, 0)],
  ["truncated snapshot", truncateTo(snapshot, 32)],
  ["empty snapshot", Buffer.alloc(0)],
];
for (const [label, malformed] of snapshotMutations) expectBackendReject(label, malformed);
for (let index = 0; index < 40; index++) {
  expectBackendReject(`snapshot header byte ${index}`, flipAt(snapshot, index % 16));
}

const validObject = backendStaticPackage(snapshot);
if (validObject.status !== 0 || !validObject.object.length) {
  throw new Error(`valid object compile failed: ${validObject.status}/${validObject.diagnostic}`);
}
const objectMutations = [
  ["object magic", flipAt(validObject.object, 0)],
  ["truncated object", truncateTo(validObject.object, 16)],
  ["empty object", Buffer.alloc(0)],
];
for (const [label, malformed] of objectMutations) expectLinkReject(label, malformed);
for (let index = 0; index < 30; index++) {
  expectLinkReject(`object header byte ${index}`, flipAt(validObject.object, index % 8));
}

if (cases < 200) throw new Error(`expected at least 200 mutations, got ${cases}`);
if (api.luauc_v1_context_destroy(context.handle) !== 0) throw new Error("context destroy failed");
const stale = compile(context.handle, request);
if (stale.status !== 7) throw new Error(`stale context was accepted: ${stale.status}`);

console.log(`fuzzed ${cases} parser mutations; same-instance valid compile reproduced the baseline artifact`);
