import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = name => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");

{
  const source = `
return function(value, text)
    local _, whitespaceEnd = text:find("^%s*", value)
    return whitespaceEnd, tostring(_)
end
`;
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
  const instance = instantiateArtifact(compilation.artifact);
  for (const [text, start, expectedEnd] of [
    ["xmlns:a=\"value\"", 8, 7],
    ["x  =\"value\"", 2, 3],
    ["x=\"value\"", 2, 1],
  ]) {
    const result = invoke(instance, start, text);
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.number, expectedEnd, `${text} at ${start}: ${JSON.stringify(result)}`);
    assert.equal(result.text, String(start), `${text} at ${start}: ${JSON.stringify(result)}`);
  }
}

{
  const source = `
return function(value, text)
    local nameEnd = text:find("[%s=/>]", value)
    local _, whitespaceEnd = text:find("^%s*", nameEnd)
    local nextIndex = whitespaceEnd + 1
    return nextIndex, text:sub(nextIndex, nextIndex)
end
`;
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
  const instance = instantiateArtifact(compilation.artifact);
  for (const [text, start, expectedIndex, expectedCharacter] of [
    ["xmlns:a=\"value\"", 1, 8, "="],
    ["name =\"value\"", 1, 6, "="],
  ]) {
    const result = invoke(instance, start, text);
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.number, expectedIndex, `${text}: ${JSON.stringify(result)}`);
    assert.equal(result.text, expectedCharacter, `${text}: ${JSON.stringify(result)}`);
  }
}

{
  const source = `
return function(value, text)
    local _, firstEnd = text:find("^%s*", value)
    local nextIndex = text:find("[%s=/>]", firstEnd + 1)
    local _, secondEnd = text:find("^%s*", nextIndex)
    return secondEnd, tostring(firstEnd)
end
`;
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
  const result = invoke(instantiateArtifact(compilation.artifact), 7, "<p:sld xmlns:a=\"hi\"/>");
  assert.equal(result.status, 0, JSON.stringify(result));
  assert.equal(result.number, 14, JSON.stringify(result));
  assert.equal(result.text, "7", JSON.stringify(result));
}

{
  const callbacks = Array.from({ length: 16 }, (_, index) => `function() return ${index} end`).join(",");
  const source = `
local callbacks = {${callbacks}}
return function(value, text)
    local start = 7
    local _, firstEnd = text:find("^%s*", start)
    start = firstEnd + 1
    local nameEnd = text:find("[%s=/>]", start)
    local name = text:sub(start, nameEnd - 1)
    start = nameEnd
    local _, secondEnd = text:find("^%s*", start)
    start = secondEnd + 1
    return start + callbacks[value + 1](), name .. text:sub(start, start)
end
`;
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
  const result = invoke(instantiateArtifact(compilation.artifact), 0, "<p:sld x=\"value\"/>");
  assert.equal(result.status, 0, JSON.stringify(result));
  assert.equal(result.number, 9, JSON.stringify(result));
  assert.equal(result.text, "x=", JSON.stringify(result));
}

for (const coverageLevel of [0, 2]) {
  const source = `
return function(value, text)
    local effects = { count = 0 }
    local function effect()
        effects.count += 1
        return 11
    end
    local methods = {
        used = function(input) return input + 3 end,
        unused = function() return function() error("unreachable") end end,
        effect = effect(),
    }
    local alias = methods
    local result = alias.used(value)
    assert(effects.count == 1 and methods.effect == 11)
    local exposed = {
        used = function() return 7 end,
        unused = function() return 13 end,
    }
    local function inspect(record)
        local count = 0
        for key, callback in pairs(record) do count += callback() end
        return count
    end
    assert(inspect(exposed) == 20)
    local rebound = { used = function() return 17 end }
    local saved = rebound
    rebound = exposed
    assert(saved.used() == 17 and rebound.unused() == 13)
    local duplicate = { unused = function() return 1 end, unused = function() return 2 end }
    assert(duplicate.unused() == 2)
    coroutine.yield("gc-boundary")
    return result, text
end
`;
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }],
    "main", { coverageLevel });
  const instance = instantiateArtifact(compilation.artifact);
  for (const value of [7, -11, 0]) {
    const result = invoke(instance, value, "fields");
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.resultStatus, 0, JSON.stringify(result));
    assert.equal(result.error, false);
    assert.equal(result.number, value + 3);
    assert.equal(result.text, "fields");
  }
}

for (const coverageLevel of [0, 2]) {
  const source = `
local function make()
    return { ["literal:key"] = "seed", flag = false, absent = nil, negative = -0.0, count = 11 }
end
return function(value, text)
    local first, second = make(), make()
    assert(first ~= second and first["literal:key"] == "seed" and first.flag == false)
    assert(first.absent == nil and 1 / first.negative == -math.huge and first.count == 11)
    first["literal:key"], first.count, first.absent = text, value, true
    table.freeze(first)
    coroutine.yield("gc-boundary")
    assert(second["literal:key"] == "seed" and second.count == 11 and second.absent == nil)
    local order = { value = "" }
    local function effect(label)
        order.value ..= label
        return label
    end
    local duplicate = { ["same"] = 1, same = effect("a"), ["same"] = 3, other = effect("b") }
    assert(order.value == "ab" and duplicate.same == 3 and duplicate.other == "b")
    local constant = { ["same"] = 1, same = 2, ["same"] = nil, flag = true }
    assert(constant.same == nil and constant.flag)
    local key = "same"
    local dynamic = { ["same"] = 1, [key] = effect("c"), same = 4 }
    assert(order.value == "abc" and dynamic.same == 4)
    local mixed = { 7, ["literal:key"] = 8, 9 }
    assert(mixed[1] == 7 and mixed[2] == 9 and mixed["literal:key"] == 8)
    return first.count, first["literal:key"]
end
`;
  const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }],
    "main", { coverageLevel });
  const instance = instantiateArtifact(compilation.artifact);
  for (const value of [7, -11, 0]) {
    const result = invoke(instance, value, "templates");
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.resultStatus, 0, JSON.stringify(result));
    assert.equal(result.error, false);
    assert.equal(result.number, value);
    assert.equal(result.text, "templates");
  }
}

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
