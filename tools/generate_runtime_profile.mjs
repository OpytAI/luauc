import { readFileSync, writeFileSync } from "node:fs";
import {
  FRONTEND_CONTRACT_DIGEST,
  PIN,
  finishDocument,
  parseRuntimeProfile,
  sha256Hex,
} from "./wasm_bytes.mjs";

export const GENERATOR_VERSION = "luauc-runtime-profile-v1";

export function generateRuntimeProfile({ profilePath, policyPath, packPath }) {
  const profileBytes = readFileSync(profilePath);
  const policyBytes = readFileSync(policyPath);
  const packBytes = packPath ? readFileSync(packPath) : null;
  const profile = parseRuntimeProfile(profileBytes);
  const policy = JSON.parse(policyBytes.toString("utf8"));
  if (policy.profile_id !== profile.profile_id) {
    throw new Error(`policy profile_id ${policy.profile_id} != profile ${profile.profile_id}`);
  }
  const document = finishDocument({
    schema_version: 1,
    generator_version: GENERATOR_VERSION,
    pin: PIN,
    luau_pin_digest: profile.luau_pin_sha256,
    frontend_contract_digest: FRONTEND_CONTRACT_DIGEST,
    input_sha256: {
      profile: sha256Hex(profileBytes),
      policy: sha256Hex(policyBytes),
      pack: packBytes ? sha256Hex(packBytes) : null,
    },
    profile_id: profile.profile_id,
    feature_mask: profile.feature_mask,
    memory_minimum: profile.memory_minimum,
    memory_maximum: profile.memory_maximum,
    table_minimum: profile.table_minimum,
    table_maximum: profile.table_maximum,
    identities: {
      luau_pin_sha256: profile.luau_pin_sha256,
      runtime_abi_sha256: profile.runtime_abi_sha256,
      object_contract_sha256: profile.object_contract_sha256,
      pack_build_sha256: profile.pack_build_sha256,
      license_inventory_sha256: profile.license_inventory_sha256,
    },
    host_imports: profile.host_imports,
    retained_exports: profile.retained_exports,
    runtime_symbols: profile.runtime_symbols.map((item) => item.name),
    bindings: profile.bindings,
    policy,
  });
  return document;
}

export function writeRuntimeProfile(path, document) {
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = Object.fromEntries(process.argv.slice(2).map((part, index, all) => (
    part.startsWith("--") ? [part.slice(2), all[index + 1]] : []
  )).filter((entry) => entry.length));
  writeRuntimeProfile(args.out, generateRuntimeProfile({
    profilePath: args.profile,
    policyPath: args.policy,
    packPath: args.pack,
  }));
}
