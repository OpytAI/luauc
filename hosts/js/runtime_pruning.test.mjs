import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = name => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");

const library = `
local methods = {}
local function helper(value) return value + 3 end
function methods.used(value) return helper(value) end
function methods.unused(value) return value + 99 end
function methods:method(value) return self.used(value) end
function methods.pair() return methods.used, methods.unused end
return methods
`;
for (const [label, body, expected] of [
  ["direct", "return methods.used(value), text", value => value + 3],
  ["alias", "local alias = methods; return alias.used(value), text", value => value + 3],
  ["argument", "local function apply(record) return record.used(value) end; return apply(methods), text", value => value + 3],
  ["returned", "local function get() return methods end; return get().used(value), text", value => value + 3],
  ["namecall", "return methods:method(value), text", value => value + 3],
  ["dynamic", 'return methods[text](value), text', value => value + 3],
  ["callback", "local ok, result = pcall(methods.used, value); assert(ok); return result, text", value => value + 3],
  ["multiple-results", "local function selectSecond(first, second) return second(value) end; return selectSecond(methods.pair()), text", value => value + 99],
  ["vararg-results", "local function selectSecond(first, ...) local second = ...; return second(value) end; return selectSecond(methods.pair()), text", value => value + 99],
  ["presence", 'assert(methods.unused ~= nil and type(methods.unused) == "function"); return methods.used(value), text', value => value + 3],
  ["iteration", "local count = 0; for key, item in pairs(methods) do count += 1 end; return count, text", () => 4],
  ["metatable", "local proxy = setmetatable({}, {__index = methods}); return proxy.used(value), text", value => value + 3],
  ["external-mutation", "local box = {run = function(record) return record.used(value) end}; pcall(function(target) target.run = function(record) return record.unused(value) end end, box); return box.run(methods), text", value => value + 99],
]) {
  for (const coverageLevel of [0, 2]) {
    const modules = coverageLevel === 0 ? [
      { name: "methods", source: library },
      { name: "main", source: `local methods = require("methods"); return function(value, text) ${body} end` },
    ] : [{ name: "main", source: `local methods = (function() ${library} end)(); return function(value, text) ${body} end` }];
    const compiled = await compilePackage(compiler, profile, pack, modules, "main", { coverageLevel });
    let result;
    try {
      result = invoke(instantiateArtifact(compiled.artifact), 7, "used");
    } catch (error) {
      throw new Error(`${label}, coverage ${coverageLevel}: ${error.message}`, { cause: error });
    }
    assert.equal(result.status, 0, label + JSON.stringify(result));
    assert.equal(result.resultStatus, 0, label + JSON.stringify(result));
    assert.equal(result.error, false, label);
    assert.ok(Math.abs(result.number - expected(7)) < 1e-9, label + JSON.stringify(result));
  }
}

const prunedSizes = [];
for (const count of [0, 64]) {
  const definitions = Array.from({ length: count }, (_, index) =>
    `function methods.unused${index}(value) return math.sin(value) + math.cos(value) + ${index} end;`).join("\n");
  const modules = [
    { name: "methods", source: `local methods = {}; function methods.used(value) return value + 3 end; ${definitions}\nreturn methods` },
    { name: "main", source: 'local methods = require("methods"); return function(value, text) return methods.used(value), text end' },
  ];
  const compiled = await compilePackage(compiler, profile, pack, modules);
  const repeated = await compilePackage(compiler, profile, pack, modules);
  assert.deepEqual(compiled.artifact, repeated.artifact);
  prunedSizes.push(compiled.artifact.length);
  assert.equal(invoke(instantiateArtifact(compiled.artifact), 7, "").number, 10);
}
assert.ok(prunedSizes[1] - prunedSizes[0] < 12000, `unused module closure growth: ${prunedSizes}`);

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
