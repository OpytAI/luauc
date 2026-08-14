import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { coverage, createContext, destroyContext, instantiateArtifact, invoke } from "./host.mjs";

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
  "--coverage", "statement",
  `lib=${paths.lib}`,
  `main=${paths.main}`,
], { encoding: "utf8" }));
const artifact = readFileSync(output);
if (report.artifact_bytes !== artifact.length || report.module_count !== 2 || report.coverage !== "statement")
  throw new Error(`CLI report does not describe its artifact: ${JSON.stringify(report)}`);
const instance = instantiateArtifact(artifact);
const context = createContext(instance);
try {
  for (const [number, text] of [[1, "alpha"], [7, "beta"], [-4, "gamma"]]) {
    const result = invoke(instance, number, text, context);
    if (result.status || result.resultStatus || result.error || result.number !== 9 * number + 13 || result.text !== `${text}:${number + 1}`)
      throw new Error(`CLI artifact ${number}/${text}: ${JSON.stringify(result)}`);
  }
  const records = coverage(instance, context);
  if (records.length < 10 || !records.some(({ hits }) => hits >= 3) || !records.some(({ depth }) => depth >= 1))
    throw new Error(`CLI covered artifact returned incomplete counters: ${JSON.stringify(records)}`);
} finally {
  destroyContext(instance, context);
}
console.log(`luauc CLI compiled a covered two-module ${artifact.length}-byte artifact that ran three real inputs in JavaScript`);
