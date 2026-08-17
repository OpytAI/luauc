import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const [rawPath, profilePath, packPath, policyPath, runtimeAbiPath, objectContractPath, ...licensePaths] = process.argv.slice(2);
if (!rawPath || !profilePath || !packPath || !policyPath || !runtimeAbiPath || !objectContractPath || !licensePaths.length)
  throw new Error("usage: pack_builder raw.wasm profile.bin pack.wasm policy.json runtime-abi object-contract license...");

const roleSpecs = new Map([
  ["program_pointer", { role: 1, kind: 3, required: true, retain: false }],
  ["generated_data_arena", { role: 2, kind: 3, required: true, retain: false }],
  ["generated_data_capacity", { role: 3, kind: 3, required: true, retain: false }],
  ["memory", { role: 4, kind: 2, required: true, retain: true }],
  ["stack_pointer", { role: 5, kind: 3, required: false, retain: true }],
  ["protected_dispatch", { role: 6, kind: 0, required: true, retain: true }],
  ["alloc", { role: 7, kind: 0, required: true, retain: true }],
  ["dealloc", { role: 8, kind: 0, required: true, retain: true }],
  ["context_create", { role: 9, kind: 0, required: true, retain: true }],
  ["context_destroy", { role: 10, kind: 0, required: true, retain: true }],
  ["invoke", { role: 11, kind: 0, required: true, retain: true }],
  ["initialize", { role: 12, kind: 0, required: true, retain: true }],
  ["coverage", { role: 13, kind: 0, required: false, retain: true }],
]);
const kindNames = new Map([["function", 0], ["table", 1], ["memory", 2], ["global", 3]]);

function requireObject(value, description) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${description} must be an object`);
  return value;
}

function requireExactKeys(value, keys, description) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index]))
    throw new Error(`${description} has unknown or missing fields`);
}

function requireName(value, description) {
  const bytes = typeof value === "string" ? Buffer.from(value) : null;
  if (!bytes || !value.length || bytes.toString("utf8") !== value || bytes.includes(0) || [...value].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f))
    throw new Error(`${description} is not a canonical name`);
  return value;
}

const policy = requireObject(JSON.parse(readFileSync(policyPath, "utf8")), "runtime profile policy");
requireExactKeys(policy, ["version", "profile_id", "bindings", "retained_exports"], "runtime profile policy");
if (policy.version !== 1) throw new Error("unsupported runtime profile policy version");
const profileId = requireName(policy.profile_id, "profile_id");
if (!Array.isArray(policy.bindings) || !Array.isArray(policy.retained_exports)) throw new Error("runtime profile policy arrays are malformed");

const policyBindings = [];
const seenRoles = new Set();
const seenBindingNames = new Set();
for (const [index, rawBinding] of policy.bindings.entries()) {
  const binding = requireObject(rawBinding, `binding ${index}`);
  requireExactKeys(binding, ["role", "name", "retain"], `binding ${index}`);
  const spec = roleSpecs.get(binding.role);
  if (!spec || seenRoles.has(spec.role)) throw new Error(`binding ${index} has an unknown or duplicate role`);
  const bindingName = requireName(binding.name, `binding ${index} name`);
  if (seenBindingNames.has(bindingName)) throw new Error(`binding ${index} has a duplicate export name`);
  if (binding.retain !== spec.retain) throw new Error(`binding ${index} has invalid retention for ${binding.role}`);
  seenRoles.add(spec.role);
  seenBindingNames.add(bindingName);
  policyBindings.push({ name: bindingName, role: spec.role, kind: spec.kind, retain: spec.retain });
}
for (const [roleName, spec] of roleSpecs) if (spec.required && !seenRoles.has(spec.role)) throw new Error(`missing required binding ${roleName}`);

const additionalRetained = [];
const seenRetainedNames = new Set(policyBindings.map((binding) => binding.name));
for (const [index, rawRetained] of policy.retained_exports.entries()) {
  const retained = requireObject(rawRetained, `retained export ${index}`);
  requireExactKeys(retained, ["name", "kind"], `retained export ${index}`);
  const retainedName = requireName(retained.name, `retained export ${index} name`);
  const retainedKind = kindNames.get(retained.kind);
  if (retainedKind === undefined || seenRetainedNames.has(retainedName)) throw new Error(`retained export ${index} is invalid or duplicated`);
  seenRetainedNames.add(retainedName);
  additionalRetained.push({ name: retainedName, kind: retainedKind });
}

const raw = readFileSync(rawPath);
if (!raw.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])))
  throw new Error("raw runtime pack is not Wasm v1");

function uleb(bytes, state) {
  let value = 0;
  let shift = 0;
  for (let count = 0; count < 5; count++) {
    if (state.at >= bytes.length) throw new Error("truncated ULEB");
    const byte = bytes[state.at++];
    value |= (byte & 0x7f) << shift;
    if (!(byte & 0x80)) return value >>> 0;
    shift += 7;
  }
  throw new Error("overlong ULEB");
}

function encodeUleb(value) {
  const bytes = [];
  do {
    let byte = value & 0x7f;
    value >>>= 7;
    if (value) byte |= 0x80;
    bytes.push(byte);
  } while (value);
  return Buffer.from(bytes);
}

function name(bytes, state) {
  const size = uleb(bytes, state);
  const finish = state.at + size;
  if (finish > bytes.length) throw new Error("truncated Wasm name");
  const value = bytes.subarray(state.at, finish).toString("utf8");
  state.at = finish;
  return value;
}

const sections = new Map();
for (const state = { at: 8 }; state.at < raw.length;) {
  const id = raw[state.at++];
  const size = uleb(raw, state);
  const finish = state.at + size;
  if (finish > raw.length) throw new Error("truncated Wasm section");
  if (id && sections.has(id)) throw new Error(`duplicate Wasm section ${id}`);
  if (id) sections.set(id, raw.subarray(state.at, finish));
  state.at = finish;
}

function vectorSection(id, parse) {
  const bytes = sections.get(id);
  if (!bytes) throw new Error(`missing Wasm section ${id}`);
  const state = { at: 0 };
  const count = uleb(bytes, state);
  const result = [];
  for (let index = 0; index < count; index++) result.push(parse(bytes, state));
  if (state.at !== bytes.length) throw new Error(`trailing bytes in section ${id}`);
  return result;
}

function skipLimits(bytes, state) {
  const flags = uleb(bytes, state);
  const minimum = uleb(bytes, state);
  const maximum = flags & 1 ? uleb(bytes, state) : minimum;
  if (flags & ~1) throw new Error("unsupported Wasm limits flags");
  return { minimum, maximum };
}

const types = vectorSection(1, (bytes, state) => {
  const start = state.at;
  if (bytes[state.at++] !== 0x60) throw new Error("non-function Wasm type");
  const params = uleb(bytes, state);
  state.at += params;
  const results = uleb(bytes, state);
  state.at += results;
  if (state.at > bytes.length) throw new Error("truncated Wasm type");
  return bytes.subarray(start, state.at);
});

const imports = vectorSection(2, (bytes, state) => {
  const module = name(bytes, state);
  const importName = name(bytes, state);
  const kind = bytes[state.at++];
  if (kind !== 0) throw new Error("runtime profiles accept function imports only");
  const typeIndex = uleb(bytes, state);
  if (typeIndex >= types.length) throw new Error("host import type is out of range");
  return { module, name: importName, kind, typeIndex };
});
const functionTypes = vectorSection(3, (bytes, state) => uleb(bytes, state));
const tables = vectorSection(4, (bytes, state) => {
  if (bytes[state.at++] !== 0x70) throw new Error("runtime pack table is not funcref");
  return skipLimits(bytes, state);
});
const memories = vectorSection(5, (bytes, state) => skipLimits(bytes, state));
if (tables.length !== 1 || memories.length !== 1) throw new Error("runtime pack needs one table and one memory");
const exports = vectorSection(7, (bytes, state) => ({ name: name(bytes, state), kind: bytes[state.at++], index: uleb(bytes, state) }));
const exportMap = new Map(exports.map((item) => [item.name, item]));

function functionTypeIndex(index) {
  if (index < imports.length) return imports[index].typeIndex;
  const defined = index - imports.length;
  if (defined >= functionTypes.length) throw new Error("function export index is out of range");
  return functionTypes[defined];
}

for (const binding of policyBindings) {
  const item = exportMap.get(binding.name);
  if (!item || item.kind !== binding.kind) throw new Error(`missing profile binding ${binding.name}`);
}
for (const retained of additionalRetained) {
  const item = exportMap.get(retained.name);
  if (!item || item.kind !== retained.kind) throw new Error(`missing retained export ${retained.name}`);
}

const runtimeSymbols = exports
  .filter(({ name: exportName, kind }) => kind === 0 && exportName.startsWith("luauc_runtime_v1_") &&
    exportName !== "luauc_runtime_v1_protected_call" && exportName !== "luauc_runtime_v1_raise")
  .map((item) => ({ ...item, typeIndex: functionTypeIndex(item.index) }))
  .sort((lhs, rhs) => Buffer.from(lhs.name).compare(Buffer.from(rhs.name)));
if (!runtimeSymbols.length) throw new Error("runtime pack exports no generated-code ABI");

imports.sort((lhs, rhs) => Buffer.from(`${lhs.module}\0${lhs.name}`).compare(Buffer.from(`${rhs.module}\0${rhs.name}`)));
const retained = [
  ...policyBindings.filter((binding) => binding.retain).map((binding) => ({ ...exportMap.get(binding.name), role: binding.role })),
  ...additionalRetained.map((item) => ({ ...exportMap.get(item.name), role: 0 })),
]
  .sort((lhs, rhs) => Buffer.from(lhs.name).compare(Buffer.from(rhs.name)));
const bindings = policyBindings.map(({ name, role, kind }) => ({ name, role, kind }))
  .sort((lhs, rhs) => lhs.role - rhs.role);

const stringParts = [];
const stringRefs = new Map();
let stringSize = 0;
function stringRef(value) {
  if (stringRefs.has(value)) return stringRefs.get(value);
  const bytes = Buffer.from(value);
  if (!bytes.length || bytes.includes(0)) throw new Error("invalid profile string");
  const result = { offset: stringSize, size: bytes.length };
  stringRefs.set(value, result);
  stringParts.push(bytes);
  stringSize += bytes.length;
  return result;
}
const profileRef = stringRef(profileId);
for (const item of imports) { stringRef(item.module); stringRef(item.name); }
for (const item of retained) stringRef(item.name);
const generatedRuntimeModule = "env";
stringRef(generatedRuntimeModule);
for (const item of runtimeSymbols) stringRef(item.name);
for (const item of bindings) stringRef(item.name);

const headerSize = 320, importSize = 24, exportSize = 16, runtimeSize = 24, bindingSize = 16;
const importOffset = headerSize;
const exportOffset = importOffset + imports.length * importSize;
const runtimeOffset = exportOffset + retained.length * exportSize;
const bindingOffset = runtimeOffset + runtimeSymbols.length * runtimeSize;
const stringOffset = bindingOffset + bindings.length * bindingSize;
const profile = Buffer.alloc(stringOffset + stringSize);
Buffer.from("LUACRP1\0", "binary").copy(profile, 0);
profile.writeUInt16LE(1, 8); profile.writeUInt16LE(headerSize, 10); profile.writeUInt32LE(profile.length, 12);
profile.writeUInt32LE(0, 16);
profile.writeUInt32LE(memories[0].minimum, 20); profile.writeUInt32LE(memories[0].maximum, 24);
profile.writeUInt32LE(tables[0].minimum, 28); profile.writeUInt32LE(tables[0].maximum, 32);
profile.writeUInt32LE(stringOffset, 36); profile.writeUInt32LE(stringSize, 40);
profile.writeUInt32LE(importOffset, 44); profile.writeUInt32LE(imports.length, 48);
profile.writeUInt32LE(exportOffset, 52); profile.writeUInt32LE(retained.length, 56);
profile.writeUInt32LE(runtimeOffset, 60); profile.writeUInt32LE(runtimeSymbols.length, 64);
profile.writeUInt32LE(bindingOffset, 68); profile.writeUInt32LE(bindings.length, 72);
profile.writeUInt32LE(importSize, 76); profile.writeUInt32LE(exportSize, 80);
profile.writeUInt32LE(runtimeSize, 84); profile.writeUInt32LE(bindingSize, 88);
profile.writeUInt32LE(profileRef.offset, 104); profile.writeUInt32LE(profileRef.size, 108);
Buffer.from("e51ead5f541633693d548057e0431927f3036c13b185fdb37fbc3f5a261e6676", "hex").copy(profile, 128);
createHash("sha256").update(readFileSync(runtimeAbiPath)).digest().copy(profile, 160);
createHash("sha256").update(readFileSync(objectContractPath)).digest().copy(profile, 192);
createHash("sha256").update(raw).digest().copy(profile, 224);
const licenseInventory = createHash("sha256").update("luauc-license-inventory-v1\0");
for (const path of licensePaths) {
  const content = readFileSync(path);
  const size = Buffer.alloc(4); size.writeUInt32LE(content.length);
  licenseInventory.update(size).update(content);
}
licenseInventory.digest().copy(profile, 256);

for (let index = 0; index < imports.length; index++) {
  const record = importOffset + index * importSize, item = imports[index], module = stringRef(item.module), importName = stringRef(item.name);
  profile.writeUInt32LE(module.offset, record); profile.writeUInt32LE(module.size, record + 4);
  profile.writeUInt32LE(importName.offset, record + 8); profile.writeUInt32LE(importName.size, record + 12);
  profile.writeUInt32LE(item.typeIndex, record + 16); profile[record + 20] = item.kind;
}
for (let index = 0; index < retained.length; index++) {
  const record = exportOffset + index * exportSize, item = retained[index], ref = stringRef(item.name);
  profile.writeUInt32LE(ref.offset, record); profile.writeUInt32LE(ref.size, record + 4);
  profile[record + 8] = item.kind; profile[record + 9] = item.role || 0;
}
for (let index = 0; index < runtimeSymbols.length; index++) {
  const record = runtimeOffset + index * runtimeSize, item = runtimeSymbols[index], ref = stringRef(item.name);
  const module = stringRef(generatedRuntimeModule);
  profile.writeUInt32LE(ref.offset, record); profile.writeUInt32LE(ref.size, record + 4);
  profile.writeUInt32LE(item.typeIndex, record + 8); profile[record + 12] = item.kind;
  profile.writeUInt32LE(module.offset, record + 16); profile.writeUInt32LE(module.size, record + 20);
}
for (let index = 0; index < bindings.length; index++) {
  const record = bindingOffset + index * bindingSize, item = bindings[index], ref = stringRef(item.name);
  profile.writeUInt32LE(ref.offset, record); profile.writeUInt32LE(ref.size, record + 4);
  profile.writeUInt16LE(item.role, record + 8); profile[record + 10] = item.kind;
}
Buffer.concat(stringParts).copy(profile, stringOffset);

const customName = Buffer.from("luauc.runtime.v1");
const customPayload = Buffer.concat([encodeUleb(customName.length), customName, profile]);
const customSection = Buffer.concat([Buffer.from([0]), encodeUleb(customPayload.length), customPayload]);
const pack = Buffer.concat([raw, customSection]);
new WebAssembly.Module(pack);
writeFileSync(profilePath, profile);
writeFileSync(packPath, pack);
