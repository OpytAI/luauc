import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const generatedSymbol = "luauc_runtime_v1_generated_ir_function";
const packageFunctionSymbols = (count) => Array.from(
  { length: count },
  (_, id) => `luauc_runtime_v1_function_${String(id).padStart(8, "0")}`,
);
const packageSymbols = packageFunctionSymbols(3);

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  if (!process.env.RUNFILES_DIR) throw new Error("RUNFILES_DIR is not set");
  return join(process.env.RUNFILES_DIR, relative);
}

async function instantiateZeroImport(path, label) {
  const module = await WebAssembly.compile(readFileSync(path));
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 0) throw new Error(`${label} is not zero-import: ${JSON.stringify(imports)}`);
  return WebAssembly.instantiate(module, {});
}

const frontend = await instantiateZeroImport(
  runfile(process.env.LUAUC_FRONTEND_WASM, "LUAUC_FRONTEND_WASM"),
  "frontend",
);
const backend = await instantiateZeroImport(
  runfile(process.env.LUAUC_BACKEND_WASM, "LUAUC_BACKEND_WASM"),
  "backend",
);
const wasmLd = runfile(process.env.LUAUC_WASM_LD, "LUAUC_WASM_LD");

const encoder = new TextEncoder();

function frontendSnapshot(sourceText, chunkText, coverageLevel = 0, inlinePlans = null) {
  const api = frontend.exports;
  api.luauc_frontend_v1_init();
  const source = encoder.encode(sourceText);
  const chunk = encoder.encode(chunkText);
  const sourcePointer = api.luauc_frontend_v1_alloc(source.length);
  const chunkPointer = api.luauc_frontend_v1_alloc(chunk.length);
  const resultPointer = api.luauc_frontend_v1_alloc(20);
  const planBytes = inlinePlans === null ? null : Buffer.alloc(inlinePlans.length * 16);
  if (planBytes)
    for (let index = 0; index < inlinePlans.length; index++) {
      const plan = inlinePlans[index];
      planBytes.writeUInt32LE(plan.callerFunctionId, index * 16);
      planBytes.writeUInt32LE(plan.feedbackSlot, index * 16 + 4);
      planBytes.writeUInt32LE(plan.targetFunctionId, index * 16 + 8);
    }
  const planPointer = planBytes?.length ? api.luauc_frontend_v1_alloc(planBytes.length) : 0;
  if (!sourcePointer || !chunkPointer || !resultPointer || (planBytes?.length && !planPointer))
    throw new Error("frontend allocation failed");

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
  if (status !== 0 || resultStatus !== 0) throw new Error(`frontend failed with ${status}/${resultStatus}`);
  const snapshot = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));

  api.luauc_frontend_snapshot_v1_free(resultPointer);
  api.luauc_frontend_v1_dealloc(resultPointer, 20);
  if (planPointer) api.luauc_frontend_v1_dealloc(planPointer, planBytes.length);
  api.luauc_frontend_v1_dealloc(chunkPointer, chunk.length);
  api.luauc_frontend_v1_dealloc(sourcePointer, source.length);
  return snapshot;
}

function backendObject(snapshot, functionId) {
  const api = backend.exports;
  const snapshotPointer = api.luauc_backend_v1_alloc(snapshot.length);
  const resultPointer = api.luauc_backend_v1_alloc(24);
  if (!snapshotPointer || !resultPointer) throw new Error("backend allocation failed");
  new Uint8Array(api.memory.buffer, snapshotPointer, snapshot.length).set(snapshot);
  new Uint8Array(api.memory.buffer, resultPointer, 24).fill(0);
  const status = api.luauc_backend_v1_compile(snapshotPointer, snapshot.length, functionId, resultPointer);
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

function backendPackage(snapshot) {
  const api = backend.exports;
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
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize)
    throw new Error(`backend package failed with ${status}/${resultStatus}: ${diagnostic}`);
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_backend_v1_free(resultPointer);
  api.luauc_backend_v1_dealloc(resultPointer, 24);
  api.luauc_backend_v1_dealloc(snapshotPointer, snapshot.length);
  return object;
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

function backendStaticPackage(frame) {
  const api = backend.exports;
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
  if (status !== 0 || resultStatus !== 0 || !dataPointer || !dataSize)
    throw new Error(`backend static package failed with ${status}/${resultStatus}: ${diagnostic}`);
  const object = Buffer.from(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
  api.luauc_backend_v1_free(resultPointer);
  api.luauc_backend_v1_dealloc(resultPointer, 24);
  api.luauc_backend_v1_dealloc(framePointer, frame.length);
  return object;
}

function snapshotSection(snapshot, wantedKind) {
  const sectionCount = snapshot.readUInt32LE(204);
  for (let index = 0; index < sectionCount; index++) {
    const descriptor = 224 + index * 32;
    if (snapshot.readUInt16LE(descriptor) !== wantedKind) continue;
    return {
      recordSize: snapshot.readUInt32LE(descriptor + 4),
      offset: Number(snapshot.readBigUInt64LE(descriptor + 8)),
      count: snapshot.readUInt32LE(descriptor + 24),
    };
  }
  throw new Error(`snapshot is missing section ${wantedKind}`);
}

function snapshotShape(snapshot) {
  const protos = snapshotSection(snapshot, 3);
  const bytecode = snapshotSection(snapshot, 5);
  const lineinfo = snapshotSection(snapshot, 11);
  const abslineinfo = snapshotSection(snapshot, 12);
  const functions = snapshotSection(snapshot, 15);
  const blocks = snapshotSection(snapshot, 16);
  const instructions = snapshotSection(snapshot, 17);
  const operands = snapshotSection(snapshot, 18);
  const constants = snapshotSection(snapshot, 19);
  const functionOffset = (functionId) => functions.offset + functionId * functions.recordSize;
  return {
    protoCount: protos.count,
    functionCount: functions.count,
    blockCount(functionId) {
      if (functionId >= functions.count) throw new Error(`function ${functionId} is out of bounds`);
      return snapshot.readUInt32LE(functionOffset(functionId) + 20);
    },
    block(functionId, blockId) {
      if (blockId >= this.blockCount(functionId)) throw new Error(`block ${functionId}/${blockId} is out of bounds`);
      const offset = blocks.offset +
        (snapshot.readUInt32LE(functionOffset(functionId) + 16) + blockId) * blocks.recordSize;
      return {
        kind: snapshot[offset],
        useCount: snapshot.readUInt16LE(offset + 2),
        start: snapshot.readUInt32LE(offset + 4),
        finish: snapshot.readUInt32LE(offset + 8),
      };
    },
    instructionCount(functionId) {
      if (functionId >= functions.count) throw new Error(`function ${functionId} is out of bounds`);
      return snapshot.readUInt32LE(functionOffset(functionId) + 28);
    },
    bytecodeWord(functionId, pc) {
      if (functionId >= functions.count) throw new Error(`function ${functionId} is out of bounds`);
      const protoId = snapshot.readUInt32LE(functionOffset(functionId) + 4);
      if (protoId >= protos.count) throw new Error(`proto ${protoId} is out of bounds`);
      const proto = protos.offset + protoId * protos.recordSize;
      const codeStart = snapshot.readUInt32LE(proto + 36);
      const codeCount = snapshot.readUInt32LE(proto + 40);
      if (pc >= codeCount) throw new Error(`bytecode ${functionId}/${pc} is out of bounds`);
      return snapshot.readUInt32LE(bytecode.offset + (codeStart + pc) * bytecode.recordSize);
    },
    sourceLine(protoId, pc) {
      if (protoId >= protos.count) throw new Error(`proto ${protoId} is out of bounds`);
      const proto = protos.offset + protoId * protos.recordSize;
      const codeCount = snapshot.readUInt32LE(proto + 40);
      if (pc >= codeCount) throw new Error(`pc ${protoId}/${pc} is out of bounds`);
      const lineCount = snapshot.readUInt32LE(proto + 88);
      if (lineCount === 0) return 0;
      const gap = snapshot[proto + 33];
      const lineStart = snapshot.readUInt32LE(proto + 84);
      const absStart = snapshot.readUInt32LE(proto + 92);
      return snapshot.readUInt32LE(abslineinfo.offset + (absStart + (pc >> gap)) * abslineinfo.recordSize) +
        snapshot[lineinfo.offset + lineStart + pc];
    },
    instruction(functionId, instructionId) {
      if (functionId >= functions.count) throw new Error(`function ${functionId} is out of bounds`);
      const functionRecord = functionOffset(functionId);
      const instructionCount = snapshot.readUInt32LE(functionRecord + 28);
      if (instructionId >= instructionCount)
        throw new Error(`instruction ${functionId}/${instructionId} is out of bounds`);
      const instructionOffset = instructions.offset +
        (snapshot.readUInt32LE(functionRecord + 24) + instructionId) * instructions.recordSize;
      const operandStart = snapshot.readUInt32LE(instructionOffset + 8);
      const operandCount = snapshot.readUInt32LE(instructionOffset + 12);
      return {
        command: snapshot[instructionOffset],
        offset: instructionOffset,
        operandCount,
        operand(operandId) {
          if (operandId >= operandCount)
            throw new Error(`operand ${functionId}/${instructionId}/${operandId} is out of bounds`);
          const operandOffset = operands.offset + (operandStart + operandId) * operands.recordSize;
          return { kind: snapshot[operandOffset], value: snapshot.readUInt32LE(operandOffset + 4), offset: operandOffset };
        },
        constant(operandId) {
          const operand = this.operand(operandId);
          if (operand.kind !== 2)
            throw new Error(`operand ${functionId}/${instructionId}/${operandId} is not constant`);
          const constantOffset = constants.offset +
            (snapshot.readUInt32LE(functionRecord + 40) + operand.value) * constants.recordSize;
          return { kind: snapshot[constantOffset], bits: snapshot.readBigUInt64LE(constantOffset + 8) };
        },
      };
    },
  };
}

function capturedSnapshotOffsets(snapshot) {
  const protos = snapshotSection(snapshot, 3);
  const functions = snapshotSection(snapshot, 15);
  const blocks = snapshotSection(snapshot, 16);
  const instructions = snapshotSection(snapshot, 17);
  const operands = snapshotSection(snapshot, 18);
  const constants = snapshotSection(snapshot, 19);
  const functionOffset = functions.offset + functions.recordSize;
  return {
    proto2: protos.offset + 2 * protos.recordSize,
    block0: blocks.offset + snapshot.readUInt32LE(functionOffset + 16) * blocks.recordSize,
    instruction(relativeId) {
      return instructions.offset +
        (snapshot.readUInt32LE(functionOffset + 24) + relativeId) * instructions.recordSize;
    },
    operand(instructionId, operandId) {
      const instructionOffset = this.instruction(instructionId);
      return operands.offset +
        (snapshot.readUInt32LE(instructionOffset + 8) + operandId) * operands.recordSize;
    },
    findConstant(kind, bits) {
      const start = snapshot.readUInt32LE(functionOffset + 40);
      const count = snapshot.readUInt32LE(functionOffset + 44);
      for (let id = 0; id < count; id++) {
        const offset = constants.offset + (start + id) * constants.recordSize;
        if (snapshot[offset] === kind && snapshot.readBigUInt64LE(offset + 8) === bits) return id;
      }
      throw new Error(`captured snapshot is missing constant ${kind}/${bits}`);
    },
  };
}

function referenceSnapshotOffsets(snapshot) {
  const protos = snapshotSection(snapshot, 3);
  const functions = snapshotSection(snapshot, 15);
  const blocks = snapshotSection(snapshot, 16);
  const instructions = snapshotSection(snapshot, 17);
  const operands = snapshotSection(snapshot, 18);
  const constants = snapshotSection(snapshot, 19);
  const functionOffset = (functionId) => functions.offset + functionId * functions.recordSize;
  return {
    proto(protoId) {
      return protos.offset + protoId * protos.recordSize;
    },
    block(functionId, relativeId) {
      const at = functionOffset(functionId);
      return blocks.offset + (snapshot.readUInt32LE(at + 16) + relativeId) * blocks.recordSize;
    },
    instruction(functionId, relativeId) {
      const at = functionOffset(functionId);
      return instructions.offset + (snapshot.readUInt32LE(at + 24) + relativeId) * instructions.recordSize;
    },
    operand(functionId, instructionId, operandId) {
      const instructionOffset = this.instruction(functionId, instructionId);
      return operands.offset +
        (snapshot.readUInt32LE(instructionOffset + 8) + operandId) * operands.recordSize;
    },
    findConstant(functionId, kind, bits) {
      const at = functionOffset(functionId);
      const start = snapshot.readUInt32LE(at + 40);
      const count = snapshot.readUInt32LE(at + 44);
      for (let id = 0; id < count; id++) {
        const offset = constants.offset + (start + id) * constants.recordSize;
        if (snapshot[offset] === kind && snapshot.readBigUInt64LE(offset + 8) === bits) return id;
      }
      throw new Error(`reference snapshot function ${functionId} is missing constant ${kind}/${bits}`);
    },
  };
}

function expectPackageRejection(snapshot, label) {
  try {
    backendPackage(snapshot);
  } catch {
    return;
  }
  throw new Error(`package mutation was accepted: ${label}`);
}

function executeForwardedCapturePackageShape() {
  const name = "forwarded-capture-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_FORWARDED_CAPTURE_SOURCE, "LUAUC_FORWARDED_CAPTURE_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/forwarded_capture.luau");
  const first = backendPackage(snapshot);
  const second = backendPackage(snapshot);
  if (!first.equals(second)) throw new Error(`${name}: package backend is nondeterministic`);

  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.operand(1, 18, 0) + 4);
    expectPackageRejection(mutated, "mixed REF/VAL capture marker no longer matches slot zero initialization");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.operand(2, 18, 0) + 4);
    expectPackageRejection(mutated, "forwarded U0 marker no longer matches its parent-upvalue source");
  }
  return { objectSize: first.length };
}

async function executeRecursiveCallPackageShape() {
  const name = "recursive-call-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_RECURSIVE_CALL_SOURCE, "LUAUC_RECURSIVE_CALL_SOURCE"),
    "utf8",
  );
  const firstSnapshot = frontendSnapshot(source, "@aot/recursive_call.luau");
  const secondSnapshot = frontendSnapshot(source, "@aot/recursive_call.luau");
  if (!firstSnapshot.equals(secondSnapshot)) throw new Error(`${name}: frontend snapshot is nondeterministic`);

  const shape = snapshotShape(firstSnapshot);
  if (shape.protoCount !== 4 || shape.functionCount !== 4)
    throw new Error(`${name}: expected four Protos/functions, got ${shape.protoCount}/${shape.functionCount}`);

  for (const [dupId, captureId, register] of [[0, 1, 2], [2, 3, 3]]) {
    const duplicate = shape.instruction(1, dupId);
    const capture = shape.instruction(1, captureId);
    const duplicateDestination = duplicate.operand(1);
    const captureSource = capture.operand(0);
    const captureKind = capture.constant(1);
    if (duplicate.command !== 168 || duplicateDestination.kind !== 6 || duplicateDestination.value !== register ||
        capture.command !== 152 || captureSource.kind !== 6 || captureSource.value !== register ||
        captureKind.kind !== 2 || captureKind.bits !== 0n)
      throw new Error(`${name}: recursive closure R${register} lost its exact LCT_VAL self-capture`);
  }

  const tailCall = shape.instruction(3, 41);
  const tailInterrupt = shape.instruction(3, 42);
  const tailReturn = shape.instruction(3, 43);
  const callFunction = tailCall.operand(0);
  const callParameters = tailCall.constant(1);
  const callResults = tailCall.constant(2);
  const interruptPc = tailInterrupt.constant(0);
  const returnSource = tailReturn.operand(0);
  const returnResults = tailReturn.constant(1);
  if (tailCall.command !== 154 || callFunction.kind !== 6 || callFunction.value !== 2 ||
      callParameters.kind !== 0 || callParameters.bits !== 2n ||
      callResults.kind !== 0 || callResults.bits !== 0xffffffffffffffffn ||
      tailInterrupt.command !== 145 || tailInterrupt.operandCount !== 1 || interruptPc.kind !== 2 ||
      tailReturn.command !== 155 || returnSource.kind !== 6 || returnSource.value !== 2 ||
      returnResults.kind !== 0 || returnResults.bits !== 0xffffffffffffffffn)
    throw new Error(
      `${name}: open-result tail CALL/INTERRUPT/RETURN shape changed: ` +
      `call=${tailCall.command}/R${callFunction.value}/${callParameters.kind}:${callParameters.bits}/` +
      `${callResults.kind}:${callResults.bits}, interrupt=${tailInterrupt.command}/${tailInterrupt.operandCount}/` +
      `${interruptPc.kind}:${interruptPc.bits}, ` +
      `return=${tailReturn.command}/R${returnSource.value}/${returnResults.kind}:${returnResults.bits}`,
    );

  const first = backendStaticPackage(staticPackageFrame("aot_recursive_call", firstSnapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_recursive_call", secondSnapshot));
  if (!first.equals(second)) throw new Error(`${name}: static-package backend is nondeterministic`);
  const functionSymbols = packageFunctionSymbols(4);
  const module = await WebAssembly.compile(linkPackage(first, functionSymbols, ["luauc_runtime_v1_protos"]));
  const exports = WebAssembly.Module.exports(module);
  const generatedFunctions = exports.filter(({ kind, name: exportName }) =>
    kind === "function" && functionSymbols.includes(exportName));
  if (generatedFunctions.length !== 4 ||
      !exports.some(({ kind, name: exportName }) => kind === "global" && exportName === "luauc_runtime_v1_protos"))
    throw new Error(`${name}: linked object does not expose four functions and its Proto descriptors`);

  const env = Object.fromEntries(WebAssembly.Module.imports(module).map(({ name: importName }) => [importName, () => 0]));
  const instance = await WebAssembly.instantiate(module, { env });
  const protoBase = Number(instance.exports.luauc_runtime_v1_protos.value);
  const view = new DataView(instance.exports.memory.buffer);
  for (let protoId = 0; protoId < 4; protoId++) {
    const record = protoBase + protoId * 88;
    const constantPointer = view.getUint32(record + 60, true);
    const constantCount = view.getUint32(record + 64, true);
    const itemPointer = view.getUint32(record + 68, true);
    const itemCount = view.getUint32(record + 72, true);
    const coveragePointer = view.getUint32(record + 76, true);
    const coverageCount = view.getUint32(record + 80, true);
    const coverageLineCount = view.getUint32(record + 84, true);
    if (view.getUint32(record, true) !== 1 || view.getUint32(record + 4, true) !== 88 ||
        view.getUint32(record + 44, true) !== protoId)
      throw new Error(`${name}: generated Proto descriptor ${protoId} is malformed`);
    if ((constantCount === 0) !== (constantPointer === 0) || (itemCount === 0) !== (itemPointer === 0) ||
        (coverageCount === 0) !== (coveragePointer === 0) || (coverageCount === 0) !== (coverageLineCount === 0))
      throw new Error(`${name}: generated Proto descriptor ${protoId} has noncanonical constant spans`);
  }
  return { objectSize: first.length, functionCount: generatedFunctions.length };
}

async function executeCoveragePackageShape() {
  const name = "coverage-package-shape";
  const source = "return function(value) if value > 0 then return value + 1 end return value - 1 end";
  const firstSnapshot = frontendSnapshot(source, "@aot/coverage_shape.luau", 1);
  const secondSnapshot = frontendSnapshot(source, "@aot/coverage_shape.luau", 1);
  const shape = snapshotShape(firstSnapshot);
  let irSites = 0;
  for (let functionId = 0; functionId < shape.functionCount; functionId++)
    for (let instructionId = 0; instructionId < shape.instructionCount(functionId); instructionId++)
      irSites += shape.instruction(functionId, instructionId).command === 159;
  if (irSites < 3) throw new Error(`${name}: expected natural statement coverage IR, got ${irSites} sites`);

  const first = backendStaticPackage(staticPackageFrame("aot_coverage", firstSnapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_coverage", secondSnapshot));
  if (!first.equals(second)) throw new Error(`${name}: static-package backend is nondeterministic`);
  const functionSymbols = packageFunctionSymbols(shape.functionCount);
  const module = await WebAssembly.compile(linkPackage(first, functionSymbols, ["luauc_runtime_v1_protos"]));
  const env = Object.fromEntries(WebAssembly.Module.imports(module).map(({ name: importName }) => [importName, () => 0]));
  const instance = await WebAssembly.instantiate(module, { env });
  const protoBase = Number(instance.exports.luauc_runtime_v1_protos.value);
  const view = new DataView(instance.exports.memory.buffer);
  let metadataSites = 0;
  for (let protoId = 0; protoId < shape.protoCount; protoId++) {
    const record = protoBase + protoId * 88;
    const pointer = view.getUint32(record + 76, true);
    const count = view.getUint32(record + 80, true);
    const lines = view.getUint32(record + 84, true);
    if ((count === 0) !== (pointer === 0) || (count === 0) !== (lines === 0))
      throw new Error(`${name}: malformed coverage metadata for Proto ${protoId}`);
    for (let site = 0; site < count; site++) {
      const line = view.getUint32(pointer + site * 8, true);
      const reserved = view.getUint32(pointer + site * 8 + 4, true);
      if (reserved !== 0 || line >= lines)
        throw new Error(`${name}: invalid coverage site ${protoId}/${site}`);
    }
    metadataSites += count;
  }
  if (metadataSites !== irSites)
    throw new Error(`${name}: coverage metadata/IR mismatch ${metadataSites}/${irSites}`);
  return { objectSize: first.length, sites: irSites };
}

function executeEmbedNamecallFamilyPackageShape() {
  const name = "embed-namecall-family-package-shape";
  const source = readFileSync(
    runfile(process.env.LUAUC_EMBED_LIB_SOURCE, "LUAUC_EMBED_LIB_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@lib.luau");
  const shape = snapshotShape(snapshot);
  const commandCounts = new Map();
  const operandKinds = new Map();
  const safeEnvironmentVmExits = [];
  let arrayAddressOperand = null;
  let crossBlockTablePointerLoad = null;
  let setListCountOperand = null;
  let setListSourceOperand = null;
  let setListKnownSizeOperand = null;
  let dupTableConstantOperand = null;
  let tableLenPointerOperand = null;
  let newTableNodeOperand = null;
  let deferredAllocAfter = null;
  const setUpvalueIndexes = new Set();
  let newclosureEnvOperand = null;
  let captureKindOperand = null;
  let dupclosureConstantOperand = null;
  const importDepths = new Set();
  let importPayload1Offset = null;
  let getglobalKeyOperand = null;
  let globalEnvPointerOperand = null;
  for (let functionId = 0; functionId < shape.functionCount; functionId++) {
    const blockByInstruction = new Map();
    for (let blockId = 0; blockId < shape.blockCount(functionId); blockId++) {
      const block = shape.block(functionId, blockId);
      if (block.start === 0xffffffff) continue;
      for (let instructionId = block.start; instructionId <= block.finish; instructionId++)
        blockByInstruction.set(instructionId, blockId);
    }
    for (let instructionId = 0; instructionId < shape.instructionCount(functionId); instructionId++) {
      const instruction = shape.instruction(functionId, instructionId);
      const command = instruction.command;
      commandCounts.set(command, (commandCounts.get(command) ?? 0) + 1);
      if (!operandKinds.has(command)) operandKinds.set(command, []);
      operandKinds.get(command).push(
        Array.from({ length: instruction.operandCount }, (_, operandId) => instruction.operand(operandId).kind),
      );
      if (command === 9 && arrayAddressOperand === null)
        arrayAddressOperand = instruction.operand(0);
      if (command === 167 && instruction.operandCount >= 2 && instruction.operand(1).kind === 4)
        newclosureEnvOperand ??= instruction.operand(1);
      if (command === 152 && instruction.operandCount >= 2)
        captureKindOperand ??= instruction.operand(1);
      if (command === 168 && instruction.operandCount >= 3 && instruction.operand(2).kind === 7)
        dupclosureConstantOperand ??= instruction.operand(2);
      if (command === 127 && instruction.operandCount >= 2 && instruction.operand(1).kind === 7) {
        const protos = snapshotSection(snapshot, 3);
        const vm = snapshotSection(snapshot, 6);
        const functions = snapshotSection(snapshot, 15);
        const protoId = snapshot.readUInt32LE(functions.offset + functionId * functions.recordSize + 4);
        const proto = protos.offset + protoId * protos.recordSize;
        const constant = vm.offset +
          (snapshot.readUInt32LE(proto + 44) + instruction.operand(1).value) * vm.recordSize;
        importDepths.add(snapshot.readUInt32LE(constant + 8));
        importPayload1Offset ??= constant + 8;
      }
      if ((command === 160 || command === 161) && instruction.operandCount >= 3)
        getglobalKeyOperand ??= instruction.operand(2);
      if (command === 10 && instruction.operandCount >= 1 && instruction.operand(0).kind === 4) {
        const producer = shape.instruction(functionId, instruction.operand(0).value);
        if (producer.command === 8)
          globalEnvPointerOperand ??= instruction.operand(0);
      }
      if (command === 130 && instruction.operandCount >= 1 && instruction.operand(0).kind === 8)
        setUpvalueIndexes.add(instruction.operand(0).value);
      if (command === 98 && tableLenPointerOperand === null)
        tableLenPointerOperand = instruction.operand(0);
      if (command === 100 && instruction.operandCount === 2 && newTableNodeOperand === null)
        newTableNodeOperand = instruction.operand(1);
      if (command === 101 && instruction.operandCount === 1) {
        const source = instruction.operand(0);
        if (source.kind === 4) {
          const producer = shape.instruction(functionId, source.value);
          if (producer.command === 2 && producer.operandCount === 1 && producer.operand(0).kind === 7)
            dupTableConstantOperand ??= producer.operand(0);
        }
      }
      if (command === 153 && instruction.operandCount === 6) {
        setListCountOperand ??= instruction.operand(3);
        setListSourceOperand ??= instruction.operand(2);
        if (instruction.operand(5).kind === 2)
          setListKnownSizeOperand ??= instruction.operand(5);
      }
      if (command === 100 && instruction.operandCount === 2 && deferredAllocAfter === null) {
        const blockId = blockByInstruction.get(instructionId);
        const block = blockId === undefined ? null : shape.block(functionId, blockId);
        if (block && instructionId + 2 <= block.finish) {
          const storePointer = shape.instruction(functionId, instructionId + 1);
          const storeTag = shape.instruction(functionId, instructionId + 2);
          const nextCommand = instructionId + 3 <= block.finish
            ? shape.instruction(functionId, instructionId + 3).command
            : null;
          if (storePointer.command === 15 && storeTag.command === 13 && nextCommand !== 146 && nextCommand !== 0) {
            deferredAllocAfter = { functionId, after: instructionId + 2 };
          }
        }
      }
      if (command === 21 && instruction.operandCount >= 3 && instruction.operand(1).kind === 2 &&
          instruction.operand(2).kind === 4 &&
          instruction.constant(1).bits === 7n)
      {
        const producerId = instruction.operand(2).value;
        const producer = shape.instruction(functionId, producerId);
        if (producer.command === 2 && producer.operandCount === 1 && producer.operand(0).kind === 6 &&
            blockByInstruction.get(producerId) !== blockByInstruction.get(instructionId))
          crossBlockTablePointerLoad ??= producer.operand(0);
      }
      if (command === 135 && instruction.operand(0).kind === 9) {
        safeEnvironmentVmExits.push(`${functionId}:${instructionId}/pc${instruction.operand(0).value}`);
      }
    }
    try {
      backendObject(snapshot, functionId);
    } catch (error) {
      const blockMatch = /block (\d+)/.exec(error.message);
      const instructionMatch = /instruction (\d+)/.exec(error.message);
      let diagnosticBlockId = blockMatch ? Number(blockMatch[1]) : null;
      if (diagnosticBlockId === null && instructionMatch) {
        const failedInstruction = Number(instructionMatch[1]);
        for (let candidateBlockId = 0; candidateBlockId < shape.blockCount(functionId); candidateBlockId++) {
          const candidate = shape.block(functionId, candidateBlockId);
          if (candidate.start !== 0xffffffff && failedInstruction >= candidate.start && failedInstruction <= candidate.finish) {
            diagnosticBlockId = candidateBlockId;
            break;
          }
        }
      }
      let blockContext = "";
      if (diagnosticBlockId !== null) {
        const blockId = diagnosticBlockId;
        const block = shape.block(functionId, blockId);
        const instructions = [];
        for (let id = block.start; id <= block.finish; id++) {
          const instruction = shape.instruction(functionId, id);
          const operands = Array.from(
            { length: instruction.operandCount },
            (_, operandId) => {
              const operand = instruction.operand(operandId);
              if (operand.kind === 2) {
                const constant = instruction.constant(operandId);
                return `${operand.kind}:${operand.value}=${constant.kind}/${constant.bits}`;
              }
              return `${operand.kind}:${operand.value}`;
            },
          );
          instructions.push(`${id}:${instruction.command}(${operands.join(",")})`);
        }
        const outgoing = [];
        for (let id = block.start; id <= block.finish; id++) {
          const instruction = shape.instruction(functionId, id);
          for (let operandId = 0; operandId < instruction.operandCount; operandId++) {
            const operand = instruction.operand(operandId);
            if (operand.kind !== 5 || outgoing.some(({ id: target }) => target === operand.value)) continue;
            const target = shape.block(functionId, operand.value);
            const commands = [];
            if (target.start !== 0xffffffff)
              for (let targetInstruction = target.start; targetInstruction <= target.finish; targetInstruction++)
                commands.push(shape.instruction(functionId, targetInstruction).command);
            outgoing.push({ id: operand.value, kind: target.kind, commands });
          }
        }
        const owners = [];
        for (let candidateBlockId = 0; candidateBlockId < shape.blockCount(functionId); candidateBlockId++) {
          const candidate = shape.block(functionId, candidateBlockId);
          if (candidate.start === 0xffffffff) continue;
          let references = false;
          for (let id = candidate.start; id <= candidate.finish && !references; id++) {
            const instruction = shape.instruction(functionId, id);
            for (let operandId = 0; operandId < instruction.operandCount; operandId++) {
              const operand = instruction.operand(operandId);
              if (operand.kind === 5 && operand.value === blockId) references = true;
            }
          }
          if (references) {
            const commands = [];
            for (let id = candidate.start; id <= candidate.finish; id++) {
              const instruction = shape.instruction(functionId, id);
              const operands = [];
              if (candidate.finish - candidate.start < 40)
                for (let operandId = 0; operandId < instruction.operandCount; operandId++) {
                  const operand = instruction.operand(operandId);
                  if (operand.kind === 2) {
                    const constant = instruction.constant(operandId);
                    operands.push(`${operand.kind}:${operand.value}=${constant.kind}/${constant.bits}`);
                  } else operands.push(`${operand.kind}:${operand.value}`);
                }
              commands.push(`${id}:${instruction.command}${operands.length ? `(${operands.join(",")})` : ""}`);
            }
            owners.push(`B${candidateBlockId}[${commands.join(",")}]`);
          }
        }
        blockContext = `; block ${blockId} kind ${block.kind}: ${instructions.join(" ")}; ` +
          `targets ${outgoing.map(({ id, kind, commands }) => `B${id}/K${kind}[${commands.join(",")}]`).join(" ")}; ` +
          `owners ${owners.join(" ")}`;
      }
      throw new Error(`${name}: function ${functionId} failed: ${error.message}${blockContext}`);
    }
  }
  if (safeEnvironmentVmExits.length)
    throw new Error(`${name}: safe-environment VM exits remain: ${safeEnvironmentVmExits.join(", ")}`);
  for (const command of [
    1, 2, 7, 8, 9, 10, 11, 12, 21, 33, 83, 97, 98, 100, 101, 102, 103, 104, 123, 124, 125, 126, 128, 129, 130, 131, 132, 133, 134, 135,
    136, 137, 138, 139, 142, 143, 144, 146, 149, 151, 152, 153, 156, 157, 160, 161, 162, 163, 164, 167, 168, 169, 200,
    127,
  ])
    if (!commandCounts.get(command))
      throw new Error(`${name}: natural source did not emit command ${command}`);
  const requireOperandKind = (command, operand, kind) => {
    if (!operandKinds.get(command)?.some((kinds) => kinds[operand] === kind))
      throw new Error(`${name}: command ${command} did not emit operand ${operand} kind ${kind}`);
  };
  requireOperandKind(1, 0, 6); // LOAD_TAG Rn
  requireOperandKind(1, 0, 4); // LOAD_TAG TValue address
  requireOperandKind(2, 0, 6); // LOAD_POINTER Rn
  requireOperandKind(2, 0, 7); // LOAD_POINTER Kn
  requireOperandKind(7, 0, 7); // LOAD_TVALUE Kn
  requireOperandKind(7, 0, 4); // LOAD_TVALUE TValue address
  requireOperandKind(21, 0, 6); // STORE_SPLIT_TVALUE Rn
  requireOperandKind(21, 0, 4); // STORE_SPLIT_TVALUE TValue address
  requireOperandKind(103, 0, 4); // TRY_NUM_TO_INDEX numeric SSA
  requireOperandKind(125, 2, 6); // GET_TABLE dynamic TValue key
  requireOperandKind(125, 2, 2); // GET_TABLE immediate numeric key
  requireOperandKind(126, 2, 6); // SET_TABLE dynamic TValue key
  requireOperandKind(126, 2, 2); // SET_TABLE immediate numeric key
  requireOperandKind(135, 0, 5); // CHECK_SAFE_ENV compiled slow arm
  if (setUpvalueIndexes.size < 2)
    throw new Error(`${name}: SET_UPVALUE did not emit two distinct vm_upvalue indexes`);
  if (arrayAddressOperand?.kind !== 4)
    throw new Error(`${name}: missing instruction-proven array address`);
  const malformedAddress = Buffer.from(snapshot);
  malformedAddress.writeUInt32LE(0, arrayAddressOperand.offset + 4);
  expectPackageRejection(malformedAddress, "array address without proven table/bounds ownership");
  if (crossBlockTablePointerLoad === null)
    throw new Error(`${name}: missing cross-block table-pointer rematerialization evidence`);
  const malformedTablePointer = Buffer.from(snapshot);
  malformedTablePointer.writeUInt32LE(0, crossBlockTablePointerLoad.offset + 4);
  expectPackageRejection(malformedTablePointer, "cross-block table pointer lost its guarded VM register");
  if (setListCountOperand === null || setListSourceOperand === null)
    throw new Error(`${name}: missing SETLIST count/source operands`);
  const malformedSetListCount = Buffer.from(snapshot);
  malformedSetListCount.writeUInt32LE(0, setListCountOperand.offset + 4);
  expectPackageRejection(malformedSetListCount, "SETLIST rejected the validated array range");
  const malformedSetListSource = Buffer.from(snapshot);
  malformedSetListSource.writeUInt32LE(250, setListSourceOperand.offset + 4);
  expectPackageRejection(malformedSetListSource, "SETLIST source+count past maxstacksize");
  if (setListKnownSizeOperand !== null) {
    const malformedSetListSize = Buffer.from(snapshot);
    malformedSetListSize.writeUInt32LE(0, setListKnownSizeOperand.offset + 4);
    expectPackageRejection(malformedSetListSize, "SETLIST known-size constant is below the last written index");
  }
  if (dupTableConstantOperand === null)
    throw new Error(`${name}: missing DUP_TABLE template constant`);
  const malformedDupTable = Buffer.from(snapshot);
  malformedDupTable.writeUInt32LE(0, dupTableConstantOperand.offset + 4);
  expectPackageRejection(malformedDupTable, "DUP_TABLE rejected a non-table template");
  if (tableLenPointerOperand === null)
    throw new Error(`${name}: missing TABLE_LEN pointer`);
  const malformedTableLen = Buffer.from(snapshot);
  malformedTableLen.writeUInt32LE(0, tableLenPointerOperand.offset + 4);
  expectPackageRejection(malformedTableLen, "TABLE_LEN pointer lost its guarded VM register");
  if (newTableNodeOperand === null)
    throw new Error(`${name}: missing NEW_TABLE node operand`);
  const malformedNewTableNode = Buffer.from(snapshot);
  malformedNewTableNode.writeUInt8(1, newTableNodeOperand.offset);
  expectPackageRejection(malformedNewTableNode, "NEW_TABLE node operand rewritten to a non-uint");
  if (deferredAllocAfter === null)
    throw new Error(`${name}: missing deferred NEW_TABLE later CHECK_GC`);
  const malformedDeferredGc = Buffer.from(snapshot);
  let removedDeferredGc = false;
  for (let later = deferredAllocAfter.after + 1; later < shape.instructionCount(deferredAllocAfter.functionId); later++) {
    const candidate = shape.instruction(deferredAllocAfter.functionId, later);
    if (candidate.command !== 146) continue;
    malformedDeferredGc.writeUInt8(0, candidate.offset);
    removedDeferredGc = true;
  }
  if (!removedDeferredGc)
    throw new Error(`${name}: deferred NEW_TABLE has no later CHECK_GC to delete`);
  expectPackageRejection(malformedDeferredGc, "deferred NEW_TABLE lost collector ownership");
  if (captureKindOperand === null)
    throw new Error(`${name}: missing CAPTURE kind operand`);
  const malformedCapture = Buffer.from(snapshot);
  malformedCapture.writeUInt32LE(3, captureKindOperand.offset + 4);
  expectPackageRejection(malformedCapture, "CAPTURE kind/source no longer matches initialized capture");
  if (newclosureEnvOperand === null)
    throw new Error(`${name}: missing NEWCLOSURE env operand`);
  const malformedEnv = Buffer.from(snapshot);
  malformedEnv.writeUInt32LE(0, newclosureEnvOperand.offset + 4);
  expectPackageRejection(malformedEnv, "LOAD_ENV env operand of NEWCLOSURE rewritten away from the previous instruction");
  if (dupclosureConstantOperand === null)
    throw new Error(`${name}: missing FALLBACK_DUPCLOSURE child constant`);
  const malformedDupclosure = Buffer.from(snapshot);
  malformedDupclosure.writeUInt8(6, dupclosureConstantOperand.offset);
  expectPackageRejection(malformedDupclosure, "FALLBACK_DUPCLOSURE child proto is not a child");
  if (!importDepths.has(2) || !importDepths.has(3))
    throw new Error(`${name}: GET_CACHED_IMPORT did not emit 2-key and 3-key depths: ${[...importDepths]}`);
  if (importPayload1Offset === null)
    throw new Error(`${name}: missing GET_CACHED_IMPORT payload1`);
  const malformedImportZero = Buffer.from(snapshot);
  malformedImportZero.writeUInt32LE(0, importPayload1Offset);
  expectPackageRejection(malformedImportZero, "import payload1 rewritten to 0");
  const malformedImportFour = Buffer.from(snapshot);
  malformedImportFour.writeUInt32LE(4, importPayload1Offset);
  expectPackageRejection(malformedImportFour, "import payload1 rewritten to 4");
  if (getglobalKeyOperand === null)
    throw new Error(`${name}: missing GETGLOBAL/SETGLOBAL key`);
  const malformedGlobalKey = Buffer.from(snapshot);
  malformedGlobalKey.writeUInt8(6, getglobalKeyOperand.offset);
  expectPackageRejection(malformedGlobalKey, "GETGLOBAL/SETGLOBAL key rewritten to a non-string vm_const");
  if (globalEnvPointerOperand === null)
    throw new Error(`${name}: missing global-cluster LOAD_ENV pointer`);
  const malformedGlobalEnv = Buffer.from(snapshot);
  malformedGlobalEnv.writeUInt32LE(
    globalEnvPointerOperand.value === 0 ? 1 : 0,
    globalEnvPointerOperand.offset + 4,
  );
  expectPackageRejection(malformedGlobalEnv, "LOAD_ENV of a global cluster rewritten so GET_SLOT_NODE_ADDR pointer is not that instruction");
  const object = backendPackage(snapshot);
  return { objectSize: object.length, functionCount: shape.functionCount, commandCounts };
}

async function executeTableInsertAppendPackageShape() {
  const name = "table-clone-append-package-shape";
  const snapshot = frontendSnapshot(
    "return function(value) local first = { count = 17, kind = 'seed', ready = true } local second = { count = 17, kind = 'seed', ready = true } table.insert(first, value) return first, second end",
    "@aot/table_clone_append_shape.luau",
  );
  const shape = snapshotShape(snapshot);
  if (shape.protoCount !== 2 || shape.functionCount !== 2)
    throw new Error(`${name}: expected two Protos/functions, got ${shape.protoCount}/${shape.functionCount}`);

  const commands = Array.from({ length: shape.instructionCount(1) }, (_, id) => shape.instruction(1, id).command);
  const locate = (wanted) => {
    const starts = [];
    for (let start = 0; start + wanted.length <= commands.length; start++)
      if (wanted.every((command, offset) => commands[start + offset] === command)) starts.push(start);
    return starts;
  };
  const duplicates = locate([2, 101, 15, 13, 146]);
  const appends = locate([2, 133, 98, 22, 102, 7, 20, 149]);
  const bytecodeStringInitializers = locate([10, 137, 133, 0, 20, 149]);
  const linearStringInitializers = locate([10, 137, 133, 20, 149]);
  const bytecodeSplitInitializers = locate([10, 137, 133, 0, 21, 0]);
  const linearNumberInitializers = locate([10, 137, 133, 21, 0]).filter((start) =>
    shape.instruction(1, start + 3).constant(1).bits === 3n
  );
  const bytecodeNumberInitializers = bytecodeSplitInitializers.filter((start) =>
    shape.instruction(1, start + 4).constant(1).bits === 3n
  );
  const bytecodeBooleanInitializers = bytecodeSplitInitializers.filter((start) =>
    shape.instruction(1, start + 4).constant(1).bits === 1n
  );
  const linearBooleanInitializers = locate([10, 137, 0, 21, 0]).filter((start) =>
    shape.instruction(1, start + 3).constant(1).bits === 1n
  );
  const constantLoads = locate([7, 20]).filter((start) =>
    shape.instruction(1, start).operand(0).kind === 7
  );
  if (duplicates.length !== 2 || appends.length !== 1)
    throw new Error(`${name}: expected two exact DUP_TABLE graphs and one append graph, got ${duplicates}/${appends}`);
  if (bytecodeStringInitializers.length !== 2 || linearStringInitializers.length !== 2 ||
      bytecodeNumberInitializers.length !== 2 || linearNumberInitializers.length !== 1 ||
      bytecodeBooleanInitializers.length !== 2 || linearBooleanInitializers.length !== 2 || constantLoads.length !== 4)
    throw new Error(`${name}: exact constant/field initializer graphs changed: ` +
      `${bytecodeStringInitializers}/${linearStringInitializers}; ` +
      `${bytecodeNumberInitializers}/${linearNumberInitializers}; ` +
      `${bytecodeBooleanInitializers}/${linearBooleanInitializers}; loads ${constantLoads}`);
  for (const start of duplicates) {
    const loadConstant = shape.instruction(1, start).operand(0);
    const duplicateSource = shape.instruction(1, start + 1).operand(0);
    const storedPointer = shape.instruction(1, start + 2).operand(1);
    if (loadConstant.kind !== 7 || duplicateSource.kind !== 4 || duplicateSource.value !== start ||
        storedPointer.kind !== 4 || storedPointer.value !== start + 1)
      throw new Error(`${name}: DUP_TABLE dependency graph changed at ${start}`);
  }

  const appendStart = appends[0];
  const pointer = shape.instruction(1, appendStart);
  const readonly = shape.instruction(1, appendStart + 1);
  const length = shape.instruction(1, appendStart + 2);
  const increment = shape.instruction(1, appendStart + 3);
  const setnum = shape.instruction(1, appendStart + 4);
  const load = shape.instruction(1, appendStart + 5);
  const store = shape.instruction(1, appendStart + 6);
  const barrier = shape.instruction(1, appendStart + 7);
  const tableRegister = pointer.operand(0);
  const sourceRegister = load.operand(0);
  const appendFailure = readonly.operand(1);
  const appendFallback = appendFailure.kind === 5 ? shape.block(1, appendFailure.value) : null;
  const appendFallbackCommands = appendFallback === null ? [] : Array.from(
    { length: appendFallback.finish - appendFallback.start + 1 },
    (_, offset) => shape.instruction(1, appendFallback.start + offset).command,
  );
  if (pointer.command !== 2 || tableRegister.kind !== 6 ||
      readonly.command !== 133 || readonly.operand(0).kind !== 4 || readonly.operand(0).value !== appendStart ||
      appendFailure.kind !== 5 || !appendFallbackCommands.includes(127) ||
      !appendFallbackCommands.includes(154) || appendFallbackCommands.at(-1) !== 88 ||
      length.command !== 98 || length.operand(0).kind !== 4 || length.operand(0).value !== appendStart ||
      increment.command !== 22 || increment.operand(0).kind !== 4 || increment.operand(0).value !== appendStart + 2 ||
      increment.constant(1).bits !== 1n ||
      setnum.command !== 102 || setnum.operand(0).kind !== 4 || setnum.operand(0).value !== appendStart ||
      setnum.operand(1).kind !== 4 || setnum.operand(1).value !== appendStart + 3 ||
      load.command !== 7 || sourceRegister.kind !== 6 ||
      store.command !== 20 || store.operand(0).kind !== 4 || store.operand(0).value !== appendStart + 4 ||
      store.operand(1).kind !== 4 || store.operand(1).value !== appendStart + 5 ||
      barrier.command !== 149 || barrier.operand(0).kind !== 4 || barrier.operand(0).value !== appendStart ||
      barrier.operand(1).kind !== 6 || barrier.operand(1).value !== sourceRegister.value || barrier.operand(2).kind !== 1)
    throw new Error(`${name}: optimized append graph changed`);

  const safeEnvironmentVmExits = commands.flatMap((command, instructionId) => {
    if (command !== 135) return [];
    const failure = shape.instruction(1, instructionId).operand(0);
    if (failure.kind !== 9) return [];
    return [`${instructionId}/pc${failure.value}`];
  });
  if (safeEnvironmentVmExits.length)
    throw new Error(`${name}: safe-environment VM exits ${safeEnvironmentVmExits.join(",")}`);

  const object = backendPackage(snapshot);
  const module = await WebAssembly.compile(linkPackage(object, packageFunctionSymbols(2)));
  const helperNames = WebAssembly.Module.imports(module).map(({ name: importName }) => importName);
  if (!helperNames.includes("luauc_runtime_v1_load_constant") ||
      !helperNames.includes("luauc_runtime_v1_dup_table") ||
      !helperNames.includes("luauc_runtime_v1_table_insert_append"))
    throw new Error(`${name}: combined runtime helper imports are missing: ${JSON.stringify(helperNames)}`);
  return { objectSize: object.length };
}

async function executePreloadedFieldAndInvertedCompare() {
  const name = "preloaded-field-and-inverted-compare";
  const snapshot = frontendSnapshot(
    "return function(target, other) target.generated_by = 'agent-plan' return target ~= other end",
    "@preloaded_field_compare.luau",
  );
  const object = backendStaticPackage(staticPackageFrame("preloaded_field_compare", snapshot));
  const module = await WebAssembly.compile(linkPackage(object, packageFunctionSymbols(2)));
  const imports = WebAssembly.Module.imports(module).map(({ name: importName }) => importName);
  for (const helper of [
    "luauc_runtime_v1_load_constant",
    "luauc_runtime_v1_table_set_string",
    "luauc_runtime_v1_compare_any",
  ]) if (!imports.includes(helper)) throw new Error(`${name}: missing ${helper}`);
  return { objectSize: object.length };
}

async function executeLinearizedStringFieldWrites() {
  const name = "linearized-string-field-writes";
  const snapshot = frontendSnapshot(
    `local inputPath = arg[1]
local outputPath = arg[2]
local mode = arg[3] or "ready"
if type(inputPath) ~= "string" or type(outputPath) ~= "string" or arg[4] ~= nil then error("usage") end
local source = assert(sys.fs.read(inputPath))
local manifest = assert(json.decode(source))
local plan = buildPlan(manifest, mode)
plan.input = inputPath
plan.generated_by = "agent-plan"
assert(sys.fs.write(outputPath, json.encode(plan)))`,
    "@linearized_string_field_writes.luau",
  );
  const shape = snapshotShape(snapshot);
  const general = [1, 131, 2, 10, 137, 133, 7, 20, 149];
  const preloaded = [7, 20, 0, 0, 0, 10, 137, 0, 20, 149];
  let generalMidBlock = false;
  let preloadedMidBlock = false;
  for (let blockId = 0; blockId < shape.blockCount(0); blockId++) {
    const block = shape.block(0, blockId);
    if (block.start === 0xffffffff || block.kind !== 3) continue;
    for (let start = block.start; start <= block.finish; start++) {
      const matches = (wanted) => start + wanted.length - 1 <= block.finish &&
        wanted.every((command, offset) => shape.instruction(0, start + offset).command === command);
      if (matches(general) && start + general.length - 1 < block.finish) generalMidBlock = true;
      if (matches(preloaded) && start + preloaded.length - 1 < block.finish) preloadedMidBlock = true;
    }
  }
  if (!generalMidBlock || !preloadedMidBlock)
    throw new Error(`${name}: optimizer no longer emits both owned mid-block SETTABLEKS graphs`);

  const object = backendStaticPackage(staticPackageFrame("linearized_string_field_writes", snapshot));
  const module = await WebAssembly.compile(linkPackage(object, packageFunctionSymbols(1)));
  const imports = WebAssembly.Module.imports(module).map(({ name: importName }) => importName);
  if (!imports.includes("luauc_runtime_v1_table_set_string"))
    throw new Error(`${name}: real literal table-set boundary is missing`);
  return { objectSize: object.length };
}

async function executePlainTableNamecallPackageShape() {
  const name = "plain-table-namecall-package-shape";
  const snapshot = frontendSnapshot(
    "return function(amount) local receiver = { value = 10 } function receiver:bump(delta) return delta + 10 end return receiver:bump(amount) end",
    "@aot/plain_table_namecall_shape.luau",
  );
  const shape = snapshotShape(snapshot);
  if (shape.protoCount !== 3 || shape.functionCount !== 3)
    throw new Error(`${name}: expected three Protos/functions, got ${shape.protoCount}/${shape.functionCount}`);

  const expectCommands = (start, wanted, label) => {
    const actual = wanted.map((_, offset) => shape.instruction(1, start + offset).command);
    if (JSON.stringify(actual) !== JSON.stringify(wanted))
      throw new Error(`${name}: ${label} commands changed: ${JSON.stringify(actual)}`);
  };
  expectCommands(35, [1, 131, 2, 11, 97], "dispatch head");
  expectCommands(40, [15, 13, 7, 20, 88], "direct-slot arm");
  expectCommands(45, [138, 104, 1, 131, 2, 10, 137, 2, 15, 13, 7, 20, 88], "__index arm");
  expectCommands(58, [164, 88], "fallback arm");

  const check = shape.instruction(1, 36);
  const hash = shape.instruction(1, 38);
  const branch = shape.instruction(1, 39);
  const directReceiver = shape.instruction(1, 40);
  const directMethod = shape.instruction(1, 43);
  const noNext = shape.instruction(1, 45);
  const fastgettm = shape.instruction(1, 46);
  const indexSlot = shape.instruction(1, 50);
  const indexMatch = shape.instruction(1, 51);
  const indexedReceiver = shape.instruction(1, 53);
  const indexedMethod = shape.instruction(1, 56);
  const fallback = shape.instruction(1, 58);
  const fallbackJump = shape.instruction(1, 59);
  const key = branch.operand(1);
  if (check.operand(0).kind !== 4 || check.operand(0).value !== 35 ||
      check.constant(1).kind !== 4 || check.constant(1).bits !== 7n ||
      check.operand(2).kind !== 5 || check.operand(2).value !== 6 ||
      hash.operand(0).kind !== 4 || hash.operand(0).value !== 37 ||
      hash.constant(1).kind !== 2 || hash.constant(1).bits !== 8460347n ||
      key.kind !== 7 || branch.operand(2).kind !== 5 || branch.operand(2).value !== 7 ||
      branch.operand(3).kind !== 5 || branch.operand(3).value !== 8 ||
      directReceiver.operand(0).kind !== 6 || directReceiver.operand(0).value !== 3 ||
      directReceiver.operand(1).kind !== 4 || directReceiver.operand(1).value !== 37 ||
      directMethod.operand(0).kind !== 6 || directMethod.operand(0).value !== 2 ||
      directMethod.operand(1).kind !== 4 || directMethod.operand(1).value !== 42 ||
      noNext.operand(0).kind !== 4 || noNext.operand(0).value !== 38 ||
      noNext.operand(1).kind !== 5 || noNext.operand(1).value !== 6 ||
      fastgettm.operand(0).kind !== 4 || fastgettm.operand(0).value !== 37 ||
      fastgettm.constant(1).kind !== 0 || fastgettm.constant(1).bits !== 0n ||
      fastgettm.operand(2).kind !== 5 || fastgettm.operand(2).value !== 6 ||
      indexSlot.operand(0).kind !== 4 || indexSlot.operand(0).value !== 49 ||
      indexSlot.constant(1).kind !== 2 || indexSlot.constant(1).bits !== 8n ||
      indexSlot.operand(2).kind !== 7 || indexSlot.operand(2).value !== key.value ||
      indexMatch.operand(0).kind !== 4 || indexMatch.operand(0).value !== 50 ||
      indexMatch.operand(1).kind !== 7 || indexMatch.operand(1).value !== key.value ||
      indexMatch.operand(2).kind !== 5 || indexMatch.operand(2).value !== 6 ||
      indexedReceiver.operand(0).kind !== 6 || indexedReceiver.operand(0).value !== 3 ||
      indexedReceiver.operand(1).kind !== 4 || indexedReceiver.operand(1).value !== 52 ||
      indexedMethod.operand(0).kind !== 6 || indexedMethod.operand(0).value !== 2 ||
      indexedMethod.operand(1).kind !== 4 || indexedMethod.operand(1).value !== 55 ||
      fallback.constant(0).kind !== 2 || fallback.constant(0).bits !== 8n ||
      fallback.operand(1).kind !== 6 || fallback.operand(1).value !== 2 ||
      fallback.operand(2).kind !== 6 || fallback.operand(2).value !== 1 ||
      fallback.operand(3).kind !== 7 || fallback.operand(3).value !== key.value ||
      fallbackJump.operand(0).kind !== 5 || fallbackJump.operand(0).value !== 5)
    throw new Error(`${name}: exact NAMECALL dependencies changed`);
  for (const jumpId of [44, 57]) {
    const jump = shape.instruction(1, jumpId).operand(0);
    if (jump.kind !== 5 || jump.value !== 5)
      throw new Error(`${name}: fast arm ${jumpId} no longer rejoins block 5`);
  }

  const blockReferences = Array(shape.blockCount(1)).fill(0);
  for (let instructionId = 0; instructionId < shape.instructionCount(1); instructionId++) {
    const instruction = shape.instruction(1, instructionId);
    for (let operandId = 0; operandId < instruction.operandCount; operandId++) {
      const operand = instruction.operand(operandId);
      if (operand.kind === 5) blockReferences[operand.value]++;
    }
  }
  const semanticBlocks = [5, 6, 7, 8].map((blockId) => shape.block(1, blockId));
  const expectedBlocks = [
    { kind: 2, useCount: 3, start: 60, finish: 64 },
    { kind: 1, useCount: 5, start: 58, finish: 59 },
    { kind: 2, useCount: 1, start: 40, finish: 44 },
    { kind: 2, useCount: 1, start: 45, finish: 57 },
  ];
  if (JSON.stringify(semanticBlocks) !== JSON.stringify(expectedBlocks) ||
      JSON.stringify(blockReferences.slice(5)) !== JSON.stringify([3, 5, 1, 1]))
    throw new Error(`${name}: NAMECALL block ownership changed: ${JSON.stringify({ semanticBlocks, blockReferences })}`);

  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(9, offsets.operand(1, 38, 1) + 4);
    expectPackageRejection(mutated, "NAMECALL hash no longer matches the literal key");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(3, offsets.operand(1, 58, 1) + 4);
    expectPackageRejection(mutated, "FALLBACK_NAMECALL destination diverges from both fast arms");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(4, offsets.operand(1, 53, 0) + 4);
    expectPackageRejection(mutated, "__index arm publishes the receiver outside destination plus one");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(4, offsets.operand(1, 59, 0) + 4);
    expectPackageRejection(mutated, "fallback arm no longer uses the canonical rejoin");
  }

  const object = backendPackage(snapshot);
  const module = await WebAssembly.compile(linkPackage(object, packageFunctionSymbols(3)));
  const helpers = WebAssembly.Module.imports(module)
    .filter(({ module: importModule, kind }) => importModule === "env" && kind === "function")
    .map(({ name: importName }) => importName);
  const expectedNamecallHelpers = [
    "luauc_runtime_v1_namecall_plain",
    "luauc_runtime_v1_set_location",
  ];
  if (expectedNamecallHelpers.some((helper) => helpers.filter((candidate) => candidate === helper).length !== 1))
    throw new Error(`${name}: NAMECALL helper/location imports changed: ${JSON.stringify(helpers)}`);
  for (const obsolete of [
    "luauc_runtime_v1_check_node_no_next",
    "luauc_runtime_v1_hash_node_addr",
    "luauc_runtime_v1_node_slot_match",
    "luauc_runtime_v1_slot_node_addr",
    "luauc_runtime_v1_try_get_tm",
  ])
    if (helpers.includes(obsolete))
      throw new Error(`${name}: fused NAMECALL retained raw node helper ${obsolete}`);

  const productSource = readFileSync(
    runfile(process.env.LUAUC_TABLE_NAMECALL_SOURCE, "LUAUC_TABLE_NAMECALL_SOURCE"),
    "utf8",
  );
  const productSnapshot = frontendSnapshot(productSource, "@aot/table_namecall.luau");
  const productShape = snapshotShape(productSnapshot);
  if (productShape.protoCount !== 4 || productShape.functionCount !== 4)
    throw new Error(`${name}: exact product expected four Protos/functions, got ${productShape.protoCount}/${productShape.functionCount}`);
  const productObject = backendPackage(productSnapshot);
  const productSecond = backendPackage(productSnapshot);
  if (!productObject.equals(productSecond)) throw new Error(`${name}: exact product object is nondeterministic`);
  const productModule = await WebAssembly.compile(linkPackage(productObject, packageFunctionSymbols(4)));
  const productHelpers = WebAssembly.Module.imports(productModule).map(({ name: importName }) => importName);
  if (expectedNamecallHelpers.some((helper) => !productHelpers.includes(helper)))
    throw new Error(`${name}: exact product omitted NAMECALL helper: ${JSON.stringify(productHelpers)}`);
  return { objectSize: productObject.length };
}

async function executeYieldCallPackage() {
  const name = "yield-call-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_YIELD_CALL_SOURCE, "LUAUC_YIELD_CALL_SOURCE"),
    "utf8",
  );
  const firstSnapshot = frontendSnapshot(source, "@aot/yield_call.luau");
  const secondSnapshot = frontendSnapshot(source, "@aot/yield_call.luau");
  if (!firstSnapshot.equals(secondSnapshot)) throw new Error(`${name}: frontend snapshot is nondeterministic`);
  const shape = snapshotShape(firstSnapshot);
  if (shape.protoCount !== 3 || shape.functionCount !== 3)
    throw new Error(`${name}: expected three Protos/functions, got ${shape.protoCount}/${shape.functionCount}`);

  const outerCall = shape.instruction(1, 16);
  const outerTail = shape.instruction(1, 18);
  const nestedCall = shape.instruction(2, 6);
  const nestedTail = shape.instruction(2, 21);
  if (outerCall.command !== 154 || outerCall.operand(0).value !== 3 ||
      outerCall.constant(1).bits !== 1n || outerCall.constant(2).bits !== 0xffffffffffffffffn ||
      outerTail.command !== 155 || outerTail.operand(0).value !== 3 || outerTail.constant(1).bits !== 0xffffffffffffffffn ||
      nestedCall.command !== 154 || nestedCall.operand(0).value !== 1 ||
      nestedCall.constant(1).bits !== 1n || nestedCall.constant(2).bits !== 1n ||
      nestedTail.command !== 155 || nestedTail.operand(0).value !== 2 || nestedTail.constant(1).bits !== 1n)
    throw new Error(`${name}: pinned outer/nested continuation shapes changed`);
  if (shape.sourceLine(1, 4) !== 7 || shape.sourceLine(2, 2) !== 3)
    throw new Error(`${name}: pinned saved-pc source lines changed`);

  const first = backendStaticPackage(staticPackageFrame("aot_yield_call", firstSnapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_yield_call", secondSnapshot));
  if (!first.equals(second)) throw new Error(`${name}: static-package backend is nondeterministic`);
  const functionSymbols = packageFunctionSymbols(3);
  const module = await WebAssembly.compile(linkPackage(first, functionSymbols));
  const imports = WebAssembly.Module.imports(module);
  if (imports.filter(({ module: importModule, name: importName, kind }) =>
    importModule === "env" && importName === "luauc_runtime_v1_exchange_continuation" && kind === "function").length !== 1)
    throw new Error(`${name}: linked package lacks the continuation exchange import`);
  if (imports.filter(({ module: importModule, name: importName, kind }) =>
    importModule === "env" && importName === "luauc_runtime_v1_set_location" && kind === "function").length !== 1)
    throw new Error(`${name}: linked package lacks the source-location import`);
  return { objectSize: first.length, functionCount: functionSymbols.length };
}

async function executeDynamicArrayTablePackage() {
  const name = "dynamic-array-table-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_DYNAMIC_ARRAY_TABLE_SOURCE, "LUAUC_DYNAMIC_ARRAY_TABLE_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/dynamic_array_table.luau");
  const shape = snapshotShape(snapshot);
  if (shape.protoCount !== 3 || shape.functionCount !== 3 ||
      shape.instruction(1, 1).command !== 100 || shape.instruction(1, 11).command !== 153 ||
      shape.instruction(1, 49).command !== 1 || shape.instruction(1, 58).command !== 149 ||
      shape.instruction(1, 65).command !== 167 || shape.instruction(2, 6).command !== 98 ||
      shape.instruction(2, 21).command !== 9)
    throw new Error(`${name}: pinned allocation/array/capture IR shape changed`);

  const first = backendStaticPackage(staticPackageFrame("aot_dynamic_array_table", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_dynamic_array_table", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(3)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_new_table",
      "luauc_runtime_v1_set_list",
      "luauc_runtime_v1_array_set",
      "luauc_runtime_v1_array_get",
      "luauc_runtime_v1_do_len",
      "luauc_runtime_v1_table_set_number",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_new_table",
    "luauc_runtime_v1_set_list",
    "luauc_runtime_v1_array_get",
    "luauc_runtime_v1_do_len",
    "luauc_runtime_v1_table_set_number",
  ])) throw new Error(`${name}: unexpected table helper imports ${JSON.stringify(helpers)}`);
  return { objectSize: first.length, functionCount: 3 };
}

async function executeDynamicHashTablePackage() {
  const name = "dynamic-hash-table-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_DYNAMIC_HASH_TABLE_SOURCE, "LUAUC_DYNAMIC_HASH_TABLE_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/dynamic_hash_table.luau");
  const shape = snapshotShape(snapshot);
  if (shape.protoCount !== 3 || shape.functionCount !== 3 ||
      shape.instruction(1, 1).command !== 100 || shape.instruction(1, 1).constant(0).bits !== 0n ||
      shape.instruction(1, 1).constant(1).bits !== 4n ||
      shape.instruction(1, 8).command !== 10 || shape.instruction(1, 15).command !== 163 ||
      shape.instruction(1, 20).command !== 10 || shape.instruction(1, 27).command !== 163 ||
      shape.instruction(1, 32).command !== 10 || shape.instruction(1, 39).command !== 163 ||
      shape.instruction(1, 44).command !== 10 || shape.instruction(1, 49).command !== 162 ||
      shape.instruction(1, 54).command !== 10 || shape.instruction(1, 59).command !== 162 ||
      shape.instruction(1, 67).command !== 36 || shape.instruction(1, 72).command !== 123 ||
      shape.instruction(1, 77).command !== 10 || shape.instruction(1, 84).command !== 163 ||
      shape.instruction(2, 5).command !== 10 || shape.instruction(2, 10).command !== 162 ||
      shape.instruction(2, 17).command !== 10 || shape.instruction(2, 22).command !== 162 ||
      shape.instruction(2, 29).command !== 10 || shape.instruction(2, 34).command !== 162 ||
      shape.instruction(2, 37).command !== 155)
    throw new Error(`${name}: pinned allocation/string-slot/capture IR shape changed`);

  const first = backendStaticPackage(staticPackageFrame("aot_dynamic_hash_table", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_dynamic_hash_table", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const keys = Buffer.from("leftmiddleright");
  if (first.indexOf(keys) < 0)
    throw new Error(`${name}: literal key pool is absent`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(3)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_new_table",
      "luauc_runtime_v1_table_set_string",
      "luauc_runtime_v1_table_get_string",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_new_table",
    "luauc_runtime_v1_table_set_string",
    "luauc_runtime_v1_table_get_string",
  ])) throw new Error(`${name}: unexpected string-table helper imports ${JSON.stringify(helpers)}`);
  if (WebAssembly.Module.imports(module).filter(({ name: importName }) =>
    importName === "luauc_runtime_v1_set_location").length !== 1)
    throw new Error(`${name}: fused literal table semantics omitted source-location publication`);
  return { objectSize: first.length, functionCount: 3 };
}

async function executeDynamicStringPackage() {
  const name = "dynamic-string-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_DYNAMIC_STRING_SOURCE, "LUAUC_DYNAMIC_STRING_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/dynamic_string.luau");
  const shape = snapshotShape(snapshot);
  const concat = shape.instruction(1, 7);
  const concatLoad = shape.instruction(1, 8);
  const concatStore = shape.instruction(1, 9);
  const length = shape.instruction(2, 8);
  const doLength = shape.instruction(2, 14);
  const fastEquality = shape.instruction(2, 26);
  const genericEquality = shape.instruction(2, 31);
  if (snapshot.length !== 5174 || shape.protoCount !== 3 || shape.functionCount !== 3 ||
      shape.instruction(1, 6).command !== 150 || concat.command !== 128 || concat.operandCount !== 2 ||
      concat.operand(0).kind !== 6 || concat.operand(0).value !== 4 || concat.constant(1).bits !== 3n ||
      concatLoad.command !== 7 || concatLoad.operand(0).value !== 4 || concatStore.command !== 20 ||
      concatStore.operand(0).value !== 3 || concatStore.operand(1).kind !== 4 || concatStore.operand(1).value !== 8 ||
      shape.instruction(1, 10).command !== 146 || length.command !== 98 || doLength.command !== 124 ||
      doLength.operand(0).value !== 1 || doLength.operand(1).value !== 2 || fastEquality.command !== 87 ||
      genericEquality.command !== 83 || shape.instruction(2, 39).command !== 155)
    throw new Error(`${name}: pinned concat/length/equality IR shape changed`);

  for (let functionId = 0; functionId < 3; functionId++) {
    try {
      backendObject(snapshot, functionId);
    } catch (error) {
      throw new Error(`${name}: function ${functionId} failed standalone lowering`, { cause: error });
    }
  }
  const first = backendStaticPackage(staticPackageFrame("aot_dynamic_string", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_dynamic_string", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(3)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_compare_any",
      "luauc_runtime_v1_concat",
      "luauc_runtime_v1_do_len",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_compare_any",
    "luauc_runtime_v1_concat",
    "luauc_runtime_v1_do_len",
  ])) throw new Error(`${name}: unexpected dynamic-string helper imports ${JSON.stringify(helpers)}`);
  return { objectSize: first.length, functionCount: 3 };
}

async function executeGenericIterationPackage() {
  const name = "generic-iteration-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_GENERIC_ITERATION_SOURCE, "LUAUC_GENERIC_ITERATION_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/generic_iteration.luau");
  const shape = snapshotShape(snapshot);
  const prep = shape.instruction(2, 6);
  const marker = shape.instruction(2, 32);
  const loadTag = shape.instruction(2, 33);
  const checkTag = shape.instruction(2, 34);
  const loop = shape.instruction(2, 35);
  const fallbackMarker = shape.instruction(2, 36);
  const fallbackLoop = shape.instruction(2, 37);
  if (snapshot.length !== 5453 || shape.protoCount !== 3 || shape.functionCount !== 3 ||
      prep.command !== 169 || prep.operandCount !== 3 || prep.constant(0).bits !== 4n ||
      prep.operand(1).kind !== 6 || prep.operand(1).value !== 1 || prep.operand(2).value !== 2 ||
      marker.command !== 145 || loadTag.command !== 1 || loadTag.operand(0).kind !== 6 ||
      loadTag.operand(0).value !== 1 || checkTag.command !== 131 ||
      checkTag.operand(0).kind !== 4 || checkTag.operand(0).value !== 33 ||
      checkTag.constant(1).bits !== 0n || checkTag.operand(2).value !== 7 ||
      loop.command !== 156 || loop.operandCount !== 4 || loop.operand(0).value !== 1 ||
      loop.constant(1).bits !== 2n || loop.operand(2).value !== 1 || loop.operand(3).value !== 6 ||
      fallbackMarker.command !== 150 || fallbackLoop.command !== 157 || fallbackLoop.operandCount !== 4 ||
      fallbackLoop.operand(0).value !== 1 || fallbackLoop.constant(1).bits !== 2n ||
      fallbackLoop.operand(2).value !== 1 || fallbackLoop.operand(3).value !== 6)
    throw new Error(`${name}: pinned table-prep/generic-loop IR shape changed`);

  for (let functionId = 0; functionId < 3; functionId++) {
    try {
      backendObject(snapshot, functionId);
    } catch (error) {
      throw new Error(`${name}: function ${functionId} failed standalone lowering`, { cause: error });
    }
  }
  const first = backendStaticPackage(staticPackageFrame("aot_generic_iteration", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_generic_iteration", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(3)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_exchange_continuation",
      "luauc_runtime_v1_forg_prep",
      "luauc_runtime_v1_forg_loop",
      "luauc_runtime_v1_forg_loop_call",
      "luauc_runtime_v1_forg_loop_finish",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_exchange_continuation",
    "luauc_runtime_v1_forg_prep",
    "luauc_runtime_v1_forg_loop",
    "luauc_runtime_v1_forg_loop_call",
    "luauc_runtime_v1_forg_loop_finish",
  ])) throw new Error(`${name}: unexpected generic-iteration helper imports ${JSON.stringify(helpers)}`);
  return { objectSize: first.length, functionCount: 3 };
}

async function executeGenericTablePackage() {
  const name = "generic-table-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_GENERIC_TABLE_SOURCE, "LUAUC_GENERIC_TABLE_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/generic_table.luau");
  const shape = snapshotShape(snapshot);
  const setA = shape.instruction(1, 22);
  const setB = shape.instruction(1, 41);
  const setC = shape.instruction(1, 60);
  const get = shape.instruction(2, 17);
  const prep = shape.instruction(2, 26);
  const loop = shape.instruction(2, 52);
  if (snapshot.length !== 10008 || shape.protoCount !== 3 || shape.functionCount !== 3 ||
      shape.instruction(1, 1).command !== 100 ||
      shape.instruction(1, 7).command !== 1 || shape.instruction(1, 11).command !== 103 ||
      shape.instruction(1, 13).command !== 136 || shape.instruction(1, 20).command !== 88 ||
      shape.instruction(1, 21).command !== 150 || setA.command !== 126 || setA.operandCount !== 3 ||
      setA.operand(0).value !== 1 || setA.operand(1).value !== 6 || setA.operand(2).value !== 0 ||
      shape.instruction(1, 24).command !== 1 || shape.instruction(1, 30).command !== 103 ||
      shape.instruction(1, 33).command !== 134 || shape.instruction(1, 34).command !== 133 ||
      shape.instruction(1, 40).command !== 150 || setB.command !== 126 ||
      setB.operand(0).value !== 3 || setB.operand(1).value !== 6 || setB.operand(2).value !== 2 ||
      shape.instruction(1, 43).command !== 1 || shape.instruction(1, 49).command !== 103 ||
      shape.instruction(1, 52).command !== 134 || shape.instruction(1, 53).command !== 133 ||
      shape.instruction(1, 59).command !== 150 || setC.command !== 126 ||
      setC.operand(0).value !== 5 || setC.operand(1).value !== 6 || setC.operand(2).value !== 4 ||
      shape.instruction(1, 74).command !== 0 || shape.instruction(1, 89).command !== 0 ||
      shape.instruction(1, 105).command !== 0 || shape.instruction(1, 117).command !== 155 ||
      shape.instruction(2, 2).command !== 1 || shape.instruction(2, 8).command !== 103 ||
      shape.instruction(2, 10).command !== 136 || shape.instruction(2, 16).command !== 150 ||
      get.command !== 125 || get.operandCount !== 3 || get.operand(0).value !== 1 ||
      get.operand(1).value !== 2 || get.operand(2).value !== 0 ||
      prep.command !== 169 || prep.constant(0).bits !== 7n || prep.operand(1).value !== 4 ||
      loop.command !== 156 || loop.constant(1).bits !== 2n ||
      shape.instruction(2, 54).command !== 157 || shape.instruction(2, 56).command !== 155)
    throw new Error(`${name}: pinned generic set/get/iteration IR shape changed`);

  for (let functionId = 0; functionId < 3; functionId++) {
    try {
      backendObject(snapshot, functionId);
    } catch (error) {
      throw new Error(`${name}: function ${functionId} failed standalone lowering`, { cause: error });
    }
  }
  const first = backendStaticPackage(staticPackageFrame("aot_generic_table", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_generic_table", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(3)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_forg_prep",
      "luauc_runtime_v1_forg_loop",
      "luauc_runtime_v1_table_set",
      "luauc_runtime_v1_table_get",
      "luauc_runtime_v1_table_array_set",
      "luauc_runtime_v1_table_array_get",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_forg_prep",
    "luauc_runtime_v1_forg_loop",
    "luauc_runtime_v1_table_set",
    "luauc_runtime_v1_table_get",
    "luauc_runtime_v1_table_array_set",
    "luauc_runtime_v1_table_array_get",
  ])) throw new Error(`${name}: unexpected generic-table helper imports ${JSON.stringify(helpers)}`);
  return { objectSize: first.length, functionCount: 3 };
}

async function executeGeneralDynamicObjectGraph() {
  const name = "general-dynamic-object-graph";
  const source = `return function(object, key, value)
    object[key] = value
    return object[key]
end`;
  const snapshot = frontendSnapshot(source, "@aot/general_dynamic_object_graph.luau");
  const shape = snapshotShape(snapshot);
  const setTableGuard = shape.instruction(1, 1);
  const setKeyGuard = shape.instruction(1, 3);
  const setFallback = shape.instruction(1, 17);
  const getTableGuard = shape.instruction(1, 20);
  const getKeyGuard = shape.instruction(1, 22);
  const getFallback = shape.instruction(1, 34);
  if (shape.protoCount !== 2 || shape.functionCount !== 2 ||
      setTableGuard.command !== 131 || setTableGuard.operand(2).kind !== 5 || setTableGuard.operand(2).value !== 1 ||
      setKeyGuard.command !== 131 || setKeyGuard.operand(2).kind !== 5 || setKeyGuard.operand(2).value !== 1 ||
      setFallback.command !== 126 || setFallback.operand(0).value !== 2 ||
      setFallback.operand(1).value !== 0 || setFallback.operand(2).value !== 1 ||
      getTableGuard.command !== 131 || getTableGuard.operand(2).kind !== 5 || getTableGuard.operand(2).value !== 3 ||
      getKeyGuard.command !== 131 || getKeyGuard.operand(2).kind !== 5 || getKeyGuard.operand(2).value !== 3 ||
      getFallback.command !== 125 || getFallback.operand(0).value !== 3 ||
      getFallback.operand(1).value !== 0 || getFallback.operand(2).value !== 1)
    throw new Error(`${name}: pinned general GET_TABLE/SET_TABLE fallback graph changed`);

  const first = backendStaticPackage(staticPackageFrame("aot_general_dynamic_object", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_general_dynamic_object", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(2)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_table_set",
      "luauc_runtime_v1_table_get",
      "luauc_runtime_v1_table_array_set",
      "luauc_runtime_v1_table_array_get",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_table_set",
    "luauc_runtime_v1_table_get",
    "luauc_runtime_v1_table_array_set",
    "luauc_runtime_v1_table_array_get",
  ])) throw new Error(`${name}: unexpected helper imports ${JSON.stringify(helpers)}`);
  return { objectSize: first.length, functionCount: 2 };
}

async function executePowMetamethodGraph() {
  const name = "pow-metamethod-graph";
  const snapshot = frontendSnapshot(
    "return function(left, right) return left ^ right end",
    "@aot/pow_metamethod_graph.luau",
  );
  const shape = snapshotShape(snapshot);
  const invoke = shape.instruction(1, 6);
  const marker = shape.instruction(1, 10);
  const fallback = shape.instruction(1, 11);
  if (shape.protoCount !== 2 || shape.functionCount !== 2 ||
      invoke.command !== 197 || invoke.constant(0).bits !== 21n ||
      marker.command !== 150 || marker.constant(0).bits !== 1n ||
      fallback.command !== 123 || fallback.operand(0).value !== 2 ||
      fallback.operand(1).value !== 0 || fallback.operand(2).value !== 1 ||
      fallback.constant(3).bits !== 14n)
    throw new Error(`${name}: pinned INVOKE_LIBM/DO_ARITH(TM_POW) graph changed`);

  const first = backendStaticPackage(staticPackageFrame("aot_pow_metamethod", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_pow_metamethod", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(2)));
  const operatorHelpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_do_arith",
      "luauc_runtime_v1_sin",
      "luauc_runtime_v1_check_safe_env",
    ].includes(importName));
  if (JSON.stringify(operatorHelpers) !== JSON.stringify(["luauc_runtime_v1_do_arith"]))
    throw new Error(`${name}: unexpected operator helper imports ${JSON.stringify(operatorHelpers)}`);
  return { objectSize: first.length, functionCount: 2 };
}

async function executeRepeatedPowMetamethodGraph() {
  const name = "repeated-pow-metamethod-graph";
  const snapshot = frontendSnapshot(
    "return function(left, right) local value = left ^ right; value = value ^ right; value = value ^ right; return value end",
    "@aot/repeated_pow_metamethod_graph.luau",
  );
  const shape = snapshotShape(snapshot);
  const firstInvoke = shape.instruction(1, 6);
  const secondInvoke = shape.instruction(1, 19);
  const thirdInvoke = shape.instruction(1, 31);
  const firstLinearized = shape.instruction(1, 45);
  const secondLinearized = shape.instruction(1, 54);
  const secondFallback = shape.instruction(1, 23);
  const thirdFallback = shape.instruction(1, 35);
  if (shape.protoCount !== 2 || shape.functionCount !== 2 ||
      firstInvoke.command !== 197 || firstInvoke.constant(0).bits !== 21n ||
      secondInvoke.command !== 197 || secondInvoke.constant(0).bits !== 21n ||
      thirdInvoke.command !== 197 || thirdInvoke.constant(0).bits !== 21n ||
      firstLinearized.command !== 197 || firstLinearized.operand(1).value !== 6 ||
      secondLinearized.command !== 197 || secondLinearized.operand(1).value !== 45 ||
      secondFallback.command !== 123 || secondFallback.operand(0).value !== 2 ||
      secondFallback.operand(1).value !== 2 || secondFallback.operand(2).value !== 1 ||
      secondFallback.constant(3).bits !== 14n ||
      thirdFallback.command !== 123 || thirdFallback.operand(0).value !== 2 ||
      thirdFallback.operand(1).value !== 2 || thirdFallback.operand(2).value !== 1 ||
      thirdFallback.constant(3).bits !== 14n)
    throw new Error(`${name}: pinned repeated-register pow graph changed`);

  const first = backendStaticPackage(staticPackageFrame("aot_repeated_pow_metamethod", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_repeated_pow_metamethod", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(2)));
  const operatorHelpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_do_arith",
      "luauc_runtime_v1_sin",
      "luauc_runtime_v1_check_safe_env",
    ].includes(importName));
  if (JSON.stringify(operatorHelpers) !== JSON.stringify(["luauc_runtime_v1_do_arith"]))
    throw new Error(`${name}: unexpected operator helper imports ${JSON.stringify(operatorHelpers)}`);
  return { objectSize: first.length, functionCount: 2 };
}

async function executeMixedTablePackage() {
  const name = "mixed-table-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_MIXED_TABLE_SOURCE, "LUAUC_MIXED_TABLE_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/mixed_table.luau");
  const shape = snapshotShape(snapshot);
  const setA = shape.instruction(1, 22);
  const setB = shape.instruction(1, 41);
  const setC = shape.instruction(1, 60);
  const setD = shape.instruction(1, 79);
  const deletion = shape.instruction(1, 98);
  const getIndex = shape.instruction(2, 17);
  const getName = shape.instruction(2, 36);
  const prep = shape.instruction(2, 46);
  const equalityIndex = shape.instruction(2, 64);
  const equalityName = shape.instruction(2, 77);
  const loop = shape.instruction(2, 85);
  const returned = shape.instruction(2, 99);
  if (snapshot.length !== 14808 || shape.protoCount !== 3 || shape.functionCount !== 3 ||
      shape.instruction(1, 1).command !== 100 ||
      shape.instruction(1, 7).command !== 1 || shape.instruction(1, 11).command !== 103 ||
      shape.instruction(1, 20).command !== 88 || shape.instruction(1, 21).command !== 150 ||
      setA.command !== 126 || setA.operand(0).value !== 1 || setA.operand(1).value !== 10 || setA.operand(2).value !== 0 ||
      shape.instruction(1, 24).command !== 1 || shape.instruction(1, 30).command !== 103 ||
      shape.instruction(1, 33).command !== 134 || shape.instruction(1, 34).command !== 133 ||
      setB.command !== 126 || setB.operand(0).value !== 3 || setB.operand(1).value !== 10 || setB.operand(2).value !== 2 ||
      shape.instruction(1, 43).command !== 1 || shape.instruction(1, 49).command !== 103 ||
      shape.instruction(1, 52).command !== 134 || shape.instruction(1, 53).command !== 133 ||
      setC.command !== 126 || setC.operand(0).value !== 5 || setC.operand(1).value !== 10 || setC.operand(2).value !== 4 ||
      shape.instruction(1, 62).command !== 1 || shape.instruction(1, 68).command !== 103 ||
      shape.instruction(1, 71).command !== 134 || shape.instruction(1, 72).command !== 133 ||
      setD.command !== 126 || setD.operand(0).value !== 7 || setD.operand(1).value !== 10 || setD.operand(2).value !== 6 ||
      shape.instruction(1, 81).command !== 1 || shape.instruction(1, 87).command !== 103 ||
      shape.instruction(1, 90).command !== 134 || shape.instruction(1, 91).command !== 133 ||
      deletion.command !== 126 || deletion.operand(0).value !== 9 || deletion.operand(1).value !== 10 || deletion.operand(2).value !== 8 ||
      shape.instruction(1, 112).command !== 0 || shape.instruction(1, 175).command !== 0 ||
      shape.instruction(1, 187).command !== 155 ||
      shape.instruction(2, 2).command !== 1 || shape.instruction(2, 8).command !== 103 ||
      shape.instruction(2, 16).command !== 150 || getIndex.command !== 125 ||
      getIndex.operand(0).value !== 2 || getIndex.operand(1).value !== 3 || getIndex.operand(2).value !== 0 ||
      shape.instruction(2, 21).command !== 1 || shape.instruction(2, 27).command !== 103 ||
      shape.instruction(2, 35).command !== 150 || getName.command !== 125 ||
      getName.operand(0).value !== 3 || getName.operand(1).value !== 4 || getName.operand(2).value !== 1 ||
      prep.command !== 169 || prep.constant(0).bits !== 10n || prep.operand(1).value !== 7 ||
      equalityIndex.command !== 83 || equalityName.command !== 83 ||
      loop.command !== 156 || loop.constant(1).bits !== 2n || shape.instruction(2, 87).command !== 157 ||
      returned.command !== 155 || returned.operand(0).value !== 7 || returned.constant(1).bits !== 5n)
    throw new Error(`${name}: pinned mixed set/get/delete/iteration IR shape changed`);

  for (let functionId = 0; functionId < 3; functionId++) {
    try {
      backendObject(snapshot, functionId);
    } catch (error) {
      throw new Error(`${name}: function ${functionId} failed standalone lowering`, { cause: error });
    }
  }
  const first = backendStaticPackage(staticPackageFrame("aot_mixed_table", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_mixed_table", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(3)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_compare_any",
      "luauc_runtime_v1_forg_prep",
      "luauc_runtime_v1_forg_loop",
      "luauc_runtime_v1_table_set",
      "luauc_runtime_v1_table_get",
      "luauc_runtime_v1_table_array_set",
      "luauc_runtime_v1_table_array_get",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_compare_any",
    "luauc_runtime_v1_forg_prep",
    "luauc_runtime_v1_forg_loop",
    "luauc_runtime_v1_table_set",
    "luauc_runtime_v1_table_get",
    "luauc_runtime_v1_table_array_set",
    "luauc_runtime_v1_table_array_get",
  ])) throw new Error(`${name}: unexpected mixed-table helper imports ${JSON.stringify(helpers)}`);
  return { objectSize: first.length, functionCount: 3 };
}

async function executeGlobalStatePackage() {
  const name = "global-state-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_GLOBAL_STATE_SOURCE, "LUAUC_GLOBAL_STATE_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/global_state.luau");
  const shape = snapshotShape(snapshot);
  const globalImport = shape.instruction(1, 0);
  const getEnv = shape.instruction(1, 1);
  const getSlot = shape.instruction(1, 2);
  const getMatch = shape.instruction(1, 3);
  const getFallback = shape.instruction(1, 7);
  const setEnv = shape.instruction(1, 22);
  const setSlot = shape.instruction(1, 23);
  const setMatch = shape.instruction(1, 24);
  const readonly = shape.instruction(1, 25);
  const barrier = shape.instruction(1, 28);
  const setFallback = shape.instruction(1, 30);
  if (snapshot.length !== 8309 || shape.protoCount !== 2 || shape.functionCount !== 2 ||
      globalImport.command !== 127 || globalImport.operand(0).kind !== 6 ||
      globalImport.operand(0).value !== 2 || globalImport.operand(1).kind !== 7 ||
      globalImport.operand(1).value !== 1 || globalImport.constant(2).bits !== 0x40000000n ||
      globalImport.constant(3).bits !== 1n ||
      getEnv.command !== 8 || getEnv.operandCount !== 0 || getSlot.command !== 10 ||
      getSlot.operand(0).kind !== 4 || getSlot.operand(0).value !== 1 ||
      getSlot.constant(1).bits !== 2n || getSlot.operand(2).kind !== 7 || getSlot.operand(2).value !== 2 ||
      getMatch.command !== 137 || getMatch.operand(0).value !== 2 || getMatch.operand(1).value !== 2 ||
      getMatch.operand(2).kind !== 5 || getMatch.operand(2).value !== 1 ||
      shape.instruction(1, 4).command !== 7 || shape.instruction(1, 5).command !== 20 ||
      shape.instruction(1, 5).operand(0).value !== 4 || shape.instruction(1, 6).command !== 88 ||
      shape.instruction(1, 6).operand(0).value !== 13 || getFallback.command !== 160 ||
      getFallback.constant(0).bits !== 2n || getFallback.operand(1).value !== 4 ||
      getFallback.operand(2).value !== 2 || shape.instruction(1, 8).command !== 88 ||
      shape.instruction(1, 8).operand(0).value !== 2 || setEnv.command !== 8 ||
      setSlot.command !== 10 || setSlot.constant(1).bits !== 5n || setSlot.operand(2).value !== 2 ||
      setMatch.command !== 137 || setMatch.operand(2).value !== 5 || readonly.command !== 133 ||
      readonly.operand(0).value !== 22 || readonly.operand(1).value !== 5 ||
      shape.instruction(1, 26).command !== 7 || shape.instruction(1, 26).operand(0).value !== 3 ||
      shape.instruction(1, 27).command !== 20 || barrier.command !== 149 ||
      barrier.operand(0).value !== 22 || barrier.operand(1).value !== 3 || barrier.operand(2).kind !== 1 ||
      shape.instruction(1, 29).command !== 88 || shape.instruction(1, 29).operand(0).value !== 6 ||
      setFallback.command !== 161 || setFallback.constant(0).bits !== 5n ||
      setFallback.operand(1).value !== 3 || setFallback.operand(2).value !== 2 ||
      shape.instruction(1, 31).command !== 88 || shape.instruction(1, 31).operand(0).value !== 6)
    throw new Error(`${name}: pinned decoded global get/set IR shape changed`);

  for (let functionId = 0; functionId < 2; functionId++) {
    try {
      backendObject(snapshot, functionId);
    } catch (error) {
      throw new Error(`${name}: function ${functionId} failed standalone lowering`, { cause: error });
    }
  }
  const first = backendStaticPackage(staticPackageFrame("aot_global_state", snapshot));
  const second = backendStaticPackage(staticPackageFrame("aot_global_state", snapshot));
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const key = Buffer.from("aot_global_accumulator");
  if (first.indexOf(key) === -1)
    throw new Error(`${name}: shared global key was not emitted`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(2)));
  const helpers = WebAssembly.Module.imports(module)
    .map(({ name: importName }) => importName)
    .filter((importName) => [
      "luauc_runtime_v1_get_global",
      "luauc_runtime_v1_set_global",
    ].includes(importName));
  if (JSON.stringify(helpers) !== JSON.stringify([
    "luauc_runtime_v1_get_global",
    "luauc_runtime_v1_set_global",
  ])) throw new Error(`${name}: unexpected decoded-global helper imports ${JSON.stringify(helpers)}`);
  return { objectSize: first.length, functionCount: 2 };
}

async function executeFastBuiltinsPackage() {
  const name = "fast-builtins-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_FAST_BUILTINS_SOURCE, "LUAUC_FAST_BUILTINS_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/fast_builtins.luau");
  const shape = snapshotShape(snapshot);
  if (shape.protoCount !== 16 || shape.functionCount !== 16)
    throw new Error(`${name}: expected the complete 16-function builtin capability package`);
  const commandCounts = new Map();
  const safeEnvironmentVmExits = [];
  for (let functionId = 0; functionId < shape.functionCount; functionId++) {
    for (let instructionId = 0; instructionId < shape.instructionCount(functionId); instructionId++) {
      const instruction = shape.instruction(functionId, instructionId);
      const command = instruction.command;
      commandCounts.set(command, (commandCounts.get(command) ?? 0) + 1);
      if (command === 135 && instruction.operand(0).kind === 9) {
        const pc = instruction.operand(0).value;
        safeEnvironmentVmExits.push(
          `${functionId}:${instructionId}/pc${pc}/op${shape.bytecodeWord(functionId, pc) & 0xff}`,
        );
      }
    }
  }
  if (safeEnvironmentVmExits.length)
    throw new Error(`${name}: safe-environment VM exits remain: ${safeEnvironmentVmExits.join(", ")}`);
  for (const [command, label] of [
    [33, "CHECK_DIV_INT64"],
    [99, "STRING_LEN"],
    [120, "FASTCALL"],
    [121, "INVOKE_FASTCALL"],
    [122, "CHECK_FASTCALL_RES"],
    [131, "CHECK_TAG"],
    [132, "CHECK_TRUTHY"],
    [135, "CHECK_SAFE_ENV"],
    [142, "CHECK_CMP_NUM"],
    [143, "CHECK_CMP_INT"],
    [144, "CHECK_CMP_INT64"],
    [146, "CHECK_GC"],
    [154, "CALL fallback"],
    [197, "INVOKE_LIBM"],
    [198, "GET_TYPE"],
    [199, "GET_TYPEOF"],
  ]) {
    if (!commandCounts.get(command))
      throw new Error(`${name}: complete source graph lost ${label}`);
  }

  const failureOperandByCommand = new Map([
    [33, 2],
    [131, 2],
    [132, 2],
    [135, 0],
    [142, 3],
    [143, 3],
    [144, 3],
  ]);
  const guardedSlowArms = new Set();
  const guardedFailureSites = new Map();
  const guardedFallbackCalls = new Map();
  for (let functionId = 0; functionId < shape.functionCount; functionId++) {
    for (let instructionId = 0; instructionId < shape.instructionCount(functionId); instructionId++) {
      const instruction = shape.instruction(functionId, instructionId);
      const failureOperand = failureOperandByCommand.get(instruction.command);
      if (failureOperand === undefined || failureOperand >= instruction.operandCount) continue;
      const failure = instruction.operand(failureOperand);
      if (failure.kind !== 5) continue;
      guardedSlowArms.add(instruction.command);
      if (!guardedFailureSites.has(instruction.command))
        guardedFailureSites.set(instruction.command, failure);
      const fallback = shape.block(functionId, failure.value);
      for (let fallbackId = fallback.start; fallbackId <= fallback.finish; fallbackId++) {
        if (shape.instruction(functionId, fallbackId).command === 154)
          guardedFallbackCalls.set(`${functionId}/${fallbackId}`, { functionId, instructionId: fallbackId });
      }
    }
  }
  for (const command of failureOperandByCommand.keys())
    if (!guardedSlowArms.has(command))
      throw new Error(`${name}: guard ${command} did not target a compiled slow arm`);
  if (guardedFallbackCalls.size === 0)
    throw new Error(`${name}: guarded builtin slow arms contain no real CALL`);
  for (const [command, failure] of guardedFailureSites) {
    const mutated = Buffer.from(snapshot);
    mutated[failure.offset] = 1;
    expectPackageRejection(mutated, `guard ${command} accepted an undefined failure destination`);
  }

  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    for (const fallback of guardedFallbackCalls.values())
      mutated[offsets.instruction(fallback.functionId, fallback.instructionId)] = 0;
    expectPackageRejection(mutated, "guarded builtin slow arms lost every real CALL");
  }

  for (let functionId = 0; functionId < shape.functionCount; functionId++) {
    try {
      backendObject(snapshot, functionId);
    } catch (error) {
      throw new Error(`${name}: function ${functionId} failed standalone lowering`, { cause: error });
    }
  }
  const frame = staticPackageFrame("aot_fast_builtins", snapshot);
  const first = backendStaticPackage(frame);
  const second = backendStaticPackage(frame);
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(shape.functionCount)));
  const imports = new Set(WebAssembly.Module.imports(module).map(({ name: importName }) => importName));
  for (const helper of [
    "luauc_runtime_v1_fastcall",
    "luauc_runtime_v1_libm",
    "luauc_runtime_v1_type_name",
    "luauc_runtime_v1_table_insert_append",
    "luauc_runtime_v1_table_get_string",
  ]) {
    if (!imports.has(helper)) throw new Error(`${name}: linked package lost ${helper}`);
  }
  for (const obsolete of ["luauc_runtime_v1_frexp", "luauc_runtime_v1_sin", "sin"]) {
    if (imports.has(obsolete)) throw new Error(`${name}: obsolete helper import survived: ${obsolete}`);
  }
  return { objectSize: first.length, functionCount: shape.functionCount };
}

async function executeBufferScalarMatrixPackage() {
  const name = "buffer-scalar-matrix-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_BUFFER_SCALAR_MATRIX_SOURCE, "LUAUC_BUFFER_SCALAR_MATRIX_SOURCE"),
    "utf8",
  );
  const firstSnapshot = frontendSnapshot(source, "@aot/buffer_scalar_matrix.luau");
  const secondSnapshot = frontendSnapshot(source, "@aot/buffer_scalar_matrix.luau");
  if (!firstSnapshot.equals(secondSnapshot)) throw new Error(`${name}: frontend snapshot is nondeterministic`);
  const shape = snapshotShape(firstSnapshot);
  if (shape.protoCount !== 9 || shape.functionCount !== 9)
    throw new Error(`${name}: expected the complete nine-function buffer package`);
  const idsFor = (command) => Array.from(
    { length: shape.instructionCount(1) },
    (_, id) => id,
  ).filter((id) => shape.instruction(1, id).command === command);
  for (const [command, minimum] of [
    [201, 1], [202, 1], [203, 1], [204, 1], [205, 1], [206, 1], [207, 2],
    [208, 1], [209, 1], [210, 1], [211, 1], [212, 1], [213, 1], [214, 1],
  ]) {
    if (idsFor(command).length < minimum)
      throw new Error(`${name}: command ${command} count is ${idsFor(command).length}, expected at least ${minimum}`);
  }
  const mergedGuardId = idsFor(140).find((id) => {
    const guard = shape.instruction(1, id);
    return guard.operandCount >= 5 && guard.operand(2).kind === 2 && guard.operand(3).kind === 2;
  });
  const firstWriteId = idsFor(203)[0];
  const firstNumToUintId = idsFor(112)[0];
  if (mergedGuardId === undefined || idsFor(155).length === 0)
    throw new Error(`${name}: dynamic-base guard/conversion/return graph changed`);

  for (let functionId = 0; functionId < 9; functionId++)
    backendObject(firstSnapshot, functionId);

  const offsets = referenceSnapshotOffsets(firstSnapshot);
  {
    const mutated = Buffer.from(firstSnapshot);
    mutated.writeUInt32LE(firstWriteId, offsets.operand(1, mergedGuardId, 4) + 4);
    expectPackageRejection(mutated, "buffer exact-integer guard no longer uses the original base double");
  }
  {
    const mutated = Buffer.from(firstSnapshot);
    mutated.writeUInt32LE(firstWriteId, offsets.operand(1, firstWriteId, 0) + 4);
    expectPackageRejection(mutated, "buffer write no longer uses the guarded buffer pointer");
  }
  {
    const mutated = Buffer.from(firstSnapshot);
    const numberTag = offsets.findConstant(1, 4, 3n);
    mutated.writeUInt32LE(numberTag, offsets.operand(1, firstWriteId, 3) + 4);
    expectPackageRejection(mutated, "buffer write carries NUMBER instead of BUFFER tag");
  }
  {
    const mutated = Buffer.from(firstSnapshot);
    const truncatedRange = offsets.findConstant(1, 0, 19n);
    mutated.writeUInt32LE(truncatedRange, offsets.operand(1, mergedGuardId, 3) + 4);
    expectPackageRejection(mutated, "merged buffer bound no longer covers all 27 packed bytes");
  }
  if (firstNumToUintId !== undefined) {
    const mutated = Buffer.from(firstSnapshot);
    mutated.writeUInt32LE(firstWriteId, offsets.operand(1, firstNumToUintId, 0) + 4);
    expectPackageRejection(mutated, "NUM_TO_UINT no longer consumes its checked runtime value");
  }
  {
    const mutated = Buffer.from(firstSnapshot);
    for (const readI32Id of idsFor(207))
      mutated[offsets.instruction(1, readI32Id)] = 208;
    expectPackageRejection(mutated, "every signed/unsigned read command was replaced by a write command");
  }

  const frame = staticPackageFrame("aot_buffer_scalar_matrix", firstSnapshot);
  const first = backendStaticPackage(frame);
  const second = backendStaticPackage(frame);
  if (!first.equals(second)) throw new Error(`${name}: backend is nondeterministic`);
  const module = await WebAssembly.compile(linkPackage(first, packageFunctionSymbols(9)));
  const imports = WebAssembly.Module.imports(module).map(({ module: importModule, name: importName, kind }) =>
    [importModule, importName, kind]);
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
    ["env", "luauc_runtime_v1_do_arith", "function"],
    ["env", "luauc_runtime_v1_dupclosure", "function"],
    ["env", "luauc_runtime_v1_dupclosure_capture", "function"],
    ["env", "luauc_runtime_v1_get_upvalue", "function"],
    ["env", "luauc_runtime_v1_call", "function"],
    ["env", "luauc_runtime_v1_exchange_continuation", "function"],
    ["env", "luauc_runtime_v1_set_location", "function"],
    ["env", "luauc_runtime_v1_new_table", "function"],
    ["env", "luauc_runtime_v1_load_constant", "function"],
    ["env", "luauc_runtime_v1_table_get_string", "function"],
    ["env", "luauc_runtime_v1_get_global", "function"],
    ["env", "luauc_runtime_v1_prep_varargs", "function"],
    ["env", "luauc_runtime_v1_get_varargs_fixed", "function"],
    ["env", "luauc_runtime_v1_get_varargs_multret", "function"],
    ["env", "luauc_runtime_v1_check_safe_env", "function"],
  ];
  if (JSON.stringify(imports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(imports)}`);
  return { objectSize: first.length, functionCount: 9 };
}

function linkObject(object, name) {
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), `luau-aot-${name}-`));
  const objectPath = join(directory, `${name}.o`);
  const wasmPath = join(directory, `${name}.wasm`);
  writeFileSync(objectPath, object);
  const linked = spawnSync(
    wasmLd,
    [
      "--no-entry",
      "--allow-undefined",
      "--export-memory",
      `--export=${generatedSymbol}`,
      objectPath,
      "-o",
      wasmPath,
    ],
    { encoding: "utf8" },
  );
  if (linked.status !== 0)
    throw new Error(`wasm-ld failed (${linked.status}): ${linked.stdout}\n${linked.stderr}`);
  const bytes = readFileSync(wasmPath);
  rmSync(directory, { recursive: true, force: true });
  return bytes;
}

function linkPackage(object, functionSymbols = packageSymbols, extraExports = []) {
  const directory = mkdtempSync(join(process.env.TEST_TMPDIR || tmpdir(), "luau-aot-package-"));
  const objectPath = join(directory, "package.o");
  const wasmPath = join(directory, "package.wasm");
  writeFileSync(objectPath, object);
  const linked = spawnSync(
    wasmLd,
    [
      "--no-entry",
      "--allow-undefined",
      "--export-memory",
      ...functionSymbols.map((symbol) => `--export=${symbol}`),
      ...extraExports.map((symbol) => `--export=${symbol}`),
      objectPath,
      "-o",
      wasmPath,
    ],
    { encoding: "utf8" },
  );
  if (linked.status !== 0)
    throw new Error(`package wasm-ld failed (${linked.status}): ${linked.stdout}\n${linked.stderr}`);
  const bytes = readFileSync(wasmPath);
  rmSync(directory, { recursive: true, force: true });
  return bytes;
}

async function executeCase(name, source, inputs) {
  const snapshot = frontendSnapshot(source, `@aot/${name}.luau`);
  const functions = snapshotSection(snapshot, 15);
  const constants = snapshotSection(snapshot, 19);
  const functionRecord = functions.offset + functions.recordSize;
  const constantStart = snapshot.readUInt32LE(functionRecord + 40);
  const object = backendObject(snapshot, 1);
  if (!object.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])))
    throw new Error(`${name}: backend did not emit a wasm32 object`);
  const module = await WebAssembly.compile(linkObject(object, name));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module, name: importName, kind }) => [module, importName, kind]);
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
  ];
  expectedImports.push(["env", "luauc_runtime_v1_do_arith", "function"]);
  expectedImports.push(["env", "luauc_runtime_v1_exchange_continuation", "function"]);
  expectedImports.push(["env", "luauc_runtime_v1_set_location", "function"]);
  if (name === "loop")
    expectedImports.push(["env", "luauc_runtime_v1_forn_prepare", "function"]);
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let committed = null;
  let interrupts = 0;
  let continuationState = 0;
  let arithmeticTypeErrors = 0;
  instance = await WebAssembly.instantiate(module, {
    env: {
      luauc_runtime_v1_return(state, sourceRegister, resultCount) {
        if (state !== 1024 || resultCount !== 1) throw new Error(`${name}: wrong return ABI ${state}/${resultCount}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * 16;
        if (view.getUint32(source + 12, true) !== 3)
          throw new Error(`${name}: return helper received non-number register ${sourceRegister}`);
        committed = view.getFloat64(source, true);
      },
      luauc_runtime_v1_set_location() {},
      luauc_runtime_v1_forn_prepare(state, baseRegister) {
        if (state !== 1024) throw new Error(`${name}: invalid numeric loop preparation state`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true) + baseRegister * 16;
        if ([0, 1, 2].every((offset) => view.getUint32(base + offset * 16 + 12, true) === 3))
          throw new Error(`${name}: numeric loop preparation slow arm ran for numeric operands`);
        arithmeticTypeErrors++;
        throw new TypeError(`${name}: numeric loop preparation rejected a non-number operand`);
      },
      luauc_runtime_v1_exchange_continuation(state, nextId) {
        if (state !== 1024) throw new Error(`${name}: invalid continuation state`);
        const previous = continuationState;
        continuationState = nextId;
        return previous;
      },
      luauc_runtime_v1_interrupt(state, pc) {
        if (state !== 1024 || pc < 0) throw new Error(`${name}: invalid interrupt ${state}/${pc}`);
        interrupts++;
        return 0;
      },
      luauc_runtime_v1_do_arith(state, destinationRegister, lhsOperand, rhsOperand, operation) {
        if (state !== 1024) throw new Error(`${name}: invalid arithmetic state`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const numberOperand = (encodedOperand) => {
          const encoded = encodedOperand >>> 0;
          if ((encoded & 0x80000000) === 0) {
            const address = base + encoded * 16;
            if (view.getUint32(address + 12, true) !== 3) {
              arithmeticTypeErrors++;
              throw new TypeError(`${name}: arithmetic runtime rejected non-number register ${encoded}`);
            }
            return view.getFloat64(address, true);
          }

          const constantId = encoded & 0x7fffffff;
          const constantOffset = constants.offset + (constantStart + constantId) * constants.recordSize;
          if (constantId >= snapshot.readUInt32LE(functionRecord + 44) || snapshot[constantOffset] !== 2)
            throw new Error(`${name}: arithmetic operand references non-number constant ${constantId}`);
          return snapshot.readDoubleLE(constantOffset + 8);
        };
        const lhs = numberOperand(lhsOperand);
        const rhs = numberOperand(rhsOperand);
        let result;
        switch (operation >>> 0) {
          case 8: result = lhs + rhs; break;
          case 9: result = lhs - rhs; break;
          case 10: result = lhs * rhs; break;
          case 11: result = lhs / rhs; break;
          case 12: result = Math.floor(lhs / rhs); break;
          case 13: result = lhs - Math.floor(lhs / rhs) * rhs; break;
          case 14: result = lhs ** rhs; break;
          case 15: result = -lhs; break;
          default: throw new Error(`${name}: invalid arithmetic operation ${operation}`);
        }
        const destination = base + (destinationRegister >>> 0) * 16;
        view.setFloat64(destination, result, true);
        view.setUint32(destination + 12, 3, true);
      },
    },
  });
  const generated = instance.exports[generatedSymbol];
  const memory = instance.exports.memory;
  if (typeof generated !== "function" || !(memory instanceof WebAssembly.Memory))
    throw new Error(`${name}: linked generated surface is incomplete`);

  const state = 1024;
  const base = 2048;
  const view = new DataView(memory.buffer);
  view.setUint32(state + 12, base, true);
  for (const [input, expected] of inputs) {
    new Uint8Array(memory.buffer, base, 16 * 8).fill(0);
    view.setFloat64(base, input, true);
    view.setUint32(base + 12, 3, true);
    committed = null;
    const status = generated(state, 0);
    if (status !== 0 || committed !== expected)
      throw new Error(`${name}(${input}): status=${status}, result=${committed}, expected=${expected}`);
  }

  view.setUint32(base + 12, 1, true);
  committed = null;
  let rejected = null;
  let runtimeTypeError = null;
  try {
    rejected = generated(state, 0);
  } catch (error) {
    runtimeTypeError = error;
  }
  if (runtimeTypeError === null) {
    if (rejected !== 1 || committed !== null || arithmeticTypeErrors !== 0)
      throw new Error(`${name}: non-number guard did not fail closed: ${rejected}/${committed}`);
  } else if (!(runtimeTypeError instanceof TypeError) || arithmeticTypeErrors !== 1 || committed !== null) {
    throw new Error(`${name}: generalized arithmetic path raised the wrong error: ${runtimeTypeError}`);
  }
  if (interrupts === 0) throw new Error(`${name}: upstream INTERRUPT instructions were erased`);
  return { objectSize: object.length, interrupts };
}

async function executeSilentRoot() {
  const name = "silent-root";
  const source = readFileSync(
    runfile(process.env.LUAUC_SILENT_SOURCE, "LUAUC_SILENT_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/silent_return.luau");
  const object = backendObject(snapshot, 0);
  const module = await WebAssembly.compile(linkObject(object, name));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module, name: importName, kind }) => [module, importName, kind]);
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
    ["env", "luauc_runtime_v1_exchange_continuation", "function"],
    ["env", "luauc_runtime_v1_prep_varargs", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let committed = null;
  let interrupts = 0;
  let continuationState = 0;
  let instance;
  instance = await WebAssembly.instantiate(module, {
    env: {
      luauc_runtime_v1_prep_varargs(state, fixedParameterCount) {
        if (state !== 1024 || fixedParameterCount !== 0)
          throw new Error(`${name}: wrong PREPVARARGS ABI ${state}/${fixedParameterCount}`);
      },
      luauc_runtime_v1_return(state, sourceRegister, resultCount) {
        if (state !== 1024 || resultCount !== 1) throw new Error(`${name}: wrong return ABI ${state}/${resultCount}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * 16;
        if (view.getUint32(source + 12, true) !== 3)
          throw new Error(`${name}: return helper received non-number register ${sourceRegister}`);
        committed = view.getFloat64(source, true);
      },
      luauc_runtime_v1_set_location() {},
      luauc_runtime_v1_exchange_continuation(state, nextId) {
        if (state !== 1024) throw new Error(`${name}: invalid continuation state`);
        const previous = continuationState;
        continuationState = nextId;
        return previous;
      },
      luauc_runtime_v1_interrupt(state, pc) {
        if (state !== 1024 || pc < 0) throw new Error(`${name}: invalid interrupt ${state}/${pc}`);
        interrupts++;
        return 0;
      },
    },
  });
  const state = 1024;
  const base = 2048;
  new DataView(instance.exports.memory.buffer).setUint32(state + 12, base, true);
  const status = instance.exports[generatedSymbol](state, 0);
  if (status !== 0 || committed !== 30 || interrupts === 0)
    throw new Error(`${name}: status=${status}, result=${committed}, interrupts=${interrupts}`);
  return { objectSize: object.length, interrupts };
}

async function executeSlowAdd() {
  const name = "slow-add";
  const source = readFileSync(
    runfile(process.env.LUAUC_SLOW_ADD_SOURCE, "LUAUC_SLOW_ADD_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/slow_add.luau");
  const object = backendObject(snapshot, 1);
  const module = await WebAssembly.compile(linkObject(object, name));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module, name: importName, kind }) => [module, importName, kind]);
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
    ["env", "luauc_runtime_v1_do_arith", "function"],
    ["env", "luauc_runtime_v1_exchange_continuation", "function"],
    ["env", "luauc_runtime_v1_set_location", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let committed = null;
  let interrupts = 0;
  let helperCalls = 0;
  let continuationState = 0;
  instance = await WebAssembly.instantiate(module, {
    env: {
      luauc_runtime_v1_return(state, sourceRegister, resultCount) {
        if (state !== 1024 || resultCount !== 1) throw new Error(`${name}: wrong return ABI ${state}/${resultCount}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * 16;
        if (view.getUint32(source + 12, true) !== 3)
          throw new Error(`${name}: return helper received non-number register ${sourceRegister}`);
        committed = view.getFloat64(source, true);
      },
      luauc_runtime_v1_set_location() {},
      luauc_runtime_v1_exchange_continuation(state, nextId) {
        if (state !== 1024) throw new Error(`${name}: invalid continuation state`);
        const previous = continuationState;
        continuationState = nextId;
        return previous;
      },
      luauc_runtime_v1_interrupt(state, pc) {
        if (state !== 1024 || pc < 0) throw new Error(`${name}: invalid interrupt ${state}/${pc}`);
        interrupts++;
        return 0;
      },
      luauc_runtime_v1_do_arith(state, destination, lhs, rhs, operation) {
        if (state !== 1024 || destination !== 2 || lhs !== 0 || rhs !== 1 || operation !== 0)
          throw new Error(`${name}: invalid slow helper ABI ${state}/${destination}/${lhs}/${rhs}/${operation}`);
        helperCalls++;
        const view = new DataView(instance.exports.memory.buffer);
        const relocatedBase = 4096;
        view.setFloat64(relocatedBase + destination * 16, 42, true);
        view.setInt32(relocatedBase + destination * 16 + 12, 3, true);
        view.setUint32(state + 12, relocatedBase, true);
      },
    },
  });

  const generated = instance.exports[generatedSymbol];
  const view = new DataView(instance.exports.memory.buffer);
  const state = 1024;
  const base = 2048;

  view.setUint32(state + 12, base, true);
  view.setFloat64(base, 20, true);
  view.setInt32(base + 12, 3, true);
  view.setFloat64(base + 16, 22, true);
  view.setInt32(base + 28, 3, true);
  if (generated(state, 0) !== 0 || committed !== 42 || helperCalls !== 0)
    throw new Error(`${name}: numeric fast path failed: result=${committed}, helpers=${helperCalls}`);

  committed = null;
  view.setUint32(state + 12, base, true);
  view.setInt32(base + 12, 5, true);
  view.setInt32(base + 28, 5, true);
  view.setFloat64(base + 32, -999, true);
  view.setInt32(base + 44, 3, true);
  if (generated(state, 0) !== 0 || committed !== 42 || helperCalls !== 1)
    throw new Error(`${name}: slow rejoin failed: result=${committed}, helpers=${helperCalls}`);
  if (interrupts < 2) throw new Error(`${name}: rejoined paths skipped the shared interrupt block`);

  return { objectSize: object.length, interrupts, helperCalls };
}

async function executeCompiledCallPackage() {
  const name = "compiled-call-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_COMPILED_CALL_SOURCE, "LUAUC_COMPILED_CALL_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/compiled_call.luau");
  const first = backendPackage(snapshot);
  const second = backendPackage(snapshot);
  if (!first.equals(second)) throw new Error(`${name}: package backend is nondeterministic`);

  const module = await WebAssembly.compile(linkPackage(first));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module: importModule, name: importName, kind }) => [importModule, importName, kind]);
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
    ["env", "luauc_runtime_v1_do_arith", "function"],
    ["env", "luauc_runtime_v1_dupclosure", "function"],
    ["env", "luauc_runtime_v1_call", "function"],
    ["env", "luauc_runtime_v1_exchange_continuation", "function"],
    ["env", "luauc_runtime_v1_set_location", "function"],
    ["env", "luauc_runtime_v1_prep_varargs", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let returned = null;
  let interrupts = 0;
  let nestedCalls = 0;
  let continuationState = 0;
  const closureChildren = [];
  const state = 1024;
  const initialBase = 2048;
  const relocatedCallerBase = 4096;
  const childBase = 8192;
  const tvalueSize = 16;
  const writeNumber = (view, base, register, value) => {
    view.setFloat64(base + register * tvalueSize, value, true);
    view.setUint32(base + register * tvalueSize + 12, 3, true);
  };

  instance = await WebAssembly.instantiate(module, {
    env: {
      luauc_runtime_v1_prep_varargs(state, fixedParameterCount) {
        if (state !== 1024 || fixedParameterCount !== 0)
          throw new Error(`${name}: wrong PREPVARARGS ABI ${state}/${fixedParameterCount}`);
      },
      luauc_runtime_v1_return(returnState, sourceRegister, resultCount) {
        if (returnState !== state || resultCount !== 1)
          throw new Error(`${name}: wrong return ABI ${returnState}/${resultCount}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * tvalueSize;
        const tag = view.getUint32(source + 12, true);
        returned = tag === 3
          ? { tag, value: view.getFloat64(source, true) }
          : { tag, value: view.getUint32(source, true) };
      },
      luauc_runtime_v1_set_location() {},
      luauc_runtime_v1_interrupt(interruptState, pc) {
        if (interruptState !== state || pc < 0) throw new Error(`${name}: invalid interrupt`);
        interrupts++;
        return 0;
      },
      luauc_runtime_v1_do_arith() {
        throw new Error(`${name}: numeric package unexpectedly entered arithmetic fallback`);
      },
      luauc_runtime_v1_dupclosure(closureState, destinationRegister, childProtoId) {
        if (closureState !== state || (childProtoId !== 1 && childProtoId !== 2))
          throw new Error(`${name}: invalid child closure ${closureState}/${childProtoId}`);
        closureChildren.push(childProtoId);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const destination = base + destinationRegister * tvalueSize;
        view.setUint32(destination, childProtoId, true);
        view.setUint32(destination + 12, 6, true);
      },
      luauc_runtime_v1_exchange_continuation(exchangeState, nextId) {
        if (exchangeState !== state) throw new Error(`${name}: invalid continuation state`);
        const previous = continuationState;
        continuationState = nextId;
        return previous;
      },
      luauc_runtime_v1_call(callState, functionRegister, parameterCount, resultCount) {
        if (callState !== state || functionRegister !== 3 || parameterCount !== 2 || resultCount !== 1)
          throw new Error(`${name}: invalid fixed call ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        const functionSlot = callerBase + functionRegister * tvalueSize;
        if (view.getUint32(functionSlot + 12, true) !== 6 || view.getUint32(functionSlot, true) !== 2)
          throw new Error(`${name}: caller did not materialize child Proto 2`);

        memory.set(memory.subarray(callerBase, callerBase + 6 * tvalueSize), relocatedCallerBase);
        memory.fill(0, childBase, childBase + 3 * tvalueSize);
        memory.set(
          memory.subarray(relocatedCallerBase + 4 * tvalueSize, relocatedCallerBase + 6 * tvalueSize),
          childBase,
        );
        view.setUint32(state + 12, childBase, true);
        returned = null;
        const callerContinuation = continuationState;
        continuationState = 0;
        const childStatus = instance.exports[packageSymbols[2]](state, 0);
        const childContinuation = continuationState;
        continuationState = callerContinuation;
        if (childStatus !== 0 || childContinuation !== 0 || returned?.tag !== 3)
          throw new Error(`${name}: nested child failed with ${childStatus}/${childContinuation}/${JSON.stringify(returned)}`);

        const childResult = returned.value;
        view.setUint32(state + 12, relocatedCallerBase, true);
        writeNumber(view, relocatedCallerBase, functionRegister, childResult);
        nestedCalls++;
        return 0;
      },
    },
  });

  for (const symbol of packageSymbols) {
    if (typeof instance.exports[symbol] !== "function")
      throw new Error(`${name}: missing generated symbol ${symbol}`);
  }

  const view = new DataView(instance.exports.memory.buffer);
  view.setUint32(state + 12, initialBase, true);
  new Uint8Array(instance.exports.memory.buffer, initialBase, tvalueSize).fill(0);
  if (instance.exports[packageSymbols[0]](state, 0) !== 0 || returned?.tag !== 6 || returned.value !== 1)
    throw new Error(`${name}: root did not return child Proto 1 closure: ${JSON.stringify(returned)}`);

  for (const [lhs, rhs, expected] of [[20, 22, 42], [-50, 8, -42], [1234, 5678, 6912]]) {
    new Uint8Array(instance.exports.memory.buffer, initialBase, 6 * tvalueSize).fill(0);
    view.setUint32(state + 12, initialBase, true);
    writeNumber(view, initialBase, 0, lhs);
    writeNumber(view, initialBase, 1, rhs);
    returned = null;
    const status = instance.exports[packageSymbols[1]](state, 0);
    if (status !== 0 || returned?.tag !== 3 || returned.value !== expected)
      throw new Error(`${name}: caller ${lhs}/${rhs} failed with ${status}/${JSON.stringify(returned)}`);
  }
  if (nestedCalls !== 3 || closureChildren.join(",") !== "1,2,2,2" || interrupts < 7)
    throw new Error(`${name}: execution evidence incomplete: calls=${nestedCalls}, closures=${closureChildren}, interrupts=${interrupts}`);
  return { objectSize: first.length, nestedCalls, interrupts };
}

async function executeCapturedCallPackage() {
  const name = "captured-call-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_CAPTURED_CALL_SOURCE, "LUAUC_CAPTURED_CALL_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/captured_call.luau");
  const first = backendPackage(snapshot);
  const second = backendPackage(snapshot);
  if (!first.equals(second)) throw new Error(`${name}: package backend is nondeterministic`);

  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.block0 + 4);
    expectPackageRejection(mutated, "closure cluster crosses its bytecode-block boundary");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated.writeUInt32LE(offsets.findConstant(2, 1n), offsets.operand(9, 1) + 4);
    expectPackageRejection(mutated, "LCT_REF replaces the sole LCT_VAL capture");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.operand(6, 1) + 4);
    expectPackageRejection(mutated, "child upvalue slot is not U0");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated[offsets.instruction(8)] = 152;
    mutated[offsets.instruction(9)] = 146;
    expectPackageRejection(mutated, "CHECK_GC occurs after the CAPTURE marker");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = capturedSnapshotOffsets(mutated);
    mutated[offsets.proto2 + 29] = 2;
    expectPackageRejection(mutated, "child declares more than one upvalue");
  }

  const module = await WebAssembly.compile(linkPackage(first));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module: importModule, name: importName, kind }) => [importModule, importName, kind]);
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
    ["env", "luauc_runtime_v1_do_arith", "function"],
    ["env", "luauc_runtime_v1_dupclosure", "function"],
    ["env", "luauc_runtime_v1_newclosure_capture", "function"],
    ["env", "luauc_runtime_v1_get_upvalue", "function"],
    ["env", "luauc_runtime_v1_call", "function"],
    ["env", "luauc_runtime_v1_exchange_continuation", "function"],
    ["env", "luauc_runtime_v1_set_location", "function"],
    ["env", "luauc_runtime_v1_prep_varargs", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let returned = null;
  let capturedValue = null;
  let interrupts = 0;
  let nestedCalls = 0;
  let continuationState = 0;
  let captureCount = 0;
  const closureChildren = [];
  const state = 1024;
  const initialBase = 2048;
  const relocatedCallerBase = 4096;
  const childBase = 8192;
  const finalCallerBase = 12288;
  const tvalueSize = 16;
  const writeNumber = (view, base, register, value) => {
    view.setFloat64(base + register * tvalueSize, value, true);
    view.setUint32(base + register * tvalueSize + 12, 3, true);
  };
  const writeClosure = (view, base, register, childProtoId) => {
    view.setUint32(base + register * tvalueSize, childProtoId, true);
    view.setUint32(base + register * tvalueSize + 12, 6, true);
  };

  instance = await WebAssembly.instantiate(module, {
    env: {
      luauc_runtime_v1_prep_varargs(state, fixedParameterCount) {
        if (state !== 1024 || fixedParameterCount !== 0)
          throw new Error(`${name}: wrong PREPVARARGS ABI ${state}/${fixedParameterCount}`);
      },
      luauc_runtime_v1_return(returnState, sourceRegister, resultCount) {
        if (returnState !== state || resultCount !== 1)
          throw new Error(`${name}: wrong return ABI ${returnState}/${resultCount}`);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        const source = base + sourceRegister * tvalueSize;
        const tag = view.getUint32(source + 12, true);
        returned = tag === 3
          ? { tag, value: view.getFloat64(source, true) }
          : { tag, value: view.getUint32(source, true) };
      },
      luauc_runtime_v1_set_location() {},
      luauc_runtime_v1_interrupt(interruptState, pc) {
        if (interruptState !== state || pc < 0) throw new Error(`${name}: invalid interrupt`);
        interrupts++;
        return 0;
      },
      luauc_runtime_v1_do_arith() {
        throw new Error(`${name}: numeric capture unexpectedly entered arithmetic fallback`);
      },
      luauc_runtime_v1_dupclosure(closureState, destinationRegister, childProtoId) {
        if (closureState !== state || childProtoId !== 1)
          throw new Error(`${name}: invalid closed child ${closureState}/${childProtoId}`);
        closureChildren.push(childProtoId);
        const view = new DataView(instance.exports.memory.buffer);
        writeClosure(view, view.getUint32(state + 12, true), destinationRegister, childProtoId);
      },
      luauc_runtime_v1_newclosure_capture(closureState, destinationRegister, childProtoId, captureIndex, captureKind, captureRegister, checkGc) {
        if (closureState !== state || destinationRegister !== 2 || childProtoId !== 2 ||
            captureIndex !== 0 || captureKind !== 0 || captureRegister !== 0 || checkGc !== 1)
          throw new Error(`${name}: invalid value closure ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        if (view.getUint32(callerBase + captureRegister * tvalueSize + 12, true) !== 3)
          throw new Error(`${name}: value closure did not capture a number`);
        capturedValue = view.getFloat64(callerBase + captureRegister * tvalueSize, true);
        memory.set(memory.subarray(callerBase, callerBase + 5 * tvalueSize), relocatedCallerBase);
        writeClosure(view, relocatedCallerBase, destinationRegister, childProtoId);
        view.setUint32(state + 12, relocatedCallerBase, true);
        closureChildren.push(childProtoId);
        captureCount++;
      },
      luauc_runtime_v1_get_upvalue(upvalueState, destinationRegister, upvalueIndex) {
        if (upvalueState !== state || destinationRegister !== 2 || upvalueIndex !== 0 || capturedValue === null)
          throw new Error(`${name}: invalid value upvalue ABI`);
        const view = new DataView(instance.exports.memory.buffer);
        writeNumber(view, view.getUint32(state + 12, true), destinationRegister, capturedValue);
      },
      luauc_runtime_v1_exchange_continuation(exchangeState, nextId) {
        if (exchangeState !== state) throw new Error(`${name}: invalid continuation state`);
        const previous = continuationState;
        continuationState = nextId;
        return previous;
      },
      luauc_runtime_v1_call(callState, functionRegister, parameterCount, resultCount) {
        if (callState !== state || functionRegister !== 3 || parameterCount !== 1 || resultCount !== 1)
          throw new Error(`${name}: invalid fixed call ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        if (callerBase !== relocatedCallerBase || view.getUint32(callerBase + functionRegister * tvalueSize + 12, true) !== 6 ||
            view.getUint32(callerBase + functionRegister * tvalueSize, true) !== 2)
          throw new Error(`${name}: generated code did not reload/copy the captured closure`);

        memory.set(memory.subarray(callerBase, callerBase + 5 * tvalueSize), finalCallerBase);
        memory.fill(0, childBase, childBase + 3 * tvalueSize);
        memory.set(
          memory.subarray(finalCallerBase + 4 * tvalueSize, finalCallerBase + 5 * tvalueSize),
          childBase,
        );
        view.setUint32(state + 12, childBase, true);
        returned = null;
        const callerContinuation = continuationState;
        continuationState = 0;
        const childStatus = instance.exports[packageSymbols[2]](state, 0);
        const childContinuation = continuationState;
        continuationState = callerContinuation;
        if (childStatus !== 0 || childContinuation !== 0 || returned?.tag !== 3)
          throw new Error(`${name}: captured child failed with ${childStatus}/${childContinuation}/${JSON.stringify(returned)}`);

        const childResult = returned.value;
        view.setUint32(state + 12, finalCallerBase, true);
        writeNumber(view, finalCallerBase, functionRegister, childResult);
        nestedCalls++;
        return 0;
      },
    },
  });

  for (const symbol of packageSymbols) {
    if (typeof instance.exports[symbol] !== "function")
      throw new Error(`${name}: missing generated symbol ${symbol}`);
  }

  const memory = new Uint8Array(instance.exports.memory.buffer);
  const view = new DataView(memory.buffer);
  view.setUint32(state + 12, initialBase, true);
  memory.fill(0, initialBase, initialBase + tvalueSize);
  if (instance.exports[packageSymbols[0]](state, 0) !== 0 || returned?.tag !== 6 || returned.value !== 1)
    throw new Error(`${name}: root did not return child Proto 1 closure: ${JSON.stringify(returned)}`);

  for (const [lhs, rhs, expected] of [[20, 22, 42], [-50, 8, -42], [1234, 5678, 6912]]) {
    memory.fill(0, initialBase, finalCallerBase + 5 * tvalueSize);
    view.setUint32(state + 12, initialBase, true);
    writeNumber(view, initialBase, 0, lhs);
    writeNumber(view, initialBase, 1, rhs);
    capturedValue = null;
    returned = null;
    const status = instance.exports[packageSymbols[1]](state, 0);
    if (status !== 0 || returned?.tag !== 3 || returned.value !== expected)
      throw new Error(`${name}: caller ${lhs}/${rhs} failed with ${status}/${JSON.stringify(returned)}`);
  }
  if (nestedCalls !== 3 || captureCount !== 3 || closureChildren.join(",") !== "1,2,2,2" || interrupts < 7)
    throw new Error(`${name}: execution evidence incomplete: calls=${nestedCalls}, captures=${captureCount}, closures=${closureChildren}, interrupts=${interrupts}`);
  return { objectSize: first.length, nestedCalls, captureCount, interrupts };
}

async function executeReferenceCapturePackage() {
  const name = "reference-capture-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_REFERENCE_CAPTURE_SOURCE, "LUAUC_REFERENCE_CAPTURE_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/reference_capture.luau");
  const first = backendPackage(snapshot);
  const second = backendPackage(snapshot);
  if (!first.equals(second)) throw new Error(`${name}: package backend is nondeterministic`);

  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(12, offsets.block(1, 0) + 4);
    expectPackageRejection(mutated, "reference closure cluster is truncated at its block boundary");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(offsets.findConstant(1, 2, 0n), offsets.operand(1, 12, 1) + 4);
    expectPackageRejection(mutated, "LCT_VAL replaces the required LCT_REF capture");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(0, offsets.operand(1, 7, 0) + 4);
    expectPackageRejection(mutated, "FINDUPVAL uses a different register from CAPTURE/CLOSE_UPVALS");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.operand(1, 8, 1) + 4);
    expectPackageRejection(mutated, "reference capture targets child upvalue U1");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(offsets.findConstant(1, 4, 8n), offsets.operand(1, 10, 1) + 4);
    expectPackageRejection(mutated, "reference upvalue publication uses a closure tag instead of LUA_TUPVAL");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated[offsets.instruction(1, 11)] = 152;
    mutated[offsets.instruction(1, 12)] = 146;
    expectPackageRejection(mutated, "CHECK_GC occurs after the reference CAPTURE marker");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated[offsets.proto(2) + 29] = 2;
    expectPackageRejection(mutated, "reference child declares more than one upvalue");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.operand(2, 15, 0) + 4);
    expectPackageRejection(mutated, "SET_UPVALUE targets U1");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(1, offsets.operand(2, 15, 2) + 4);
    expectPackageRejection(mutated, "SET_UPVALUE carries a non-undef tag operand");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(0, offsets.operand(2, 15, 1) + 4);
    expectPackageRejection(mutated, "SET_UPVALUE no longer consumes its adjacent LOAD_TVALUE");
  }
  {
    const mutated = Buffer.from(snapshot);
    const offsets = referenceSnapshotOffsets(mutated);
    mutated.writeUInt32LE(15, offsets.block(2, 2));
    expectPackageRejection(mutated, "LOAD_TVALUE and SET_UPVALUE cross a block boundary");
  }

  const module = await WebAssembly.compile(linkPackage(first));
  const moduleImports = WebAssembly.Module.imports(module).map(
    ({ module: importModule, name: importName, kind }) => [importModule, importName, kind],
  );
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
    ["env", "luauc_runtime_v1_do_arith", "function"],
    ["env", "luauc_runtime_v1_dupclosure", "function"],
    ["env", "luauc_runtime_v1_newclosure_capture", "function"],
    ["env", "luauc_runtime_v1_get_upvalue", "function"],
    ["env", "luauc_runtime_v1_set_upvalue", "function"],
    ["env", "luauc_runtime_v1_close_upvalues", "function"],
    ["env", "luauc_runtime_v1_exchange_continuation", "function"],
    ["env", "luauc_runtime_v1_set_location", "function"],
    ["env", "luauc_runtime_v1_prep_varargs", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let returned = null;
  let activeClosureId = null;
  let nextClosureId = 1;
  let nextCellAddress = 16384;
  let interrupts = 0;
  let referenceClosures = 0;
  let closes = 0;
  let upvalueReads = 0;
  let upvalueWrites = 0;
  let continuationState = 0;
  const closures = new Map();
  const cells = new Map();
  const state = 1024;
  const initialBase = 2048;
  const relocatedFactoryBase = 4096;
  const childBase = 8192;
  const tvalueSize = 16;
  const writeNumber = (view, base, register, value) => {
    view.setFloat64(base + register * tvalueSize, value, true);
    view.setUint32(base + register * tvalueSize + 12, 3, true);
  };
  const readValue = (view, base, register) => {
    const address = base + register * tvalueSize;
    const tag = view.getUint32(address + 12, true);
    return { tag, value: tag === 3 ? view.getFloat64(address, true) : view.getUint32(address, true) };
  };
  const publishClosure = (view, base, register, protoId, cellAddress = null) => {
    const closureId = nextClosureId++;
    closures.set(closureId, { protoId, cellAddress });
    view.setUint32(base + register * tvalueSize, closureId, true);
    view.setUint32(base + register * tvalueSize + 12, 6, true);
    return closureId;
  };

  instance = await WebAssembly.instantiate(module, {
    env: {
      luauc_runtime_v1_prep_varargs(state, fixedParameterCount) {
        if (state !== 1024 || fixedParameterCount !== 0)
          throw new Error(`${name}: wrong PREPVARARGS ABI ${state}/${fixedParameterCount}`);
      },
      luauc_runtime_v1_return(returnState, sourceRegister, resultCount) {
        if (returnState !== state || resultCount !== 1)
          throw new Error(`${name}: invalid fixed return ${returnState}/${sourceRegister}/${resultCount}`);
        const view = new DataView(instance.exports.memory.buffer);
        returned = readValue(view, view.getUint32(state + 12, true), sourceRegister);
      },
      luauc_runtime_v1_set_location() {},
      luauc_runtime_v1_exchange_continuation(exchangeState, nextId) {
        if (exchangeState !== state) throw new Error(`${name}: invalid continuation state`);
        const previous = continuationState;
        continuationState = nextId;
        return previous;
      },
      luauc_runtime_v1_interrupt(interruptState, pc) {
        if (interruptState !== state || pc < 0) throw new Error(`${name}: invalid interrupt`);
        interrupts++;
        return 0;
      },
      luauc_runtime_v1_do_arith() {
        throw new Error(`${name}: numeric mutation unexpectedly entered arithmetic fallback`);
      },
      luauc_runtime_v1_dupclosure(closureState, destinationRegister, childProtoId) {
        if (closureState !== state || childProtoId !== 1)
          throw new Error(`${name}: invalid root closure ${closureState}/${childProtoId}`);
        const view = new DataView(instance.exports.memory.buffer);
        publishClosure(view, view.getUint32(state + 12, true), destinationRegister, childProtoId);
      },
      luauc_runtime_v1_newclosure_capture(closureState, destinationRegister, childProtoId, captureIndex, captureKind, captureRegister, checkGc) {
        if (closureState !== state || destinationRegister !== 2 || childProtoId !== 2 ||
            captureIndex !== 0 || captureKind !== 1 || captureRegister !== 1 || checkGc !== 1)
          throw new Error(`${name}: invalid reference closure ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        const captured = readValue(view, callerBase, captureRegister);
        if (captured.tag !== 3) throw new Error(`${name}: reference capture is not numeric`);

        memory.set(memory.subarray(callerBase, callerBase + 3 * tvalueSize), relocatedFactoryBase);
        const cellAddress = nextCellAddress;
        nextCellAddress += tvalueSize;
        cells.set(cellAddress, {
          open: true,
          stackAddress: relocatedFactoryBase + captureRegister * tvalueSize,
        });
        publishClosure(view, relocatedFactoryBase, destinationRegister, childProtoId, cellAddress);
        view.setUint32(state + 12, relocatedFactoryBase, true);
        referenceClosures++;
      },
      luauc_runtime_v1_get_upvalue(upvalueState, destinationRegister, upvalueIndex) {
        if (upvalueState !== state || destinationRegister !== 1 || upvalueIndex !== 0)
          throw new Error(`${name}: invalid upvalue read ABI`);
        const closure = closures.get(activeClosureId);
        const cell = closure && cells.get(closure.cellAddress);
        if (!cell || cell.open) throw new Error(`${name}: read did not use a closed UpVal cell`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const base = view.getUint32(state + 12, true);
        memory.set(memory.subarray(closure.cellAddress, closure.cellAddress + tvalueSize), base + destinationRegister * tvalueSize);
        upvalueReads++;
      },
      luauc_runtime_v1_set_upvalue(upvalueState, upvalueIndex, sourceRegister) {
        if (upvalueState !== state || upvalueIndex !== 0 || sourceRegister !== 1)
          throw new Error(`${name}: invalid upvalue write ABI`);
        const closure = closures.get(activeClosureId);
        const cell = closure && cells.get(closure.cellAddress);
        if (!cell || cell.open) throw new Error(`${name}: write did not use a closed UpVal cell`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const base = view.getUint32(state + 12, true);
        memory.set(memory.subarray(base + sourceRegister * tvalueSize, base + (sourceRegister + 1) * tvalueSize), closure.cellAddress);
        upvalueWrites++;
      },
      luauc_runtime_v1_close_upvalues(closeState, firstRegister) {
        if (closeState !== state || firstRegister !== 1)
          throw new Error(`${name}: invalid close ABI ${closeState}/${firstRegister}`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const stackAddress = view.getUint32(state + 12, true) + firstRegister * tvalueSize;
        const entry = [...cells.entries()].find(([, cell]) => cell.open && cell.stackAddress === stackAddress);
        if (!entry) throw new Error(`${name}: close did not find its open UpVal`);
        const [cellAddress, cell] = entry;
        memory.set(memory.subarray(stackAddress, stackAddress + tvalueSize), cellAddress);
        cell.open = false;
        cell.stackAddress = null;
        closes++;
      },
    },
  });

  for (const symbol of packageSymbols) {
    if (typeof instance.exports[symbol] !== "function")
      throw new Error(`${name}: missing generated symbol ${symbol}`);
  }

  const memory = new Uint8Array(instance.exports.memory.buffer);
  const view = new DataView(memory.buffer);
  const runRoot = () => {
    memory.fill(0, initialBase, initialBase + tvalueSize);
    view.setUint32(state + 12, initialBase, true);
    returned = null;
    if (instance.exports[packageSymbols[0]](state, 0) !== 0 || returned?.tag !== 6)
      throw new Error(`${name}: root did not return its factory: ${JSON.stringify(returned)}`);
    const closure = closures.get(returned.value);
    if (closure?.protoId !== 1 || closure.cellAddress !== null)
      throw new Error(`${name}: root returned an invalid factory closure`);
    return returned.value;
  };
  const runFactory = (factoryId, initial) => {
    memory.fill(0, initialBase, initialBase + 3 * tvalueSize);
    view.setUint32(state + 12, initialBase, true);
    writeNumber(view, initialBase, 0, initial);
    activeClosureId = factoryId;
    returned = null;
    if (instance.exports[packageSymbols[1]](state, factoryId) !== 0 || returned?.tag !== 6)
      throw new Error(`${name}: factory(${initial}) failed: ${JSON.stringify(returned)}`);
    const closure = closures.get(returned.value);
    const cell = closure && cells.get(closure.cellAddress);
    if (closure?.protoId !== 2 || !cell || cell.open)
      throw new Error(`${name}: factory returned a closure without a closed reference cell`);
    return returned.value;
  };
  const runAccumulator = (closureId, delta, expected) => {
    memory.fill(0, childBase, childBase + 2 * tvalueSize);
    view.setUint32(state + 12, childBase, true);
    writeNumber(view, childBase, 0, delta);
    activeClosureId = closureId;
    returned = null;
    const status = instance.exports[packageSymbols[2]](state, closureId);
    if (status !== 0 || returned?.tag !== 3 || returned.value !== expected)
      throw new Error(`${name}: accumulator(${delta}) failed with ${status}/${JSON.stringify(returned)}, expected ${expected}`);
  };

  const factory = runRoot();
  const firstAccumulator = runFactory(factory, 10);
  runAccumulator(firstAccumulator, 5, 15);
  runAccumulator(firstAccumulator, -2, 13);
  const secondAccumulator = runFactory(factory, -3);
  runAccumulator(secondAccumulator, 8, 5);
  runAccumulator(firstAccumulator, 4, 17);

  if (referenceClosures !== 2 || closes !== 2 || upvalueReads !== 4 || upvalueWrites !== 4 || interrupts < 7)
    throw new Error(
      `${name}: evidence incomplete: closures=${referenceClosures}, closes=${closes}, ` +
      `reads=${upvalueReads}, writes=${upvalueWrites}, interrupts=${interrupts}`,
    );
  return { objectSize: first.length, referenceClosures, closes, upvalueWrites, interrupts };
}

async function executeMultiResultCallPackage() {
  const name = "multi-result-call-package";
  const source = readFileSync(
    runfile(process.env.LUAUC_MULTI_RESULT_CALL_SOURCE, "LUAUC_MULTI_RESULT_CALL_SOURCE"),
    "utf8",
  );
  const snapshot = frontendSnapshot(source, "@aot/multi_result_call.luau");
  const first = backendPackage(snapshot);
  const second = backendPackage(snapshot);
  if (!first.equals(second)) throw new Error(`${name}: package backend is nondeterministic`);

  const module = await WebAssembly.compile(linkPackage(first));
  const moduleImports = WebAssembly.Module.imports(module).map(({ module: importModule, name: importName, kind }) => [importModule, importName, kind]);
  const expectedImports = [
    ["env", "luauc_runtime_v1_return", "function"],
    ["env", "luauc_runtime_v1_interrupt", "function"],
    ["env", "luauc_runtime_v1_do_arith", "function"],
    ["env", "luauc_runtime_v1_dupclosure", "function"],
    ["env", "luauc_runtime_v1_call", "function"],
    ["env", "luauc_runtime_v1_exchange_continuation", "function"],
    ["env", "luauc_runtime_v1_set_location", "function"],
    ["env", "luauc_runtime_v1_prep_varargs", "function"],
  ];
  if (JSON.stringify(moduleImports) !== JSON.stringify(expectedImports))
    throw new Error(`${name}: unexpected generated imports ${JSON.stringify(moduleImports)}`);

  let instance;
  let returned = [];
  let interrupts = 0;
  let nestedCalls = 0;
  let pairReturns = 0;
  let continuationState = 0;
  const closureChildren = [];
  const state = 1024;
  const initialBase = 2048;
  const relocatedCallerBase = 4096;
  const childBase = 8192;
  const tvalueSize = 16;
  const readValue = (view, base, register) => {
    const address = base + register * tvalueSize;
    const tag = view.getUint32(address + 12, true);
    return { tag, value: tag === 3 ? view.getFloat64(address, true) : view.getUint32(address, true) };
  };
  const writeNumber = (view, base, register, value) => {
    view.setFloat64(base + register * tvalueSize, value, true);
    view.setUint32(base + register * tvalueSize + 12, 3, true);
  };

  instance = await WebAssembly.instantiate(module, {
    env: {
      luauc_runtime_v1_prep_varargs(state, fixedParameterCount) {
        if (state !== 1024 || fixedParameterCount !== 0)
          throw new Error(`${name}: wrong PREPVARARGS ABI ${state}/${fixedParameterCount}`);
      },
      luauc_runtime_v1_return(returnState, sourceRegister, resultCount) {
        if (returnState !== state || (resultCount !== 1 && resultCount !== 2))
          throw new Error(`${name}: invalid fixed return ${returnState}/${sourceRegister}/${resultCount}`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const base = view.getUint32(state + 12, true);
        const sourceAddress = base + sourceRegister * tvalueSize;
        memory.copyWithin(base, sourceAddress, sourceAddress + resultCount * tvalueSize);
        returned = Array.from({ length: resultCount }, (_, register) => readValue(view, base, register));
        if (resultCount === 2) pairReturns++;
      },
      luauc_runtime_v1_set_location() {},
      luauc_runtime_v1_interrupt(interruptState, pc) {
        if (interruptState !== state || pc < 0) throw new Error(`${name}: invalid interrupt`);
        interrupts++;
        return 0;
      },
      luauc_runtime_v1_do_arith() {
        throw new Error(`${name}: numeric package unexpectedly entered arithmetic fallback`);
      },
      luauc_runtime_v1_dupclosure(closureState, destinationRegister, childProtoId) {
        if (closureState !== state || (childProtoId !== 1 && childProtoId !== 2))
          throw new Error(`${name}: invalid child closure ${closureState}/${childProtoId}`);
        closureChildren.push(childProtoId);
        const view = new DataView(instance.exports.memory.buffer);
        const base = view.getUint32(state + 12, true);
        view.setUint32(base + destinationRegister * tvalueSize, childProtoId, true);
        view.setUint32(base + destinationRegister * tvalueSize + 12, 6, true);
      },
      luauc_runtime_v1_exchange_continuation(exchangeState, nextId) {
        if (exchangeState !== state) throw new Error(`${name}: invalid continuation state`);
        const previous = continuationState;
        continuationState = nextId;
        return previous;
      },
      luauc_runtime_v1_call(callState, functionRegister, parameterCount, resultCount) {
        if (callState !== state || functionRegister !== 3 || parameterCount !== 2 || resultCount !== 2)
          throw new Error(`${name}: invalid fixed call ABI`);
        const memory = new Uint8Array(instance.exports.memory.buffer);
        const view = new DataView(memory.buffer);
        const callerBase = view.getUint32(state + 12, true);
        const functionValue = readValue(view, callerBase, functionRegister);
        if (functionValue.tag !== 6 || functionValue.value !== 2)
          throw new Error(`${name}: caller did not materialize child Proto 2`);

        memory.set(memory.subarray(callerBase, callerBase + 6 * tvalueSize), relocatedCallerBase);
        memory.fill(0, childBase, childBase + 4 * tvalueSize);
        memory.set(
          memory.subarray(relocatedCallerBase + 4 * tvalueSize, relocatedCallerBase + 6 * tvalueSize),
          childBase,
        );
        view.setUint32(state + 12, childBase, true);
        returned = [];
        const callerContinuation = continuationState;
        continuationState = 0;
        const childStatus = instance.exports[packageSymbols[2]](state, 0);
        const childContinuation = continuationState;
        continuationState = callerContinuation;
        if (childStatus !== 0 || childContinuation !== 0 || returned.length !== 2 || returned.some((value) => value.tag !== 3))
          throw new Error(`${name}: nested pair failed with ${childStatus}/${childContinuation}/${JSON.stringify(returned)}`);

        view.setUint32(state + 12, relocatedCallerBase, true);
        writeNumber(view, relocatedCallerBase, functionRegister, returned[0].value);
        writeNumber(view, relocatedCallerBase, functionRegister + 1, returned[1].value);
        nestedCalls++;
        return 0;
      },
    },
  });

  const memory = new Uint8Array(instance.exports.memory.buffer);
  const view = new DataView(memory.buffer);
  view.setUint32(state + 12, initialBase, true);
  memory.fill(0, initialBase, initialBase + tvalueSize);
  if (instance.exports[packageSymbols[0]](state, 0) !== 0 || returned.length !== 1 ||
      returned[0].tag !== 6 || returned[0].value !== 1)
    throw new Error(`${name}: root did not return child Proto 1 closure: ${JSON.stringify(returned)}`);

  for (const [lhs, rhs, expected] of [[20, 22, 62], [-50, 8, -92], [1234, 5678, 8146]]) {
    memory.fill(0, initialBase, relocatedCallerBase + 6 * tvalueSize);
    view.setUint32(state + 12, initialBase, true);
    writeNumber(view, initialBase, 0, lhs);
    writeNumber(view, initialBase, 1, rhs);
    returned = [];
    const status = instance.exports[packageSymbols[1]](state, 0);
    if (status !== 0 || returned.length !== 1 || returned[0].tag !== 3 || returned[0].value !== expected)
      throw new Error(`${name}: caller ${lhs}/${rhs} failed with ${status}/${JSON.stringify(returned)}`);
  }
  if (nestedCalls !== 3 || pairReturns !== 3 || closureChildren.join(",") !== "1,2,2,2" || interrupts < 10)
    throw new Error(`${name}: evidence incomplete: calls=${nestedCalls}, pairs=${pairReturns}, closures=${closureChildren}, interrupts=${interrupts}`);
  return { objectSize: first.length, nestedCalls, pairReturns, interrupts };
}

async function executeProtoIdentityControlPackageShape() {
  const name = "Proto identity control";
  const source = readFileSync(
    runfile(process.env.LUAUC_PROTO_IDENTITY_SOURCE, "LUAUC_PROTO_IDENTITY_SOURCE"),
    "utf8",
  );
  const plan = [{ callerFunctionId: 2, feedbackSlot: 0, targetFunctionId: 0 }];
  const firstSnapshot = frontendSnapshot(source, "@proto_identity.luau", 0, plan);
  const secondSnapshot = frontendSnapshot(source, "@proto_identity.luau", 0, plan);
  if (!firstSnapshot.equals(secondSnapshot)) throw new Error(`${name}: frontend snapshot is nondeterministic`);

  const shape = snapshotShape(firstSnapshot);
  if (shape.protoCount !== 5 || shape.functionCount !== 5)
    throw new Error(`${name}: expected five Protos/functions, got ${shape.protoCount}/${shape.functionCount}`);
  let identityJump = null;
  for (let functionId = 0; functionId < shape.functionCount; functionId++) {
    for (let instructionId = 0; instructionId < shape.instructionCount(functionId); instructionId++) {
      const instruction = shape.instruction(functionId, instructionId);
      if (instruction.command !== 215) continue;
      if (identityJump) throw new Error(`${name}: expected one JUMP_CMP_PROTOID`);
      identityJump = { functionId, instructionId, instruction };
    }
    backendObject(firstSnapshot, functionId);
  }
  if (!identityJump || identityJump.instruction.operandCount !== 4)
    throw new Error(`${name}: upstream inliner produced no canonical JUMP_CMP_PROTOID`);
  const expectedProtoId = identityJump.instruction.constant(1);
  if (expectedProtoId.kind !== 2 || expectedProtoId.bits !== 0n)
    throw new Error(`${name}: inline guard target identity drifted: ${expectedProtoId.kind}/${expectedProtoId.bits}`);

  const firstObject = backendPackage(firstSnapshot);
  const secondObject = backendPackage(firstSnapshot);
  if (!firstObject.equals(secondObject)) throw new Error(`${name}: package backend is nondeterministic`);
  const linked = await WebAssembly.compile(linkPackage(firstObject, packageFunctionSymbols(shape.functionCount)));
  if (!WebAssembly.Module.imports(linked).some(({ name: importName }) =>
    importName === "luauc_runtime_v1_closure_matches_proto_id"))
    throw new Error(`${name}: generated module lacks the opaque runtime identity predicate`);
  const staticObject = backendStaticPackage(staticPackageFrame("proto_identity", firstSnapshot));
  if (!staticObject.length) throw new Error(`${name}: static package produced no object`);

  {
    const mutated = Buffer.from(firstSnapshot);
    const protos = snapshotSection(mutated, 3);
    mutated.writeUInt32LE(1, protos.offset + 24);
    expectPackageRejection(mutated, "duplicate/misaligned Proto funid");
  }
  {
    const mutated = Buffer.from(firstSnapshot);
    const functions = snapshotSection(mutated, 15);
    const constants = snapshotSection(mutated, 19);
    const functionRecord = functions.offset + identityJump.functionId * functions.recordSize;
    const constantId = identityJump.instruction.operand(1).value;
    const constantStart = mutated.readUInt32LE(functionRecord + 40);
    mutated.writeBigUInt64LE(BigInt(shape.protoCount + 1), constants.offset + (constantStart + constantId) * constants.recordSize + 8);
    expectPackageRejection(mutated, "JUMP_CMP_PROTOID references an unknown source funid");
  }
  return { objectSize: firstObject.length, functionCount: shape.functionCount };
}

const scalar = await executeCase(
  "scalar",
  "return function(n) return n * 2 + 1 end",
  [
    [1, 3],
    [4, 9],
    [7, 15],
  ],
);
const loop = await executeCase(
  "loop",
  "return function(n) local sum = 0 for i = 1, n do sum += i end return sum end",
  [
    [1, 1],
    [4, 10],
    [7, 28],
  ],
);
const silent = await executeSilentRoot();
const slowAdd = await executeSlowAdd();
const compiledCall = await executeCompiledCallPackage();
const capturedCall = await executeCapturedCallPackage();
const referenceCapture = await executeReferenceCapturePackage();
const multiResultCall = await executeMultiResultCallPackage();
const forwardedCapture = executeForwardedCapturePackageShape();
const recursiveCall = await executeRecursiveCallPackageShape();
const coverage = await executeCoveragePackageShape();
const tableInsertAppend = await executeTableInsertAppendPackageShape();
const preloadedFieldCompare = await executePreloadedFieldAndInvertedCompare();
const linearizedStringFields = await executeLinearizedStringFieldWrites();
const plainTableNamecall = await executePlainTableNamecallPackageShape();
const yieldCall = await executeYieldCallPackage();
const dynamicArrayTable = await executeDynamicArrayTablePackage();
const dynamicHashTable = await executeDynamicHashTablePackage();
const dynamicString = await executeDynamicStringPackage();
const genericIteration = await executeGenericIterationPackage();
const genericTable = await executeGenericTablePackage();
const generalDynamicObject = await executeGeneralDynamicObjectGraph();
const powMetamethod = await executePowMetamethodGraph();
const repeatedPowMetamethod = await executeRepeatedPowMetamethodGraph();
const mixedTable = await executeMixedTablePackage();
const globalState = await executeGlobalStatePackage();
const fastBuiltins = await executeFastBuiltinsPackage();
const bufferScalarMatrix = await executeBufferScalarMatrixPackage();
const embedNamecallFamily = executeEmbedNamecallFamilyPackageShape();
const protoIdentityControl = await executeProtoIdentityControlPackageShape();

console.log(
  `frontend -> IR -> relocatable wasm: scalar ${scalar.objectSize} bytes, loop ${loop.objectSize} bytes; ` +
    `silent root ${silent.objectSize} bytes, slow add ${slowAdd.objectSize} bytes; ` +
    `compiled call package ${compiledCall.objectSize} bytes/${compiledCall.nestedCalls} nested calls; ` +
    `captured call package ${capturedCall.objectSize} bytes/${capturedCall.captureCount} captures; ` +
    `reference capture package ${referenceCapture.objectSize} bytes/${referenceCapture.closes} closes; ` +
    `forwarded capture package ${forwardedCapture.objectSize} bytes; ` +
    `recursive call package ${recursiveCall.objectSize} bytes/${recursiveCall.functionCount} functions; ` +
    `coverage package ${coverage.objectSize} bytes/${coverage.sites} sites; ` +
    `table.insert append package ${tableInsertAppend.objectSize} bytes; ` +
    `preloaded field/inverted compare ${preloadedFieldCompare.objectSize} bytes; ` +
    `linearized string fields ${linearizedStringFields.objectSize} bytes; ` +
    `plain table NAMECALL package ${plainTableNamecall.objectSize} bytes; ` +
    `yield call package ${yieldCall.objectSize} bytes/${yieldCall.functionCount} functions; ` +
    `dynamic array table ${dynamicArrayTable.objectSize} bytes/${dynamicArrayTable.functionCount} functions; ` +
    `dynamic hash table ${dynamicHashTable.objectSize} bytes/${dynamicHashTable.functionCount} functions; ` +
    `dynamic string ${dynamicString.objectSize} bytes/${dynamicString.functionCount} functions; ` +
    `generic iteration ${genericIteration.objectSize} bytes/${genericIteration.functionCount} functions; ` +
    `generic table ${genericTable.objectSize} bytes/${genericTable.functionCount} functions; ` +
    `general dynamic object ${generalDynamicObject.objectSize} bytes/${generalDynamicObject.functionCount} functions; ` +
    `pow metamethod ${powMetamethod.objectSize} bytes/${powMetamethod.functionCount} functions; ` +
    `repeated pow metamethod ${repeatedPowMetamethod.objectSize} bytes/${repeatedPowMetamethod.functionCount} functions; ` +
    `mixed table ${mixedTable.objectSize} bytes/${mixedTable.functionCount} functions; ` +
    `global state ${globalState.objectSize} bytes/${globalState.functionCount} functions; ` +
    `fast builtins ${fastBuiltins.objectSize} bytes/${fastBuiltins.functionCount} functions; ` +
    `buffer scalar matrix ${bufferScalarMatrix.objectSize} bytes/${bufferScalarMatrix.functionCount} functions; ` +
    `embed NAMECALL family ${embedNamecallFamily.objectSize} bytes/${embedNamecallFamily.functionCount} functions; ` +
    `Proto identity control ${protoIdentityControl.objectSize} bytes/${protoIdentityControl.functionCount} functions; ` +
    `multi-result package ${multiResultCall.objectSize} bytes/${multiResultCall.pairReturns} pair returns; ` +
    `interrupt calls ${scalar.interrupts}/${loop.interrupts}/${silent.interrupts}/${slowAdd.interrupts}; ` +
    `slow helpers ${slowAdd.helperCalls}`,
);
