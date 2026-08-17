import { createHash } from "node:crypto";

export const WASM_MAGIC = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
export const RELOC = Object.freeze({
  function_index_leb: 0,
  table_index_i32: 2,
  memory_addr_sleb: 4,
  memory_addr_i32: 5,
});
export const RELOC_NAME = Object.freeze({
  0: "R_WASM_FUNCTION_INDEX_LEB",
  2: "R_WASM_TABLE_INDEX_I32",
  4: "R_WASM_MEMORY_ADDR_SLEB",
  5: "R_WASM_MEMORY_ADDR_I32",
});
export const CHECKED_RELOCS = Object.freeze([
  RELOC.function_index_leb,
  RELOC.memory_addr_sleb,
  RELOC.memory_addr_i32,
]);

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function canonicalJson(value) {
  return `${JSON.stringify(sortValue(value))}\n`;
}

export function canonicalHashOf(value) {
  return sha256Hex(canonicalJson(value));
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

export function readUleb(bytes, offset) {
  let value = 0;
  let shift = 0;
  let next = offset;
  for (let count = 0; count < 5; count++) {
    if (next >= bytes.length) throw new Error("truncated ULEB");
    const byte = bytes[next++];
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value: value >>> 0, next, width: next - offset };
    shift += 7;
  }
  throw new Error("overlong ULEB");
}

export function readSleb(bytes, offset) {
  let value = 0;
  let shift = 0;
  let next = offset;
  let byte = 0;
  for (let count = 0; count < 5; count++) {
    if (next >= bytes.length) throw new Error("truncated SLEB");
    byte = bytes[next++];
    value |= (byte & 0x7f) << shift;
    shift += 7;
    if ((byte & 0x80) === 0) {
      if (byte & 0x40 && shift < 32) value |= (~0 << shift);
      return { value: value | 0, next, width: next - offset };
    }
  }
  throw new Error("overlong SLEB");
}

export function readName(bytes, offset) {
  const length = readUleb(bytes, offset);
  const start = length.next;
  const end = start + length.value;
  if (end > bytes.length) throw new Error("truncated name");
  return { text: bytes.subarray(start, end).toString("utf8"), next: end };
}

export function readPaddedUleb32(bytes, offset) {
  if (offset + 5 > bytes.length) throw new Error("truncated padded ULEB");
  let value = 0;
  for (let index = 0; index < 5; index++) {
    const byte = bytes[offset + index];
    if (index < 4 && (byte & 0x80) === 0) throw new Error("expected 5-byte padded ULEB");
    value |= (byte & 0x7f) << (7 * index);
  }
  return value >>> 0;
}

export function readPaddedSleb32(bytes, offset) {
  if (offset + 5 > bytes.length) throw new Error("truncated padded SLEB");
  let bits = 0;
  for (let index = 0; index < 4; index++) {
    const byte = bytes[offset + index];
    if ((byte & 0x80) === 0) throw new Error("expected 5-byte padded SLEB");
    bits |= (byte & 0x7f) << (7 * index);
  }
  bits |= (bytes[offset + 4] & 0x0f) << 28;
  return bits << 0;
}

export function readI32le(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
}

export function parseSections(bytes) {
  if (bytes.length < 8 || !bytes.subarray(0, 8).equals(WASM_MAGIC)) {
    throw new Error("not a Wasm v1 module");
  }
  const sections = [];
  const byId = new Map();
  const custom = new Map();
  let offset = 8;
  let ordinal = 0;
  while (offset < bytes.length) {
    const id = bytes[offset++];
    const size = readUleb(bytes, offset);
    const start = size.next;
    const end = start + size.value;
    if (end > bytes.length) throw new Error(`truncated section ${id}`);
    const payload = bytes.subarray(start, end);
    const entry = { id, ordinal, start, end, payload };
    if (id === 0) {
      const name = readName(payload, 0);
      entry.name = name.text;
      entry.customPayload = payload.subarray(name.next);
      custom.set(name.text, entry);
    } else {
      if (byId.has(id)) throw new Error(`duplicate section ${id}`);
      byId.set(id, entry);
    }
    sections.push(entry);
    offset = end;
    ordinal += 1;
  }
  return { sections, byId, custom };
}

function skipLimits(bytes, offset) {
  const flags = readUleb(bytes, offset);
  const min = readUleb(bytes, flags.next);
  if (flags.value & 1) {
    const max = readUleb(bytes, min.next);
    return {
      flags: flags.value,
      minimum: min.value,
      maximum: max.value,
      shared: (flags.value & 2) !== 0,
      memory64: (flags.value & 4) !== 0,
      next: max.next,
    };
  }
  return {
    flags: flags.value,
    minimum: min.value,
    maximum: min.value,
    shared: (flags.value & 2) !== 0,
    memory64: (flags.value & 4) !== 0,
    next: min.next,
  };
}

function parseTypes(payload) {
  const types = [];
  let offset = 0;
  const count = readUleb(payload, 0);
  offset = count.next;
  for (let index = 0; index < count.value; index++) {
    const start = offset;
    if (payload[offset++] !== 0x60) throw new Error("non-function type");
    const params = readUleb(payload, offset);
    offset = params.next + params.value;
    const results = readUleb(payload, offset);
    offset = results.next + results.value;
    types.push({
      encoding: payload.subarray(start, offset),
      paramCount: params.value,
      resultCount: results.value,
    });
  }
  return types;
}

function parseImports(payload) {
  const items = [];
  let offset = 0;
  const count = readUleb(payload, 0);
  offset = count.next;
  let functions = 0;
  let tables = 0;
  let memories = 0;
  let globals = 0;
  for (let index = 0; index < count.value; index++) {
    const module = readName(payload, offset);
    const name = readName(payload, module.next);
    const kind = payload[name.next];
    offset = name.next + 1;
    const item = { module: module.text, name: name.text, kind };
    if (kind === 0) {
      const type = readUleb(payload, offset);
      item.typeIndex = type.value;
      offset = type.next;
      functions += 1;
    } else if (kind === 1) {
      offset += 1;
      const limits = skipLimits(payload, offset);
      item.limits = limits;
      offset = limits.next;
      tables += 1;
    } else if (kind === 2) {
      const limits = skipLimits(payload, offset);
      item.limits = limits;
      offset = limits.next;
      memories += 1;
    } else if (kind === 3) {
      item.valueType = payload[offset];
      item.mutable = payload[offset + 1] === 1;
      offset += 2;
      globals += 1;
    } else {
      throw new Error(`unsupported import kind ${kind}`);
    }
    items.push(item);
  }
  return { items, functions, tables, memories, globals };
}

function parseIndexVector(payload) {
  const count = readUleb(payload, 0);
  const values = [];
  let offset = count.next;
  for (let index = 0; index < count.value; index++) {
    const item = readUleb(payload, offset);
    values.push(item.value);
    offset = item.next;
  }
  return values;
}

function parseExports(payload) {
  const items = [];
  let offset = 0;
  const count = readUleb(payload, 0);
  offset = count.next;
  for (let index = 0; index < count.value; index++) {
    const name = readName(payload, offset);
    const kind = payload[name.next];
    const idx = readUleb(payload, name.next + 1);
    items.push({ name: name.text, kind, index: idx.value });
    offset = idx.next;
  }
  return items;
}

function parseMemory(payload) {
  const count = readUleb(payload, 0);
  if (count.value === 0) return null;
  return skipLimits(payload, count.next);
}

function parseTable(payload) {
  const count = readUleb(payload, 0);
  if (count.value === 0) return null;
  const reftype = payload[count.next];
  const limits = skipLimits(payload, count.next + 1);
  return { reftype, ...limits };
}

function parseGlobals(payload) {
  if (!payload) return [];
  const items = [];
  const count = readUleb(payload, 0);
  let offset = count.next;
  for (let index = 0; index < count.value; index++) {
    const valueType = payload[offset++];
    const mutable = payload[offset++] === 1;
    const opcode = payload[offset++];
    let i32Value = null;
    if (opcode === 0x41) {
      const imm = readSleb(payload, offset);
      i32Value = imm.value;
      offset = imm.next;
    } else {
      throw new Error("unsupported global initializer");
    }
    if (payload[offset++] !== 0x0b) throw new Error("global initializer missing end");
    items.push({ valueType, mutable, i32Value });
  }
  return items;
}

function parseBodies(payload) {
  if (!payload) return [];
  const count = readUleb(payload, 0);
  const bodies = [];
  let offset = count.next;
  for (let index = 0; index < count.value; index++) {
    const size = readUleb(payload, offset);
    const start = size.next;
    const end = start + size.value;
    bodies.push({ payloadOffset: start, bytes: Buffer.from(payload.subarray(start, end)) });
    offset = end;
  }
  return bodies;
}

function parseData(payload) {
  if (!payload) return [];
  const count = readUleb(payload, 0);
  const segments = [];
  let offset = count.next;
  for (let index = 0; index < count.value; index++) {
    const flags = readUleb(payload, offset);
    offset = flags.next;
    if (flags.value === 2) {
      const memory = readUleb(payload, offset);
      offset = memory.next;
    } else if (flags.value !== 0) {
      throw new Error(`unsupported data flags ${flags.value}`);
    }
    if (payload[offset++] !== 0x41) throw new Error("data offset is not i32.const");
    const addr = readSleb(payload, offset);
    offset = addr.next;
    if (payload[offset++] !== 0x0b) throw new Error("data offset missing end");
    const size = readUleb(payload, offset);
    const start = size.next;
    const end = start + size.value;
    segments.push({
      memoryOffset: addr.value,
      payloadOffset: start,
      bytes: Buffer.from(payload.subarray(start, end)),
    });
    offset = end;
  }
  return segments;
}

export function parseCoreModule(bytes) {
  const sections = parseSections(bytes);
  const types = sections.byId.has(1) ? parseTypes(sections.byId.get(1).payload) : [];
  const imports = sections.byId.has(2)
    ? parseImports(sections.byId.get(2).payload)
    : { items: [], functions: 0, tables: 0, memories: 0, globals: 0 };
  const functionTypes = sections.byId.has(3) ? parseIndexVector(sections.byId.get(3).payload) : [];
  const table = sections.byId.has(4) ? parseTable(sections.byId.get(4).payload) : null;
  const memory = sections.byId.has(5) ? parseMemory(sections.byId.get(5).payload) : null;
  const importedMemory = imports.items.find((item) => item.kind === 2);
  const globals = parseGlobals(sections.byId.get(6)?.payload);
  const exports = sections.byId.has(7) ? parseExports(sections.byId.get(7).payload) : [];
  const bodies = parseBodies(sections.byId.get(10)?.payload);
  const data = parseData(sections.byId.get(11)?.payload);
  return {
    sections,
    types,
    imports,
    functionTypes,
    table,
    memory,
    importedMemory,
    globals,
    exports,
    bodies,
    data,
    functionCount: imports.functions + functionTypes.length,
    definedFunctionCount: functionTypes.length,
    memoryMin: memory?.minimum ?? importedMemory?.limits?.minimum ?? 0,
    exportNames: exports.map((item) => item.name).sort(),
  };
}

function parseRelocations(payload) {
  const section = readUleb(payload, 0);
  const count = readUleb(payload, section.next);
  const items = [];
  let offset = count.next;
  for (let index = 0; index < count.value; index++) {
    const kind = payload[offset++];
    const at = readUleb(payload, offset);
    const symbol = readUleb(payload, at.next);
    offset = symbol.next;
    let addend = 0;
    if (kind === RELOC.memory_addr_sleb || kind === RELOC.memory_addr_i32) {
      const imm = readSleb(payload, offset);
      addend = imm.value;
      offset = imm.next;
    }
    items.push({
      kind,
      name: RELOC_NAME[kind] ?? `R_WASM_${kind}`,
      offset: at.value,
      symbolIndex: symbol.value,
      addend,
    });
  }
  return { sectionIndex: section.value, items };
}

function parseLinking(payload, imports) {
  const version = readUleb(payload, 0);
  if (version.value !== 2) throw new Error(`unsupported linking version ${version.value}`);
  const functionImports = imports.items.filter((item) => item.kind === 0);
  const symbols = [];
  const segments = [];
  let offset = version.next;
  while (offset < payload.length) {
    const id = payload[offset++];
    const size = readUleb(payload, offset);
    const finish = size.next + size.value;
    let cursor = size.next;
    if (id === 8) {
      const count = readUleb(payload, cursor);
      cursor = count.next;
      for (let index = 0; index < count.value; index++) {
        const kind = payload[cursor++];
        const flags = readUleb(payload, cursor);
        cursor = flags.next;
        if (kind === 0) {
          const fnIndex = readUleb(payload, cursor);
          cursor = fnIndex.next;
          const undefined_ = (flags.value & 0x10) !== 0;
          let name;
          if (undefined_) {
            name = functionImports[fnIndex.value]?.name;
            if (!name) throw new Error(`undefined function symbol ${fnIndex.value} has no function import`);
          } else {
            const named = readName(payload, cursor);
            name = named.text;
            cursor = named.next;
          }
          symbols.push({
            kind: "function",
            flags: flags.value,
            objectIndex: fnIndex.value,
            name,
            undefined: undefined_,
          });
        } else if (kind === 1) {
          const named = readName(payload, cursor);
          const segment = readUleb(payload, named.next);
          const dataOffset = readUleb(payload, segment.next);
          const dataSize = readUleb(payload, dataOffset.next);
          cursor = dataSize.next;
          symbols.push({
            kind: "data",
            flags: flags.value,
            name: named.text,
            segmentIndex: segment.value,
            offset: dataOffset.value,
            size: dataSize.value,
          });
        } else {
          throw new Error(`unsupported linking symbol kind ${kind}`);
        }
      }
    } else if (id === 5) {
      const count = readUleb(payload, cursor);
      cursor = count.next;
      for (let index = 0; index < count.value; index++) {
        const named = readName(payload, cursor);
        const align = readUleb(payload, named.next);
        const flags = readUleb(payload, align.next);
        cursor = flags.next;
        segments.push({ name: named.text, alignmentLog2: align.value, flags: flags.value });
      }
    }
    offset = finish;
  }
  return { symbols, segments };
}

export function parseObject(bytes) {
  const module = parseCoreModule(bytes);
  const linkingSection = module.sections.custom.get("linking");
  if (!linkingSection) throw new Error("object is missing linking section");
  const linking = parseLinking(linkingSection.customPayload, module.imports);
  const codeRelocs = module.sections.custom.get("reloc.CODE")
    ? parseRelocations(module.sections.custom.get("reloc.CODE").customPayload).items
    : [];
  const dataRelocs = module.sections.custom.get("reloc.DATA")
    ? parseRelocations(module.sections.custom.get("reloc.DATA").customPayload).items
    : [];
  return { ...module, linking, codeRelocs, dataRelocs, bytes };
}

export function relocTypesOf(object) {
  return [...new Set([...object.codeRelocs, ...object.dataRelocs].map((item) => item.name))].sort();
}

export function symbolNamesOf(object) {
  return [...new Set(object.linking.symbols.map((item) => item.name))].sort();
}

function locateBody(bodies, offset, width) {
  const finish = offset + width;
  for (const body of bodies) {
    const bodyFinish = body.payloadOffset + body.bytes.length;
    if (offset >= body.payloadOffset && finish <= bodyFinish) {
      return { body, local: offset - body.payloadOffset };
    }
  }
  return null;
}

function locateData(data, offset, width) {
  const finish = offset + width;
  for (const segment of data) {
    const end = segment.payloadOffset + segment.bytes.length;
    if (offset >= segment.payloadOffset && finish <= end) {
      return { segment, local: offset - segment.payloadOffset };
    }
  }
  return null;
}

export function objectLocalResolution(object) {
  const functionValues = [];
  for (let index = 0; index < object.imports.functions + object.definedFunctionCount; index++) {
    functionValues.push(index);
  }
  const dataAddresses = object.data.map((segment) => segment.memoryOffset >>> 0);
  return { functionValues, dataAddresses, arenaBase: 0 };
}

export function wasmLdNameResolution(object, linked) {
  const functionByName = new Map();
  const importFunctions = linked.imports.items.filter((item) => item.kind === 0);
  for (let index = 0; index < importFunctions.length; index++) {
    functionByName.set(importFunctions[index].name, index);
  }
  for (const item of linked.exports) {
    if (item.kind === 0) functionByName.set(item.name, item.index);
  }
  const relocatedFunctionIndexes = new Set(
    object.codeRelocs
      .filter((item) => item.kind === RELOC.function_index_leb)
      .map((item) => object.linking.symbols[item.symbolIndex].objectIndex),
  );
  const byObjectIndex = [];
  for (const symbol of object.linking.symbols) {
    if (symbol.kind !== "function") continue;
    if (relocatedFunctionIndexes.has(symbol.objectIndex) && !functionByName.has(symbol.name)) {
      throw new Error(`wasm-ld dropped relocated function symbol ${symbol.name}`);
    }
    byObjectIndex[symbol.objectIndex] = functionByName.get(symbol.name) ?? 0xffffffff;
  }
  const dataAddresses = linked.data.length
    ? object.data.map((segment, index) => (linked.data[index]?.memoryOffset ?? segment.memoryOffset) >>> 0)
    : object.data.map((segment) => segment.memoryOffset >>> 0);
  return { functionValues: byObjectIndex, dataAddresses, arenaBase: 0 };
}

export function productionResolution(object, pack, profile) {
  const packModule = parseCoreModule(pack);
  const exportByName = new Map(packModule.exports.map((item) => [item.name, item]));
  const arenaName = profile.bindings.find((item) => item.role === "generated_data_arena")?.name;
  const arenaExport = exportByName.get(arenaName);
  if (!arenaExport || arenaExport.kind !== 3) throw new Error("pack is missing generated data arena");
  const arenaBase = packModule.globals[arenaExport.index].i32Value >>> 0;
  const functionValues = [];
  for (const item of object.imports.items.filter((entry) => entry.kind === 0)) {
    const found = exportByName.get(item.name);
    if (!found || found.kind !== 0) throw new Error(`pack is missing generated import ${item.name}`);
    functionValues.push(found.index);
  }
  const packFunctionCount = packModule.imports.functions + packModule.definedFunctionCount;
  for (let index = 0; index < object.definedFunctionCount; index++) {
    functionValues.push(packFunctionCount + index);
  }
  const dataAddresses = object.data.map((segment) => (arenaBase + segment.memoryOffset) >>> 0);
  return {
    functionValues,
    dataAddresses,
    arenaBase,
    packFunctionCount,
    packDefinedCount: packModule.definedFunctionCount,
    packExportNames: packModule.exports.map((item) => item.name).sort(),
    packMemoryMin: packModule.memoryMin,
    packFunctionTotal: packFunctionCount,
  };
}

function symbolFunction(object, resolution, symbolIndex) {
  const symbol = object.linking.symbols[symbolIndex];
  if (!symbol || symbol.kind !== "function") throw new Error(`symbol ${symbolIndex} is not a function`);
  return resolution.functionValues[symbol.objectIndex];
}

function symbolMemory(object, resolution, symbolIndex, addend) {
  const symbol = object.linking.symbols[symbolIndex];
  if (!symbol || symbol.kind !== "data") throw new Error(`symbol ${symbolIndex} is not data`);
  return (resolution.dataAddresses[symbol.segmentIndex] + symbol.offset + addend) >>> 0;
}

export function expectedRelocApplications(object, resolution) {
  const applications = [];
  for (const item of object.codeRelocs) {
    if (!CHECKED_RELOCS.includes(item.kind)) continue;
    const located = locateBody(object.bodies, item.offset, 5);
    if (!located) throw new Error(`code reloc at ${item.offset} is outside a body`);
    const value = item.kind === RELOC.function_index_leb
      ? symbolFunction(object, resolution, item.symbolIndex)
      : symbolMemory(object, resolution, item.symbolIndex, item.addend);
    applications.push({
      section: "code",
      kind: item.name,
      offset: item.offset,
      symbol: object.linking.symbols[item.symbolIndex].name,
      addend: item.addend,
      bodyIndex: object.bodies.indexOf(located.body),
      localOffset: located.local,
      value: value >>> 0,
    });
  }
  for (const item of object.dataRelocs) {
    if (item.kind !== RELOC.memory_addr_i32) continue;
    const located = locateData(object.data, item.offset, 4);
    if (!located) throw new Error(`data reloc at ${item.offset} is outside a segment`);
    applications.push({
      section: "data",
      kind: item.name,
      offset: item.offset,
      symbol: object.linking.symbols[item.symbolIndex].name,
      addend: item.addend,
      segmentIndex: object.data.indexOf(located.segment),
      localOffset: located.local,
      value: symbolMemory(object, resolution, item.symbolIndex, item.addend) >>> 0,
    });
  }
  return applications;
}

export function readAppliedRelocsFromBodies(object, bodies, applications) {
  return applications.filter((item) => item.section === "code").map((item) => {
    const body = bodies[item.bodyIndex];
    if (!body) throw new Error(`missing body ${item.bodyIndex}`);
    const value = item.kind === "R_WASM_FUNCTION_INDEX_LEB"
      ? readPaddedUleb32(body.bytes, item.localOffset)
      : readPaddedSleb32(body.bytes, item.localOffset) >>> 0;
    return { ...item, applied: value };
  });
}

export function scanCallImmediates(bodyBytes) {
  const values = [];
  let offset = 0;
  const localGroups = readUleb(bodyBytes, 0);
  offset = localGroups.next;
  for (let index = 0; index < localGroups.value; index++) {
    const count = readUleb(bodyBytes, offset);
    offset = count.next + 1;
  }
  while (offset < bodyBytes.length) {
    const opcode = bodyBytes[offset++];
    if (opcode === 0x10) {
      const imm = readUleb(bodyBytes, offset);
      values.push(imm.value);
      offset = imm.next;
    } else if (opcode === 0x11) {
      const type = readUleb(bodyBytes, offset);
      const table = readUleb(bodyBytes, type.next);
      offset = table.next;
    } else if (opcode === 0x41) {
      offset = readSleb(bodyBytes, offset).next;
    } else if (opcode === 0x42) {
      offset = readSleb(bodyBytes, offset).next;
    } else if (opcode === 0x43) {
      offset += 4;
    } else if (opcode === 0x44) {
      offset += 8;
    } else if (opcode === 0x0c || opcode === 0x0d || opcode === 0x20 || opcode === 0x21 || opcode === 0x22) {
      offset = readUleb(bodyBytes, offset).next;
    } else if (opcode === 0x28 || opcode === 0x29 || opcode === 0x2a || opcode === 0x2b ||
               opcode === 0x2c || opcode === 0x2d || opcode === 0x2e || opcode === 0x2f ||
               opcode === 0x36 || opcode === 0x37 || opcode === 0x38 || opcode === 0x39) {
      offset = readUleb(bodyBytes, readUleb(bodyBytes, offset).next).next;
    }
  }
  return values;
}

function walkBodyFeatures(bytes, present) {
  let offset = 0;
  if (offset >= bytes.length) return true;
  const groups = readUleb(bytes, offset);
  offset = groups.next;
  for (let index = 0; index < groups.value; index++) {
    const count = readUleb(bytes, offset);
    offset = count.next + 1;
  }
  const skipUleb = () => {
    const item = readUleb(bytes, offset);
    offset = item.next;
    return item.value;
  };
  const skipSleb = () => {
    offset = readSleb(bytes, offset).next;
  };
  const speculative = new Set();
  while (offset < bytes.length) {
    const opcode = bytes[offset++];
    if (opcode === 0x02 || opcode === 0x03 || opcode === 0x04) {
      if (bytes[offset] === 0x40 || (bytes[offset] >= 0x6f && bytes[offset] <= 0x7f)) offset += 1;
      else skipSleb();
      continue;
    }
    if (opcode === 0x0c || opcode === 0x0d || opcode === 0x10 || opcode === 0x20 || opcode === 0x21 ||
        opcode === 0x22 || opcode === 0x23 || opcode === 0x24 || opcode === 0x25 || opcode === 0x26) {
      skipUleb();
      continue;
    }
    if (opcode === 0x0e) {
      const count = skipUleb();
      for (let index = 0; index < count; index++) skipUleb();
      skipUleb();
      continue;
    }
    if (opcode === 0x11) {
      skipUleb();
      skipUleb();
      present.add("reference-types");
      continue;
    }
    if (opcode === 0x12 || opcode === 0x13) {
      skipUleb();
      speculative.add("tail-call");
      continue;
    }
    if (opcode === 0x1c) {
      const count = skipUleb();
      offset += count;
      continue;
    }
    if ((opcode >= 0x28 && opcode <= 0x3e)) {
      skipUleb();
      skipUleb();
      continue;
    }
    if (opcode === 0x3f || opcode === 0x40) {
      skipUleb();
      continue;
    }
    if (opcode === 0x41 || opcode === 0x42) {
      skipSleb();
      continue;
    }
    if (opcode === 0x43) {
      offset += 4;
      continue;
    }
    if (opcode === 0x44) {
      offset += 8;
      continue;
    }
    if (opcode >= 0xc0 && opcode <= 0xc4) {
      present.add("sign-ext");
      continue;
    }
    if (opcode === 0xd0) {
      offset += 1;
      present.add("reference-types");
      continue;
    }
    if (opcode === 0xd1) {
      present.add("reference-types");
      continue;
    }
    if (opcode === 0xd2) {
      skipUleb();
      present.add("reference-types");
      continue;
    }
    if (opcode === 0xfc) {
      const op = skipUleb();
      if (op <= 7) present.add("nontrapping-fptoint");
      else if (op >= 8 && op <= 11) {
        present.add("bulk-memory");
        if (op <= 10) {
          skipUleb();
          skipUleb();
        } else {
          skipUleb();
        }
      } else if (op === 12 || op === 13 || op === 14) {
        present.add("bulk-memory");
        skipUleb();
        skipUleb();
      } else if (op === 15 || op === 16 || op === 17) {
        present.add("reference-types");
        if (op === 16) skipUleb();
      }
      continue;
    }
    if (opcode === 0xfd) {
      speculative.add("simd");
      skipUleb();
      continue;
    }
    if (opcode === 0xfe) {
      speculative.add("threads");
      skipUleb();
      continue;
    }
    if (opcode === 0xfb) {
      speculative.add("gc");
      skipUleb();
      continue;
    }
  }
  if (offset !== bytes.length) return false;
  for (const name of speculative) present.add(name);
  return true;
}

export function scanFeatures(bytes, label) {
  const module = parseCoreModule(bytes);
  const present = new Set(["mvp"]);
  if (module.types.some((type) => type.resultCount > 1)) present.add("multi-value");
  if (module.globals.some((item) => item.mutable) || module.imports.items.some((item) => item.kind === 3 && item.mutable)) {
    present.add("mutable-globals");
  }
  if (module.table?.reftype === 0x6f) present.add("reference-types");
  if (module.memory?.shared || module.importedMemory?.limits?.shared) present.add("threads");
  if (module.memory?.memory64 || module.importedMemory?.limits?.memory64) present.add("memory64");

  for (const body of module.bodies) {
    try {
      walkBodyFeatures(body.bytes, present);
    } catch {
      // A malformed body is not a feature claim.
    }
  }

  const forbidden = ["threads", "memory64", "gc"];
  return {
    label,
    sha256: sha256Hex(bytes),
    export_names: module.exportNames,
    import_names: module.imports.items.map((item) => `${item.module}.${item.name}`).sort(),
    function_count: module.functionCount,
    memory_min: module.memoryMin,
    features: [...present].sort(),
    forbidden_present: forbidden.filter((name) => present.has(name)),
  };
}

const PROFILE_ROLES = Object.freeze({
  1: "program_pointer",
  2: "generated_data_arena",
  3: "generated_data_capacity",
  4: "memory",
  5: "stack_pointer",
  6: "protected_dispatch",
  7: "alloc",
  8: "dealloc",
  9: "context_create",
  10: "context_destroy",
  11: "invoke",
  12: "initialize",
  13: "coverage",
});
const PROFILE_KINDS = Object.freeze({ 0: "function", 1: "table", 2: "memory", 3: "global" });

export function parseRuntimeProfile(bytes) {
  if (bytes.length < 320) throw new Error("truncated runtime profile");
  if (bytes.subarray(0, 8).toString("binary") !== "LUACRP1\0") throw new Error("bad profile magic");
  if (bytes.readUInt16LE(8) !== 1 || bytes.readUInt16LE(10) !== 320) throw new Error("bad profile header");
  if (bytes.readUInt32LE(12) !== bytes.length) throw new Error("profile size mismatch");
  const stringOffset = bytes.readUInt32LE(36);
  const stringSize = bytes.readUInt32LE(40);
  const stringAt = (offset, size) => bytes.subarray(stringOffset + offset, stringOffset + offset + size).toString("utf8");
  const importCount = bytes.readUInt32LE(48);
  const exportCount = bytes.readUInt32LE(56);
  const runtimeCount = bytes.readUInt32LE(64);
  const bindingCount = bytes.readUInt32LE(72);
  const importOffset = bytes.readUInt32LE(44);
  const exportOffset = bytes.readUInt32LE(52);
  const runtimeOffset = bytes.readUInt32LE(60);
  const bindingOffset = bytes.readUInt32LE(68);
  const hostImports = [];
  for (let index = 0; index < importCount; index++) {
    const at = importOffset + index * 24;
    hostImports.push({
      module: stringAt(bytes.readUInt32LE(at), bytes.readUInt32LE(at + 4)),
      name: stringAt(bytes.readUInt32LE(at + 8), bytes.readUInt32LE(at + 12)),
      type_index: bytes.readUInt32LE(at + 16),
      kind: PROFILE_KINDS[bytes[at + 20]],
    });
  }
  const retainedExports = [];
  for (let index = 0; index < exportCount; index++) {
    const at = exportOffset + index * 16;
    retainedExports.push({
      name: stringAt(bytes.readUInt32LE(at), bytes.readUInt32LE(at + 4)),
      kind: PROFILE_KINDS[bytes[at + 8]],
      role: bytes[at + 9] ? PROFILE_ROLES[bytes[at + 9]] : null,
    });
  }
  const runtimeSymbols = [];
  for (let index = 0; index < runtimeCount; index++) {
    const at = runtimeOffset + index * 24;
    runtimeSymbols.push({
      name: stringAt(bytes.readUInt32LE(at), bytes.readUInt32LE(at + 4)),
      type_index: bytes.readUInt32LE(at + 8),
      kind: PROFILE_KINDS[bytes[at + 12]],
    });
  }
  const bindings = [];
  for (let index = 0; index < bindingCount; index++) {
    const at = bindingOffset + index * 16;
    bindings.push({
      name: stringAt(bytes.readUInt32LE(at), bytes.readUInt32LE(at + 4)),
      role: PROFILE_ROLES[bytes.readUInt16LE(at + 8)],
      kind: PROFILE_KINDS[bytes[at + 10]],
    });
  }
  return {
    feature_mask: bytes.readUInt32LE(16),
    memory_minimum: bytes.readUInt32LE(20),
    memory_maximum: bytes.readUInt32LE(24),
    table_minimum: bytes.readUInt32LE(28),
    table_maximum: bytes.readUInt32LE(32),
    profile_id: stringAt(bytes.readUInt32LE(104), bytes.readUInt32LE(108)),
    luau_pin_sha256: bytes.subarray(128, 160).toString("hex"),
    runtime_abi_sha256: bytes.subarray(160, 192).toString("hex"),
    object_contract_sha256: bytes.subarray(192, 224).toString("hex"),
    pack_build_sha256: bytes.subarray(224, 256).toString("hex"),
    license_inventory_sha256: bytes.subarray(256, 288).toString("hex"),
    host_imports: hostImports,
    retained_exports: retainedExports,
    runtime_symbols: runtimeSymbols,
    bindings,
    bytes,
  };
}

export const PIN = "luau-0.725+luauc-patches";
export const LUAU_PIN_DIGEST = "e51ead5f541633693d548057e0431927f3036c13b185fdb37fbc3f5a261e6676";
export const FRONTEND_CONTRACT_DIGEST = "65331dc7d2821c6ec8df07225183590a5dae4a0be2ddd97b1cecf6c6391d698b";

export function finishDocument(document) {
  const withoutHash = { ...document };
  delete withoutHash.canonical_hash;
  document.canonical_hash = canonicalHashOf(withoutHash);
  return document;
}
