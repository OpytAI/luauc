import { executeGenericIterationPackage } from "./harness.mjs";

const genericIteration = await executeGenericIterationPackage();
console.log(`iteration: ${genericIteration.objectSize} bytes/${genericIteration.functionCount} functions`);
