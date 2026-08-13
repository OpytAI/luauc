import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = (value) => value.startsWith("/") ? value : join(process.env.RUNFILES_DIR, value);
const compiler = readFileSync(runfile(process.env.LUAUC_COMPILER_WASM));
const profile = readFileSync(runfile(process.env.LUAUC_EMBED_PROFILE));
const pack = readFileSync(runfile(process.env.LUAUC_EMBED_PACK));
const modules = [
  { name: "lib", source: readFileSync(runfile(process.env.LUAUC_EMBED_LIB), "utf8") },
  { name: "main", source: readFileSync(runfile(process.env.LUAUC_EMBED_MAIN), "utf8") },
];
const first = await compilePackage(compiler, profile, pack, modules);
const second = await compilePackage(compiler, profile, pack, modules);
if (Buffer.compare(first.artifact, second.artifact) !== 0) throw new Error("JavaScript host compile output is nondeterministic");
const instance = instantiateArtifact(first.artifact);
for (const [number, text] of [[1, "alpha"], [7, "beta"], [-4, "gamma"]]) {
  const result = invoke(instance, number, text);
  const expectedNumber = 9 * number + 13;
  const expectedText = `${text}:${number + 1}`;
  if (result.status || result.resultStatus || result.error || result.number !== expectedNumber || result.text !== expectedText)
    throw new Error(`embed-v1 ${number}/${text} => ${JSON.stringify(result)}, expected ${expectedNumber}/${expectedText}`);
}
console.log(`JavaScript embed-v1 compiled one multi-module artifact (${first.artifact.length} bytes) and ran three runtime inputs with calls/errors/tables/strings/iteration/coroutine/GC`);
