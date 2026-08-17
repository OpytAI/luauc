import {
  executeCompiledCallPackage,
  executeMultiResultCallPackage,
  executeRecursiveCallPackageShape,
  executeYieldCallPackage,
} from "./harness.mjs";

const compiledCall = await executeCompiledCallPackage();
const multiResultCall = await executeMultiResultCallPackage();
const recursiveCall = await executeRecursiveCallPackageShape();
const yieldCall = await executeYieldCallPackage();
console.log(
  `calls: compiled ${compiledCall.objectSize}, multi ${multiResultCall.objectSize}, ` +
    `recursive ${recursiveCall.objectSize}, yield ${yieldCall.objectSize}`,
);
