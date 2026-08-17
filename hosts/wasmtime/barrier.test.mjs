import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { compilePackage, createContext, destroyContext, instantiateArtifact } from "../js/host.mjs";

const runfile = (value) => {
  if (!value) throw new Error("missing runfile path");
  if (value.startsWith("/")) return value;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const direct = join(root, value);
  try {
    readFileSync(direct);
    return direct;
  } catch {
    return join(root, "_main", value);
  }
};

function toolModule(relative) {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  for (const path of [join(root, relative), join(root, "_main", relative)]) {
    try {
      readFileSync(path);
      return pathToFileURL(path).href;
    } catch {
      // try next
    }
  }
  throw new Error(`missing tool module ${relative}`);
}

const irLedger = await import(toolModule("tools/ir_ledger.mjs"));

const paths = {
  compiler: runfile(process.env.LUAUC_COMPILER_WASM),
  profile: runfile(process.env.LUAUC_EMBED_PROFILE),
  pack: runfile(process.env.LUAUC_EMBED_PACK),
  frontend: runfile(process.env.LUAUC_FRONTEND_WASM),
  backend: runfile(process.env.LUAUC_BACKEND_WASM),
  linker: runfile(process.env.LUAUC_LINKER_CLI),
  interpreter: runfile(process.env.LUAUC_PINNED_INTERPRETER),
  hold: runfile(process.env.LUAUC_USERDATA_HOLD),
  store: runfile(process.env.LUAUC_USERDATA_STORE),
};

const BARRIER_OBJ = 147;
const BARRIER_TABLE_BACK = 148;

const strip = execFileSync(paths.interpreter, ["--barrier-strip"], { encoding: "utf8" });
if (!strip.includes("strip=hold barrier=on dead=0") ||
    !strip.includes("strip=hold barrier=off dead=1") ||
    !strip.includes("strip=store barrier=on dead=0") ||
    !strip.includes("strip=store barrier=off dead=1")) {
  throw new Error(`interpreter color strip failed:\n${strip}`);
}

function commandCounts(snapshot) {
  const counts = new Map();
  irLedger.walkSnapshot(irLedger.parseSnapshot(snapshot), {
    instruction({ command }) {
      counts.set(command, (counts.get(command) ?? 0) + 1);
    },
  });
  return counts;
}

function nopCommand(snapshot, commandValue) {
  const parsed = irLedger.parseSnapshot(snapshot);
  const mutated = Buffer.from(snapshot);
  const functions = irLedger.snapshotSection(parsed, 15);
  const instructions = irLedger.snapshotSection(parsed, 17);
  let count = 0;
  irLedger.walkSnapshot(parsed, {
    instruction({ command, functionId, instructionId }) {
      if (command !== commandValue) return;
      const functionRecord = functions.offset + functionId * functions.recordSize;
      const instructionStart = mutated.readUInt32LE(functionRecord + 24);
      const instructionOffset = instructions.offset +
        (instructionStart + instructionId) * instructions.recordSize;
      mutated[instructionOffset] = 0;
      count += 1;
    },
  });
  return { mutated, count };
}

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
    api.luauc_backend_v1_free(resultPointer);
    api.luauc_backend_v1_dealloc(resultPointer, 24);
    api.luauc_backend_v1_dealloc(framePointer, frame.length);
    throw new Error(`backend static package failed with ${status}/${resultStatus}: ${diagnostic}`);
  }
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_backend_v1_free(resultPointer);
  api.luauc_backend_v1_dealloc(resultPointer, 24);
  api.luauc_backend_v1_dealloc(framePointer, frame.length);
  return object;
}

function linkObject(objectBytes, name) {
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), `luauc-barrier-${name}-`));
  const profilePath = join(directory, "embed.profile");
  const packPath = join(directory, "embed.pack.wasm");
  const objectPath = join(directory, `${name}.o`);
  writeFileSync(profilePath, readFileSync(paths.profile));
  writeFileSync(packPath, readFileSync(paths.pack));
  writeFileSync(objectPath, objectBytes);
  const linked = spawnSync(paths.linker, [profilePath, packPath, objectPath], { encoding: "buffer" });
  rmSync(directory, { recursive: true, force: true });
  if (linked.status !== 0) {
    throw new Error(`linker ${name} failed (${linked.status}): ${linked.stderr?.toString() ?? ""}`);
  }
  return Buffer.from(linked.stdout);
}

function probeArtifact(artifact, kind) {
  const instance = instantiateArtifact(artifact);
  if (typeof instance.exports.luauc_embed_v1_barrier_probe !== "function") {
    throw new Error("embed pack is missing luauc_embed_v1_barrier_probe");
  }
  const context = createContext(instance);
  try {
    return instance.exports.luauc_embed_v1_barrier_probe(context, kind) >>> 0;
  } finally {
    destroyContext(instance, context);
  }
}

async function compileLive(name, sourcePath) {
  const compiled = await compilePackage(
    readFileSync(paths.compiler),
    readFileSync(paths.profile),
    readFileSync(paths.pack),
    [{ name, source: readFileSync(sourcePath, "utf8") }],
    name,
  );
  return compiled.artifact;
}

const frontend = await irLedger.instantiateZeroImport(paths.frontend, "frontend");
const backend = await irLedger.instantiateZeroImport(paths.backend, "backend");
frontend.exports.luauc_frontend_v1_init();

const holdSource = readFileSync(paths.hold, "utf8");
const storeSource = readFileSync(paths.store, "utf8");
const holdSnapshot = irLedger.compileFrontendSnapshot(frontend.exports, holdSource, "@userdata_hold.luau");
const storeSnapshot = irLedger.compileFrontendSnapshot(frontend.exports, storeSource, "@userdata_store.luau");
const holdCounts = commandCounts(holdSnapshot);
const storeCounts = commandCounts(storeSnapshot);
if (!holdCounts.get(BARRIER_OBJ) || holdCounts.get(BARRIER_TABLE_BACK)) {
  throw new Error(`userdata_hold census is not Hold-only: ${JSON.stringify([...holdCounts])}`);
}
if (!storeCounts.get(BARRIER_TABLE_BACK) || storeCounts.get(BARRIER_OBJ)) {
  throw new Error(`userdata_store census is not Store-only: ${JSON.stringify([...storeCounts])}`);
}

const holdLive = await compileLive("userdata_hold", paths.hold);
const storeLive = await compileLive("userdata_store", paths.store);
const holdLiveDead = probeArtifact(holdLive, 0);
const storeLiveDead = probeArtifact(storeLive, 1);
if (holdLiveDead !== 0) throw new Error(`live Hold strip must keep the white object, got ${holdLiveDead}`);
if (storeLiveDead !== 0) throw new Error(`live Store strip must keep the white object, got ${storeLiveDead}`);

const holdOmit = nopCommand(holdSnapshot, BARRIER_OBJ);
const storeOmit = nopCommand(storeSnapshot, BARRIER_TABLE_BACK);
if (holdOmit.count === 0) throw new Error("Hold snapshot has no BARRIER_OBJ to omit");
if (storeOmit.count === 0) throw new Error("Store snapshot has no BARRIER_TABLE_BACK to omit");
if (commandCounts(holdOmit.mutated).get(BARRIER_OBJ)) {
  throw new Error("Hold omit left BARRIER_OBJ in the snapshot");
}
if (commandCounts(storeOmit.mutated).get(BARRIER_TABLE_BACK)) {
  throw new Error("Store omit left BARRIER_TABLE_BACK in the snapshot");
}

const holdOmitArtifact = linkObject(
  compileStaticPackage(backend.exports, staticPackageFrame("userdata_hold", holdOmit.mutated)),
  "hold-omit",
);
const storeOmitArtifact = linkObject(
  compileStaticPackage(backend.exports, staticPackageFrame("userdata_store", storeOmit.mutated)),
  "store-omit",
);
const holdOmitDead = probeArtifact(holdOmitArtifact, 0);
const storeOmitDead = probeArtifact(storeOmitArtifact, 1);
if (holdOmitDead !== 1) throw new Error(`omitting BARRIER_OBJ must kill the Hold white, got ${holdOmitDead}`);
if (storeOmitDead !== 1) throw new Error(`omitting BARRIER_TABLE_BACK must kill the Store white, got ${storeOmitDead}`);

console.log("isolated Hold/Store color strips: live keeps, omitted IR dies");
