import { readFileSync, writeFileSync } from "node:fs";
import {
  FRONTEND_CONTRACT_DIGEST,
  LUAU_PIN_DIGEST,
  PIN,
  finishDocument,
  scanFeatures,
  sha256Hex,
} from "./wasm_bytes.mjs";

export const GENERATOR_VERSION = "luauc-wasm-features-v1";
export const PERMITTED = Object.freeze([
  "mvp",
  "mutable-globals",
  "sign-ext",
  "nontrapping-fptoint",
  "multi-value",
  "bulk-memory",
  "reference-types",
]);
export const FORBIDDEN = Object.freeze(["threads", "memory64", "gc"]);

export function generateWasmFeatures({ compiler, pack, corpus }) {
  const compilerBytes = readFileSync(compiler);
  const packBytes = readFileSync(pack);
  const corpusBytes = readFileSync(corpus);
  const artifacts = [
    scanFeatures(compilerBytes, "luauc.wasm"),
    scanFeatures(packBytes, "embed_v1.pack.wasm"),
    scanFeatures(corpusBytes, "corpus_artifact"),
  ];
  const forbiddenPresent = [...new Set(artifacts.flatMap((item) => item.forbidden_present))].sort();
  const emitted = [...new Set(artifacts.flatMap((item) => item.features))].sort();
  const document = finishDocument({
    schema_version: 1,
    generator_version: GENERATOR_VERSION,
    pin: PIN,
    luau_pin_digest: LUAU_PIN_DIGEST,
    frontend_contract_digest: FRONTEND_CONTRACT_DIGEST,
    input_sha256: {
      compiler: sha256Hex(compilerBytes),
      pack: sha256Hex(packBytes),
      corpus: sha256Hex(corpusBytes),
    },
    permitted: [...PERMITTED],
    forbidden: [...FORBIDDEN],
    emitted,
    forbidden_present: forbiddenPresent,
    artifacts,
  });
  return document;
}

export function writeWasmFeatures(path, document) {
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = Object.fromEntries(process.argv.slice(2).map((part, index, all) => (
    part.startsWith("--") ? [part.slice(2), all[index + 1]] : []
  )).filter((entry) => entry.length));
  writeWasmFeatures(args.out, generateWasmFeatures({
    compiler: args.compiler,
    pack: args.pack,
    corpus: args.corpus,
  }));
}
