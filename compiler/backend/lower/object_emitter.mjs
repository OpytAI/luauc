import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

async function instantiate(path, label) {
  const module = await WebAssembly.compile(readFileSync(path));
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 0) throw new Error(`${label} is not zero-import: ${JSON.stringify(imports)}`);
  return WebAssembly.instantiate(module, {});
}

const [frontendPath, backendPath, sourcePath, outputPath, functionText] = process.argv.slice(2);
if (!frontendPath || !backendPath || !sourcePath || !outputPath || (functionText !== "package" && !/^[0-9]+$/.test(functionText || "")))
  throw new Error("usage: object_emitter <frontend.wasm> <backend.wasm> <source.luau> <output.o> <function-id|package>");
const functionId = functionText === "package" ? null : Number(functionText);
if (functionId !== null && (!Number.isSafeInteger(functionId) || functionId > 0xffffffff))
  throw new Error(`invalid function id ${functionText}`);

const frontend = await instantiate(frontendPath, "frontend");
const backend = await instantiate(backendPath, "backend");
const encoder = new TextEncoder();

function compileFrontend(sourceBytes) {
  const api = frontend.exports;
  api.luauc_frontend_v1_init();
  const chunk = encoder.encode(`@aot/${basename(sourcePath)}`);
  const sourcePointer = api.luauc_frontend_v1_alloc(sourceBytes.length);
  const chunkPointer = api.luauc_frontend_v1_alloc(chunk.length);
  const resultPointer = api.luauc_frontend_v1_alloc(20);
  if (!sourcePointer || !chunkPointer || !resultPointer) throw new Error("frontend allocation failed");
  new Uint8Array(api.memory.buffer, sourcePointer, sourceBytes.length).set(sourceBytes);
  new Uint8Array(api.memory.buffer, chunkPointer, chunk.length).set(chunk);
  new Uint8Array(api.memory.buffer, resultPointer, 20).fill(0);
  const status = api.luauc_frontend_snapshot_v1_compile(
    sourcePointer,
    sourceBytes.length,
    chunkPointer,
    chunk.length,
    0,
    resultPointer,
  );
  const result = new DataView(api.memory.buffer, resultPointer, 20);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const diagnosticPointer = result.getUint32(8, true);
  const diagnosticSize = result.getUint32(12, true);
  const resultStatus = result.getUint32(16, true);
  const diagnostic = diagnosticPointer && diagnosticSize
    ? new TextDecoder().decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
    : "";
  if (status !== 0 || resultStatus !== 0)
    throw new Error(`frontend failed with ${status}/${resultStatus}: ${diagnostic}`);
  const snapshot = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_frontend_snapshot_v1_free(resultPointer);
  api.luauc_frontend_v1_dealloc(resultPointer, 20);
  api.luauc_frontend_v1_dealloc(chunkPointer, chunk.length);
  api.luauc_frontend_v1_dealloc(sourcePointer, sourceBytes.length);
  return snapshot;
}

function compileBackend(snapshot) {
  const api = backend.exports;
  const snapshotPointer = api.luauc_backend_v1_alloc(snapshot.length);
  const resultPointer = api.luauc_backend_v1_alloc(24);
  if (!snapshotPointer || !resultPointer) throw new Error("backend allocation failed");
  new Uint8Array(api.memory.buffer, snapshotPointer, snapshot.length).set(snapshot);
  new Uint8Array(api.memory.buffer, resultPointer, 24).fill(0);
  const status = functionId === null
    ? api.luauc_backend_v1_compile_package(snapshotPointer, snapshot.length, resultPointer)
    : api.luauc_backend_v1_compile(snapshotPointer, snapshot.length, functionId, resultPointer);
  const result = new DataView(api.memory.buffer, resultPointer, 24);
  const dataPointer = result.getUint32(0, true);
  const dataSize = result.getUint32(4, true);
  const resultStatus = result.getUint32(8, true);
  const diagnosticPointer = result.getUint32(16, true);
  const diagnosticSize = result.getUint32(20, true);
  const diagnostic = diagnosticPointer && diagnosticSize
    ? new TextDecoder().decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
    : "";
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize)
    throw new Error(`backend failed with ${status}/${resultStatus}: ${diagnostic}`);
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_backend_v1_free(resultPointer);
  api.luauc_backend_v1_dealloc(resultPointer, 24);
  api.luauc_backend_v1_dealloc(snapshotPointer, snapshot.length);
  return object;
}

const source = readFileSync(sourcePath);
const first = compileBackend(compileFrontend(source));
const second = compileBackend(compileFrontend(source));
if (!first.equals(second)) throw new Error("identical source produced nondeterministic backend objects");
if (!first.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])))
  throw new Error("backend output is not a wasm v1 object");
writeFileSync(outputPath, first);
