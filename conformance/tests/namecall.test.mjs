import {
  executePlainTableNamecallPackageShape,
  executeEmbedNamecallFamilyPackageShape,
} from "./harness.mjs";

const plainTableNamecall = await executePlainTableNamecallPackageShape();
const embedNamecallFamily = executeEmbedNamecallFamilyPackageShape();
if (!embedNamecallFamily.commandCounts.get(172))
  throw new Error("compile-only MARK_DEAD is missing from the embed snapshot");
console.log(
  `namecall: plain ${plainTableNamecall.objectSize}, embed family ${embedNamecallFamily.objectSize}`,
);
