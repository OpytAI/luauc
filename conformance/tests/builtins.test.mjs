import { executeFastBuiltinsPackage } from "./harness.mjs";

const fastBuiltins = await executeFastBuiltinsPackage();
console.log(`builtins: ${fastBuiltins.objectSize} bytes/${fastBuiltins.functionCount} functions`);
