import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "../js/host.mjs";

const runfile = (value) => value.startsWith("/") ? value : join(process.env.RUNFILES_DIR, value);
const paths = {
  compiler: runfile(process.env.LUAUC_COMPILER_WASM),
  profile: runfile(process.env.LUAUC_EMBED_PROFILE),
  pack: runfile(process.env.LUAUC_EMBED_PACK),
  lib: runfile(process.env.LUAUC_EMBED_LIB),
  main: runfile(process.env.LUAUC_EMBED_MAIN),
  protoIdentity: runfile(process.env.LUAUC_PROTO_IDENTITY),
  userdataHooks: runfile(process.env.LUAUC_USERDATA_HOOKS),
  wasmtime: runfile(process.env.LUAUC_WASMTIME_HOST),
  interpreter: runfile(process.env.LUAUC_PINNED_INTERPRETER),
};
const modules = [
  { name: "lib", source: readFileSync(paths.lib, "utf8") },
  { name: "main", source: readFileSync(paths.main, "utf8") },
  {
    name: "proto_identity",
    source: readFileSync(paths.protoIdentity, "utf8"),
    inlinePlans: [{ callerFunctionId: 2, feedbackSlot: 0, targetFunctionId: 0 }],
  },
  { name: "userdata_hooks", source: readFileSync(paths.userdataHooks, "utf8") },
];
const jsCompilation = await compilePackage(
  readFileSync(paths.compiler),
  readFileSync(paths.profile),
  readFileSync(paths.pack),
  modules,
);
const jsInstance = instantiateArtifact(jsCompilation.artifact);
const matrix = [[1, "alpha"], [7, "beta"], [-4, "gamma"]];
const jsLines = matrix.map(([number, text]) => {
  const result = invoke(jsInstance, number, text);
  if (result.status || result.resultStatus || result.error)
    throw new Error(`JavaScript invocation failed: ${JSON.stringify(result)}`);
  return `result=${number}|${text}|${result.number}|${result.text}`;
});
const rustLines = execFileSync(paths.wasmtime, ["compile-run", paths.compiler, paths.profile, paths.pack, paths.lib, paths.main, paths.protoIdentity, paths.userdataHooks, "1", "alpha", "7", "beta", "-4", "gamma"], { encoding: "utf8" }).trim().split("\n");
const interpreterLines = execFileSync(paths.interpreter, [paths.lib, paths.main, paths.protoIdentity, paths.userdataHooks], { encoding: "utf8" }).trim().split("\n");
const artifactLine = `artifact=${createHash("sha256").update(jsCompilation.artifact).digest("hex")}`;
if (rustLines[0] !== artifactLine || JSON.stringify(rustLines.slice(1)) !== JSON.stringify(jsLines))
  throw new Error(`cross-host drift:\nJavaScript ${[artifactLine, ...jsLines].join("\n")}\nWasmtime ${rustLines.join("\n")}`);
if (JSON.stringify(interpreterLines) !== JSON.stringify(jsLines))
  throw new Error(`pinned Luau differential drift:\nAOT ${jsLines.join("\n")}\nInterpreter ${interpreterLines.join("\n")}`);
console.log(`JavaScript and Wasmtime compiled byte-identical ${jsCompilation.artifact.length}-byte artifacts; both hosts matched pinned Luau runtime results across three inputs`);
