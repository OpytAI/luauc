import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

if (!process.env.RUNFILES_DIR) throw new Error("RUNFILES_DIR is not set");
const runfile = (value) => value.startsWith("/") ? value : join(process.env.RUNFILES_DIR, value);
const compilerBytes = readFileSync(runfile(process.env.LUAUC_COMPILER_WASM));
const compilerModule = new WebAssembly.Module(compilerBytes);
if (WebAssembly.Module.imports(compilerModule).length !== 0) throw new Error("luauc.wasm is not zero-import");
const expectedCompilerExports = new Map([
  ["memory", "memory"], ["luauc_v1_describe", "function"], ["luauc_v1_alloc", "function"],
  ["luauc_v1_dealloc", "function"], ["luauc_v1_context_create", "function"],
  ["luauc_v1_context_destroy", "function"], ["luauc_v1_compile", "function"],
  ["luauc_v1_result_free", "function"],
]);
const actualCompilerExports = new Map(WebAssembly.Module.exports(compilerModule).map(({ name, kind }) => [name, kind]));
if (actualCompilerExports.size !== expectedCompilerExports.size ||
    [...expectedCompilerExports].some(([name, kind]) => actualCompilerExports.get(name) !== kind))
  throw new Error(`compiler export surface drifted: ${JSON.stringify([...actualCompilerExports])}`);
const api = new WebAssembly.Instance(compilerModule, {}).exports;

const sha256 = (bytes) => createHash("sha256").update(bytes).digest();
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
const descriptionView = new DataView(api.memory.buffer, description.pointer, 32);
if (descriptionView.getUint32(0, true) !== 1 || descriptionView.getUint32(8, true) !== 72 || descriptionView.getUint32(12, true) !== 208 || descriptionView.getUint32(16, true) !== 8)
  throw new Error("compiler description drifted");
release(description);

function createContext(profile, pack, expectedStatus = 0) {
  const profileInput = allocation(profile), packInput = allocation(pack), result = allocation(72);
  try {
    new Uint8Array(api.memory.buffer, result.pointer, result.size).fill(0);
    const status = api.luauc_v1_context_create(profileInput.pointer, profileInput.size, packInput.pointer, packInput.size, result.pointer);
    const view = new DataView(api.memory.buffer, result.pointer, result.size);
    if (status !== expectedStatus || view.getUint32(4, true) !== expectedStatus)
      throw new Error(`context create returned ${status}/${view.getUint32(4, true)}, expected ${expectedStatus}`);
    return expectedStatus === 0 ? {
      handle: view.getUint32(0, true),
      profileDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 8, 32)),
      packDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 40, 32)),
    } : null;
  } finally { release(result); release(packInput); release(profileInput); }
}

function canonicalRequest(source, profileDigest, packDigest, coverageLevel = 0) {
  const name = Buffer.from("main"), sourceName = Buffer.from("@main.luau"), content = Buffer.from(source), contentDigest = sha256(content);
  const sized = (bytes) => { const size = Buffer.alloc(4); size.writeUInt32LE(bytes.length); return Buffer.concat([size, bytes]); };
  const manifestHeader = Buffer.alloc(8); manifestHeader.writeUInt32LE(1, 0);
  const manifestDigest = sha256(Buffer.concat([manifestHeader, sized(name), sized(sourceName), contentDigest]));
  const total = 160 + 64 + name.length + sourceName.length + content.length;
  const request = Buffer.alloc(total);
  Buffer.from("LUAUCS1\0", "binary").copy(request, 0);
  request.writeUInt16LE(1, 8); request.writeUInt16LE(160, 10); request.writeUInt32LE(total, 12);
  request.writeUInt32LE(1, 16); request.writeUInt32LE(0, 20); request.writeUInt32LE(64, 24);
  request.writeUInt32LE(coverageLevel, 28);
  const coverage = Buffer.alloc(4); coverage.writeUInt32LE(coverageLevel);
  sha256(Buffer.concat([Buffer.from("luauc-source-request-v1\0"), coverage, profileDigest, packDigest, manifestDigest])).subarray(0, 16).copy(request, 32);
  profileDigest.copy(request, 48); packDigest.copy(request, 80); manifestDigest.copy(request, 112);
  let cursor = 224;
  request.writeUInt32LE(cursor, 160); request.writeUInt32LE(name.length, 164); name.copy(request, cursor); cursor += name.length;
  request.writeUInt32LE(cursor, 168); request.writeUInt32LE(sourceName.length, 172); sourceName.copy(request, cursor); cursor += sourceName.length;
  request.writeUInt32LE(cursor, 176); request.writeUInt32LE(content.length, 180); content.copy(request, cursor); contentDigest.copy(request, 184);
  return request;
}

function compile(handle, request) {
  const requestInput = allocation(request), result = allocation(208);
  try {
    new Uint8Array(api.memory.buffer, result.pointer, result.size).fill(0);
    const status = api.luauc_v1_compile(handle, requestInput.pointer, requestInput.size, result.pointer);
    const view = new DataView(api.memory.buffer, result.pointer, result.size);
    const dataPointer = view.getUint32(0, true), dataSize = view.getUint32(4, true);
    const diagnosticPointer = view.getUint32(8, true), diagnosticSize = view.getUint32(12, true);
    return {
      status, resultStatus: view.getUint32(16, true),
      artifact: dataPointer && dataSize ? Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize)) : Buffer.alloc(0),
      diagnostic: diagnosticPointer && diagnosticSize ? new TextDecoder().decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize)) : "",
      profileDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 40, 32)),
      packDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 72, 32)),
      objectDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 136, 32)),
      artifactDigest: Buffer.from(new Uint8Array(api.memory.buffer, result.pointer + 168, 32)),
    };
  } finally { api.luauc_v1_result_free(result.pointer); release(result); release(requestInput); }
}

const profiles = [
  { id: "embed-v1", profile: readFileSync(runfile(process.env.LUAUC_EMBED_PROFILE)), pack: readFileSync(runfile(process.env.LUAUC_EMBED_PACK)), module: "luauc_embed_v1" },
  { id: "embed-alt-v1", profile: readFileSync(runfile(process.env.LUAUC_EMBED_ALT_PROFILE)), pack: readFileSync(runfile(process.env.LUAUC_EMBED_ALT_PACK)), module: "luauc_embed_alt_v1" },
];
const source = "return function(value, text) return value * 3 + 1, text .. ':' .. value end";
for (const item of profiles) {
  const context = createContext(item.profile, item.pack);
  if (!context.profileDigest.equals(sha256(item.profile)) || !context.packDigest.equals(sha256(item.pack))) throw new Error(`${item.id}: context identity mismatch`);
  const request = canonicalRequest(source, context.profileDigest, context.packDigest);
  const first = compile(context.handle, request), second = compile(context.handle, request);
  if (first.status !== 0 || first.resultStatus !== 0 || !first.artifact.length || !first.artifact.equals(second.artifact))
    throw new Error(`${item.id}: deterministic compile failed: ${first.status}/${first.resultStatus}/${first.diagnostic}`);
  if (!first.profileDigest.equals(context.profileDigest) || !first.packDigest.equals(context.packDigest) || !first.objectDigest.equals(second.objectDigest) || !first.artifactDigest.equals(sha256(first.artifact)))
    throw new Error(`${item.id}: compile provenance mismatch`);
  const module = new WebAssembly.Module(first.artifact);
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 2 || imports.some(({ module: namespace, kind }) => namespace !== item.module || kind !== "function"))
    throw new Error(`${item.id}: artifact import boundary drifted: ${JSON.stringify(imports)}`);
  const identity = WebAssembly.Module.customSections(module, "luauc.link.v1");
  if (identity.length !== 1 || !Buffer.from(identity[0]).subarray(1, 33).equals(context.profileDigest) || !Buffer.from(identity[0]).subarray(33, 65).equals(context.packDigest))
    throw new Error(`${item.id}: artifact linker identity mismatch`);

  const badContent = Buffer.from(request); badContent[184] ^= 0xff;
  const badRequestId = Buffer.from(request); badRequestId[32] ^= 0xff;
  const badCoverage = Buffer.from(request); badCoverage.writeUInt32LE(3, 28);
  for (const [label, malformed, diagnostic] of [
    ["content digest", badContent, "InvalidContentDigest"],
    ["request identity", badRequestId, "InvalidRequestDigest"],
    ["coverage level", badCoverage, "InvalidHeader"],
  ]) {
    const rejected = compile(context.handle, malformed);
    if (rejected.status !== 2 || !rejected.diagnostic.includes(diagnostic))
      throw new Error(`${item.id}: malformed ${label} was accepted: ${rejected.status}/${rejected.diagnostic}`);
    const recovered = compile(context.handle, request);
    if (!recovered.artifact.equals(first.artifact))
      throw new Error(`${item.id}: ${label} failure poisoned deterministic recovery`);
  }
  if (api.luauc_v1_context_destroy(context.handle) !== 0) throw new Error(`${item.id}: context destroy failed`);
  const stale = compile(context.handle, request);
  if (stale.status !== 7 || !stale.diagnostic.includes("InvalidContext")) throw new Error(`${item.id}: stale context handle was accepted`);
}

const malformedProfile = Buffer.from(profiles[0].profile); malformedProfile[0] ^= 0xff;
createContext(malformedProfile, profiles[0].pack, 2);
const recoveredContext = createContext(profiles[0].profile, profiles[0].pack);
if (api.luauc_v1_context_destroy(recoveredContext.handle) !== 0) throw new Error("malformed profile poisoned context recovery");

function encodeUleb(value) {
  const result = [];
  do {
    let byte = value & 0x7f;
    value >>>= 7;
    if (value) byte |= 0x80;
    result.push(byte);
  } while (value);
  return Buffer.from(result);
}

function profileCustomSection(profile) {
  const name = Buffer.from("luauc.runtime.v1");
  const payload = Buffer.concat([encodeUleb(name.length), name, profile]);
  return Buffer.concat([Buffer.from([0]), encodeUleb(payload.length), payload]);
}

const reference = profiles[0];
const referenceContext = createContext(reference.profile, reference.pack);
const referenceRequest = canonicalRequest(source, referenceContext.profileDigest, referenceContext.packDigest);
const referenceArtifact = compile(referenceContext.handle, referenceRequest).artifact;
if (api.luauc_v1_context_destroy(referenceContext.handle) !== 0) throw new Error("reference context destroy failed");

function rejectContextThenRecover(label, profile, pack) {
  createContext(profile, pack, 2);
  const context = createContext(reference.profile, reference.pack);
  const recovered = compile(context.handle, referenceRequest);
  if (recovered.status !== 0 || recovered.resultStatus !== 0 || !recovered.artifact.equals(referenceArtifact))
    throw new Error(`${label}: malformed context poisoned the compiler instance: ${recovered.status}/${recovered.resultStatus}/${recovered.diagnostic}`);
  if (api.luauc_v1_context_destroy(context.handle) !== 0) throw new Error(`${label}: recovered context destroy failed`);
}

const badVersion = Buffer.from(reference.profile); badVersion.writeUInt16LE(2, 8);
const badLength = Buffer.from(reference.profile); badLength.writeUInt32LE(badLength.length - 1, 12);
const badReserved = Buffer.from(reference.profile); badReserved[92] = 1;
const badRole = Buffer.from(reference.profile); {
  const bindings = badRole.readUInt32LE(68);
  badRole.writeUInt16LE(badRole.readUInt16LE(bindings + 8), bindings + 16 + 8);
}
const badProfileManifest = Buffer.from(reference.profile); badProfileManifest[256] ^= 1;
const badPackMagic = Buffer.from(reference.pack); badPackMagic[0] = 1;
const badPackManifest = Buffer.from(reference.pack); badPackManifest[badPackManifest.length - 1] ^= 1;
const custom = profileCustomSection(reference.profile);
if (!reference.pack.subarray(reference.pack.length - custom.length).equals(custom))
  throw new Error("reference pack manifest is not the canonical trailing section");
const missingPackManifest = reference.pack.subarray(0, reference.pack.length - custom.length);
const duplicatePackManifest = Buffer.concat([reference.pack, custom]);

for (const [label, profile, pack] of [
  ["truncated profile", reference.profile.subarray(0, reference.profile.length - 1), reference.pack],
  ["unsupported profile version", badVersion, reference.pack],
  ["inconsistent profile length", badLength, reference.pack],
  ["nonzero profile reserved field", badReserved, reference.pack],
  ["duplicate profile binding role", badRole, reference.pack],
  ["profile/pack manifest mismatch", badProfileManifest, reference.pack],
  ["invalid pack magic", reference.profile, badPackMagic],
  ["truncated pack section", reference.profile, reference.pack.subarray(0, reference.pack.length - 1)],
  ["mutated pack manifest", reference.profile, badPackManifest],
  ["missing pack manifest", reference.profile, missingPackManifest],
  ["duplicate pack manifest", reference.profile, duplicatePackManifest],
]) rejectContextThenRecover(label, profile, pack);

const sourceFailureContext = createContext(reference.profile, reference.pack);
const invalidSource = canonicalRequest("return function(", sourceFailureContext.profileDigest, sourceFailureContext.packDigest);
const sourceFailure = compile(sourceFailureContext.handle, invalidSource);
if (sourceFailure.status !== 3 || !sourceFailure.diagnostic.length)
  throw new Error(`malformed source was not rejected by the frontend: ${sourceFailure.status}/${sourceFailure.diagnostic}`);
const sourceRecovery = compile(sourceFailureContext.handle, referenceRequest);
if (!sourceRecovery.artifact.equals(referenceArtifact)) throw new Error("malformed source poisoned deterministic recovery");
if (api.luauc_v1_context_destroy(sourceFailureContext.handle) !== 0) throw new Error("source recovery context destroy failed");

console.log("verified zero-import context compiler with two independent runtime profiles, deterministic output, provenance, malformed request/profile/pack recovery, source recovery, and stale-handle rejection");
