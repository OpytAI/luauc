import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { coverage, createContext, destroyContext, instantiateArtifact, invoke } from "./host.mjs";
import { oracleLines } from "./oracle.mjs";

const runfile = (value) => value.startsWith("/") ? value : join(process.env.RUNFILES_DIR, value);
const paths = Object.fromEntries(Object.entries({
  cli: process.env.LUAUC_CLI,
  compiler: process.env.LUAUC_COMPILER_WASM,
  profile: process.env.LUAUC_EMBED_PROFILE,
  pack: process.env.LUAUC_EMBED_PACK,
  lib: process.env.LUAUC_EMBED_LIB,
  main: process.env.LUAUC_EMBED_MAIN,
  protoIdentity: process.env.LUAUC_PROTO_IDENTITY,
  userdataHooks: process.env.LUAUC_USERDATA_HOOKS,
}).map(([name, value]) => [name, runfile(value)]));
const output = join(process.env.TEST_TMPDIR, "program.wasm");
const report = JSON.parse(execFileSync(paths.cli, [
  "compile",
  "--compiler", paths.compiler,
  "--profile", paths.profile,
  "--pack", paths.pack,
  "--output", output,
  "--entry", "main",
  "--coverage", "statement",
  "--inline-plan", "proto_identity:2:0:0",
  `lib=${paths.lib}`,
  `main=${paths.main}`,
  `proto_identity=${paths.protoIdentity}`,
  `userdata_hooks=${paths.userdataHooks}`,
], { encoding: "utf8" }));
const artifact = readFileSync(output);
if (report.artifact_bytes !== artifact.length || report.module_count !== 4 || report.coverage !== "statement")
  throw new Error(`CLI report does not describe its artifact: ${JSON.stringify(report)}`);
const instance = instantiateArtifact(artifact);
const context = createContext(instance);
const inputs = [[1, "alpha"], [7, "beta"], [-4, "gamma"]];
const expected = oracleLines(runfile(process.env.LUAUC_PINNED_INTERPRETER), [
  paths.lib,
  paths.main,
  paths.protoIdentity,
  paths.userdataHooks,
], inputs);
try {
  for (const [index, [number, text]] of inputs.entries()) {
    const result = invoke(instance, number, text, context);
    const want = expected[index];
    if (result.status || result.resultStatus || result.error || result.number !== want.number || result.text !== want.text)
      throw new Error(`CLI artifact ${number}/${text}: ${JSON.stringify(result)} expected ${want.number}/${want.text}`);
  }
  const records = coverage(instance, context);
  if (records.length < 10 || !records.some(({ hits }) => hits >= 3) || !records.some(({ depth }) => depth >= 1))
    throw new Error(`CLI covered artifact returned incomplete counters: ${JSON.stringify(records)}`);
} finally {
  destroyContext(instance, context);
}
console.log(`luauc CLI compiled a covered four-module ${artifact.length}-byte artifact with a real profile-guided inline plan and ran three inputs in JavaScript`);
