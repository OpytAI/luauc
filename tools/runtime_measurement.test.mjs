import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

function runfile(value, variable) {
  if (!value) throw new Error(`${variable} is not set`);
  if (value.startsWith("/")) return value;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  const direct = join(root, value);
  try {
    readFileSync(direct);
    return direct;
  } catch {
    return join(root, "_main", value);
  }
}

const { measureRuntime, validateMeasurement } = await import(
  pathToFileURL(runfile(process.env.LUAUC_MEASURE_RUNTIME, "LUAUC_MEASURE_RUNTIME")).href
);

const document = await measureRuntime({
  compiler: runfile(process.env.LUAUC_COMPILER_WASM, "LUAUC_COMPILER_WASM"),
  profile: runfile(process.env.LUAUC_EMBED_PROFILE, "LUAUC_EMBED_PROFILE"),
  pack: runfile(process.env.LUAUC_EMBED_PACK, "LUAUC_EMBED_PACK"),
  interpreter: runfile(process.env.LUAUC_PINNED_INTERPRETER, "LUAUC_PINNED_INTERPRETER"),
  lib: runfile(process.env.LUAUC_EMBED_LIB, "LUAUC_EMBED_LIB"),
  main: runfile(process.env.LUAUC_EMBED_MAIN, "LUAUC_EMBED_MAIN"),
  protoIdentity: runfile(process.env.LUAUC_PROTO_IDENTITY, "LUAUC_PROTO_IDENTITY"),
  userdataHooks: runfile(process.env.LUAUC_USERDATA_HOOKS, "LUAUC_USERDATA_HOOKS"),
  callGraph: runfile(process.env.LUAUC_CALL_GRAPH, "LUAUC_CALL_GRAPH"),
  tableChurn: runfile(process.env.LUAUC_TABLE_CHURN, "LUAUC_TABLE_CHURN"),
}, {
  baselineCommit: process.env.LUAUC_BASELINE_COMMIT,
});

const errors = validateMeasurement(document);
if (errors.length) throw new Error(errors.join("\n"));

const checked = JSON.parse(readFileSync(runfile(process.env.LUAUC_RUNTIME_MEASUREMENT, "LUAUC_RUNTIME_MEASUREMENT"), "utf8"));
const checkedErrors = validateMeasurement(checked);
if (checkedErrors.length) throw new Error(checkedErrors.join("\n"));
for (const name of ["embed_product", "call_graph", "table_churn"]) {
  if (!checked.programs?.[name]?.compiled || !checked.programs?.[name]?.interpreted)
    throw new Error(`checked-in measurement is missing ${name}`);
}
if (checked.programs.embed_product && !checked.programs.call_graph)
  throw new Error("P1-only measurement JSON is not acceptable");
if (checked.baseline_commit !== process.env.LUAUC_BASELINE_COMMIT)
  throw new Error(`baseline_commit drift: json=${checked.baseline_commit} env=${process.env.LUAUC_BASELINE_COMMIT}`);

const p2 = document.programs.call_graph.compiled;
if (p2.trampoline_calls !== 0 || p2.direct_calls !== 168 || p2.indirect_calls !== 24) {
  throw new Error(
    `P2 counters: trampoline=${p2.trampoline_calls} direct=${p2.direct_calls} indirect=${p2.indirect_calls}`,
  );
}
if (p2.result_number !== 67 || p2.result_text !== "beta")
  throw new Error(`P2 result drift: ${p2.result_number}/${p2.result_text}`);
const p3 = document.programs.table_churn.compiled;
if (p3.result_number !== 8 || p3.result_text !== "beta")
  throw new Error(`P3 result drift: ${p3.result_number}/${p3.result_text}`);

console.log(
  `runtime measurement: ${Object.keys(document.programs).join(",")} ` +
    `P2 trampoline=${p2.trampoline_calls} direct=${p2.direct_calls} indirect=${p2.indirect_calls}`,
);
