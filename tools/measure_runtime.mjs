import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

function runfile(value, variable) {
  if (!value) throw new Error(`${variable} is not set`);
  if (value.startsWith("/")) return value;
  const root = process.env.RUNFILES_DIR;
  if (!root) return value;
  const direct = join(root, value);
  try {
    readFileSync(direct);
    return direct;
  } catch {
    return join(root, "_main", value);
  }
}

const hostModule = process.env.LUAUC_HOST_JS
  ? await import(pathToFileURL(runfile(process.env.LUAUC_HOST_JS, "LUAUC_HOST_JS")).href)
  : await import("../hosts/js/host.mjs");
const { compilePackage, createContext, destroyContext, instantiateArtifact, invoke } = hostModule;

export const GENERATOR_VERSION = "luauc-runtime-measurement-v1";

function percentile(sorted, fraction) {
  if (!sorted.length) return 0;
  const index = Math.min(sorted.length - 1, Math.floor(sorted.length * fraction));
  return sorted[index];
}

function readCounts(instance, context) {
  const api = instance.exports;
  return {
    helper_calls: api.luauc_embed_v1_helper_calls(context) >>> 0,
    trampoline_calls: api.luauc_embed_v1_trampoline_calls(context) >>> 0,
    direct_calls: api.luauc_embed_v1_direct_calls(context) >>> 0,
    indirect_calls: api.luauc_embed_v1_indirect_calls(context) >>> 0,
  };
}

async function measureCompiled(compiler, profile, pack, modules, entry, number, text, warmup, samples) {
  const compiled = await compilePackage(compiler, profile, pack, modules, entry);
  const instance = instantiateArtifact(compiled.artifact);
  const context = createContext(instance);
  try {
    for (let index = 0; index < warmup; index++) {
      const result = invoke(instance, number, text, context);
      if (result.status || result.resultStatus || result.error)
        throw new Error(`compiled warmup failed: ${JSON.stringify(result)}`);
    }
    instance.exports.luauc_embed_v1_reset_counts(context);
    const times = [];
    let last = null;
    for (let index = 0; index < samples; index++) {
      const start = process.hrtime.bigint();
      last = invoke(instance, number, text, context);
      times.push(Number(process.hrtime.bigint() - start));
      if (last.status || last.resultStatus || last.error)
        throw new Error(`compiled sample failed: ${JSON.stringify(last)}`);
    }
    times.sort((a, b) => a - b);
    return {
      p50_ns: percentile(times, 0.5),
      p90_ns: percentile(times, 0.9),
      samples,
      result_number: last.number,
      result_text: last.text,
      ...readCounts(instance, context),
    };
  } finally {
    destroyContext(instance, context);
  }
}

function parseMeasureLine(stdout) {
  const line = stdout.trim().split("\n").find((entry) => entry.startsWith("measure="));
  if (!line) throw new Error(`interpreter measure missing result: ${stdout}`);
  const parts = Object.fromEntries(line.slice("measure=".length).split(" ").map((item) => {
    const split = item.indexOf("=");
    return [item.slice(0, split), Number(item.slice(split + 1))];
  }));
  return { p50_ns: parts.p50_ns, p90_ns: parts.p90_ns, samples: parts.samples };
}

function measureInterpreted(interpreter, args, number, text, warmup, samples) {
  const stdout = execFileSync(interpreter, [...args, String(number), text, String(warmup), String(samples)], {
    encoding: "utf8",
  });
  return parseMeasureLine(stdout);
}

export async function measureRuntime(paths, options = {}) {
  const warmup = options.warmup ?? 8;
  const samples = options.samples ?? 24;
  const number = options.number ?? 7;
  const text = options.text ?? "beta";
  const compiler = readFileSync(paths.compiler);
  const profile = readFileSync(paths.profile);
  const pack = readFileSync(paths.pack);
  const productModules = [
    { name: "lib", source: readFileSync(paths.lib, "utf8") },
    { name: "main", source: readFileSync(paths.main, "utf8") },
    {
      name: "proto_identity",
      source: readFileSync(paths.protoIdentity, "utf8"),
      inlinePlans: [{ callerFunctionId: 2, feedbackSlot: 0, targetFunctionId: 0 }],
    },
    { name: "userdata_hooks", source: readFileSync(paths.userdataHooks, "utf8") },
  ];
  const programs = {
    embed_product: {
      compiled: await measureCompiled(compiler, profile, pack, productModules, "main", number, text, warmup, samples),
      interpreted: measureInterpreted(paths.interpreter, [
        "--measure-product",
        paths.lib,
        paths.main,
        paths.protoIdentity,
        paths.userdataHooks,
      ], number, text, warmup, samples),
    },
    call_graph: {
      compiled: await measureCompiled(
        compiler,
        profile,
        pack,
        [{ name: "main", source: readFileSync(paths.callGraph, "utf8") }],
        "main",
        number,
        text,
        warmup,
        samples,
      ),
      interpreted: measureInterpreted(paths.interpreter, ["--measure", paths.callGraph], number, text, warmup, samples),
    },
    table_churn: {
      compiled: await measureCompiled(
        compiler,
        profile,
        pack,
        [{ name: "main", source: readFileSync(paths.tableChurn, "utf8") }],
        "main",
        number,
        text,
        warmup,
        samples,
      ),
      interpreted: measureInterpreted(paths.interpreter, ["--measure", paths.tableChurn], number, text, warmup, samples),
    },
  };
  return {
    schema_version: 1,
    generator_version: GENERATOR_VERSION,
    baseline_commit: options.baselineCommit,
    input: { number, text, warmup, samples },
    programs,
  };
}

export function validateMeasurement(document) {
  const errors = [];
  if (document.schema_version !== 1) errors.push("schema_version must be 1");
  if (document.generator_version !== GENERATOR_VERSION) errors.push("generator_version drift");
  if (!/^[0-9a-f]{40}$/.test(document.baseline_commit ?? "")) errors.push("baseline_commit must be a 40-hex SHA");
  for (const name of ["embed_product", "call_graph", "table_churn"]) {
    const program = document.programs?.[name];
    if (!program) {
      errors.push(`missing program ${name}`);
      continue;
    }
    for (const engine of ["compiled", "interpreted"]) {
      const row = program[engine];
      if (!row || !Number.isFinite(row.p50_ns) || !Number.isFinite(row.p90_ns))
        errors.push(`${name}.${engine} is missing wall percentiles`);
    }
    const compiled = program.compiled;
    for (const counter of ["helper_calls", "trampoline_calls", "direct_calls", "indirect_calls"]) {
      if (!Number.isFinite(compiled?.[counter])) errors.push(`${name}.compiled missing ${counter}`);
    }
  }
  return errors;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const paths = {
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
  };
  const document = await measureRuntime(paths, {
    baselineCommit: process.env.LUAUC_BASELINE_COMMIT,
  });
  const errors = validateMeasurement(document);
  if (errors.length) throw new Error(errors.join("\n"));
  if (process.env.LUAUC_WRITE_MEASUREMENT)
    writeFileSync(process.env.LUAUC_WRITE_MEASUREMENT, `${JSON.stringify(document, null, 2)}\n`);
  console.log(`measured ${Object.keys(document.programs).join(",")} baseline=${document.baseline_commit}`);
}
