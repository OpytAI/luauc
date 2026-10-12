import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return join(root, relative);
}

const contractInputs = [
  "compiler/ir/BUILD.bazel",
  "compiler/ir/frontend_snapshot_v1.zig",
  "frontend/BUILD.bazel",
  "frontend/compiler_error_channel.h",
  "frontend/error_channel.h",
  "frontend/frontend_adapter.cpp",
  "frontend/package_liveness.h",
  "frontend/frontend_fastflags.cpp",
  "frontend/frontend_host.zig",
  "frontend/host_wasi_stubs.c",
  "frontend/trap.h",
  "schema/BUILD.bazel",
  "schema/frontend_snapshot_v1.h",
  "third_party/luau/BUILD.luau.bazel",
  "third_party/luau/BUILD.bazel",
  "third_party/luau/patches/0001-wasm-errors.patch",
  "third_party/luau/patches/0002-frontend-single-thread.patch",
  "third_party/luau/patches/0003-strict-aot-runtime-dispatch.patch",
  "third_party/luau/patches/0004-integer-buffer-fastcalls.patch",
  "third_party/luau/patches/0005-analysis-no-exceptions.patch",
  "third_party/luau/patches/0006-analysis-named-catch.patch",
  "third_party/luau/patches/0007-analysis-shim.patch",
  "third_party/luau/patches/0008-analysis-explicit-control-flow.patch",
  "third_party/luau/patches/0009-aot-coverage-data.patch",
  "third_party/luau/patches/0010-bytecode-builder-introspection.patch",
  "third_party/luau/patches/0011-compiler-owned-builder.patch",
  "third_party/luau/patches/0012-aot-builtin-guard-fallbacks.patch",
  "third_party/luau/patches/0013-aot-xnext-safeenv-fallback.patch",
  "third_party/luau/patches/0014-aot-fastcall-safeenv-fallback.patch",
  "third_party/luau/patches/0015-aot-fallback-safeenv-no-entry-exit.patch",
  "third_party/luau/patches/0016-aot-fastcall-safeenv-retain-fallback.patch",
  "third_party/luau/patches/0017-aot-cache-independent-imports.patch",
  "third_party/luau/patches/0018-aot-semantic-type-fallbacks.patch",
  "third_party/luau/patches/0019-aot-literal-and-namecall-fallbacks.patch",
  "third_party/luau/patches/0020-aot-goto-labels.patch",
  "third_party/luau/patches/0021-aot-vector-fallbacks.patch",
  "third_party/luau/patches/0022-aot-straight-add-chain.patch",
  "third_party/luau/patches/0023-aot-compact-semantic-operations.patch",
  "third_party/luau/patches/0024-aot-compact-control-operations.patch",
  "third_party/luau/patches/0025-aot-literal-key-templates.patch",
  "third_party/luau/patches/0026-closed-table-field-liveness.patch",
].sort();

function frontendContractDigest() {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const hash = createHash("sha256");
  const fileDigests = [];
  for (const path of contractInputs) {
    const bytes = readFileSync(join(root, "_main", path));
    hash.update(path);
    hash.update(Buffer.from([0]));
    hash.update(bytes);
    hash.update(Buffer.from([0xff]));
    fileDigests.push({ path, sha256: createHash("sha256").update(bytes).digest("hex") });
  }
  return { digest: hash.digest("hex"), fileDigests };
}

function workspaceFile(path) {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return readFileSync(join(root, "_main", path));
}

function patchsetDigest() {
  const hash = createHash("sha256");
  for (const path of contractInputs.filter((path) => path.startsWith("third_party/luau/patches/")))
    hash.update(workspaceFile(path));
  return hash.digest("hex");
}

function u16(bytes, offset) {
  return bytes.readUInt16LE(offset);
}

function u32(bytes, offset) {
  return bytes.readUInt32LE(offset);
}

function u64(bytes, offset) {
  return Number(bytes.readBigUInt64LE(offset));
}

function parseSnapshot(bytes) {
  if (bytes.subarray(0, 8).toString("binary") !== "LUAUCIR\0") throw new Error("bad snapshot magic");
  if (u16(bytes, 8) !== 1 || u16(bytes, 10) !== 224) throw new Error("bad snapshot version/header");
  if (u32(bytes, 12) !== 1) throw new Error("bad snapshot pipeline flags");
  if (u64(bytes, 16) !== bytes.length) throw new Error("bad snapshot total size");
  if (u32(bytes, 184) !== 1) throw new Error("snapshot is not a single-module frontend unit");

  const protoCount = u32(bytes, 188);
  const irFunctionCount = u32(bytes, 192);
  const stringCount = u32(bytes, 196);
  const rootProto = u32(bytes, 200);
  const sectionCount = u32(bytes, 204);
  if (protoCount !== irFunctionCount || rootProto !== 0) throw new Error("invalid graph header counts");
  if (sectionCount !== 21) throw new Error(`expected all 21 canonical sections, got ${sectionCount}`);

  const sections = new Map();
  let payload = 224 + sectionCount * 32;
  for (let index = 0; index < sectionCount; index++) {
    const at = 224 + index * 32;
    const kind = u16(bytes, at);
    const flags = u16(bytes, at + 2);
    const recordSize = u32(bytes, at + 4);
    const offset = u64(bytes, at + 8);
    const length = u64(bytes, at + 16);
    const count = u32(bytes, at + 24);
    if (kind !== index + 1 || flags !== 0 || u32(bytes, at + 28) !== 0)
      throw new Error(`noncanonical section descriptor ${index}`);
    if (offset !== payload || length !== recordSize * count || offset + length > bytes.length)
      throw new Error(`invalid section range ${kind}`);
    sections.set(kind, { recordSize, offset, length, count });
    payload += length;
  }
  if (payload !== bytes.length) throw new Error("snapshot has trailing or missing bytes");

  if (sections.get(1).count !== stringCount) throw new Error("string header/table count mismatch");
  if (sections.get(3).count !== protoCount) throw new Error("proto header/table count mismatch");
  if (sections.get(15).count !== irFunctionCount) throw new Error("IR header/table count mismatch");

  return { protoCount, irFunctionCount, stringCount, sections };
}

function functionCommands(bytes, parsed, functionId) {
  const functions = parsed.sections.get(15);
  const instructions = parsed.sections.get(17);
  const record = functions.offset + functionId * functions.recordSize;
  if (u32(bytes, record) !== functionId || u32(bytes, record + 4) !== functionId)
    throw new Error(`function/proto identity mismatch for ${functionId}`);
  const blockCount = u32(bytes, record + 20);
  const instructionStart = u32(bytes, record + 24);
  const instructionCount = u32(bytes, record + 28);
  if (blockCount === 0 || instructionCount === 0) throw new Error(`empty IR function ${functionId}`);
  const commands = [];
  for (let index = 0; index < instructionCount; index++) {
    commands.push(bytes[instructions.offset + (instructionStart + index) * instructions.recordSize]);
  }
  return commands;
}

function importPaths(bytes, parsed) {
  const strings = parsed.sections.get(1);
  const stringBytes = parsed.sections.get(2);
  const protos = parsed.sections.get(3);
  const constants = parsed.sections.get(6);
  const constantItems = parsed.sections.get(7);
  const paths = [];

  for (let protoId = 0; protoId < protos.count; protoId++) {
    const proto = protos.offset + protoId * protos.recordSize;
    const constantStart = u32(bytes, proto + 44);
    const constantCount = u32(bytes, proto + 48);
    for (let constantId = 0; constantId < constantCount; constantId++) {
      const constant = constants.offset + (constantStart + constantId) * constants.recordSize;
      if (bytes[constant] !== 6) continue;

      const itemStart = u32(bytes, constant + 4);
      const itemCount = u32(bytes, constant + 8);
      const path = [];
      for (let itemId = 0; itemId < itemCount; itemId++) {
        const item = constantItems.offset + (itemStart + itemId) * constantItems.recordSize;
        const nameConstantId = u32(bytes, item);
        if (u32(bytes, item + 4) !== 0xffffffff || nameConstantId >= constantCount)
          throw new Error("invalid import constant item");
        const nameConstant = constants.offset + (constantStart + nameConstantId) * constants.recordSize;
        if (bytes[nameConstant] !== 4) throw new Error("import component is not a VM string constant");
        const stringId = u32(bytes, nameConstant + 4);
        if (stringId >= strings.count) throw new Error("import component string is out of bounds");
        const string = strings.offset + stringId * strings.recordSize;
        const byteOffset = u64(bytes, string);
        const byteLength = u32(bytes, string + 8);
        path.push(bytes.subarray(stringBytes.offset + byteOffset, stringBytes.offset + byteOffset + byteLength).toString());
      }
      paths.push(path);
    }
  }

  return paths;
}

function tableConstants(bytes, parsed) {
  const strings = parsed.sections.get(1);
  const stringBytes = parsed.sections.get(2);
  const protos = parsed.sections.get(3);
  const constants = parsed.sections.get(6);
  const constantItems = parsed.sections.get(7);
  const tables = [];

  function scalar(constantStart, constantCount, constantId) {
    if (constantId === 0xffffffff) return { kind: "placeholder" };
    if (constantId >= constantCount) throw new Error("table item constant id is out of bounds");
    const constant = constants.offset + (constantStart + constantId) * constants.recordSize;
    const kind = bytes[constant];
    if (kind === 0) return { kind: "nil" };
    if (kind === 1) return { kind: "boolean", value: u32(bytes, constant + 4) !== 0 };
    if (kind === 2) return { kind: "number", value: bytes.readDoubleLE(constant + 24) };
    if (kind === 4) {
      const stringId = u32(bytes, constant + 4);
      if (stringId >= strings.count) throw new Error("table item string id is out of bounds");
      const string = strings.offset + stringId * strings.recordSize;
      const byteOffset = u64(bytes, string);
      const byteLength = u32(bytes, string + 8);
      return {
        kind: "string",
        value: bytes.subarray(stringBytes.offset + byteOffset, stringBytes.offset + byteOffset + byteLength).toString(),
      };
    }
    throw new Error(`unexpected table item scalar kind ${kind}`);
  }

  for (let protoId = 0; protoId < protos.count; protoId++) {
    const proto = protos.offset + protoId * protos.recordSize;
    const constantStart = u32(bytes, proto + 44);
    const constantCount = u32(bytes, proto + 48);
    for (let constantId = 0; constantId < constantCount; constantId++) {
      const constant = constants.offset + (constantStart + constantId) * constants.recordSize;
      if (bytes[constant] !== 7) continue;
      const itemStart = u32(bytes, constant + 4);
      const itemCount = u32(bytes, constant + 8);
      const items = [];
      for (let itemId = 0; itemId < itemCount; itemId++) {
        const item = constantItems.offset + (itemStart + itemId) * constantItems.recordSize;
        items.push({
          keyId: u32(bytes, item),
          valueId: u32(bytes, item + 4),
          key: scalar(constantStart, constantCount, u32(bytes, item)),
          value: scalar(constantStart, constantCount, u32(bytes, item + 4)),
        });
      }
      tables.push({ protoId, constantId, items });
    }
  }
  return tables;
}

const wasmBytes = readFileSync(runfile(process.env.LUAUC_FRONTEND_WASM, "LUAUC_FRONTEND_WASM"));
const module = await WebAssembly.compile(wasmBytes);
const imports = WebAssembly.Module.imports(module);
if (imports.length !== 0) throw new Error(`host compiler is not zero-import: ${JSON.stringify(imports)}`);
const exportNames = WebAssembly.Module.exports(module).map(({ name }) => name).sort();
const expectedExportNames = [
  "_start",
  "luauc_frontend_snapshot_v1_compile",
  "luauc_frontend_snapshot_v1_compile_inlined",
  "luauc_frontend_snapshot_v1_free",
  "luauc_frontend_snapshot_v1_last_raise_message",
  "luauc_frontend_snapshot_v1_last_raise_message_size",
  "luauc_frontend_v1_alloc",
  "luauc_frontend_v1_dealloc",
  "luauc_frontend_v1_init",
  "luauc_frontend_v1_validate_snapshot",
  "memory",
].sort();
if (JSON.stringify(exportNames) !== JSON.stringify(expectedExportNames))
  throw new Error(`frontend export surface drifted: ${JSON.stringify(exportNames)}`);

const instance = await WebAssembly.instantiate(module, {});
const api = instance.exports;
for (const name of [
  "memory",
  "luauc_frontend_v1_init",
  "luauc_frontend_v1_alloc",
  "luauc_frontend_v1_dealloc",
  "luauc_frontend_v1_validate_snapshot",
  "luauc_frontend_snapshot_v1_compile",
  "luauc_frontend_snapshot_v1_compile_inlined",
  "luauc_frontend_snapshot_v1_free",
]) {
  if (!(name in api)) throw new Error(`missing frontend export ${name}`);
}
api.luauc_frontend_v1_init();

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function compile(sourceText, chunkText, coverageLevel = 0, inlinePlans = null) {
  const source = encoder.encode(sourceText);
  const chunk = encoder.encode(chunkText);
  const sourcePointer = api.luauc_frontend_v1_alloc(source.length);
  const chunkPointer = api.luauc_frontend_v1_alloc(chunk.length);
  const resultPointer = api.luauc_frontend_v1_alloc(20);
  const planBytes = inlinePlans === null ? null : new Uint8Array(inlinePlans.length * 16);
  if (planBytes)
    for (let index = 0; index < inlinePlans.length; index++) {
      const plan = inlinePlans[index];
      new DataView(planBytes.buffer).setUint32(index * 16, plan.callerFunctionId, true);
      new DataView(planBytes.buffer).setUint32(index * 16 + 4, plan.feedbackSlot, true);
      new DataView(planBytes.buffer).setUint32(index * 16 + 8, plan.targetFunctionId, true);
    }
  const planPointer = planBytes?.length ? api.luauc_frontend_v1_alloc(planBytes.length) : 0;
  if (!sourcePointer || !chunkPointer || !resultPointer || (planBytes?.length && !planPointer))
    throw new Error("frontend host allocation failed");

  new Uint8Array(api.memory.buffer, sourcePointer, source.length).set(source);
  new Uint8Array(api.memory.buffer, chunkPointer, chunk.length).set(chunk);
  if (planBytes?.length) new Uint8Array(api.memory.buffer, planPointer, planBytes.length).set(planBytes);
  new Uint8Array(api.memory.buffer, resultPointer, 20).fill(0);
  const returned = inlinePlans === null
    ? api.luauc_frontend_snapshot_v1_compile(
      sourcePointer,
      source.length,
      chunkPointer,
      chunk.length,
      coverageLevel,
      resultPointer,
    )
    : api.luauc_frontend_snapshot_v1_compile_inlined(
      sourcePointer,
      source.length,
      chunkPointer,
      chunk.length,
      coverageLevel,
      planPointer,
      inlinePlans.length,
      resultPointer,
    );

  const result = new DataView(api.memory.buffer, resultPointer, 20);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const diagnosticPointer = result.getUint32(8, true);
  const diagnosticSize = result.getUint32(12, true);
  const status = result.getUint32(16, true);
  if (status !== returned) throw new Error(`status return/result mismatch: ${returned}/${status}`);

  const snapshot = dataPointer && dataSize
    ? Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize))
    : Buffer.alloc(0);
  const diagnostic = diagnosticPointer && diagnosticSize
    ? decoder.decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
    : "";
  const validation = dataPointer && dataSize
    ? api.luauc_frontend_v1_validate_snapshot(dataPointer, dataSize)
    : 0;

  api.luauc_frontend_snapshot_v1_free(resultPointer);
  api.luauc_frontend_v1_dealloc(resultPointer, 20);
  if (planPointer) api.luauc_frontend_v1_dealloc(planPointer, planBytes.length);
  api.luauc_frontend_v1_dealloc(chunkPointer, chunk.length);
  api.luauc_frontend_v1_dealloc(sourcePointer, source.length);
  return { status, snapshot, diagnostic, validation };
}

const source = `
local function add(a, b)
    return a + b
end

return add(20, 22)
`;

const first = compile(source, "@frontend/closed-graph.luau");
if (first.status !== 0) throw new Error(`frontend compile failed: ${first.status}: ${first.diagnostic}`);
if (first.validation !== 0) throw new Error(`Zig rejected C++ FrontendSnapshotV1 with code ${first.validation}`);
const { digest: contractDigest, fileDigests } = frontendContractDigest();
const carriedDigest = first.snapshot.subarray(88, 120).toString("hex");
if (carriedDigest !== contractDigest) {
  const firstPath = fileDigests[0]?.path ?? "(none)";
  throw new Error(
    `frontend contract identity drifted: carried=${carriedDigest} derived=${contractDigest}; ` +
      `first contract-input path=${firstPath}; files=${fileDigests.map((item) => `${item.path}=${item.sha256.slice(0, 8)}`).join(",")}`,
  );
}
const layoutIdentity = JSON.parse(workspaceFile("conformance/maps/luauc_layout.json"));
const irIdentity = JSON.parse(workspaceFile("conformance/maps/luauc_ir_coverage.json"));
const carriedPin = first.snapshot.subarray(24, 56).toString("hex");
const carriedPatchset = first.snapshot.subarray(56, 88).toString("hex");
const carriedIr = first.snapshot.subarray(120, 152).toString("hex");
const carriedLayout = first.snapshot.subarray(152, 184).toString("hex");
if (carriedPin !== layoutIdentity.luau_pin.archive_sha256) throw new Error("snapshot Luau pin identity drifted");
const derivedPatchset = patchsetDigest();
if (carriedPatchset !== derivedPatchset)
  throw new Error(`snapshot patchset identity drifted: carried=${carriedPatchset} derived=${derivedPatchset}`);
if (carriedIr !== irIdentity.input_sha256) throw new Error("snapshot IR enum identity drifted");
if (carriedLayout !== layoutIdentity.fields_sha256) throw new Error("snapshot layout identity drifted");
const parsed = parseSnapshot(first.snapshot);
if (parsed.protoCount !== 2) throw new Error(`expected root + child Proto, got ${parsed.protoCount}`);

const rootCommands = functionCommands(first.snapshot, parsed, 0);
const childCommands = functionCommands(first.snapshot, parsed, 1);
if (!rootCommands.includes(154) || !rootCommands.includes(155))
  throw new Error(`root IR lacks real CALL/RETURN commands: ${JSON.stringify(rootCommands)}`);
if (!childCommands.includes(36) || !childCommands.includes(155))
  throw new Error(`child IR lacks real ADD_NUM/RETURN commands: ${JSON.stringify(childCommands)}`);

const second = compile(source, "@frontend/closed-graph.luau");
if (second.status !== 0) throw new Error(`second frontend compile failed: ${second.diagnostic}`);
if (!first.snapshot.equals(second.snapshot)) throw new Error("identical input produced nondeterministic snapshot bytes");

const invalid = compile("local =", "@frontend/syntax-error.luau");
if (invalid.status !== 2 || invalid.snapshot.length !== 0 || invalid.diagnostic.length === 0)
  throw new Error(`syntax failure was not a structured diagnostic: ${JSON.stringify(invalid)}`);

const closedFields = `
local methods = {
    used = function(value) return value + 1 end,
    unused = function() return function() return 99 end end,
}
`;
for (const [label, suffix, expected] of [
  ["literal", "return methods.used(7)", 2],
  ["alias", "local alias = methods; local other = alias; return other.used(7)", 2],
  ["index", 'return methods["used"](7)', 2],
  ["return", "return methods", 4],
  ["argument", "return unknown(methods)", 4],
  ["dynamic", "return methods[unknown()](7)", 4],
  ["iterate", "for key in pairs(methods) do print(key) end", 4],
  ["length", "return #methods", 4],
  ["namecall", "return methods:used()", 4],
  ["mutation", "methods.unused = nil; return methods.used(7)", 4],
  ["alias-mutation", "local alias = methods; alias.unused = nil; return methods.used(7)", 4],
  ["rebind", "local alias = methods; methods = unknown(); return alias.used(7)", 4],
  ["capture", "return function() return methods.used(7) end", 5],
  ["environment", "getfenv(); return methods.used(7)", 4],
]) {
  for (const coverageLevel of [0, 2, 0]) {
    const result = compile(closedFields + suffix, `@frontend/closed-fields-${label}.luau`, coverageLevel);
    if (result.status !== 0 || result.validation !== 0)
      throw new Error(`closed field analysis failed for ${label}: ${result.diagnostic}`);
    const count = parseSnapshot(result.snapshot).protoCount;
    const retained = coverageLevel ? (label === "capture" ? 5 : 4) : expected;
    if (count !== retained)
      throw new Error(`closed fields ${label} coverage ${coverageLevel}: expected ${retained} prototypes, got ${count}`);
    const repeated = compile(closedFields + suffix, `@frontend/closed-fields-${label}.luau`, coverageLevel);
    if (!result.snapshot.equals(repeated.snapshot))
      throw new Error(`closed field analysis is nondeterministic for ${label}`);
  }
}
for (const [label, source, expected] of [
  ["duplicate", "local t = { unused = function() return 1 end, unused = function() return 2 end }; return t.missing", 3],
  ["mixed", "local t = { function() return 1 end, unused = function() return 2 end }; return t.missing", 3],
  ["effect", "local t = { effect = unknown(function() return 1 end), unused = function() return 2 end }; return t.missing", 2],
  ["binary-key", 'local t = { ["a\\0b"] = function() return 1 end, a = function() return 2 end }; return t["a\\0b"]()', 2],
  ["native", "local t = { unused = @native function() return 1 end }; return t.missing", 2],
]) {
  const result = compile(source, `@frontend/closed-fields-${label}.luau`);
  if (result.status !== 0 || result.validation !== 0 || parseSnapshot(result.snapshot).protoCount !== expected)
    throw new Error(`closed field boundary failed for ${label}: ${result.diagnostic}`);
}

const protoIdentitySource = `
local function hot(a, b)
    return a * 3 + b
end
local function cold(a, b)
    return a - b
end
local function dispatch(fn, a, b)
    local result = fn(a, b)
    return result
end
return function(useHot, a, b)
    return dispatch(if useHot then hot else cold, a, b)
end
`;
const protoIdentityPlan = [{ callerFunctionId: 2, feedbackSlot: 0, targetFunctionId: 0 }];
const inlined = compile(protoIdentitySource, "@frontend/proto_identity.luau", 0, protoIdentityPlan);
if (inlined.status !== 0 || inlined.validation !== 0)
  throw new Error(`profile-guided inline frontend failed: ${inlined.status}: ${inlined.diagnostic}`);
const inlinedParsed = parseSnapshot(inlined.snapshot);
const protoIdentityFunctions = Array.from(
  { length: inlinedParsed.irFunctionCount },
  (_, functionId) => functionCommands(inlined.snapshot, inlinedParsed, functionId),
);
if (!protoIdentityFunctions.some((commands) => commands.includes(215)))
  throw new Error(`upstream inliner produced no JUMP_CMP_PROTOID: ${JSON.stringify(protoIdentityFunctions)}`);
const inlinedAgain = compile(protoIdentitySource, "@frontend/proto_identity.luau", 0, protoIdentityPlan);
if (inlinedAgain.status !== 0 || !inlined.snapshot.equals(inlinedAgain.snapshot))
  throw new Error("profile-guided inline frontend is nondeterministic");
const invalidInline = compile(
  protoIdentitySource,
  "@frontend/proto_identity-invalid.luau",
  0,
  [{ callerFunctionId: 2, feedbackSlot: 99, targetFunctionId: 0 }],
);
if (invalidInline.status !== 1 || invalidInline.snapshot.length !== 0 || invalidInline.diagnostic.length === 0)
  throw new Error(`invalid inline plan was not rejected structurally: ${JSON.stringify(invalidInline)}`);
const invalidInlineSource = compile(
  "local =",
  "@frontend/proto_identity-syntax-error.luau",
  0,
  [{ callerFunctionId: 0, feedbackSlot: 0, targetFunctionId: 0 }],
);
if (invalidInlineSource.status !== 2 || invalidInlineSource.snapshot.length !== 0 || invalidInlineSource.diagnostic.length === 0)
  throw new Error(`inlined syntax failure was not a structured diagnostic: ${JSON.stringify(invalidInlineSource)}`);

const compoundSource = 'return function() return { first = 11, second = 22, label = "seed" } end';
const compound = compile(compoundSource, "@frontend/compound-constant.luau");
if (compound.status !== 0 || compound.validation !== 0)
  throw new Error(`table constant frontend failed: ${compound.status}: ${compound.diagnostic}`);
const compoundParsed = parseSnapshot(compound.snapshot);
const decodedTables = tableConstants(compound.snapshot, compoundParsed);
if (decodedTables.length !== 1) throw new Error(`expected one VM_TABLE constant: ${JSON.stringify(decodedTables)}`);
const decodedItems = decodedTables[0].items;
if (decodedItems.some((item, index) => index > 0 && decodedItems[index - 1].keyId >= item.keyId))
  throw new Error(`VM_TABLE items are not in deterministic local-key order: ${JSON.stringify(decodedItems)}`);
const decodedRecord = Object.fromEntries(decodedItems.map((item) => [item.key.value, item.value.value]));
if (
  JSON.stringify(Object.keys(decodedRecord).sort()) !== JSON.stringify(["first", "label", "second"]) ||
  decodedRecord.first !== 11 || decodedRecord.second !== 22 || decodedRecord.label !== "seed"
)
  throw new Error(`VM_TABLE item references mismatch: ${JSON.stringify(decodedItems)}`);
const compoundSecond = compile(compoundSource, "@frontend/compound-constant.luau");
if (compoundSecond.status !== 0 || !compound.snapshot.equals(compoundSecond.snapshot))
  throw new Error("identical record-only table input produced nondeterministic snapshot bytes");

for (const coverageLevel of [0, 2, 0]) {
  for (const inlinePlans of [null, protoIdentityPlan]) {
    const literal = '{ ["first:key"] = 11, ["nil:key"] = nil, flag = false }';
    const source = inlinePlans === null ? `return function() return ${literal} end`
      : protoIdentitySource.replace("return a - b", `return ${literal}`);
    const result = compile(source,
      "@frontend/literal-key-template.luau", coverageLevel, inlinePlans);
    if (result.status !== 0 || result.validation !== 0)
      throw new Error(`literal-key template failed: ${result.diagnostic}`);
    const tables = tableConstants(result.snapshot, parseSnapshot(result.snapshot));
    if (tables.length !== 1) throw new Error("literal keys did not use a table template");
    const fields = Object.fromEntries(tables[0].items.map(item => [item.key.value, item.value]));
    if (coverageLevel < 2) {
      if (fields["first:key"]?.value !== 11 || fields.flag?.value !== false ||
          fields["nil:key"]?.kind !== "nil")
        throw new Error(`literal-key template values mismatch: ${JSON.stringify(fields)}`);
    } else if (Object.values(fields).some(value => value.kind !== "placeholder")) {
      throw new Error("expression coverage must retain individual field initializers");
    }
  }
}

const imported = compile("return math.abs(-42)", "@frontend/import-constant.luau");
if (imported.status !== 0 || imported.validation !== 0)
  throw new Error(`decoded import frontend failed: ${imported.status}: ${imported.diagnostic}`);
const importedParsed = parseSnapshot(imported.snapshot);
if (JSON.stringify(importPaths(imported.snapshot, importedParsed)) !== JSON.stringify([["math", "abs"]]))
  throw new Error(`decoded import path mismatch: ${JSON.stringify(importPaths(imported.snapshot, importedParsed))}`);

const required = compile('return require("./module")', "@frontend/static-require-import.luau");
if (required.status !== 0 || required.validation !== 0)
  throw new Error(`static require import frontend failed: ${required.status}: ${required.diagnostic}`);
const requiredParsed = parseSnapshot(required.snapshot);
if (!functionCommands(required.snapshot, requiredParsed, 0).includes(127))
  throw new Error("decoded require snapshot lacks GET_CACHED_IMPORT");
if (JSON.stringify(importPaths(required.snapshot, requiredParsed)) !== JSON.stringify([["require"]]))
  throw new Error(`static require import path mismatch: ${JSON.stringify(importPaths(required.snapshot, requiredParsed))}`);

const threePartImport = compile("return game.workspace.part", "@frontend/three-part-import.luau");
if (threePartImport.status !== 0 || threePartImport.validation !== 0)
  throw new Error(`three-part import frontend failed: ${threePartImport.status}: ${threePartImport.diagnostic}`);
const threePartParsed = parseSnapshot(threePartImport.snapshot);
if (JSON.stringify(importPaths(threePartImport.snapshot, threePartParsed)) !== JSON.stringify([["game", "workspace", "part"]]))
  throw new Error(`three-part import path mismatch: ${JSON.stringify(importPaths(threePartImport.snapshot, threePartParsed))}`);

console.log(
  `verified zero-import FrontendSnapshotV1: ${parsed.protoCount} protos, ` +
    `${parsed.sections.get(16).count} blocks, ${parsed.sections.get(17).count} instructions, deterministic bytes`,
);
