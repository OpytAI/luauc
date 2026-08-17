import { readFileSync, writeFileSync } from "node:fs";
import {
  FRONTEND_CONTRACT_DIGEST,
  LUAU_PIN_DIGEST,
  PIN,
  finishDocument,
  sha256Hex,
} from "./wasm_bytes.mjs";

export const GENERATOR_VERSION = "luauc-runtime-symbols-v1";

function quotedStrings(text) {
  return [...text.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

export function parseGeneratedSymbols(bzlText) {
  const match = bzlText.match(/AOT_GENERATED_RUNTIME_SYMBOLS\s*=\s*\[([\s\S]*?)\]/);
  if (!match) throw new Error("AOT_GENERATED_RUNTIME_SYMBOLS not found");
  const names = quotedStrings(match[1]);
  if (!names.length) throw new Error("AOT_GENERATED_RUNTIME_SYMBOLS is empty");
  return names;
}

export function parseHeaderSymbols(headerText) {
  const names = new Set();
  const re = /\bluauc_runtime_v1_[A-Za-z0-9_]+/g;
  let match;
  while ((match = re.exec(headerText))) names.add(match[0]);
  if (!names.size) throw new Error("aot_runtime_v1.h declares no luauc_runtime_v1_* symbols");
  return [...names].sort();
}

export function parsePackExports(buildText) {
  const match = buildText.match(/PACK_EXPORTS\s*=\s*\[([\s\S]*?)\]/);
  if (!match) throw new Error("PACK_EXPORTS not found");
  const explicit = quotedStrings(match[1]);
  return {
    explicit,
    includes_generated_list: match[1].includes("AOT_GENERATED_RUNTIME_SYMBOLS"),
  };
}

export function generateRuntimeSymbols({ symbolsBzl, runtimeHeader, embedBuild }) {
  const bzlText = readFileSync(symbolsBzl);
  const headerText = readFileSync(runtimeHeader);
  const buildText = readFileSync(embedBuild);
  const generated = parseGeneratedSymbols(bzlText.toString("utf8"));
  const header = parseHeaderSymbols(headerText.toString("utf8"));
  const pack = parsePackExports(buildText.toString("utf8"));
  const headerSet = new Set(header);
  const missingFromHeader = generated.filter((name) => !headerSet.has(name));
  if (missingFromHeader.length) {
    throw new Error(`generated symbols missing from aot_runtime_v1.h: ${missingFromHeader.join(", ")}`);
  }
  const packExports = pack.includes_generated_list
    ? [...pack.explicit, ...generated]
    : pack.explicit;
  const document = finishDocument({
    schema_version: 1,
    generator_version: GENERATOR_VERSION,
    pin: PIN,
    luau_pin_digest: LUAU_PIN_DIGEST,
    frontend_contract_digest: FRONTEND_CONTRACT_DIGEST,
    input_sha256: {
      runtime_symbols_bzl: sha256Hex(bzlText),
      aot_runtime_v1_h: sha256Hex(headerText),
      embed_build: sha256Hex(buildText),
    },
    generated_runtime_symbols: generated,
    header_symbols: header,
    pack_exports: packExports,
    program_symbol: {
      name: "luauc_runtime_v1_program",
      kind: "data",
      match: "symbol_name",
      note: "Generated objects export this data symbol; the linker matches it by name, not as a pack function export.",
    },
  });
  return document;
}

export function writeRuntimeSymbols(path, document) {
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = Object.fromEntries(process.argv.slice(2).map((part, index, all) => (
    part.startsWith("--") ? [part.slice(2), all[index + 1]] : []
  )).filter((entry) => entry.length));
  const document = generateRuntimeSymbols({
    symbolsBzl: args.symbols,
    runtimeHeader: args.header,
    embedBuild: args.build,
  });
  writeRuntimeSymbols(args.out, document);
}
