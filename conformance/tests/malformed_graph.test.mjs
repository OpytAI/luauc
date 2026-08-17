import { executeEmbedNamecallFamilyPackageShape } from "./harness.mjs";

// Malformed half of the embed NAMECALL family lives in the same helper: it
// mutates snapshot operands and expects package rejection before linking.
const embedNamecallFamily = executeEmbedNamecallFamilyPackageShape();
if (!embedNamecallFamily.objectSize)
  throw new Error("embed NAMECALL malformed suite produced no object");
console.log(`malformed graph: embed NAMECALL family ${embedNamecallFamily.objectSize} bytes`);
