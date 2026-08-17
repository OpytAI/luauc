import { readFileSync } from "node:fs";
import {
  backendPackage,
  executeCase,
  frontendSnapshot,
  runfile,
  snapshotShape,
} from "./harness.mjs";

function source(variable) {
  return readFileSync(runfile(process.env[variable], variable), "utf8");
}

function compileOnce(name, text) {
  const first = frontendSnapshot(text, `@${name}.luau`);
  const second = frontendSnapshot(text, `@${name}.luau`);
  if (!first.equals(second)) throw new Error(`${name}: frontend snapshot is nondeterministic`);
  const object = backendPackage(first);
  const again = backendPackage(first);
  if (!object.equals(again)) throw new Error(`${name}: backend package is nondeterministic`);
  return object;
}

const numeric = await executeCase(
  "loop",
  source("LUAUC_NUMERIC_LOOP_SOURCE"),
  [
    [1, 1],
    [4, 10],
    [7, 28],
  ],
);
function requireFamilyCommands(name, text, required) {
  const snapshot = frontendSnapshot(text, `@${name}.luau`);
  const shape = snapshotShape(snapshot);
  const present = new Set();
  for (let functionId = 0; functionId < shape.functionCount; functionId++) {
    for (let instructionId = 0; instructionId < shape.instructionCount(functionId); instructionId++)
      present.add(shape.instruction(functionId, instructionId).command);
  }
  for (const command of required) {
    if (!present.has(command))
      throw new Error(`${name}: missing IrCmd ${command}`);
  }
  return compileOnce(name, text);
}

const integer = requireFamilyCommands("natural_integer", source("LUAUC_NATURAL_INTEGER_SOURCE"), [
  24, 25, 28, 107,
]);
const bit32 = requireFamilyCommands("natural_bit32", source("LUAUC_NATURAL_BIT32_SOURCE"), [
  185, 194,
]);
const buffer = requireFamilyCommands("natural_buffer", source("LUAUC_NATURAL_BUFFER_SOURCE"), [
  201, 203, 206, 208, 211, 212,
]);
if (!integer.length || !bit32.length || !buffer.length)
  throw new Error("natural integer/bit32/buffer sources produced empty objects");
console.log(
  `natural sources: numeric ${numeric.objectSize}, integer ${integer.length}, bit32 ${bit32.length}, buffer ${buffer.length}`,
);
