import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = (name) => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");
const padding = `local padding = { ${Array.from({ length: 8 }, (_, index) =>
  `function() return ${index} end`).join(", ")} }`;

async function compile(source) {
  return compilePackage(compiler, profile, pack, [{ name: "main", source }]);
}

for (const suspend of [false, true]) {
  const sizes = [];
  for (const count of [8, 16, 32]) {
    const compilation = await compile(`
${padding}
local function step(value)
    ${suspend ? 'coroutine.yield("gc-boundary")' : ""}
    return value + 1
end
return function(value, text)
    ${Array.from({ length: count }, () => "value = step(value)").join("\n    ")}
    return value + #padding - 8, text
end
`);
    sizes.push(compilation.artifact.length);
    const instance = instantiateArtifact(compilation.artifact);
    for (const value of [-7, 0, 13]) {
      const result = invoke(instance, value, "shared calls");
      assert.equal(result.status, 0);
      assert.equal(result.resultStatus, 0);
      assert.equal(result.error, false);
      assert.equal(result.number, value + count);
      assert.equal(result.text, "shared calls");
    }
  }
  assert.ok(sizes[2] - sizes[1] < (sizes[1] - sizes[0]) * 2.5,
    `shared continuation growth: ${sizes.join(", ")}`);
  assert.ok(sizes[2] - sizes[1] < 16 * 220,
    `shared call lowering exceeds 220 bytes per added call: ${sizes.join(", ")}`);
  console.log(`shared call sizes (suspend=${suspend}): ${sizes.join(", ")}`);
}

const semantics = await compile(`
${padding}
local function counter(value)
    return function()
        value += 1
        return value
    end
end
return function(value, text)
    local nextValue = counter(value)
    coroutine.yield("gc-boundary")
    local total = nextValue() + nextValue() + #padding
    local values = { 3, 5, 7 }
    for _, item in ipairs(values) do total += item end
    values[2] = nil
    for _, item in pairs(values) do total += item end
    local step = 0
    local iterator = setmetatable({}, { __call = function()
        step += 1
        coroutine.yield("gc-boundary")
        if step == 1 then return false, 11 end
        if step == 2 then return 2, 13 end
        return nil
    end })
    for key, item in iterator do
        assert(key == false or key == 2)
        total += item
    end
    assert(text:find("a.", 1, true) == nil)
    assert(text:match("^%a+$") == text)
    return total, text:sub(2, -2)
end
`);
const instance = instantiateArtifact(semantics.artifact);
for (const [value, text] of [[-3, "alpha"], [0, "beta"], [7, "gamma"]]) {
  const result = invoke(instance, value, text);
  assert.equal(result.status, 0);
  assert.equal(result.resultStatus, 0);
  assert.equal(result.error, false);
  assert.equal(result.number, 2 * value + 60);
  assert.equal(result.text, text.slice(1, -1));
}

const unsafeEnvironment = await compile(`
${padding}
local function overridden(value)
    local environment = {}
    for key, item in pairs(getfenv()) do environment[key] = item end
    environment.math = { floor = function(number) return number + 17 end }
    setfenv(1, environment)
    return math.floor(value)
end
return function(value, text)
    return overridden(value) + #padding - 8, text
end
`);
const unsafeInstance = instantiateArtifact(unsafeEnvironment.artifact);
for (const value of [-3, 0, 7]) {
  const result = invoke(unsafeInstance, value, "unsafe environment");
  assert.equal(result.status, 0);
  assert.equal(result.resultStatus, 0);
  assert.equal(result.error, false);
  assert.equal(result.number, value + 17);
  assert.equal(result.text, "unsafe environment");
}
