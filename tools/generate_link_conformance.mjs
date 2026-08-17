import { writeFileSync } from "node:fs";
import {
  FRONTEND_CONTRACT_DIGEST,
  LUAU_PIN_DIGEST,
  PIN,
  finishDocument,
} from "./wasm_bytes.mjs";

export const GENERATOR_VERSION = "luauc-link-conformance-v1";

export function generateLinkConformance(objects) {
  return finishDocument({
    schema_version: 1,
    generator_version: GENERATOR_VERSION,
    pin: PIN,
    luau_pin_digest: LUAU_PIN_DIGEST,
    frontend_contract_digest: FRONTEND_CONTRACT_DIGEST,
    objects,
  });
}

export function writeLinkConformance(path, document) {
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
}
