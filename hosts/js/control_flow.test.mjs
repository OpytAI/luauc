import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { compilePackage, instantiateArtifact, invoke } from "./host.mjs";

const runfile = name => readFileSync(join(process.env.RUNFILES_DIR, process.env[name]));
const compiler = runfile("LUAUC_COMPILER_WASM");
const profile = runfile("LUAUC_EMBED_PROFILE");
const pack = runfile("LUAUC_EMBED_PACK");

for (const count of [8, 96]) {
  for (const suspend of [false, true]) {
    const branches = Array.from({ length: count }, (_, index) => `
        if (value + iteration) % 97 == ${index} then
            total += step(${index + 1})
        else
            total -= 1
        end
    `).join("\n");
    const source = `
local function step(amount)
    ${suspend ? 'coroutine.yield("gc-boundary")' : ""}
    return amount * 2
end
return function(value, text)
    local total = 0
    for iteration = 1, 3 do
        ${branches}
    end
    local success, result = pcall(function()
        if value == 13 then error("branch error") end
        return total + value
    end)
    if not success then return total - value, text end
    return result, text
end
`;
    const compilation = await compilePackage(compiler, profile, pack, [{ name: "main", source }]);
    assert.ok(WebAssembly.validate(compilation.artifact));
    const instance = instantiateArtifact(compilation.artifact);
    for (const value of [-7, 0, 13, 96]) {
      let total = 0;
      for (let iteration = 1; iteration <= 3; iteration++) {
        const selected = ((value + iteration) % 97 + 97) % 97;
        total += selected < count ? (selected + 1) * 2 - count + 1 : -count;
      }
      const result = invoke(instance, value, "structured control");
      assert.equal(result.status, 0);
      assert.equal(result.resultStatus, 0);
      assert.equal(result.error, false);
      assert.equal(result.number, total + (value === 13 ? -value : value));
      assert.equal(result.text, "structured control");
    }
    console.log(`control flow count=${count} suspend=${suspend}: ${compilation.artifact.length} bytes`);
  }
}
