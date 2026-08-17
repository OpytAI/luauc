import { executeProtoIdentityControlPackageShape } from "./harness.mjs";

const protoIdentityControl = await executeProtoIdentityControlPackageShape();
console.log(`proto identity: ${protoIdentityControl.objectSize} bytes/${protoIdentityControl.functionCount} functions`);
