import { executeCoveragePackageShape } from "./harness.mjs";

const coverage = await executeCoveragePackageShape();
console.log(`coverage: ${coverage.objectSize} bytes/${coverage.sites} sites`);
