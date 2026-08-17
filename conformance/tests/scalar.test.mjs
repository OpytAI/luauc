import { executeCase, executeSilentRoot } from "./harness.mjs";

const scalar = await executeCase(
  "scalar",
  "return function(n) return n * 2 + 1 end",
  [
    [1, 3],
    [4, 9],
    [7, 15],
  ],
);
const loop = await executeCase(
  "loop",
  "return function(n) local sum = 0 for i = 1, n do sum += i end return sum end",
  [
    [1, 1],
    [4, 10],
    [7, 28],
  ],
);
const silent = await executeSilentRoot();
console.log(`scalar ${scalar.objectSize} bytes, loop ${loop.objectSize} bytes, silent ${silent.objectSize} bytes`);
