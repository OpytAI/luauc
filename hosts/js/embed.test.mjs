import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compilePackage, coverage, createContext, destroyContext, instantiateArtifact, invoke } from "./host.mjs";
import { oracleLines } from "./oracle.mjs";

const runfile = (value) => value.startsWith("/") ? value : join(process.env.RUNFILES_DIR, value);
const compiler = readFileSync(runfile(process.env.LUAUC_COMPILER_WASM));
const profile = readFileSync(runfile(process.env.LUAUC_EMBED_PROFILE));
const pack = readFileSync(runfile(process.env.LUAUC_EMBED_PACK));
const modules = [
  { name: "lib", source: readFileSync(runfile(process.env.LUAUC_EMBED_LIB), "utf8") },
  { name: "main", source: readFileSync(runfile(process.env.LUAUC_EMBED_MAIN), "utf8") },
  {
    name: "proto_identity",
    source: readFileSync(runfile(process.env.LUAUC_PROTO_IDENTITY), "utf8"),
    inlinePlans: [{ callerFunctionId: 2, feedbackSlot: 0, targetFunctionId: 0 }],
  },
  { name: "userdata_hooks", source: readFileSync(runfile(process.env.LUAUC_USERDATA_HOOKS), "utf8") },
];
const first = await compilePackage(compiler, profile, pack, modules, "main", { coverageLevel: 1 });
const second = await compilePackage(compiler, profile, pack, modules, "main", { coverageLevel: 1 });
if (Buffer.compare(first.artifact, second.artifact) !== 0) throw new Error("JavaScript host compile output is nondeterministic");
const instance = instantiateArtifact(first.artifact);
const context = createContext(instance);
const inputs = [[1, "alpha"], [7, "beta"], [-4, "gamma"]];
const expected = oracleLines(runfile(process.env.LUAUC_PINNED_INTERPRETER), [
  runfile(process.env.LUAUC_EMBED_LIB),
  runfile(process.env.LUAUC_EMBED_MAIN),
  runfile(process.env.LUAUC_PROTO_IDENTITY),
  runfile(process.env.LUAUC_USERDATA_HOOKS),
], inputs);
try {
  for (const [index, [number, text]] of inputs.entries()) {
    const result = invoke(instance, number, text, context);
    const want = expected[index];
    if (result.status || result.resultStatus || result.error || result.number !== want.number || result.text !== want.text)
      throw new Error(`embed-v1 ${number}/${text} => ${JSON.stringify(result)}, expected ${want.number}/${want.text}`);
  }
  const records = coverage(instance, context);
  if (records.length < 10 || !records.some(({ hits }) => hits > 0) ||
      !records.some(({ hits }) => hits >= 3) || !records.some(({ depth }) => depth >= 1))
    throw new Error(`embed-v1 coverage evidence is incomplete: ${JSON.stringify(records)}`);
} finally {
  destroyContext(instance, context);
}
console.log(`JavaScript embed-v1 compiled one covered multi-module artifact (${first.artifact.length} bytes) and ran three runtime inputs with NAMECALL, mutation, guarded builtin slow paths, repeated yield/full-GC continuation, errors, and coverage`);

const interpreter = runfile(process.env.LUAUC_PINNED_INTERPRETER);
const yieldDir = mkdtempSync(join(tmpdir(), "luauc-yield-"));
const noYieldSource = "return function(n, t)\n    return n, t\nend\n";
const unknownYieldSource = "return function(n, t)\n    coroutine.yield(\"nope\")\n    return n, t\nend\n";
writeFileSync(join(yieldDir, "no_yield.luau"), noYieldSource);
writeFileSync(join(yieldDir, "unknown_yield.luau"), unknownYieldSource);

function runInterpreterSource(path) {
  try {
    const stdout = execFileSync(interpreter, ["--source", path], { encoding: "utf8" });
    return { ok: true, stdout };
  } catch (error) {
    return { ok: false, stdout: `${error.stdout ?? ""}${error.stderr ?? ""}` };
  }
}

const noYieldInterp = runInterpreterSource(join(yieldDir, "no_yield.luau"));
if (!noYieldInterp.ok || !noYieldInterp.stdout.includes("result=1|alpha|1|alpha"))
  throw new Error(`zero-yield interpreter failed: ${JSON.stringify(noYieldInterp)}`);
const unknownYieldInterp = runInterpreterSource(join(yieldDir, "unknown_yield.luau"));
if (unknownYieldInterp.ok)
  throw new Error(`unknown-yield interpreter must fail, got ${JSON.stringify(unknownYieldInterp)}`);

const noYieldPack = await compilePackage(compiler, profile, pack, [
  { name: "main", source: noYieldSource },
], "main");
const noYieldInstance = instantiateArtifact(noYieldPack.artifact);
const noYieldContext = createContext(noYieldInstance);
try {
  const result = invoke(noYieldInstance, 1, "alpha", noYieldContext);
  if (result.status || result.resultStatus || result.error || result.number !== 1 || result.text !== "alpha")
    throw new Error(`zero-yield pack invoke failed: ${JSON.stringify(result)}`);
} finally {
  destroyContext(noYieldInstance, noYieldContext);
}

const unknownYieldPack = await compilePackage(compiler, profile, pack, [
  { name: "main", source: unknownYieldSource },
], "main");
const unknownYieldInstance = instantiateArtifact(unknownYieldPack.artifact);
const unknownYieldContext = createContext(unknownYieldInstance);
try {
  const result = invoke(unknownYieldInstance, 1, "alpha", unknownYieldContext);
  if (!result.status && !result.resultStatus && !result.error)
    throw new Error(`unknown-yield pack invoke must fail, got ${JSON.stringify(result)}`);
} finally {
  destroyContext(unknownYieldInstance, unknownYieldContext);
}

function expectedHookMark(n) {
  if (n === 0) return 0;
  return n + Math.fround(Math.sign(n) / Math.SQRT2);
}
function almostEqual(actual, expected) {
  return Number.isFinite(actual) && Math.abs(actual - expected) <= 1e-12 * Math.max(1, Math.abs(expected));
}
const hookEntry = `
local hooks = require("userdata_hooks")
return function(n, t)
    local value = hooks(embed.vec2(n))
    return 0, string.format("%.17g", value)
end
`;
const hookPack = await compilePackage(compiler, profile, pack, [
  { name: "userdata_hooks", source: readFileSync(runfile(process.env.LUAUC_USERDATA_HOOKS), "utf8") },
  { name: "main", source: hookEntry },
], "main");
const hookInstance = instantiateArtifact(hookPack.artifact);
const hookContext = createContext(hookInstance);
try {
  for (const [number, text] of [[1, "alpha"], [7, "beta"], [-4, "gamma"]]) {
    const result = invoke(hookInstance, number, text, hookContext);
    if (result.status || result.resultStatus || result.error)
      throw new Error(`hook-only AOT ${number}/${text} failed: ${JSON.stringify(result)}`);
    const value = Number(result.text);
    if (!almostEqual(value, expectedHookMark(number)))
      throw new Error(`hook-only AOT ${number}/${text}: got ${value}, expected ${expectedHookMark(number)}`);
  }
} finally {
  destroyContext(hookInstance, hookContext);
}
