import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { instantiateArtifact, invoke } from "./host.mjs";

const runfile = (value) => value.startsWith("/") ? value : join(process.env.RUNFILES_DIR, value);
const paths = Object.fromEntries(Object.entries({
  cli: process.env.LUAUC_CLI,
  compiler: process.env.LUAUC_COMPILER_WASM,
  profile: process.env.LUAUC_EMBED_PROFILE,
  pack: process.env.LUAUC_EMBED_PACK,
  lib: process.env.LUAUC_EMBED_LIB,
  main: process.env.LUAUC_EMBED_MAIN,
}).map(([name, value]) => [name, runfile(value)]));
const output = join(process.env.TEST_TMPDIR, "program.wasm");
const report = JSON.parse(execFileSync(paths.cli, [
  "compile",
  "--compiler", paths.compiler,
  "--profile", paths.profile,
  "--pack", paths.pack,
  "--output", output,
  "--entry", "main",
  `lib=${paths.lib}`,
  `main=${paths.main}`,
], { encoding: "utf8" }));
const artifact = readFileSync(output);
if (report.artifact_bytes !== artifact.length || report.module_count !== 2)
  throw new Error(`CLI report does not describe its artifact: ${JSON.stringify(report)}`);
const instance = instantiateArtifact(artifact);
for (const [number, text] of [[1, "alpha"], [7, "beta"], [-4, "gamma"]]) {
  const result = invoke(instance, number, text);
  if (result.status || result.resultStatus || result.error || result.number !== 9 * number + 13 || result.text !== `${text}:${number + 1}`)
    throw new Error(`CLI artifact ${number}/${text}: ${JSON.stringify(result)}`);
}
console.log(`luauc CLI compiled a two-module ${artifact.length}-byte artifact that ran three real inputs in JavaScript`);
