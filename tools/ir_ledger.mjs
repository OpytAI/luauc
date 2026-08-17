import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const LEDGER_GENERATOR_VERSION = "luauc-ir-ledger-v2";
export const GENERAL_ARMS_GENERATOR_VERSION = "luauc-general-arms-v1";
export const PIN = "luau-0.725+luauc-patches";
export const COMMAND_COUNT = 216;

export const QUALIFYING_GATES = Object.freeze([
  "//hosts/wasmtime:parity_test",
  "//conformance:runtime_measurement_test",
]);

export const EMBED_ORACLE_GATES = Object.freeze([
  "//hosts/js:embed_test",
  "//hosts/js:cli_test",
]);

export const USERDATA_HELPERS = Object.freeze([
  "luauc_runtime_v1_check_userdata_tag",
  "luauc_runtime_v1_new_userdata",
  "luauc_runtime_v1_barrier_object",
  "luauc_runtime_v1_set_userdata_metatable",
]);

const COMPILE_ONLY = new Set(["NOP", "SUBSTITUTE", "MARK_USED", "MARK_DEAD", "CAPTURE"]);

export function isCompileOnly(command) {
  return COMPILE_ONLY.has(command);
}

export function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const direct = join(root, relative);
  try {
    readFileSync(direct);
    return direct;
  } catch {
    const nested = join(root, "_main", relative);
    try {
      readFileSync(nested);
      return nested;
    } catch {
      return direct;
    }
  }
}

export function resolvePath(relativeOrAbs, workspaceRoot) {
  if (!relativeOrAbs) throw new Error("path is empty");
  if (relativeOrAbs.startsWith("/")) return relativeOrAbs;
  if (process.env.RUNFILES_DIR) {
    try {
      return runfile(relativeOrAbs, relativeOrAbs);
    } catch {
      // Fall through to workspace path when generating outside Bazel.
    }
  }
  return join(workspaceRoot, relativeOrAbs);
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function hexOfBytes(bytes) {
  return Buffer.from(bytes).toString("hex");
}

export function canonicalJson(value) {
  return `${JSON.stringify(sortValue(value))}\n`;
}

function sortValue(value) {
  if (Array.isArray(value)) return value.map(sortValue);
  if (value && typeof value === "object") {
    const sorted = {};
    for (const key of Object.keys(value).sort()) sorted[key] = sortValue(value[key]);
    return sorted;
  }
  return value;
}

export function canonicalHashOf(value) {
  return sha256Hex(canonicalJson(value));
}

export function loadJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function commandCatalog(formsSpec) {
  const byName = new Map();
  const byValue = new Map();
  for (const [name, spec] of Object.entries(formsSpec.commands)) {
    const row = { name, ...spec };
    byName.set(name, row);
    byValue.set(spec.value, row);
  }
  if (byName.size !== COMMAND_COUNT) {
    throw new Error(`ir_command_forms.json must list ${COMMAND_COUNT} commands, got ${byName.size}`);
  }
  return { byName, byValue };
}

export function parseSnapshot(bytes) {
  if (bytes.subarray(0, 8).toString("binary") !== "LUAUCIR\0") throw new Error("bad snapshot magic");
  if (bytes.readUInt16LE(8) !== 1 || bytes.readUInt16LE(10) !== 224) {
    throw new Error("bad snapshot version/header");
  }
  const protoCount = bytes.readUInt32LE(188);
  const irFunctionCount = bytes.readUInt32LE(192);
  const sectionCount = bytes.readUInt32LE(204);
  const sections = new Map();
  for (let index = 0; index < sectionCount; index++) {
    const at = 224 + index * 32;
    const kind = bytes.readUInt16LE(at);
    sections.set(kind, {
      recordSize: bytes.readUInt32LE(at + 4),
      offset: Number(bytes.readBigUInt64LE(at + 8)),
      count: bytes.readUInt32LE(at + 24),
    });
  }
  return {
    bytes,
    protoCount,
    irFunctionCount,
    luauPin: bytes.subarray(24, 56),
    frontendContract: bytes.subarray(88, 120),
    irEnum: bytes.subarray(120, 152),
    sections,
  };
}

export function snapshotSection(parsed, kind) {
  const section = parsed.sections.get(kind);
  if (!section) throw new Error(`snapshot is missing section ${kind}`);
  return section;
}

export function walkSnapshot(parsed, visit) {
  const functions = snapshotSection(parsed, 15);
  const blocks = snapshotSection(parsed, 16);
  const instructions = snapshotSection(parsed, 17);
  const operands = snapshotSection(parsed, 18);
  const constants = snapshotSection(parsed, 19);
  const bytes = parsed.bytes;
  for (let functionId = 0; functionId < functions.count; functionId++) {
    const functionRecord = functions.offset + functionId * functions.recordSize;
    const blockStart = bytes.readUInt32LE(functionRecord + 16);
    const blockCount = bytes.readUInt32LE(functionRecord + 20);
    const instructionStart = bytes.readUInt32LE(functionRecord + 24);
    const instructionCount = bytes.readUInt32LE(functionRecord + 28);
    const constantStart = bytes.readUInt32LE(functionRecord + 40);
    for (let blockId = 0; blockId < blockCount; blockId++) {
      const blockOffset = blocks.offset + (blockStart + blockId) * blocks.recordSize;
      visit.block?.({ functionId, blockId, kind: bytes[blockOffset] });
    }
    for (let instructionId = 0; instructionId < instructionCount; instructionId++) {
      const instructionOffset = instructions.offset +
        (instructionStart + instructionId) * instructions.recordSize;
      const operandStart = bytes.readUInt32LE(instructionOffset + 8);
      const operandCount = bytes.readUInt32LE(instructionOffset + 12);
      const ops = [];
      for (let operandId = 0; operandId < operandCount; operandId++) {
        const operandOffset = operands.offset + (operandStart + operandId) * operands.recordSize;
        const kind = bytes[operandOffset];
        const value = bytes.readUInt32LE(operandOffset + 4);
        let constant = null;
        if (kind === 2) {
          const constantOffset = constants.offset + (constantStart + value) * constants.recordSize;
          constant = { kind: bytes[constantOffset], bits: bytes.readBigUInt64LE(constantOffset + 8) };
        }
        ops.push({ kind, value, constant });
        visit.operand?.({ functionId, instructionId, operandId, kind, value, constant });
      }
      visit.instruction?.({
        functionId,
        instructionId,
        command: bytes[instructionOffset],
        operands: ops,
      });
    }
  }
}

export function parseWasmFunctionImports(bytes) {
  if (bytes.length < 8 || bytes.readUInt32LE(0) !== 0x6d736100 || bytes.readUInt32LE(4) !== 1) {
    throw new Error("backend output is not a wasm v1 object");
  }
  let offset = 8;
  const names = [];
  while (offset < bytes.length) {
    const id = bytes[offset];
    offset += 1;
    const { value: size, next } = readUleb(bytes, offset);
    offset = next;
    const end = offset + size;
    if (id === 2) {
      const count = readUleb(bytes, offset);
      offset = count.next;
      for (let index = 0; index < count.value; index++) {
        const module = readName(bytes, offset);
        const field = readName(bytes, module.next);
        const kind = bytes[field.next];
        offset = field.next + 1;
        if (kind === 0) {
          const type = readUleb(bytes, offset);
          offset = type.next;
          names.push(field.text);
        } else if (kind === 1) {
          offset += 1;
          const limits = readLimits(bytes, offset);
          offset = limits.next;
        } else if (kind === 2) {
          const limits = readLimits(bytes, offset);
          offset = limits.next;
        } else if (kind === 3) {
          offset += 2;
        } else {
          throw new Error(`unsupported wasm import kind ${kind}`);
        }
      }
      break;
    }
    offset = end;
  }
  return names.filter((name) => name.startsWith("luauc_runtime_v1_"));
}

function readUleb(bytes, offset) {
  let value = 0;
  let shift = 0;
  let next = offset;
  while (next < bytes.length) {
    const byte = bytes[next];
    next += 1;
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value, next };
    shift += 7;
    if (shift > 35) throw new Error("uleb overflow");
  }
  throw new Error("truncated uleb");
}

function readName(bytes, offset) {
  const length = readUleb(bytes, offset);
  const start = length.next;
  const end = start + length.value;
  return { text: bytes.subarray(start, end).toString("utf8"), next: end };
}

function readLimits(bytes, offset) {
  const flags = bytes[offset];
  const min = readUleb(bytes, offset + 1);
  if (flags & 1) {
    const max = readUleb(bytes, min.next);
    return { next: max.next };
  }
  return { next: min.next };
}

export async function instantiateZeroImport(path, label) {
  const module = await WebAssembly.compile(readFileSync(path));
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 0) throw new Error(`${label} is not zero-import: ${JSON.stringify(imports)}`);
  return WebAssembly.instantiate(module, {});
}

export function compileFrontendSnapshot(api, sourceText, chunkText, coverageLevel = 0, inlinePlans = null) {
  const encoder = new TextEncoder();
  const source = encoder.encode(sourceText);
  const chunk = encoder.encode(chunkText);
  const sourcePointer = api.luauc_frontend_v1_alloc(source.length);
  const chunkPointer = api.luauc_frontend_v1_alloc(chunk.length);
  const resultPointer = api.luauc_frontend_v1_alloc(20);
  const planBytes = inlinePlans === null ? null : Buffer.alloc(inlinePlans.length * 16);
  if (planBytes) {
    for (let index = 0; index < inlinePlans.length; index++) {
      const plan = inlinePlans[index];
      planBytes.writeUInt32LE(plan.callerFunctionId, index * 16);
      planBytes.writeUInt32LE(plan.feedbackSlot, index * 16 + 4);
      planBytes.writeUInt32LE(plan.targetFunctionId, index * 16 + 8);
    }
  }
  const planPointer = planBytes?.length ? api.luauc_frontend_v1_alloc(planBytes.length) : 0;
  if (!sourcePointer || !chunkPointer || !resultPointer || (planBytes?.length && !planPointer)) {
    throw new Error("frontend allocation failed");
  }
  new Uint8Array(api.memory.buffer, sourcePointer, source.length).set(source);
  new Uint8Array(api.memory.buffer, chunkPointer, chunk.length).set(chunk);
  if (planBytes?.length) new Uint8Array(api.memory.buffer, planPointer, planBytes.length).set(planBytes);
  new Uint8Array(api.memory.buffer, resultPointer, 20).fill(0);
  const status = inlinePlans === null
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
  const resultStatus = result.getUint32(16, true);
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize) {
    api.luauc_frontend_snapshot_v1_free(resultPointer);
    api.luauc_frontend_v1_dealloc(resultPointer, 20);
    if (planPointer) api.luauc_frontend_v1_dealloc(planPointer, planBytes.length);
    api.luauc_frontend_v1_dealloc(chunkPointer, chunk.length);
    api.luauc_frontend_v1_dealloc(sourcePointer, source.length);
    throw new Error(`frontend failed with ${status}/${resultStatus}`);
  }
  const snapshot = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_frontend_snapshot_v1_free(resultPointer);
  api.luauc_frontend_v1_dealloc(resultPointer, 20);
  if (planPointer) api.luauc_frontend_v1_dealloc(planPointer, planBytes.length);
  api.luauc_frontend_v1_dealloc(chunkPointer, chunk.length);
  api.luauc_frontend_v1_dealloc(sourcePointer, source.length);
  return snapshot;
}

export function compileBackendPackage(api, snapshot) {
  const snapshotPointer = api.luauc_backend_v1_alloc(snapshot.length);
  const resultPointer = api.luauc_backend_v1_alloc(24);
  if (!snapshotPointer || !resultPointer) throw new Error("backend package allocation failed");
  new Uint8Array(api.memory.buffer, snapshotPointer, snapshot.length).set(snapshot);
  new Uint8Array(api.memory.buffer, resultPointer, 24).fill(0);
  const status = api.luauc_backend_v1_compile_package(snapshotPointer, snapshot.length, resultPointer);
  const result = new DataView(api.memory.buffer, resultPointer, 24);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const resultStatus = result.getUint32(8, true);
  const diagnosticPointer = result.getUint32(16, true);
  const diagnosticSize = result.getUint32(20, true);
  const diagnostic = diagnosticPointer && diagnosticSize
    ? new TextDecoder().decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
    : "";
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize) {
    api.luauc_backend_v1_free(resultPointer);
    api.luauc_backend_v1_dealloc(resultPointer, 24);
    api.luauc_backend_v1_dealloc(snapshotPointer, snapshot.length);
    throw new Error(`backend package failed with ${status}/${resultStatus}: ${diagnostic}`);
  }
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_backend_v1_free(resultPointer);
  api.luauc_backend_v1_dealloc(resultPointer, 24);
  api.luauc_backend_v1_dealloc(snapshotPointer, snapshot.length);
  return object;
}

export function censusFormsFor(commandName, instruction) {
  const forms = new Set(["any"]);
  if (commandName === "FORGLOOP") {
    const aux = instruction.operands[instruction.operands.length - 1];
    if (aux?.constant && aux.constant.kind === 0) {
      const value = Number(aux.constant.bits & 0xffffffffn);
      if (value >= 1 && value <= 255) forms.add("aux_1_255");
    }
    forms.add("iterator_generic_callable");
  }
  if (commandName === "FORGLOOP_FALLBACK") forms.add("generic_callable");
  if (commandName === "FALLBACK_GETTABLEKS" || commandName === "FALLBACK_SETTABLEKS") {
    forms.add("string_key");
  }
  if (commandName === "FALLBACK_GETGLOBAL" || commandName === "FALLBACK_SETGLOBAL") {
    forms.add("global_name");
  }
  if (commandName === "INVOKE_FASTCALL") forms.add("builtin");
  if (commandName === "NEW_USERDATA" || commandName === "CHECK_USERDATA_TAG") forms.add("hook_vec2");
  if (commandName === "BARRIER_OBJ") forms.add("hold_slot");
  if (commandName === "BARRIER_TABLE_BACK") forms.add("store_slot");
  return [...forms];
}

export function validateCoverageMap(map, options = {}) {
  const errors = [];
  if (map.schema_version !== 2) errors.push("schema_version must be 2");
  if (map.generator_version !== LEDGER_GENERATOR_VERSION) {
    errors.push(`generator_version must be ${LEDGER_GENERATOR_VERSION}`);
  }
  if (!Array.isArray(map.commands) || map.commands.length !== COMMAND_COUNT) {
    errors.push(`commands must have ${COMMAND_COUNT} rows`);
  }
  const totals = map.totals ?? {};
  const sum = (totals.implemented ?? 0) + (totals.partial ?? 0) +
    (totals.unimplemented ?? 0) + (totals.frontend_unreachable ?? 0);
  if (sum !== COMMAND_COUNT) {
    errors.push(`I+P+U+R must be ${COMMAND_COUNT}, got ${sum}`);
  }
  const withoutHash = { ...map };
  delete withoutHash.canonical_hash;
  if (map.canonical_hash !== canonicalHashOf(withoutHash)) {
    errors.push("canonical_hash does not match canonical JSON");
  }
  const allow = new Set(options.allowLabels ?? []);
  const existingGates = new Set(options.existingGates ?? QUALIFYING_GATES);
  for (const row of map.commands ?? []) {
    if (row.status === "implemented") {
      if (!row.tests?.length) errors.push(`${row.command}: implemented row has tests: []`);
      if (!row.census_sources?.length) errors.push(`${row.command}: implemented row has empty census`);
      if (!row.lowered_sources?.length) errors.push(`${row.command}: implemented row has empty lowered_sources`);
      if (!row.executed_gates?.length) errors.push(`${row.command}: implemented row has empty executed_gates`);
      if (!row.general_arm && row.class !== "compile_only") {
        errors.push(`${row.command}: implemented row lacks a general arm`);
      }
      for (const gate of row.executed_gates ?? []) {
        if (!existingGates.has(gate) && !EMBED_ORACLE_GATES.includes(gate)) {
          errors.push(`${row.command}: non-qualifying executed gate ${gate}`);
        }
      }
    }
    for (const label of row.tests ?? []) {
      if (allow.size && !allow.has(label)) errors.push(`${row.command}: unknown test label ${label}`);
    }
    if (row.command === "INT_TO_NUM") {
      for (const symbol of row.runtime_symbols ?? []) {
        if (USERDATA_HELPERS.includes(symbol) && !options.intToNumMayImportUserdata) {
          errors.push("INT_TO_NUM.runtime_symbols contains a userdata helper");
        }
      }
    }
    if (row.status === "implemented" && row.evidence?.kind === "hook_unit_mark" &&
        !options.hookUnitMarkSatisfied) {
      errors.push(`${row.command}: hook_unit_mark evidence lock is unsatisfied`);
    }
    if (row.status === "implemented" &&
        (row.evidence?.kind === "isolated_store_strip" || row.evidence?.kind === "isolated_hold_strip")) {
      if (!options.isolatedStripSatisfied) {
        errors.push(`${row.command}: isolated strip evidence lock is unsatisfied`);
      }
    }
  }
  return errors;
}

export function printRule13(totals) {
  return [
    `${totals.implemented} / ${totals.partial} / ${totals.unimplemented}`,
    `frontend_unreachable = ${totals.frontend_unreachable}`,
  ].join("\n");
}
