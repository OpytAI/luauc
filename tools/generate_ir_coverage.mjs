import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  COMMAND_COUNT,
  LEDGER_GENERATOR_VERSION,
  PIN,
  QUALIFYING_GATES,
  USERDATA_HELPERS,
  canonicalHashOf,
  canonicalJson,
  censusFormsFor,
  commandCatalog,
  compileBackendPackage,
  compileFrontendSnapshot,
  hexOfBytes,
  instantiateZeroImport,
  isCompileOnly,
  loadJson,
  parseSnapshot,
  parseWasmFunctionImports,
  walkSnapshot,
} from "./ir_ledger.mjs";
import { generateGeneralArms } from "./generate_general_arms.mjs";
import { generateCompilerBuildDigest } from "./generate_compiler_build_digest.mjs";

const WORKSPACE = dirname(dirname(fileURLToPath(import.meta.url)));

const FRONTEND_TO_WASM_SOURCES = new Set([
  "buffer_scalar_matrix",
  "captured_call",
  "compiled_call",
  "dynamic_array_table",
  "dynamic_hash_table",
  "dynamic_string",
  "fast_builtins",
  "forwarded_capture",
  "generic_iteration",
  "generic_table",
  "global_state",
  "mixed_table",
  "multi_result_call",
  "reference_capture",
  "recursive_call",
  "silent_return",
  "slow_add",
  "table_clone_append",
  "table_namecall",
  "yield_call",
  "embed_lib",
  "proto_identity",
  "userdata_hooks",
]);

const PARITY_SOURCES = new Set([
  "embed_lib",
  "embed_main",
  "proto_identity",
  "userdata_hooks",
]);

function emptyRowState() {
  return {
    census_sources: new Set(),
    census_forms: new Set(),
    lowered_sources: new Set(),
    operand_kinds: new Set(),
    block_kinds: new Set(),
    import_sets: [],
    reachability: "none",
  };
}

function intersectSorted(sets) {
  if (sets.length === 0) return [];
  let current = new Set(sets[0]);
  for (const next of sets.slice(1)) {
    current = new Set([...current].filter((item) => next.has(item)));
  }
  return [...current].sort();
}

const NATURAL_SOURCES = new Set([
  "numeric_loop",
  "natural_integer",
  "natural_bit32",
  "natural_buffer",
]);

const FAMILY_TESTS = Object.freeze({
  buffer_scalar_matrix: "//conformance/tests:buffers_test",
  captured_call: "//conformance/tests:calls_test",
  compiled_call: "//conformance/tests:calls_test",
  dynamic_array_table: "//conformance/tests:tables_test",
  dynamic_hash_table: "//conformance/tests:tables_test",
  dynamic_string: "//conformance/tests:tables_test",
  fast_builtins: "//conformance/tests:builtins_test",
  forwarded_capture: "//conformance/tests:closures_test",
  generic_iteration: "//conformance/tests:iteration_test",
  generic_table: "//conformance/tests:tables_test",
  global_state: "//conformance/tests:tables_test",
  mixed_table: "//conformance/tests:tables_test",
  multi_result_call: "//conformance/tests:calls_test",
  reference_capture: "//conformance/tests:closures_test",
  recursive_call: "//conformance/tests:calls_test",
  silent_return: "//conformance/tests:scalar_test",
  slow_add: "//conformance/tests:operators_test",
  table_clone_append: "//conformance/tests:tables_test",
  table_namecall: "//conformance/tests:namecall_test",
  yield_call: "//conformance/tests:calls_test",
  embed_lib: "//conformance/tests:frontend_to_wasm_test",
  proto_identity: "//conformance/tests:proto_identity_test",
  userdata_hooks: "//conformance/tests:userdata_test",
  userdata_hold: "//hosts/wasmtime:barrier_parity_test",
  userdata_store: "//hosts/wasmtime:barrier_parity_test",
  numeric_loop: "//conformance/tests:natural_sources_test",
  natural_integer: "//conformance/tests:natural_sources_test",
  natural_bit32: "//conformance/tests:natural_sources_test",
  natural_buffer: "//conformance/tests:natural_sources_test",
});

function existingTests(sourceIds) {
  const tests = [];
  const seen = new Set();
  for (const id of sourceIds) {
    const label = FAMILY_TESTS[id];
    if (label && !seen.has(label)) {
      seen.add(label);
      tests.push(label);
    }
  }
  if (sourceIds.some((id) => PARITY_SOURCES.has(id))) {
    for (const label of ["//hosts/js:embed_test", "//hosts/wasmtime:parity_test"]) {
      if (!seen.has(label)) {
        seen.add(label);
        tests.push(label);
      }
    }
  }
  return tests;
}

function executedGates(sourceIds, options) {
  const gates = [];
  if (sourceIds.some((id) => PARITY_SOURCES.has(id))) gates.push("//hosts/wasmtime:parity_test");
  if (options.oracleGates && sourceIds.some((id) => PARITY_SOURCES.has(id))) {
    gates.push("//hosts/js:embed_test", "//hosts/js:cli_test");
  }
  if (options.measurementGate) gates.push("//conformance:runtime_measurement_test");
  if (sourceIds.some((id) => id === "userdata_hold" || id === "userdata_store")) {
    gates.push("//hosts/wasmtime:barrier_parity_test");
  }
  return [...new Set(gates)];
}

function classify(row, state, spec, generalArm, options) {
  const census = [...state.census_sources];
  if (census.length === 0) {
    if (spec.evidence?.kind === "isolated_hold_strip") {
      return { status: "partial", reachability: "published_hook" };
    }
    return {
      status: "frontend_unreachable",
      reachability: "none",
    };
  }
  const reachability = state.reachability;
  const forms = spec.forms ?? [];
  const missingForms = forms.filter((form) => !state.census_forms.has(form.id));
  const emptyFormsHole = forms.length === 0 && spec.class !== "compile_only";
  const evidenceOk = evidenceSatisfied(spec.evidence, options, state);
  const tests = existingTests(census);
  const gates = executedGates(census, options);
  const lowered = [...state.lowered_sources];
  const compileOnly = spec.class === "compile_only" || isCompileOnly(row);
  const generalOk = generalArm || compileOnly;
  // Over-approximated lowering (successful backendPackage) cannot promote a row.
  const canImplement = !options.overApproximateLowering &&
    census.length > 0 &&
    missingForms.length === 0 &&
    !emptyFormsHole &&
    lowered.length > 0 &&
    generalOk &&
    gates.length > 0 &&
    tests.length > 0 &&
    evidenceOk;
  if (canImplement) {
    return { status: "implemented", reachability };
  }
  return { status: "partial", reachability };
}

function evidenceSatisfied(evidence, options, state) {
  if (!evidence) return true;
  if (evidence.kind === "hook_unit_mark") return options.hookUnitMarkSatisfied === true;
  if (evidence.kind === "isolated_hold_strip") {
    return options.isolatedStripSatisfied === true && state.census_sources.has("userdata_hold");
  }
  if (evidence.kind === "isolated_store_strip") {
    return options.isolatedStripSatisfied === true && state.census_sources.has("userdata_store");
  }
  return false;
}

export async function generateIrCoverage(paths, options = {}) {
  const formsSpec = loadJson(paths.forms);
  const corpus = loadJson(paths.corpus);
  const fixture = loadJson(paths.fixture);
  const dispatchSource = readFileSync(paths.dispatch, "utf8");
  const catalog = commandCatalog(formsSpec);
  const generalArms = generateGeneralArms(dispatchSource, formsSpec, fixture);
  const frontend = await instantiateZeroImport(paths.frontend, "frontend");
  const backend = await instantiateZeroImport(paths.backend, "backend");
  frontend.exports.luauc_frontend_v1_init();

  const states = new Map();
  for (const name of catalog.byName.keys()) states.set(name, emptyRowState());
  const seenOperand = new Set();
  const seenBlock = new Set();
  let pinDigest = null;
  let contractDigest = null;
  let irEnumDigest = null;

  for (const entry of corpus.sources) {
    const sourcePath = options.resolveSource
      ? options.resolveSource(entry)
      : join(WORKSPACE, entry.path);
    const sourceText = readFileSync(sourcePath, "utf8");
    const snapshot = compileFrontendSnapshot(
      frontend.exports,
      sourceText,
      `@${entry.source}.luau`,
      entry.coverage_level ?? 0,
      entry.inline_plans ?? null,
    );
    const parsed = parseSnapshot(snapshot);
    pinDigest = hexOfBytes(parsed.luauPin);
    contractDigest = hexOfBytes(parsed.frontendContract);
    irEnumDigest = hexOfBytes(parsed.irEnum);

    const present = new Set();
    walkSnapshot(parsed, {
      instruction({ command, operands }) {
        const spec = catalog.byValue.get(command);
        if (!spec) throw new Error(`${entry.source}: unknown IrCmd ${command}`);
        const state = states.get(spec.name);
        state.census_sources.add(entry.source);
        if (entry.hook) state.reachability = "published_hook";
        else if (state.reachability === "none") state.reachability = "census";
        for (const form of censusFormsFor(spec.name, { operands })) state.census_forms.add(form);
        present.add(spec.name);
      },
      operand({ kind }) {
        seenOperand.add(kind);
      },
      block({ kind }) {
        seenBlock.add(kind);
      },
    });

    try {
      const object = compileBackendPackage(backend.exports, snapshot);
      const imports = new Set(parseWasmFunctionImports(object));
      for (const name of present) {
        const state = states.get(name);
        state.lowered_sources.add(entry.source);
        state.import_sets.push(imports);
      }
    } catch (error) {
      if (options.strictLowering) throw error;
    }
  }

  const commands = [];
  const totals = { implemented: 0, partial: 0, unimplemented: 0, frontend_unreachable: 0 };
  for (const [name, spec] of Object.entries(formsSpec.commands)) {
    const state = states.get(name);
    const generalArm = generalArms.commands[name] === true;
    const classified = classify(name, state, spec, generalArm, {
      overApproximateLowering: options.overApproximateLowering !== false,
      hookUnitMarkSatisfied: options.hookUnitMarkSatisfied === true,
      isolatedStripSatisfied: options.isolatedStripSatisfied === true,
      oracleGates: options.oracleGates === true,
      measurementGate: options.measurementGate === true,
    });
    totals[classified.status] += 1;
    const census = [...state.census_sources].sort();
    const runtimeSymbols = classified.status === "frontend_unreachable"
      ? []
      : intersectSorted(state.import_sets);
    if (name === "INT_TO_NUM") {
      const filtered = runtimeSymbols.filter((symbol) => !USERDATA_HELPERS.includes(symbol));
      runtimeSymbols.length = 0;
      runtimeSymbols.push(...filtered);
    }
    const row = {
      command: name,
      value: spec.value,
      class: spec.class,
      status: classified.status,
      reachability: classified.reachability,
      general_arm: generalArm,
      cluster_only: generalArm === false && state.lowered_sources.size > 0,
      forms: spec.forms ?? [],
      runtime_symbols: runtimeSymbols,
      wasm_features: spec.wasm_features ?? [],
      may_allocate: spec.may_allocate === true,
      may_raise: spec.may_raise === true,
      may_call_luau: spec.may_call_luau === true,
      safepoint: spec.safepoint === true,
      rejoins: spec.rejoins === true,
      upstream_reference: spec.upstream_reference ?? "",
      census_sources: census,
      census_forms: [...state.census_forms].sort(),
      lowered_sources: [...state.lowered_sources].sort(),
      executed_gates: classified.status === "frontend_unreachable" ? [] : executedGates(census, options),
      tests: classified.status === "frontend_unreachable" ? [] : existingTests(census),
    };
    if (spec.evidence) row.evidence = spec.evidence;
    commands.push(row);
  }
  commands.sort((a, b) => a.value - b.value);

  const operandKinds = (formsSpec.operand_kinds ?? []).map((kind) => ({
    ...kind,
    status: kind.value === 9
      ? "rejected_closed"
      : seenOperand.has(kind.value) ? "admitted" : "unimplemented",
  }));
  const blockKinds = (formsSpec.block_kinds ?? []).map((kind) => ({
    ...kind,
    status: seenBlock.has(kind.value) ? "admitted" : "unimplemented",
  }));

  const compilerBuildDigest = paths.compilerDigest
    ? loadJson(paths.compilerDigest).sha256
    : generateCompilerBuildDigest(WORKSPACE).hex;
  const document = {
    schema_version: 2,
    generator_version: LEDGER_GENERATOR_VERSION,
    pin: PIN,
    compiler_build_digest: compilerBuildDigest,
    luau_pin_digest: pinDigest,
    frontend_contract_digest: contractDigest,
    input_sha256: irEnumDigest,
    totals,
    commands,
    operand_kinds: operandKinds,
    block_kinds: blockKinds,
  };
  document.canonical_hash = canonicalHashOf(document);
  if (commands.length !== COMMAND_COUNT) {
    throw new Error(`generated ${commands.length} commands, expected ${COMMAND_COUNT}`);
  }
  return { document, generalArms };
}

export function writeCoverageMap(outputPath, document) {
  writeFileSync(outputPath, `${JSON.stringify(document, null, 2)}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = Object.fromEntries(process.argv.slice(2).map((part, index, all) => {
    if (!part.startsWith("--")) return [];
    return [part.slice(2), all[index + 1]];
  }).filter((entry) => entry.length));
  const result = await generateIrCoverage({
    frontend: args.frontend,
    backend: args.backend,
    forms: args.forms,
    corpus: args.corpus,
    fixture: args.fixture,
    dispatch: args.dispatch,
  });
  writeCoverageMap(args.out, result.document);
  writeFileSync(args["general-arms-out"] ?? args.out.replace("luauc_ir_coverage.json", "general_arms.json"),
    canonicalJson(result.generalArms));
  const t = result.document.totals;
  console.log(`${t.implemented} / ${t.partial} / ${t.unimplemented}`);
  console.log(`frontend_unreachable = ${t.frontend_unreachable}`);
}
