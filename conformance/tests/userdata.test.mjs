import { readFileSync } from "node:fs";
import { executeUserdataHooksPackageShape, frontendSnapshot, runfile, snapshotShape } from "./harness.mjs";

const userdataHooks = executeUserdataHooksPackageShape();
for (const command of [105, 141, 148])
  if (!userdataHooks.commandCounts.get(command))
    throw new Error(`Phase E hook did not execute command ${command} in the userdata-hooks snapshot`);

const source = readFileSync(
  runfile(process.env.LUAUC_USERDATA_HOOKS_SOURCE, "LUAUC_USERDATA_HOOKS_SOURCE"),
  "utf8",
);
const shape = snapshotShape(frontendSnapshot(source, "@userdata_hooks.luau"));
const unitOpcodes = new Map();
for (let functionId = 0; functionId < shape.functionCount; functionId++) {
  for (let instructionId = 0; instructionId < shape.instructionCount(functionId); instructionId++) {
    const command = shape.instruction(functionId, instructionId).command;
    unitOpcodes.set(command, (unitOpcodes.get(command) ?? 0) + 1);
  }
}
for (const [command, label] of [
  [209, "BUFFER_READF32"],
  [38, "MUL_NUM"],
  [49, "SQRT_NUM"],
  [64, "SELECT_NUM"],
  [105, "NEW_USERDATA"],
  [141, "CHECK_USERDATA_TAG"],
]) {
  if (!unitOpcodes.get(command))
    throw new Error(`Unit/Mark IR is missing ${label} (${command})`);
}
console.log(`userdata: ${userdataHooks.objectSize} bytes/${userdataHooks.functionCount} functions`);
