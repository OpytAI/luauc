import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = name => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");

for (const paddingCount of [0, 8]) {
  const padding = Array.from({ length: paddingCount }, () => "function() return 0 end").join(", ");
  const source = `local padding = { ${padding} }\n` + runfile("LUAUC_NUMERIC_FLOOR_DIVISION").toString()
    .replace("value // divisor", "value // divisor + #padding");
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
  const instance = instantiateArtifact(compilation.artifact);
  for (const [value, text] of [[7, "3"], [-7, "3"], [7, "-3"], [-7, "-3"], [0, "3"]]) {
    const result = invoke(instance, value, text);
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.resultStatus, 0);
    assert.equal(result.error, false);
    assert.equal(result.number, Math.floor(value / Number(text)) + paddingCount);
    assert.equal(result.text, text);
  }
}

for (const paddingCount of [0, 8]) {
  const sizes = [];
  for (const count of [16, 64]) {
    const padding = Array.from({ length: paddingCount }, (_, index) => `function() return ${index} end`).join(", ");
    const steps = Array.from({ length: count }, () => `
        box[key] = box[key] + 1
        box.value = box.value + 2
        box[1] = box[1] + 3
    `).join("\n");
    const source = `
local padding = { ${padding} }
return function(value, text)
    setfenv(1, setmetatable({}, { __index = getfenv() }))
    local observed = {}
    local box = setmetatable({}, {
        __index = function(_, key) return observed[key] or 0 end,
        __newindex = function(_, key, item) observed[key] = item end,
    })
    local key = text
    ${steps}
    coroutine.yield("gc-boundary")
    local arithmetic = setmetatable({}, {
        __add = function(_, amount) return amount + 11 end,
    })
    local frozen = table.freeze({ value = 1 })
    local writable = pcall(function() frozen.value = 2 end)
    local valid = pcall(function() return box[nil].missing end)
    assert(not writable and not valid)
    compact_global = value
    local globalValue = compact_global
    compact_global = nil
    local vectorValue = vector.create(2, 3, 4)
    return box[key] + box.value + box[1] + (arithmetic + value)
        + ("4" + globalValue) + vectorValue.x + #padding, text
end
`;
    const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
    assert.ok(WebAssembly.validate(compilation.artifact));
    sizes.push(compilation.artifact.length);
    const instance = instantiateArtifact(compilation.artifact);
    for (const value of [-7, 0, 13]) {
      const result = invoke(instance, value, "dynamic");
      assert.equal(result.status, 0, JSON.stringify({ paddingCount, count, value, result }));
      assert.equal(result.resultStatus, 0);
      assert.equal(result.error, false);
      assert.equal(result.number, count * 6 + value * 2 + 17 + paddingCount);
      assert.equal(result.text, "dynamic");
    }
  }
  if (paddingCount === 8)
    assert.ok(sizes[1] - sizes[0] < 48 * 300, `compact operation growth: ${sizes.join(", ")}`);
  console.log(`semantic operations padding=${paddingCount}: ${sizes.join(", ")} bytes`);
}

for (const paddingCount of [0, 8]) {
  const padding = Array.from({ length: paddingCount }, (_, index) => `function() return ${index} end`).join(", ");
  const source = `
local padding = { ${padding} }
local function hook(seed: vec2)
    local unit: vec2 = seed.Unit
    coroutine.yield("gc-boundary")
    return seed:Mark({ 0 }) + unit:Mark({ 0 })
end
return function(value, text)
    return hook(embed.vec2(value)) + #padding, text
end
`;
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
  const instance = instantiateArtifact(compilation.artifact);
  for (const value of [-7, 0, 13]) {
    const result = invoke(instance, value, "typed hooks");
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.resultStatus, 0);
    assert.equal(result.error, false);
    assert.equal(result.text, "typed hooks");
    assert.equal(result.number, Math.trunc(value + Math.sign(value) / Math.sqrt(2) + paddingCount));
  }
}
