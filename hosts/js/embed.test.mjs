import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, coverage, createContext, destroyContext, instantiateArtifact, invoke } from "./host.mjs";

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
];
const first = await compilePackage(compiler, profile, pack, modules, "main", { coverageLevel: 1 });
const second = await compilePackage(compiler, profile, pack, modules, "main", { coverageLevel: 1 });
if (Buffer.compare(first.artifact, second.artifact) !== 0) throw new Error("JavaScript host compile output is nondeterministic");
const instance = instantiateArtifact(first.artifact);
const context = createContext(instance);
try {
  for (const [number, text] of [[1, "alpha"], [7, "beta"], [-4, "gamma"]]) {
    const result = invoke(instance, number, text, context);
    const protoResult = number % 2 !== 0 ? number * 3 + text.length : number - text.length;
    const operatorResult = number + 1 - 3 + Math.floor(number / 2) + 2 + 8 - number
      + (number + number) + number * number + (-number) + 1 + 1 + (text.length * 2 + 1) + text.length * 2 + 3;
    const iterationResult = 12 * number + 16;
    const expectedNumber = 32 * number + 175 + text.length + protoResult + operatorResult + iterationResult;
    const expectedText = `${text}:${number + 1}:2/1/11:missing`;
    if (result.status || result.resultStatus || result.error || result.number !== expectedNumber || result.text !== expectedText)
      throw new Error(`embed-v1 ${number}/${text} => ${JSON.stringify(result)}, expected ${expectedNumber}/${expectedText}`);
  }
  const records = coverage(instance, context);
  if (records.length < 10 || !records.some(({ hits }) => hits > 0) ||
      !records.some(({ hits }) => hits >= 3) || !records.some(({ depth }) => depth >= 1))
    throw new Error(`embed-v1 coverage evidence is incomplete: ${JSON.stringify(records)}`);
} finally {
  destroyContext(instance, context);
}
console.log(`JavaScript embed-v1 compiled one covered multi-module artifact (${first.artifact.length} bytes) and ran three runtime inputs with NAMECALL, mutation, guarded builtin slow paths, repeated yield/full-GC continuation, errors, and coverage`);
