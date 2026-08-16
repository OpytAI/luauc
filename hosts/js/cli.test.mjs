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
  protoIdentity: process.env.LUAUC_PROTO_IDENTITY,
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
], { encoding: "utf8" }));
const artifact = readFileSync(output);
if (report.artifact_bytes !== artifact.length || report.module_count !== 3 || report.coverage !== "statement")
  throw new Error(`CLI report does not describe its artifact: ${JSON.stringify(report)}`);
const instance = instantiateArtifact(artifact);
const context = createContext(instance);
try {
  for (const [number, text] of [[1, "alpha"], [7, "beta"], [-4, "gamma"]]) {
    const result = invoke(instance, number, text, context);
    const protoResult = number % 2 !== 0 ? number * 3 + text.length : number - text.length;
    const operatorResult = number + 1 - 3 + Math.floor(number / 2) + 2 + 8 - number
      + (number + number) + number * number + (-number) + 1 + 1 + (text.length * 2 + 1) + text.length * 2 + 3;
    const expectedNumber = 32 * number + 175 + text.length + protoResult + operatorResult;
    const expectedText = `${text}:${number + 1}:2/1/11:missing`;
    if (result.status || result.resultStatus || result.error || result.number !== expectedNumber || result.text !== expectedText)
      throw new Error(`CLI artifact ${number}/${text}: ${JSON.stringify(result)}`);
  }
  const records = coverage(instance, context);
  if (records.length < 10 || !records.some(({ hits }) => hits >= 3) || !records.some(({ depth }) => depth >= 1))
    throw new Error(`CLI covered artifact returned incomplete counters: ${JSON.stringify(records)}`);
} finally {
  destroyContext(instance, context);
}
console.log(`luauc CLI compiled a covered three-module ${artifact.length}-byte artifact with a real profile-guided inline plan and ran three inputs in JavaScript`);
