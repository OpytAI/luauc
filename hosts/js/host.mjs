const encoder = new TextEncoder();
const decoder = new TextDecoder();

function hexBytes(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let index = 0; index < out.length; index++)
    out[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  return out;
}

// Must match compiler/ir/frontend_identity_v1.zig frontend_contract_sha256.
const FRONTEND_CONTRACT = hexBytes("35c7e683add7d255a76e3b1434070e288e74c9e53c961a8774bd02fb5646507e");

function bytes(value) {
  if (typeof value === "string") return encoder.encode(value);
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  throw new TypeError("expected a string, ArrayBuffer, or typed-array view");
}

function copyBytes(value) {
  return Uint8Array.from(bytes(value));
}

function concat(parts) {
  const total = parts.reduce((size, part) => size + part.length, 0);
  const result = new Uint8Array(total);
  let cursor = 0;
  for (const part of parts) {
    result.set(part, cursor);
    cursor += part.length;
  }
  return result;
}

function compareBytes(lhs, rhs) {
  const count = Math.min(lhs.length, rhs.length);
  for (let index = 0; index < count; index++) {
    if (lhs[index] !== rhs[index]) return lhs[index] - rhs[index];
  }
  return lhs.length - rhs.length;
}

function putU16(target, offset, value) {
  new DataView(target.buffer, target.byteOffset, target.byteLength).setUint16(offset, value, true);
}

function putU32(target, offset, value) {
  new DataView(target.buffer, target.byteOffset, target.byteLength).setUint32(offset, value, true);
}

async function sha256(value) {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw new Error("the JavaScript host requires the standard Web Crypto digest API");
  return new Uint8Array(await subtle.digest("SHA-256", bytes(value)));
}

function allocation(api, bytesOrSize) {
  const size = typeof bytesOrSize === "number" ? bytesOrSize : bytes(bytesOrSize).length;
  const pointer = api.luauc_v1_alloc(size);
  if (!pointer) throw new Error(`luauc allocation failed for ${size} bytes`);
  if (typeof bytesOrSize !== "number")
    new Uint8Array(api.memory.buffer, pointer, size).set(bytes(bytesOrSize));
  return { pointer, size };
}

async function buildRequest(modules, entryModuleId, profileDigest, packDigest, coverageLevel) {
  modules = await Promise.all(modules.map(async ({ name, source, inlinePlans = [] }) => {
    const canonicalName = bytes(name);
    const content = bytes(source);
    const canonicalPlans = inlinePlans.map(({ callerFunctionId, feedbackSlot, targetFunctionId }) => {
      for (const [field, value] of Object.entries({ callerFunctionId, feedbackSlot, targetFunctionId }))
        if (!Number.isInteger(value) || value < 0 || value > 0xffffffff)
          throw new TypeError(`${name} inline plan ${field} is not a uint32`);
      return { callerFunctionId, feedbackSlot, targetFunctionId };
    }).sort((lhs, rhs) => lhs.callerFunctionId - rhs.callerFunctionId || lhs.feedbackSlot - rhs.feedbackSlot);
    if (canonicalPlans.some((plan, index) => index &&
        canonicalPlans[index - 1].callerFunctionId === plan.callerFunctionId &&
        canonicalPlans[index - 1].feedbackSlot === plan.feedbackSlot))
      throw new Error(`${name} has duplicate inline plan call sites`);
    const planBytes = new Uint8Array(canonicalPlans.length * 16);
    for (let index = 0; index < canonicalPlans.length; index++) {
      const plan = canonicalPlans[index];
      putU32(planBytes, index * 16, plan.callerFunctionId);
      putU32(planBytes, index * 16 + 4, plan.feedbackSlot);
      putU32(planBytes, index * 16 + 8, plan.targetFunctionId);
    }
    return {
      name: canonicalName,
      sourceName: bytes(`@${name}.luau`),
      content,
      contentDigest: await sha256(content),
      planBytes,
      planCount: canonicalPlans.length,
    };
  }));
  modules.sort((lhs, rhs) => compareBytes(lhs.name, rhs.name));
  if (!modules.length || modules.some((module, index) => index && compareBytes(modules[index - 1].name, module.name) === 0))
    throw new Error("invalid source package modules");
  const manifestHeader = new Uint8Array(8);
  putU32(manifestHeader, 0, modules.length);
  putU32(manifestHeader, 4, entryModuleId);
  const sized = (value) => {
    const header = new Uint8Array(4);
    putU32(header, 0, value.length);
    return concat([header, value]);
  };
  const manifest = [manifestHeader];
  for (const module of modules) {
    manifest.push(sized(module.name), sized(module.sourceName), module.contentDigest);
    const planCount = new Uint8Array(4);
    putU32(planCount, 0, module.planCount);
    manifest.push(planCount, module.planBytes);
  }
  const manifestDigest = await sha256(concat(manifest));

  const headerSize = 240;
  const recordSize = 64;
  const allowedImportCeiling = 32;
  const featureCeiling = 0;
  const budgetInstructions = 1_048_576;
  const budgetFunctions = 4096;
  const budgetBytes = 16_777_216;
  const total = modules.reduce(
    (size, module) => size + module.name.length + module.sourceName.length + module.content.length + module.planBytes.length,
    headerSize + recordSize * modules.length,
  );
  const request = new Uint8Array(total);
  request.set(bytes("LUAUCS1\0"), 0);
  putU16(request, 8, 1);
  putU16(request, 10, headerSize);
  putU32(request, 12, total);
  putU32(request, 16, modules.length);
  putU32(request, 20, entryModuleId);
  putU32(request, 24, recordSize);
  putU32(request, 28, coverageLevel);
  putU32(request, 176, 0);
  putU32(request, 180, allowedImportCeiling);
  putU32(request, 184, featureCeiling);
  putU32(request, 188, budgetInstructions);
  putU32(request, 192, budgetFunctions);
  putU32(request, 196, budgetBytes);
  const coverage = new Uint8Array(4);
  putU32(coverage, 0, coverageLevel);
  const optionBytes = new Uint8Array(32);
  putU32(optionBytes, 0, 0);
  putU32(optionBytes, 4, allowedImportCeiling);
  putU32(optionBytes, 8, featureCeiling);
  putU32(optionBytes, 12, budgetInstructions);
  putU32(optionBytes, 16, budgetFunctions);
  putU32(optionBytes, 20, budgetBytes);
  const planPreimage = [];
  for (const module of modules) {
    const planCount = new Uint8Array(4);
    putU32(planCount, 0, module.planCount);
    planPreimage.push(planCount, module.planBytes);
  }
  request.set((await sha256(concat([
    bytes("luauc-source-request-v1\0"),
    coverage,
    FRONTEND_CONTRACT,
    profileDigest,
    packDigest,
    manifestDigest,
    optionBytes,
    ...planPreimage,
  ]))).subarray(0, 16), 32);
  request.set(FRONTEND_CONTRACT, 48);
  request.set(profileDigest, 80);
  request.set(packDigest, 112);
  request.set(manifestDigest, 144);

  let cursor = headerSize + recordSize * modules.length;
  for (let index = 0; index < modules.length; index++) {
    const module = modules[index];
    const record = headerSize + recordSize * index;
    putU32(request, record, cursor);
    putU32(request, record + 4, module.name.length);
    request.set(module.name, cursor);
    cursor += module.name.length;
    putU32(request, record + 8, cursor);
    putU32(request, record + 12, module.sourceName.length);
    request.set(module.sourceName, cursor);
    cursor += module.sourceName.length;
    putU32(request, record + 16, cursor);
    putU32(request, record + 20, module.content.length);
    request.set(module.content, cursor);
    cursor += module.content.length;
    request.set(module.contentDigest, record + 24);
    if (module.planCount !== 0) {
      putU32(request, record + 56, cursor);
      putU32(request, record + 60, module.planCount);
      request.set(module.planBytes, cursor);
      cursor += module.planBytes.length;
    }
  }
  if (cursor !== request.length) throw new Error("source package request layout drifted");
  return request;
}

export async function compilePackage(compilerBytes, profileBytes, packBytes, modules, entryName = "main", options = {}) {
  const coverageLevel = options.coverageLevel ?? 0;
  if (!Number.isInteger(coverageLevel) || coverageLevel < 0 || coverageLevel > 2)
    throw new TypeError("coverageLevel must be 0, 1, or 2");
  const module = new WebAssembly.Module(bytes(compilerBytes));
  if (WebAssembly.Module.imports(module).length) throw new Error("luauc.wasm has imports");
  const api = new WebAssembly.Instance(module, {}).exports;
  const profileInput = allocation(api, profileBytes);
  const packInput = allocation(api, packBytes);
  const contextResult = allocation(api, 72);
  let handle = 0;
  try {
    new Uint8Array(api.memory.buffer, contextResult.pointer, contextResult.size).fill(0);
    const status = api.luauc_v1_context_create(
      profileInput.pointer,
      profileInput.size,
      packInput.pointer,
      packInput.size,
      contextResult.pointer,
    );
    const result = new DataView(api.memory.buffer, contextResult.pointer, contextResult.size);
    if (status || result.getUint32(4, true))
      throw new Error(`context creation failed with ${status}/${result.getUint32(4, true)}`);
    handle = result.getUint32(0, true);
    const profileDigest = copyBytes(new Uint8Array(api.memory.buffer, contextResult.pointer + 8, 32));
    const packDigest = copyBytes(new Uint8Array(api.memory.buffer, contextResult.pointer + 40, 32));
    const sorted = [...modules].sort((lhs, rhs) => compareBytes(bytes(lhs.name), bytes(rhs.name)));
    const entryModuleId = sorted.findIndex(({ name }) => name === entryName);
    if (entryModuleId < 0) throw new Error(`missing entry module ${entryName}`);
    const request = await buildRequest(sorted, entryModuleId, profileDigest, packDigest, coverageLevel);
    const requestInput = allocation(api, request);
    const compileResultSize = api.luauc_v1_describe
      ? (() => {
        const describe = allocation(api, 32);
        try {
          if (api.luauc_v1_describe(describe.pointer) !== 0) throw new Error("luauc describe failed");
          return new DataView(api.memory.buffer, describe.pointer, 32).getUint32(12, true);
        } finally {
          api.luauc_v1_dealloc(describe.pointer, describe.size);
        }
      })()
      : 320;
    const compileResult = allocation(api, compileResultSize);
    try {
      new Uint8Array(api.memory.buffer, compileResult.pointer, compileResult.size).fill(0);
      const compileStatus = api.luauc_v1_compile(
        handle,
        requestInput.pointer,
        requestInput.size,
        compileResult.pointer,
      );
      const view = new DataView(api.memory.buffer, compileResult.pointer, compileResult.size);
      const diagnosticPointer = view.getUint32(8, true);
      const diagnosticSize = view.getUint32(12, true);
      const diagnostic = diagnosticPointer && diagnosticSize
        ? decoder.decode(new Uint8Array(api.memory.buffer, diagnosticPointer, diagnosticSize))
        : "";
      if (compileStatus || view.getUint32(16, true))
        throw new Error(`compile failed with ${compileStatus}/${view.getUint32(16, true)}: ${diagnostic}`);
      const dataPointer = view.getUint32(0, true);
      const dataSize = view.getUint32(4, true);
      const artifact = copyBytes(new Uint8Array(api.memory.buffer, dataPointer, dataSize));
      const provenance = {
        profileDigest: copyBytes(new Uint8Array(api.memory.buffer, compileResult.pointer + 104, 32)),
        packDigest: copyBytes(new Uint8Array(api.memory.buffer, compileResult.pointer + 136, 32)),
        objectDigest: copyBytes(new Uint8Array(api.memory.buffer, compileResult.pointer + 200, 32)),
        artifactDigest: copyBytes(new Uint8Array(api.memory.buffer, compileResult.pointer + 232, 32)),
      };
      return { artifact, provenance };
    } finally {
      api.luauc_v1_result_free(compileResult.pointer);
      api.luauc_v1_dealloc(compileResult.pointer, compileResult.size);
      api.luauc_v1_dealloc(requestInput.pointer, requestInput.size);
    }
  } finally {
    if (handle) api.luauc_v1_context_destroy(handle);
    api.luauc_v1_dealloc(contextResult.pointer, contextResult.size);
    api.luauc_v1_dealloc(packInput.pointer, packInput.size);
    api.luauc_v1_dealloc(profileInput.pointer, profileInput.size);
  }
}

export function instantiateArtifact(artifact, namespace = "luauc_embed_v1") {
  const module = new WebAssembly.Module(bytes(artifact));
  let instance;
  const throwCodes = [];
  const imports = {
    [namespace]: {
      protected_call() {
        try {
          instance.exports.luauc_embed_v1_protected_call_run();
          return 0;
        } catch (error) {
          if (!throwCodes.length) throw error;
          return throwCodes.pop();
        }
      },
      set_throw(code) {
        throwCodes.push(code >>> 0);
      },
    },
  };
  instance = new WebAssembly.Instance(module, imports);
  if (typeof instance.exports._start !== "function")
    throw new Error("embed runtime profile has no initializer");
  instance.exports._start();
  if (throwCodes.length) throw new Error("protected-call adapter retained stale throw state");
  return instance;
}

export function createContext(instance) {
  const context = instance.exports.luauc_embed_v1_context_create();
  if (!context) {
    const pointer = instance.exports.luauc_embed_v1_last_error?.() ?? 0;
    const size = instance.exports.luauc_embed_v1_last_error_size?.() ?? 0;
    const detail = pointer && size
      ? new TextDecoder().decode(new Uint8Array(instance.exports.memory.buffer, pointer, size))
      : "unknown initialization failure";
    throw new Error(`embed-v1 context creation failed: ${detail}`);
  }
  return context;
}

export function destroyContext(instance, context) {
  if (context) instance.exports.luauc_embed_v1_context_destroy(context);
}

export function invoke(instance, number, text, existingContext = 0) {
  if (!Number.isSafeInteger(number)) throw new TypeError("embed-v1 JavaScript numbers must be safe integers");
  const api = instance.exports;
  const encoded = bytes(text);
  const allocations = [];
  const allocate = (size) => {
    if (size === 0) return 0;
    const pointer = api.luauc_embed_v1_alloc(size);
    if (!pointer) throw new Error(`embed-v1 allocation failed for ${size} bytes`);
    allocations.push(pointer);
    return pointer;
  };
  let context = existingContext;
  const ownsContext = context === 0;
  try {
    const textPointer = allocate(encoded.length);
    const outputCapacity = 4096;
    const outputPointer = allocate(outputCapacity);
    const requestPointer = allocate(32);
    const resultPointer = allocate(32);
    if (ownsContext) context = createContext(instance);

    if (encoded.length) new Uint8Array(api.memory.buffer, textPointer, encoded.length).set(encoded);
    const request = new DataView(api.memory.buffer, requestPointer, 32);
    request.setUint32(0, 1, true);
    request.setUint32(4, 32, true);
    request.setBigInt64(8, BigInt(number), true);
    request.setUint32(16, textPointer, true);
    request.setUint32(20, encoded.length, true);
    request.setUint32(24, outputPointer, true);
    request.setUint32(28, outputCapacity, true);
    new Uint8Array(api.memory.buffer, resultPointer, 32).fill(0);
    const status = api.luauc_embed_v1_invoke(context, requestPointer, 32, resultPointer);
    const result = new DataView(api.memory.buffer, resultPointer, 32);
    const outputSize = result.getUint32(16, true);
    if (outputSize > outputCapacity) throw new Error("embed-v1 returned an out-of-range output size");
    const output = decoder.decode(new Uint8Array(api.memory.buffer, outputPointer, outputSize));
    return {
      status,
      resultStatus: result.getUint32(0, true),
      error: !!(result.getUint32(4, true) & 1),
      number: Number(result.getBigInt64(8, true)),
      text: output,
    };
  } finally {
    if (ownsContext && context) destroyContext(instance, context);
    for (let index = allocations.length; index-- > 0;)
      api.luauc_embed_v1_dealloc(allocations[index]);
  }
}

export function coverage(instance, context) {
  if (!context) throw new TypeError("coverage requires a live embed-v1 context");
  const api = instance.exports;
  const resultPointer = api.luauc_embed_v1_alloc(16);
  if (!resultPointer) throw new Error("coverage result allocation failed");
  let outputPointer = 0;
  try {
    new Uint8Array(api.memory.buffer, resultPointer, 16).fill(0);
    const probeStatus = api.luauc_embed_v1_coverage(context, 0, 0, resultPointer);
    let result = new DataView(api.memory.buffer, resultPointer, 16);
    const requiredCapacity = result.getUint32(8, true);
    if ((requiredCapacity === 0 && probeStatus !== 0) || (requiredCapacity !== 0 && probeStatus !== 2) ||
        result.getUint32(0, true) !== probeStatus || requiredCapacity === 0xffffffff)
      throw new Error(`coverage size query failed with ${probeStatus}/${result.getUint32(0, true)} (${requiredCapacity} bytes)`);
    if (requiredCapacity === 0) return [];
    outputPointer = api.luauc_embed_v1_alloc(requiredCapacity);
    if (!outputPointer) throw new Error(`coverage output allocation failed for ${requiredCapacity} bytes`);
    new Uint8Array(api.memory.buffer, resultPointer, 16).fill(0);
    const status = api.luauc_embed_v1_coverage(context, outputPointer, requiredCapacity, resultPointer);
    result = new DataView(api.memory.buffer, resultPointer, 16);
    const recordCount = result.getUint32(4, true);
    const returnedCapacity = result.getUint32(8, true);
    if (status || result.getUint32(0, true) || returnedCapacity !== requiredCapacity ||
        recordCount * 16 !== returnedCapacity)
      throw new Error(`coverage query failed with ${status}/${result.getUint32(0, true)} (${returnedCapacity} bytes)`);
    const records = [];
    const view = new DataView(api.memory.buffer, outputPointer, returnedCapacity);
    for (let index = 0; index < recordCount; index++) {
      const offset = index * 16;
      records.push({
        functionIndex: view.getUint32(offset, true),
        depth: view.getUint32(offset + 4, true),
        line: view.getUint32(offset + 8, true),
        hits: view.getUint32(offset + 12, true),
      });
    }
    return records;
  } finally {
    api.luauc_embed_v1_dealloc(resultPointer);
    if (outputPointer) api.luauc_embed_v1_dealloc(outputPointer);
  }
}
