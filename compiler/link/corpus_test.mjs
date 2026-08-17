import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

function toolModule(relative) {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const candidates = [join(root, relative), join(root, "_main", relative)];
  for (const path of candidates) {
    try {
      readFileSync(path);
      return pathToFileURL(path).href;
    } catch {
      // try next
    }
  }
  throw new Error(`missing tool module ${relative}`);
}

const wasmBytes = await import(toolModule("tools/wasm_bytes.mjs"));
const { generateLinkConformance } = await import(toolModule("tools/generate_link_conformance.mjs"));
const {
  compileFrontendSnapshot,
  instantiateZeroImport,
} = await import(toolModule("tools/ir_ledger.mjs"));

function staticPackageFrame(moduleName, snapshot) {
  const name = Buffer.from(moduleName);
  const sourceName = Buffer.from(`@${moduleName}.luau`);
  const headerSize = 24;
  const recordSize = 24;
  const frame = Buffer.alloc(headerSize + recordSize + name.length + sourceName.length + snapshot.length);
  Buffer.from("LUAUCP1\0", "binary").copy(frame, 0);
  frame.writeUInt16LE(1, 8);
  frame.writeUInt16LE(headerSize, 10);
  frame.writeUInt32LE(1, 12);
  frame.writeUInt32LE(0, 16);
  frame.writeUInt32LE(recordSize, 20);
  let cursor = headerSize + recordSize;
  frame.writeUInt32LE(cursor, headerSize);
  frame.writeUInt32LE(name.length, headerSize + 4);
  name.copy(frame, cursor);
  cursor += name.length;
  frame.writeUInt32LE(cursor, headerSize + 16);
  frame.writeUInt32LE(sourceName.length, headerSize + 20);
  sourceName.copy(frame, cursor);
  cursor += sourceName.length;
  frame.writeUInt32LE(cursor, headerSize + 8);
  frame.writeUInt32LE(snapshot.length, headerSize + 12);
  snapshot.copy(frame, cursor);
  return frame;
}

function compileStaticPackage(api, frame) {
  const framePointer = api.luauc_backend_v1_alloc(frame.length);
  const resultPointer = api.luauc_backend_v1_alloc(24);
  if (!framePointer || !resultPointer) throw new Error("backend static-package allocation failed");
  new Uint8Array(api.memory.buffer, framePointer, frame.length).set(frame);
  new Uint8Array(api.memory.buffer, resultPointer, 24).fill(0);
  const status = api.luauc_backend_v1_compile_static_package(framePointer, frame.length, resultPointer);
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
    throw new Error(`backend static package failed with ${status}/${resultStatus}: ${diagnostic}`);
  }
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_backend_v1_free(resultPointer);
  api.luauc_backend_v1_dealloc(resultPointer, 24);
  api.luauc_backend_v1_dealloc(framePointer, frame.length);
  return object;
}
const {
  canonicalHashOf,
  expectedRelocApplications,
  parseCoreModule,
  parseObject,
  parseRuntimeProfile,
  productionResolution,
  readAppliedRelocsFromBodies,
  relocTypesOf,
  sha256Hex,
  symbolNamesOf,
  wasmLdNameResolution,
} = wasmBytes;

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

const wasmLd = runfile(process.env.LUAUC_WASM_LD, "LUAUC_WASM_LD");
const linkerCli = runfile(process.env.LUAUC_LINKER_CLI, "LUAUC_LINKER_CLI");
const profileBytes = readFileSync(runfile(process.env.LUAUC_EMBED_PROFILE, "LUAUC_EMBED_PROFILE"));
const packBytes = readFileSync(runfile(process.env.LUAUC_EMBED_PACK, "LUAUC_EMBED_PACK"));
const profile = parseRuntimeProfile(profileBytes);
const checked = JSON.parse(readFileSync(runfile(process.env.LUAUC_LINK_CONFORMANCE, "LUAUC_LINK_CONFORMANCE"), "utf8"));

const frontend = await instantiateZeroImport(
  runfile(process.env.LUAUC_FRONTEND_WASM, "LUAUC_FRONTEND_WASM"),
  "frontend",
);
const backend = await instantiateZeroImport(
  runfile(process.env.LUAUC_BACKEND_WASM, "LUAUC_BACKEND_WASM"),
  "backend",
);

const LUAU_CORPUS = [
  ["embed_lib", "LUAUC_EMBED_LIB_SOURCE"],
  ["compiled_call", "LUAUC_COMPILED_CALL_SOURCE"],
  ["recursive_call", "LUAUC_RECURSIVE_CALL_SOURCE"],
  ["table_clone_append", "LUAUC_TABLE_CLONE_APPEND_SOURCE"],
  ["generic_iteration", "LUAUC_GENERIC_ITERATION_SOURCE"],
];

function definedFunctionNames(object) {
  return object.linking.symbols
    .filter((item) => item.kind === "function" && !item.undefined)
    .map((item) => item.name);
}

function wasmLdLink(objectBytes, exports, name) {
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), `luauc-corpus-${name}-`));
  const objectPath = join(directory, `${name}.o`);
  const wasmPath = join(directory, `${name}.wasm`);
  writeFileSync(objectPath, objectBytes);
  const linked = spawnSync(
    wasmLd,
    [
      "--no-entry",
      "--allow-undefined",
      "--export-memory",
      ...exports.map((symbol) => `--export=${symbol}`),
      objectPath,
      "-o",
      wasmPath,
    ],
    { encoding: "utf8" },
  );
  if (linked.status !== 0) {
    throw new Error(`wasm-ld ${name} failed (${linked.status}): ${linked.stdout}\n${linked.stderr}`);
  }
  const bytes = readFileSync(wasmPath);
  rmSync(directory, { recursive: true, force: true });
  return bytes;
}

function productionLink(objectBytes, name) {
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), `luauc-prod-${name}-`));
  const profilePath = join(directory, "embed.profile");
  const packPath = join(directory, "embed.pack.wasm");
  const objectPath = join(directory, `${name}.o`);
  writeFileSync(profilePath, profileBytes);
  writeFileSync(packPath, packBytes);
  writeFileSync(objectPath, objectBytes);
  const linked = spawnSync(linkerCli, [profilePath, packPath, objectPath], { encoding: "buffer" });
  if (linked.status !== 0) {
    throw new Error(
      `production linker ${name} failed (${linked.status}): ${linked.stderr?.toString() ?? ""}`,
    );
  }
  rmSync(directory, { recursive: true, force: true });
  return Buffer.from(linked.stdout);
}

function compareRelocApplication(name, object, wasmLdModule, productionModule) {
  if (wasmLdModule.sections.custom.has("reloc.CODE") || wasmLdModule.sections.custom.has("reloc.DATA")) {
    throw new Error(`${name}: wasm-ld left reloc custom sections in the output`);
  }
  const localExpected = expectedRelocApplications(object, wasmLdNameResolution(object, wasmLdModule));
  const functionIndexExpected = localExpected.filter((item) => item.kind === "R_WASM_FUNCTION_INDEX_LEB");
  const sameLayout = wasmLdModule.bodies.length === object.bodies.length &&
    functionIndexExpected.every((item) => wasmLdModule.bodies[item.bodyIndex]?.bytes.length === object.bodies[item.bodyIndex].bytes.length);
  if (sameLayout) {
    const applied = readAppliedRelocsFromBodies(object, wasmLdModule.bodies, functionIndexExpected);
    for (const item of applied) {
      if (item.applied !== item.value) {
        throw new Error(
          `${name}: wasm-ld ${item.kind} ${item.symbol} applied ${item.applied}, expected ${item.value}`,
        );
      }
    }
  } else {
    const required = new Set(functionIndexExpected.map((item) => item.symbol));
    const present = new Set([
      ...wasmLdModule.imports.items.filter((item) => item.kind === 0).map((item) => item.name),
      ...wasmLdModule.exports.filter((item) => item.kind === 0).map((item) => item.name),
    ]);
    for (const symbol of required) {
      if (!present.has(symbol)) throw new Error(`${name}: wasm-ld dropped relocated ${symbol}`);
    }
  }

  if (!productionModule) return localExpected;
  if (productionModule.sections.custom.has("reloc.CODE") || productionModule.sections.custom.has("reloc.DATA")) {
    throw new Error(`${name}: production linker left reloc custom sections in the output`);
  }
  const production = productionResolution(object, packBytes, profile);
  const productionExpected = expectedRelocApplications(object, production);
  const generatedBodies = productionModule.bodies.slice(production.packDefinedCount);
  if (generatedBodies.length !== object.definedFunctionCount) {
    throw new Error(
      `${name}: production generated function count ${generatedBodies.length} != ${object.definedFunctionCount}`,
    );
  }
  const applied = readAppliedRelocsFromBodies(object, generatedBodies, productionExpected);
  for (const item of applied) {
    if (item.applied !== item.value) {
      throw new Error(
        `${name}: production ${item.kind} ${item.symbol}+${item.addend} applied ${item.applied}, expected ${item.value}`,
      );
    }
  }
  const memoryExpected = productionExpected.filter((item) => item.kind === "R_WASM_MEMORY_ADDR_I32");
  const generatedData = productionModule.data.slice(productionModule.data.length - object.data.length);
  for (const item of memoryExpected) {
    const segment = generatedData[item.segmentIndex];
    const appliedValue = segment.bytes.readUInt32LE(item.localOffset);
    if (appliedValue !== item.value) {
      throw new Error(
        `${name}: production memory reloc ${item.symbol}+${item.addend} applied ${appliedValue}, expected ${item.value}`,
      );
    }
  }
  return productionExpected;
}

const records = [];

for (const [name, envKey] of LUAU_CORPUS) {
  const source = readFileSync(runfile(process.env[envKey], envKey), "utf8");
  const snapshot = compileFrontendSnapshot(frontend.exports, source, `@aot/${name}.luau`);
  const objectBytes = compileStaticPackage(backend.exports, staticPackageFrame(name, snapshot));
  const object = parseObject(objectBytes);
  const names = definedFunctionNames(object);
  const wasmLdBytes = wasmLdLink(objectBytes, names, name);
  const wasmLdModule = parseCoreModule(wasmLdBytes);
  const productionBytes = productionLink(objectBytes, name);
  const productionModule = parseCoreModule(productionBytes);
  compareRelocApplication(name, object, wasmLdModule, productionModule);

  if (wasmLdModule.exportNames.filter((item) => item !== "memory").sort().join(",") !== [...names].sort().join(",")) {
    throw new Error(`${name}: wasm-ld export names drifted: ${JSON.stringify(wasmLdModule.exportNames)}`);
  }
  if (wasmLdModule.definedFunctionCount !== object.definedFunctionCount) {
    throw new Error(`${name}: wasm-ld defined function count drifted`);
  }
  if (productionModule.exportNames.join(",") !== profile.retained_exports.map((item) => item.name).sort().join(",")) {
    throw new Error(`${name}: production export names drifted: ${JSON.stringify(productionModule.exportNames)}`);
  }
  if (productionModule.memoryMin !== profile.memory_minimum) {
    throw new Error(`${name}: production memory min ${productionModule.memoryMin} != profile ${profile.memory_minimum}`);
  }
  if (productionModule.definedFunctionCount !== productionResolution(object, packBytes, profile).packDefinedCount + object.definedFunctionCount) {
    throw new Error(`${name}: production function count does not include generated functions`);
  }

  records.push({
    name,
    kind: "generated_package",
    object_sha256: sha256Hex(objectBytes),
    reloc_types: relocTypesOf(object),
    symbol_names: symbolNamesOf(object),
    wasm_ld: {
      sha256: sha256Hex(wasmLdBytes),
      export_names: wasmLdModule.exportNames,
      memory_min: wasmLdModule.memoryMin,
      function_count: wasmLdModule.functionCount,
    },
    production: {
      sha256: sha256Hex(productionBytes),
      export_names: productionModule.exportNames,
      memory_min: productionModule.memoryMin,
      function_count: productionModule.functionCount,
    },
  });
}

const scalarBytes = readFileSync(runfile(process.env.LUAUC_SCALAR_FIXTURE_OBJECT, "LUAUC_SCALAR_FIXTURE_OBJECT"));
const scalarObject = parseObject(scalarBytes);
const scalarNames = definedFunctionNames(scalarObject);
const scalarWasmLd = wasmLdLink(scalarBytes, scalarNames, "scalar_fixture");
const scalarModule = parseCoreModule(scalarWasmLd);
compareRelocApplication("scalar_fixture", scalarObject, scalarModule, null);
if (!scalarModule.exportNames.includes("luauc_runtime_v1_generated_scalar_fixture")) {
  throw new Error("scalar_fixture wasm-ld omitted the generated export");
}

records.push({
  name: "scalar_fixture",
  kind: "hand_written_object",
  object_sha256: sha256Hex(scalarBytes),
  reloc_types: relocTypesOf(scalarObject),
  symbol_names: symbolNamesOf(scalarObject),
  wasm_ld: {
    sha256: sha256Hex(scalarWasmLd),
    export_names: scalarModule.exportNames,
    memory_min: scalarModule.memoryMin,
    function_count: scalarModule.functionCount,
  },
  production: null,
});

const generated = generateLinkConformance(records);
if (process.env.LUAUC_WRITE_LINK_CONFORMANCE) {
  writeFileSync(process.env.LUAUC_WRITE_LINK_CONFORMANCE, `${JSON.stringify(generated, null, 2)}\n`);
}
if (generated.canonical_hash !== checked.canonical_hash) {
  throw new Error(
    `link_conformance.json drifted (checked ${checked.canonical_hash}, generated ${generated.canonical_hash})`,
  );
}
if (canonicalHashOf((({ canonical_hash, ...rest }) => rest)(generated)) !== generated.canonical_hash) {
  throw new Error("link_conformance canonical_hash is not self-consistent");
}

console.log(`link corpus verified (${records.length} objects)`);
