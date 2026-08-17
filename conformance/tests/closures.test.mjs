import {
  executeCapturedCallPackage,
  executeReferenceCapturePackage,
  executeForwardedCapturePackageShape,
} from "./harness.mjs";

const capturedCall = await executeCapturedCallPackage();
const referenceCapture = await executeReferenceCapturePackage();
const forwardedCapture = executeForwardedCapturePackageShape();
console.log(
  `closures: captured ${capturedCall.objectSize}, reference ${referenceCapture.objectSize}, ` +
    `forwarded ${forwardedCapture.objectSize}`,
);
