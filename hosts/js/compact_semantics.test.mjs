import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = name => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");

for (const paddingCount of [0, 8]) {
  const sizes = [];
  for (const count of [16, 48]) {
    const padding = Array.from({ length: paddingCount }, () => "function() return 0 end").join(", ");
    const steps = Array.from({ length: count }, () => `
        if lhs < rhs then total += #box end
        if lhs == rhs then total += box:size() end
    `).join("\n");
    const operations = `
local padding = { ${padding} }
return function(lhs, rhs, box)
    local total = #padding
    ${steps}
    return total
end
`;
    const source = `
local operations = require("operations")
return function(value, text)
    local box = {1, 2, 3, size = function() return 5 end}
    assert(operations(value, value + 1, box) == ${count * 3 + paddingCount})
    assert(operations(value, value - 1, box) == ${paddingCount})
    return operations(value, value, box), text
end
`;
    const compilation = await compilePackage(compiler, profile, pack, [
      { name: "operations", source: operations }, { name: "main", source },
    ]);
    sizes.push(compilation.artifact.length);
    const result = invoke(instantiateArtifact(compilation.artifact), 7, "controls");
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.resultStatus, 0, JSON.stringify(result));
    assert.equal(result.error, false);
    assert.equal(result.number, count * 5 + paddingCount);
    assert.equal(result.text, "controls");
  }
  if (paddingCount === 8)
    assert.ok(sizes[1] - sizes[0] < 32 * 300, `compact control growth: ${sizes.join(", ")}`);
  console.log(`semantic controls padding=${paddingCount}: ${sizes.join(", ")} bytes`);
}

for (const paddingCount of [0, 8]) {
  const padding = Array.from({ length: paddingCount }, () => "function() return 0 end").join(", ");
  const source = `
local padding = { ${padding} }
local function compare(lhs, rhs, eq, lt, le)
    assert((lhs == rhs) == eq and (lhs ~= rhs) == not eq)
    assert((lhs < rhs) == lt and (lhs <= rhs) == le)
    if lhs == rhs then assert(eq) else assert(not eq) end
    if lhs ~= rhs then assert(not eq) else assert(eq) end
    if lhs < rhs then assert(lt) else assert(not lt) end
    if lhs <= rhs then assert(le) else assert(not le) end
    if not (lhs < rhs) then assert(not lt) else assert(lt) end
    if not (lhs <= rhs) then assert(not le) else assert(le) end
end
local function negate(value) return -value end
local function length(value) return #value end
local function call(value, amount) return value:measure(amount) end
return function(value, text)
    compare(value, value, true, false, true)
    compare(value, value + 1, false, true, true)
    compare(value + 1, value, false, false, false)
    compare(text, text .. "z", false, true, true)
    local nan = 0 / 0
    compare(nan, value, false, false, false)
    local equality = function(lhs, rhs) return lhs.value == rhs.value end
    local less = function(lhs, rhs) return lhs.value < rhs.value end
    local metatable = {
        __eq = equality,
        __lt = less,
        __unm = function(item) return -item.value end,
        __len = function(item) return item.value + 20 end,
    }
    local first = setmetatable({value = value}, metatable)
    local same = setmetatable({value = value}, metatable)
    local greater = setmetatable({value = value + 1}, metatable)
    compare(first, same, true, false, true)
    compare(first, greater, false, true, true)
    metatable.__le = function(lhs, rhs) return lhs.value <= rhs.value end
    compare(first, greater, false, true, true)
    assert(negate(first) == -value and negate(tostring(value)) == -value)
    assert(length(first) == value + 20 and length(text) == 3 and length({1, 2, 3}) == 3)
    local function measure(self, amount)
        coroutine.yield("gc-boundary")
        return self.value + amount
    end
    local inherited = setmetatable({value = value}, {__index = {measure = measure}})
    local dynamic = setmetatable({value = value}, {__index = function() return measure end})
    assert(call(inherited, 3) == value + 3 and call(dynamic, 4) == value + 4)
    assert(not pcall(function() return call({}, 0) end))
    assert(not pcall(function() return length(false) end))
    assert(not pcall(function() return negate({}) end))
    assert(not pcall(function() return first < 1 end))
    assert(not (first == value) and nil == nil and true ~= false)
    return value + #padding, text:sub(1, 2)
end
`;
  const split = source.indexOf("return function(value, text)");
  const operations = source.slice(0, split) + "return {compare = compare, negate = negate, length = length, call = call}";
  const main = `local padding = {${padding}}
local operations = require("operations")
local compare, negate, length, call = operations.compare, operations.negate, operations.length, operations.call
` + source.slice(split);
  const compilation = await compilePackage(compiler, profile, pack, [
    { name: "operations", source: operations },
    { name: "main", source: main },
  ]);
  const instance = instantiateArtifact(compilation.artifact);
  for (const value of [-7, 0, 13]) {
    const result = invoke(instance, value, "abc");
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.resultStatus, 0, JSON.stringify(result));
    assert.equal(result.error, false);
    assert.equal(result.number, value + paddingCount);
    assert.equal(result.text, "ab");
  }
}

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
