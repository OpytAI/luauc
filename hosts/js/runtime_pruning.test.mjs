import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = name => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");
const cases = [
  { name: "identity", body: "return value, text", limit: 230000, result: value => value },
  { name: "dynamic math", body: "return math.floor(math[text](value) * 1000000), text", limit: 245000, result: value => Math.floor(Math.cos(value) * 1000000) },
  { name: "table", body: "local t = {value, 2, 3}; table.insert(t, 4); local total = 0; for _, item in pairs(t) do total += item end; return total, text", limit: 245000, result: value => value + 9 },
  { name: "yield", body: 'coroutine.yield("gc-boundary"); return value + 1, text', limit: 235000, result: value => value + 1 },
];

for (const test of cases) {
  const modules = [{ name: "main", source: `return function(value, text) ${test.body} end` }];
  const first = await compilePackage(compiler, profile, pack, modules);
  const second = await compilePackage(compiler, profile, pack, modules);
  assert.deepEqual(first.artifact, second.artifact);
  assert.ok(first.artifact.length < test.limit, `${test.name}: ${first.artifact.length} exceeds ${test.limit}`);
  const instance = instantiateArtifact(first.artifact);
  for (const value of [-7, 0, 13]) {
    const result = invoke(instance, value, "cos");
    assert.equal(result.status, 0);
    assert.equal(result.resultStatus, 0);
    assert.equal(result.error, false);
    assert.equal(result.number, test.result(value), `${test.name}: incorrect result`);
    assert.equal(result.text, "cos");
  }
  console.log(`${test.name}: ${first.artifact.length} bytes`);
}
