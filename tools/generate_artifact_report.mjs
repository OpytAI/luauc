import { readFileSync, writeFileSync } from "node:fs";
import {
  FRONTEND_CONTRACT_DIGEST,
  LUAU_PIN_DIGEST,
  PIN,
  finishDocument,
  parseCoreModule,
  scanFeatures,
  sha256Hex,
} from "./wasm_bytes.mjs";

export const GENERATOR_VERSION = "luauc-artifact-report-v1";

function describeArtifact(label, bytes, extra = {}) {
  const module = parseCoreModule(bytes);
  const features = scanFeatures(bytes, label);
  return {
    label,
    sha256: sha256Hex(bytes),
    size: bytes.length,
    imports: module.imports.items.map((item) => `${item.module}.${item.name}`).sort(),
    exports: module.exportNames,
    function_count: module.functionCount,
    memory_min: module.memoryMin,
    helpers: module.imports.items
      .map((item) => item.name)
      .filter((name) => name.startsWith("luauc_runtime_v1_"))
      .sort(),
    features: features.features,
    ...extra,
  };
}

export function generateArtifactReport({ artifacts, gates = [] }) {
  const entries = artifacts.map(({ label, path, bytes, extra }) => (
    describeArtifact(label, bytes ?? readFileSync(path), extra ?? {})
  ));
  return finishDocument({
    schema_version: 1,
    generator_version: GENERATOR_VERSION,
    pin: PIN,
    luau_pin_digest: LUAU_PIN_DIGEST,
    frontend_contract_digest: FRONTEND_CONTRACT_DIGEST,
    input_sha256: Object.fromEntries(entries.map((item) => [item.label, item.sha256])),
    gates,
    artifacts: entries,
  });
}

export function writeArtifactReport(path, document) {
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
}
