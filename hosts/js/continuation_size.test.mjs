import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = (name) => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");

function source(count, suspend) {
  return `
local function step(value)
    ${suspend ? 'coroutine.yield("gc-boundary")' : ""}
    return value + 1
end
return function(value, text)
    ${Array.from({ length: count }, () => "value = step(value)").join("\n    ")}
    return value, text
end
`;
}

for (const suspend of [false, true]) {
  const sizes = [];
  for (const count of [8, 16, 32]) {
    const compilation = await compilePackage(compiler, profile, pack, [
      { name: "main", source: source(count, suspend) },
    ]);
    sizes.push(compilation.artifact.length);
    const instance = instantiateArtifact(compilation.artifact);
    for (const value of [-7, 0, 13]) {
      const result = invoke(instance, value, "continuations");
      assert.equal(result.status, 0);
      assert.equal(result.resultStatus, 0);
      assert.equal(result.error, false);
      assert.equal(result.number, value + count);
      assert.equal(result.text, "continuations");
    }
  }
  const firstGrowth = sizes[1] - sizes[0];
  const secondGrowth = sizes[2] - sizes[1];
  assert.ok(firstGrowth > 0);
  assert.ok(secondGrowth < firstGrowth * 2.5,
    `continuation tails grow faster than linearly: ${sizes.join(", ")}`);
  console.log(`continuation sizes (suspend=${suspend}): ${sizes.join(", ")}`);
}

const captureSource = `
${Array.from({ length: 10 }, (_, index) => `local convert${index} = tostring`).join("\n")}
local padding = { ${Array.from({ length: 8 }, (_, index) => `function() return ${index} end`).join(", ")} }
return function(value, text)
    return value + #padding, ${Array.from({ length: 10 }, (_, index) => `convert${index}(value)`).join(" .. ")}
end
`;
const captures = await compilePackage(compiler, profile, pack, [{ name: "main", source: captureSource }]);
const captureInstance = instantiateArtifact(captures.artifact);
for (const value of [-3, 0, 7]) {
  const result = invoke(captureInstance, value, "captures");
  assert.equal(result.status, 0);
  assert.equal(result.resultStatus, 0);
  assert.equal(result.error, false);
  assert.equal(result.number, value + 8);
  assert.equal(result.text, String(value).repeat(10));
}
