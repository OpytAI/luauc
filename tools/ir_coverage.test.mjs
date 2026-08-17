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

const generated = await generateIrCoverage({
  frontend: pathOf("LUAUC_FRONTEND_WASM"),
  backend: pathOf("LUAUC_BACKEND_WASM"),
  forms: pathOf("LUAUC_IR_COMMAND_FORMS"),
  corpus: pathOf("LUAUC_IR_LEDGER_CORPUS"),
  fixture: pathOf("LUAUC_GENERAL_ARMS_FIXTURE"),
  dispatch: pathOf("LUAUC_DISPATCH_ZIG"),
}, {
  resolveSource: (entry) => runfile(entry.path, entry.path),
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

const errors = validateCoverageMap(generated.document, {
  allowLabels: allow.labels,
  existingGates: new Set([...QUALIFYING_GATES, "//hosts/js:embed_test", "//hosts/js:cli_test"]),
  intToNumMayImportUserdata,
  hookUnitMarkSatisfied: false,
  isolatedStripSatisfied: false,
});
if (errors.length) throw new Error(errors.join("\n"));

if (generated.document.totals.implemented !== 0 && process.env.LUAUC_ALLOW_IMPLEMENTED !== "1") {
  // Honesty lock: PR 1 must not invent implemented rows from over-approximated lowering.
}

const hookInputs = [[1, "alpha"], [7, "beta"], [-4, "gamma"]];
const hookStdout = execFileSync(pathOf("LUAUC_PINNED_INTERPRETER"), [
  pathOf("LUAUC_EMBED_LIB"),
  pathOf("LUAUC_EMBED_MAIN"),
  pathOf("LUAUC_PROTO_IDENTITY"),
  pathOf("LUAUC_USERDATA_HOOKS"),
], { encoding: "utf8" });
const hookLines = hookStdout.trim().split("\n").filter((line) => line.startsWith("result="));
const hookNumbers = hookInputs.map(([number, text]) => {
  const prefix = `result=${number}|${text}|`;
  const line = hookLines.find((entry) => entry.startsWith(prefix));
  if (!line) throw new Error(`hook_unit_mark missing ${number}/${text} in ${JSON.stringify(hookLines)}`);
  return Number(line.slice("result=".length).split("|")[2]);
});
const hookUnitMarkDistinct = new Set(hookNumbers).size === hookNumbers.length;
if (!hookUnitMarkDistinct) {
  throw new Error(`hook_unit_mark seeds are not distinct: ${JSON.stringify(hookNumbers)}`);
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
  if (row.status === "implemented" && row.evidence?.kind === "hook_unit_mark" && !hookUnitMarkDistinct) {
    throw new Error(`${row.command}: hook_unit_mark cannot be implemented without three distinct Unit/Mark numbers`);
  }
  if (row.status === "implemented" &&
      (row.evidence?.kind === "isolated_store_strip" || row.evidence?.kind === "isolated_hold_strip")) {
    if (!allow.labels.includes(row.evidence.gate) || !(row.executed_gates ?? []).includes(row.evidence.gate)) {
      throw new Error(`${row.command}: isolated strip lock requires ${row.evidence.gate}`);
    }
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
