import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  COMMAND_COUNT,
  QUALIFYING_GATES,
  USERDATA_HELPERS,
  canonicalHashOf,
  loadJson,
  printRule13,
  runfile,
  validateCoverageMap,
} from "./ir_ledger.mjs";
import { generateGeneralArms } from "./generate_general_arms.mjs";
import { generateIrCoverage, writeCoverageMap } from "./generate_ir_coverage.mjs";
import { execFileSync } from "node:child_process";

function pathOf(variable) {
  return runfile(process.env[variable], variable);
}

const forms = loadJson(pathOf("LUAUC_IR_COMMAND_FORMS"));
const fixture = loadJson(pathOf("LUAUC_GENERAL_ARMS_FIXTURE"));
const allow = loadJson(pathOf("LUAUC_BAZEL_LABEL_ALLOWLIST"));
const checkedCoverage = loadJson(pathOf("LUAUC_IR_COVERAGE"));
const checkedArms = loadJson(pathOf("LUAUC_GENERAL_ARMS"));
const dispatchSource = readFileSync(pathOf("LUAUC_DISPATCH_ZIG"), "utf8");

const generatedArms = generateGeneralArms(dispatchSource, forms, fixture);
if (canonicalHashOf(generatedArms) !== canonicalHashOf(checkedArms)) {
  throw new Error("general_arms.json drifted from compiler/backend/emit/dispatch.zig");
}

function expectedHookMark(n) {
  if (n === 0) return 0;
  // Unit payload is f32; Mark promotes that lane to a Luau number.
  return n + Math.fround(Math.sign(n) / Math.SQRT2);
}

function almostEqual(actual, expected) {
  return Number.isFinite(actual) && Math.abs(actual - expected) <= 1e-12 * Math.max(1, Math.abs(expected));
}

const hookInputs = [[1, "alpha"], [7, "beta"], [-4, "gamma"]];
const hookStdout = execFileSync(pathOf("LUAUC_PINNED_INTERPRETER"), [
  "--hook-only",
  pathOf("LUAUC_USERDATA_HOOKS"),
], { encoding: "utf8" });
const hookLines = hookStdout.trim().split("\n").filter((line) => line.startsWith("hook="));
const hookNumbers = hookInputs.map(([number, text]) => {
  const prefix = `hook=${number}|${text}|`;
  const line = hookLines.find((entry) => entry.startsWith(prefix));
  if (!line) throw new Error(`hook_unit_mark missing ${number}/${text} in ${JSON.stringify(hookLines)}`);
  const value = Number(line.slice(prefix.length));
  const expected = expectedHookMark(number);
  if (!almostEqual(value, expected)) {
    throw new Error(`hook_unit_mark ${number}/${text}: got ${value}, expected ${expected} (n + sign(n)/√2)`);
  }
  return value;
});
const zeroLine = hookLines.find((entry) => entry.startsWith("hook=0|zero|"));
if (!zeroLine) throw new Error(`hook_unit_mark missing embed.vec2(0) in ${JSON.stringify(hookLines)}`);
const zeroValue = Number(zeroLine.slice("hook=0|zero|".length));
if (!almostEqual(zeroValue, 0)) {
  throw new Error(`embed.vec2(0) Unit/Mark must be 0, got ${zeroValue}`);
}
const hookUnitMarkSatisfied = hookNumbers.length === hookInputs.length &&
  hookNumbers.every((value, index) => almostEqual(value, expectedHookMark(hookInputs[index][0])));
if (!hookUnitMarkSatisfied) {
  throw new Error(`hook_unit_mark seeds failed: ${JSON.stringify(hookNumbers)}`);
}

const stripStdout = execFileSync(pathOf("LUAUC_PINNED_INTERPRETER"), ["--barrier-strip"], {
  encoding: "utf8",
});
if (!stripStdout.includes("strip=hold barrier=on dead=0") ||
    !stripStdout.includes("strip=hold barrier=off dead=1") ||
    !stripStdout.includes("strip=store barrier=on dead=0") ||
    !stripStdout.includes("strip=store barrier=off dead=1")) {
  throw new Error(`interpreter color strip failed:\n${stripStdout}`);
}

const generated = await generateIrCoverage({
  frontend: pathOf("LUAUC_FRONTEND_WASM"),
  backend: pathOf("LUAUC_BACKEND_WASM"),
  forms: pathOf("LUAUC_IR_COMMAND_FORMS"),
  corpus: pathOf("LUAUC_IR_LEDGER_CORPUS"),
  fixture: pathOf("LUAUC_GENERAL_ARMS_FIXTURE"),
  dispatch: pathOf("LUAUC_DISPATCH_ZIG"),
  compilerDigest: pathOf("LUAUC_COMPILER_BUILD_DIGEST"),
}, {
  resolveSource: (entry) => runfile(entry.path, entry.path),
  hookUnitMarkSatisfied,
  isolatedStripSatisfied: true,
});

const temp = mkdtempSync(join(tmpdir(), "luauc-ir-coverage-"));
const generatedPath = join(temp, "luauc_ir_coverage.json");
writeCoverageMap(generatedPath, generated.document);

if (generated.document.canonical_hash !== checkedCoverage.canonical_hash) {
  throw new Error(
    `luauc_ir_coverage.json is stale (checked ${checkedCoverage.canonical_hash}, generated ${generated.document.canonical_hash})`,
  );
}

const intToNum = generated.document.commands.find((row) => row.command === "INT_TO_NUM");
const intToNumMayImportUserdata = (intToNum?.runtime_symbols ?? [])
  .some((symbol) => USERDATA_HELPERS.includes(symbol));

const coverageOptions = {
  allowLabels: allow.labels,
  existingGates: new Set([...QUALIFYING_GATES, "//hosts/js:embed_test", "//hosts/js:cli_test"]),
  intToNumMayImportUserdata,
  hookUnitMarkSatisfied,
  isolatedStripSatisfied: true,
};

const errors = validateCoverageMap(generated.document, coverageOptions);
if (errors.length) throw new Error(errors.join("\n"));

if (generated.document.totals.implemented !== 0 && process.env.LUAUC_ALLOW_IMPLEMENTED !== "1") {
  throw new Error(
    `honesty lock: generator reported implemented=${generated.document.totals.implemented}; ` +
      "over-approximated lowering must not invent implemented rows",
  );
}

function rehash(document) {
  const withoutHash = { ...document };
  delete withoutHash.canonical_hash;
  return { ...document, canonical_hash: canonicalHashOf(withoutHash) };
}

function cloneDocument(document) {
  return JSON.parse(JSON.stringify(document));
}

function expectValidateError(label, document, options, match) {
  const errorsForCase = validateCoverageMap(document, options);
  if (!errorsForCase.some((entry) => entry.includes(match))) {
    throw new Error(`${label}: expected error containing ${JSON.stringify(match)}, got ${JSON.stringify(errorsForCase)}`);
  }
}

{
  const forgedImplemented = rehash(cloneDocument(generated.document));
  const addNum = forgedImplemented.commands.find((row) => row.command === "ADD_NUM");
  addNum.status = "implemented";
  addNum.tests = [];
  addNum.census_sources = ["slow_add"];
  addNum.lowered_sources = ["slow_add"];
  addNum.executed_gates = [];
  addNum.general_arm = false;
  forgedImplemented.totals.implemented += 1;
  forgedImplemented.totals.partial -= 1;
  expectValidateError("fake implemented", rehash(forgedImplemented), coverageOptions, "implemented row has tests: []");
}

{
  const forgedLabel = rehash(cloneDocument(generated.document));
  const addNum = forgedLabel.commands.find((row) => row.command === "ADD_NUM");
  addNum.tests = ["//compiler/backend:does_not_exist_test"];
  expectValidateError("unknown label", rehash(forgedLabel), coverageOptions, "unknown test label");
}

{
  const forgedHook = rehash(cloneDocument(generated.document));
  const row = forgedHook.commands.find((entry) => entry.command === "NEW_USERDATA");
  row.status = "implemented";
  row.tests = ["//tools:ir_coverage_test"];
  row.census_sources = ["userdata_hooks"];
  row.lowered_sources = ["userdata_hooks"];
  row.executed_gates = ["//hosts/wasmtime:parity_test"];
  row.general_arm = true;
  row.evidence = { kind: "hook_unit_mark", require_distinct_unit_mark: true };
  forgedHook.totals.implemented += 1;
  forgedHook.totals.partial -= 1;
  expectValidateError(
    "unsatisfied hook lock",
    rehash(forgedHook),
    { ...coverageOptions, hookUnitMarkSatisfied: false },
    "hook_unit_mark evidence lock is unsatisfied",
  );
}

{
  const forgedStrip = rehash(cloneDocument(generated.document));
  const row = forgedStrip.commands.find((entry) => entry.command === "BARRIER_TABLE_BACK");
  row.status = "implemented";
  row.tests = ["//tools:ir_coverage_test"];
  row.census_sources = ["userdata_hooks"];
  row.lowered_sources = ["userdata_hooks"];
  row.executed_gates = ["//hosts/wasmtime:parity_test"];
  row.general_arm = true;
  row.evidence = { kind: "isolated_store_strip", gate: "//hosts/wasmtime:barrier_parity_test" };
  forgedStrip.totals.implemented += 1;
  forgedStrip.totals.partial -= 1;
  expectValidateError(
    "unsatisfied isolated strip",
    rehash(forgedStrip),
    { ...coverageOptions, isolatedStripSatisfied: false },
    "isolated strip evidence lock is unsatisfied",
  );
}

{
  const forgedIntToNum = rehash(cloneDocument(generated.document));
  const row = forgedIntToNum.commands.find((entry) => entry.command === "INT_TO_NUM");
  row.runtime_symbols = [...(row.runtime_symbols ?? []), "luauc_runtime_v1_new_userdata"];
  expectValidateError(
    "INT_TO_NUM userdata helper",
    rehash(forgedIntToNum),
    { ...coverageOptions, intToNumMayImportUserdata: false },
    "INT_TO_NUM.runtime_symbols contains a userdata helper",
  );
}

for (const row of generated.document.commands) {
  if (row.status === "implemented" && row.forms.length === 0 && row.class !== "compile_only") {
    throw new Error(`${row.command}: empty forms[] on a non-compile_only implemented row`);
  }
  if (row.command === "INT_TO_NUM") {
    for (const symbol of row.runtime_symbols) {
      if (USERDATA_HELPERS.includes(symbol)) {
        throw new Error("INT_TO_NUM.runtime_symbols contains a userdata helper");
      }
    }
  }
  if (row.status === "implemented" && row.evidence?.kind === "hook_unit_mark" && !hookUnitMarkSatisfied) {
    throw new Error(`${row.command}: hook_unit_mark cannot be implemented without n + sign(n)/√2`);
  }
  if ((row.command === "NEW_USERDATA" || row.command === "CHECK_USERDATA_TAG") &&
      row.status === "implemented") {
    throw new Error(`${row.command}: stay partial until forms/gates allow implemented`);
  }
  if (row.status === "implemented" &&
      (row.evidence?.kind === "isolated_store_strip" || row.evidence?.kind === "isolated_hold_strip")) {
    if (!allow.labels.includes(row.evidence.gate) || !(row.executed_gates ?? []).includes(row.evidence.gate)) {
      throw new Error(`${row.command}: isolated strip lock requires ${row.evidence.gate}`);
    }
  }
}

{
  const hold = generated.document.commands.find((row) => row.command === "BARRIER_OBJ");
  const store = generated.document.commands.find((row) => row.command === "BARRIER_TABLE_BACK");
  if (!hold?.census_sources.includes("userdata_hold") || hold.census_sources.includes("userdata_store")) {
    throw new Error(`BARRIER_OBJ census is not Hold-only: ${JSON.stringify(hold?.census_sources)}`);
  }
  if (!store?.census_sources.includes("userdata_store") || store.census_sources.includes("userdata_hold")) {
    throw new Error(`BARRIER_TABLE_BACK census is not Store-only: ${JSON.stringify(store?.census_sources)}`);
  }
  if (hold.status === "implemented" || store.status === "implemented") {
    throw new Error("147/148 stay partial until over-approximated lowering is replaced");
  }
}

const holes = generated.document.commands
  .filter((row) => row.class !== "compile_only" && row.forms.length === 0)
  .map((row) => row.command);
if (holes.length) {
  console.log(`forms holes (kept partial): ${holes.join(", ")}`);
}

const withoutHash = { ...checkedCoverage };
delete withoutHash.canonical_hash;
if (canonicalHashOf(withoutHash) !== checkedCoverage.canonical_hash) {
  throw new Error("checked-in canonical_hash does not match the checked-in document");
}

const sum = generated.document.totals.implemented + generated.document.totals.partial +
  generated.document.totals.unimplemented + generated.document.totals.frontend_unreachable;
if (sum !== COMMAND_COUNT) throw new Error(`I+P+U+R is ${sum}, not ${COMMAND_COUNT}`);

console.log(printRule13(generated.document.totals));
console.log(`ir coverage map is current (${generated.document.canonical_hash})`);
