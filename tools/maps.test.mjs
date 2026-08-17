import { readFileSync } from "node:fs";
import { join } from "node:path";
import { canonicalHashOf } from "./wasm_bytes.mjs";
import { generateRuntimeSymbols } from "./generate_runtime_symbols.mjs";
import { generateRuntimeProfile } from "./generate_runtime_profile.mjs";
import { generateWasmFeatures } from "./generate_wasm_features.mjs";
import { generateArtifactReport } from "./generate_artifact_report.mjs";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const direct = join(root, relative);
  try {
    readFileSync(direct);
    return direct;
  } catch {
    return join(root, "_main", relative);
  }
}

function loadJson(variable) {
  return JSON.parse(readFileSync(runfile(process.env[variable], variable), "utf8"));
}

function assertSame(name, generated, checked) {
  if (generated.canonical_hash !== checked.canonical_hash) {
    throw new Error(
      `${name} drifted (checked ${checked.canonical_hash}, generated ${generated.canonical_hash})`,
    );
  }
  if (canonicalHashOf((({ canonical_hash, ...rest }) => rest)(generated)) !== generated.canonical_hash) {
    throw new Error(`${name} canonical_hash is not self-consistent`);
  }
}

const symbols = generateRuntimeSymbols({
  symbolsBzl: runfile(process.env.LUAUC_RUNTIME_SYMBOLS_BZL, "LUAUC_RUNTIME_SYMBOLS_BZL"),
  runtimeHeader: runfile(process.env.LUAUC_RUNTIME_HEADER, "LUAUC_RUNTIME_HEADER"),
  embedBuild: runfile(process.env.LUAUC_EMBED_BUILD, "LUAUC_EMBED_BUILD"),
});
assertSame("runtime_symbols.json", symbols, loadJson("LUAUC_RUNTIME_SYMBOLS"));
if (!symbols.generated_runtime_symbols.includes("luauc_runtime_v1_call")) {
  throw new Error("generated runtime symbols omit luauc_runtime_v1_call");
}
if (symbols.program_symbol.name !== "luauc_runtime_v1_program") {
  throw new Error("program symbol must stay a name-only data match");
}
if (symbols.generated_runtime_module !== "env") {
  throw new Error(`generated_runtime_module must be env, got ${symbols.generated_runtime_module}`);
}

const profile = generateRuntimeProfile({
  profilePath: runfile(process.env.LUAUC_EMBED_PROFILE, "LUAUC_EMBED_PROFILE"),
  policyPath: runfile(process.env.LUAUC_EMBED_POLICY, "LUAUC_EMBED_POLICY"),
  packPath: runfile(process.env.LUAUC_EMBED_PACK, "LUAUC_EMBED_PACK"),
});
assertSame("runtime_profile.json", profile, loadJson("LUAUC_RUNTIME_PROFILE"));
if (profile.profile_id !== "embed-v1") throw new Error(`unexpected profile_id ${profile.profile_id}`);
if (!profile.runtime_symbols.includes("luauc_runtime_v1_call")) {
  throw new Error("profile runtime_symbols omit luauc_runtime_v1_call");
}

const features = generateWasmFeatures({
  compiler: runfile(process.env.LUAUC_COMPILER_WASM, "LUAUC_COMPILER_WASM"),
  pack: runfile(process.env.LUAUC_EMBED_PACK, "LUAUC_EMBED_PACK"),
  corpus: runfile(process.env.LUAUC_CORPUS_ARTIFACT, "LUAUC_CORPUS_ARTIFACT"),
});
assertSame("wasm_features.json", features, loadJson("LUAUC_WASM_FEATURES"));
for (const artifact of features.artifacts) {
  if (artifact.label === "luauc.wasm") continue;
  if (artifact.forbidden_present.length) {
    throw new Error(
      `${artifact.label} contains forbidden Wasm features: ${artifact.forbidden_present.join(", ")}`,
    );
  }
}

const report = generateArtifactReport({
  artifacts: [
    { label: "luauc.wasm", path: runfile(process.env.LUAUC_COMPILER_WASM, "LUAUC_COMPILER_WASM") },
    { label: "embed_v1.pack.wasm", path: runfile(process.env.LUAUC_EMBED_PACK, "LUAUC_EMBED_PACK") },
    { label: "scalar_fixture.wasm", path: runfile(process.env.LUAUC_CORPUS_ARTIFACT, "LUAUC_CORPUS_ARTIFACT") },
  ],
  gates: [
    "//hosts/js:embed_test",
    "//hosts/js:cli_test",
    "//hosts/wasmtime:parity_test",
    "//compiler/link:corpus_test",
  ],
});
assertSame("artifact_report.json", report, loadJson("LUAUC_ARTIFACT_REPORT"));
if (report.artifacts.some((item) => item.imports.length === 0 && item.label === "missing")) {
  throw new Error("artifact report is empty");
}

console.log(
  `maps up to date: ${symbols.generated_runtime_symbols.length} generated symbols, ` +
  `profile ${profile.profile_id}, features ${features.emitted.join(",")}`,
);
