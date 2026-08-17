import { executeBufferScalarMatrixPackage } from "./harness.mjs";

const bufferScalarMatrix = await executeBufferScalarMatrixPackage();
console.log(`buffers: ${bufferScalarMatrix.objectSize} bytes/${bufferScalarMatrix.functionCount} functions`);
