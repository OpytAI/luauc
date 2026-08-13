#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { instantiateArtifact, invoke } from "./host.mjs";

const [artifactPath, ...arguments_] = process.argv.slice(2);
if (!artifactPath || !arguments_.length || arguments_.length % 2 !== 0)
  throw new Error("usage: luauc-embed-js <artifact.wasm> <number> <text> [<number> <text> ...]");
const instance = instantiateArtifact(readFileSync(artifactPath));
for (let index = 0; index < arguments_.length; index += 2) {
  const input = Number(arguments_[index]);
  if (!Number.isSafeInteger(input)) throw new Error(`invalid integer input ${JSON.stringify(arguments_[index])}`);
  const label = arguments_[index + 1];
  const result = invoke(instance, input, label);
  if (result.status || result.resultStatus || result.error)
    throw new Error(`runtime invocation failed: ${JSON.stringify(result)}`);
  process.stdout.write(`result=${input}|${label}|${result.number}|${result.text}\n`);
}
