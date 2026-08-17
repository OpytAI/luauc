import { readFileSync } from "node:fs";
import {
  backendPackage,
  executeCase,
  frontendSnapshot,
  runfile,
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
const integer = compileOnce("natural_integer", source("LUAUC_NATURAL_INTEGER_SOURCE"));
const bit32 = compileOnce("natural_bit32", source("LUAUC_NATURAL_BIT32_SOURCE"));
const buffer = compileOnce("natural_buffer", source("LUAUC_NATURAL_BUFFER_SOURCE"));
if (!integer.length || !bit32.length || !buffer.length)
  throw new Error("natural integer/bit32/buffer sources produced empty objects");
console.log(
  `natural sources: numeric ${numeric.objectSize}, integer ${integer.length}, bit32 ${bit32.length}, buffer ${buffer.length}`,
);
