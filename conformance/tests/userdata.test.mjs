import { executeUserdataHooksPackageShape } from "./harness.mjs";

const userdataHooks = executeUserdataHooksPackageShape();
for (const command of [105, 141, 147, 148])
  if (!userdataHooks.commandCounts.get(command))
    throw new Error(`Phase E hook did not execute command ${command} in the userdata-hooks snapshot`);
console.log(`userdata: ${userdataHooks.objectSize} bytes/${userdataHooks.functionCount} functions`);
