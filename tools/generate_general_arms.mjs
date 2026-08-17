import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import {
  GENERAL_ARMS_GENERATOR_VERSION,
  canonicalJson,
  commandCatalog,
  loadJson,
} from "./ir_ledger.mjs";

const REJECT_ONLY = new Set([
  "GET_CLOSURE_UPVAL_ADDR",
  "CAPTURE",
  "FINDUPVAL",
]);

const ZIG_COMMAND_ALIASES = {
  barrier_object: "BARRIER_OBJ",
  close_upvals: "CLOSE_UPVALS",
};

export function zigIdentToCommand(ident) {
  let name = ident;
  if (name.startsWith("ir_cmd_")) name = name.slice("ir_cmd_".length);
  if (name.startsWith(".")) name = name.slice(1);
  if (name.endsWith("_")) name = name.slice(0, -1);
  return ZIG_COMMAND_ALIASES[name] ?? name.toUpperCase();
}

function extractSwitchBody(source) {
  const marker = "switch (instruction_value.command)";
  const start = source.indexOf(marker);
  if (start < 0) throw new Error("emitInstructionInner is missing the command switch");
  const open = source.indexOf("{", start);
  if (open < 0) throw new Error("command switch has no opening brace");
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    const ch = source[index];
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(open + 1, index);
    }
  }
  throw new Error("command switch is unterminated");
}

function tokenizeCases(body) {
  const lines = body.split("\n");
  const cases = [];
  let pending = [];
  let collecting = false;
  let current = null;
  const flush = () => {
    if (current) {
      current.body = current.body.replace(/\s+/g, " ").trim();
      cases.push(current);
      current = null;
    }
  };
  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("//")) continue;
    const labelMatch = line.match(/^(?:ir_cmd_[A-Za-z0-9_]+|\.[A-Za-z0-9_]+)\s*,?$/);
    if (labelMatch && !line.includes("=>")) {
      collecting = true;
      pending.push(line.replace(/,$/, "").replace(/^\./, ""));
      continue;
    }
    const arrow = line.match(/^(.*?)=>\s*(.*)$/);
    if (arrow) {
      const labelsPart = arrow[1].trim();
      if (labelsPart === "else") {
        flush();
        collecting = false;
        pending = [];
        break;
      }
      const extra = labelsPart
        .split(",")
        .map((part) => part.trim())
        .filter(Boolean)
        .map((part) => part.replace(/^\./, ""));
      const labels = [...pending, ...extra].filter((label) => label !== "");
      pending = [];
      collecting = false;
      flush();
      current = { labels, body: arrow[2] };
      if (braceBalance(current.body) <= 0 && /;$/.test(current.body) && !current.body.includes("{")) {
        flush();
      }
      continue;
    }
    if (current) {
      current.body += ` ${line}`;
      if (braceBalance(current.body) <= 0 && line.endsWith("}")) flush();
    } else if (collecting && !labelMatch) {
      pending = [];
      collecting = false;
    }
  }
  flush();
  return cases;
}

function braceBalance(text) {
  let depth = 0;
  for (const ch of text) {
    if (ch === "{") depth += 1;
    else if (ch === "}") depth -= 1;
  }
  return depth;
}

export function armMaterializes(command, body) {
  if (REJECT_ONLY.has(command)) return false;
  if (!body) return false;
  if (/return false/.test(body) && !/emit[A-Z]/.test(body) && !/\.call\(/.test(body)) return false;
  return /emit[A-Z]/.test(body) ||
    /\.call\(/.test(body) ||
    /body\.(i32|i64|f32|f64|localGet|localSet|load|store)/.test(body);
}

export function scanDispatch(source, catalog) {
  const body = extractSwitchBody(source);
  const cases = tokenizeCases(body);
  const arms = new Map();
  for (const entry of cases) {
    const materializes = entry.labels.some((label) => {
      const command = zigIdentToCommand(label);
      return armMaterializes(command, entry.body);
    });
    for (const label of entry.labels) {
      const command = zigIdentToCommand(label);
      if (!catalog.byName.has(command)) {
        throw new Error(`dispatch switch mentions unknown command ${command} (${label})`);
      }
      arms.set(command, materializes || arms.get(command) === true);
    }
  }
  const result = {};
  for (const name of catalog.byName.keys()) result[name] = arms.get(name) === true;
  return result;
}

export function generateGeneralArms(dispatchSource, formsSpec, fixture) {
  const catalog = commandCatalog(formsSpec);
  const commands = scanDispatch(dispatchSource, catalog);
  const errors = [];
  for (const name of fixture.true ?? []) {
    if (!commands[name]) errors.push(`fixture-true ${name} does not materialize operands in the emit switch`);
  }
  for (const name of fixture.false ?? []) {
    if (commands[name]) errors.push(`fixture-false ${name} materializes operands in the emit switch`);
  }
  if (errors.length) throw new Error(errors.join("\n"));
  return {
    generator_version: GENERAL_ARMS_GENERATOR_VERSION,
    dispatch_sha256: createHash("sha256").update(dispatchSource).digest("hex"),
    commands,
  };
}

export function writeGeneralArms(outputPath, document) {
  writeFileSync(outputPath, canonicalJson(document));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [dispatchPath, formsPath, fixturePath, outputPath] = process.argv.slice(2);
  if (!dispatchPath || !formsPath || !fixturePath || !outputPath) {
    throw new Error("usage: generate_general_arms <dispatch.zig> <ir_command_forms.json> <fixture.json> <out.json>");
  }
  const document = generateGeneralArms(
    readFileSync(dispatchPath, "utf8"),
    loadJson(formsPath),
    loadJson(fixturePath),
  );
  writeGeneralArms(outputPath, document);
  const truthy = Object.values(document.commands).filter(Boolean).length;
  const falsy = Object.values(document.commands).length - truthy;
  console.log(`general_arms: ${truthy} true / ${falsy} false`);
}
