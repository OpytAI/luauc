import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

function runfile(relative, variable) {
  if (!relative) throw new Error(`${variable} is not set`);
  if (relative.startsWith("/")) return relative;
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return join(root, relative);
}

function parseDecimal(bytes, label) {
  const text = bytes.toString("ascii").trim();
  if (!/^[0-9]+$/.test(text)) throw new Error(`invalid ar ${label}: ${JSON.stringify(text)}`);
  const value = Number(text);
  if (!Number.isSafeInteger(value)) throw new Error(`ar ${label} is not a safe integer`);
  return value;
}

function gnuName(table, offset) {
  if (!table) throw new Error(`GNU ar name /${offset} has no string table`);
  if (offset >= table.length) throw new Error(`GNU ar name offset ${offset} is out of range`);
  let end = offset;
  while (end < table.length && table[end] !== 0x0a && table[end] !== 0x00) end++;
  let name = table.subarray(offset, end).toString("utf8");
  if (name.endsWith("/")) name = name.slice(0, -1);
  if (!name) throw new Error(`GNU ar name at offset ${offset} is empty`);
  return name;
}

function parseArchive(bytes) {
  const magic = "!<arch>\n";
  if (bytes.subarray(0, magic.length).toString("ascii") !== magic)
    throw new Error("runtime artifact is not a Unix ar archive");

  const members = [];
  let stringTable;
  let offset = magic.length;
  while (offset < bytes.length) {
    if (offset + 60 > bytes.length) throw new Error(`truncated ar header at byte ${offset}`);
    const header = bytes.subarray(offset, offset + 60);
    if (header.subarray(58, 60).toString("ascii") !== "`\n")
      throw new Error(`invalid ar header trailer at byte ${offset}`);

    const rawName = header.subarray(0, 16).toString("ascii").trim();
    const storedSize = parseDecimal(header.subarray(48, 58), "member size");
    const storedStart = offset + 60;
    const storedEnd = storedStart + storedSize;
    if (storedEnd > bytes.length) throw new Error(`truncated ar member ${JSON.stringify(rawName)}`);

    let name = rawName;
    let dataStart = storedStart;
    if (rawName.startsWith("#1/")) {
      const nameLength = parseDecimal(Buffer.from(rawName.slice(3)), "BSD name length");
      if (nameLength > storedSize) throw new Error("BSD ar name is larger than its member");
      name = bytes.subarray(storedStart, storedStart + nameLength).toString("utf8").replace(/\0+$/, "");
      dataStart += nameLength;
    } else if (rawName === "//") {
      stringTable = bytes.subarray(storedStart, storedEnd);
    } else if (/^\/[0-9]+$/.test(rawName)) {
      name = gnuName(stringTable, Number(rawName.slice(1)));
    } else if (name.endsWith("/") && name !== "/" && name !== "/SYM64/") {
      name = name.slice(0, -1);
    }

    const special = rawName === "/" || rawName === "//" || rawName === "/SYM64/" ||
      name === "__.SYMDEF" || name === "__.SYMDEF SORTED";
    if (!special) {
      if (!name) throw new Error(`empty ar member name at byte ${offset}`);
      members.push({ name, data: bytes.subarray(dataStart, storedEnd) });
    }

    offset = storedEnd + (storedSize & 1);
  }
  if (offset !== bytes.length) throw new Error("invalid final ar padding");
  return members;
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]));
  }
  return value;
}

const archive = readFileSync(runfile(process.env.LUAUC_RUNTIME_ARCHIVE, "LUAUC_RUNTIME_ARCHIVE"));
const manifest = JSON.parse(readFileSync(
  runfile(process.env.LUAUC_RUNTIME_SOURCE_MANIFEST, "LUAUC_RUNTIME_SOURCE_MANIFEST"),
  "utf8",
));
const objectManifest = JSON.parse(readFileSync(
  runfile(process.env.LUAUC_RUNTIME_OBJECT_MANIFEST, "LUAUC_RUNTIME_OBJECT_MANIFEST"),
  "utf8",
));

if (manifest.status !== "archive_built_unlinked")
  throw new Error(`runtime source manifest has non-archive status ${JSON.stringify(manifest.status)}`);
if (manifest.project_adapter?.source !== "src/call_frame.cpp")
  throw new Error("runtime source manifest must name project_adapter.source as src/call_frame.cpp");
if (!Array.isArray(manifest.retained_runtime_sources) || manifest.retained_runtime_sources.length !== 34)
  throw new Error("runtime source manifest must contain the exact 34 retained upstream sources");
const { canonical_hash: sourceManifestHash, ...sourceManifestBody } = manifest;
const actualSourceManifestHash = createHash("sha256")
  .update(`${JSON.stringify(canonicalize(sourceManifestBody))}\n`)
  .digest("hex");
if (actualSourceManifestHash !== sourceManifestHash)
  throw new Error(`runtime source manifest canonical hash drifted: ${actualSourceManifestHash}`);

const retainedSources = [...manifest.retained_runtime_sources].sort();
const expectedInventory = retainedSources.map((source, index) => {
  if (!/^VM\/src\/[^/]+\.cpp$/.test(source))
    throw new Error(`invalid retained runtime source ${JSON.stringify(source)}`);
  return { name: `aot_runtime_wasm32_wasi_unit_${index}.o`, source, owner: "luau" };
});
expectedInventory.push({ name: "runtime_call_frame_object.o", source: "runtime/src/call_frame.cpp", owner: "luauc" });
const expected = expectedInventory.map(({ name }) => name).sort();
if (new Set(expected).size !== expected.length) throw new Error("expected runtime object basenames collide");

const objectMembers = parseArchive(archive).filter(({ name }) => basename(name).endsWith(".o"));
const actual = objectMembers.map(({ name }) => basename(name));
if (new Set(actual).size !== actual.length)
  throw new Error(`duplicate runtime object basename: ${JSON.stringify(actual.sort())}`);
if (JSON.stringify([...actual].sort()) !== JSON.stringify(expected))
  throw new Error(`runtime archive membership drifted\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify([...actual].sort())}`);

const inventoryByName = new Map(expectedInventory.map((entry) => [entry.name, entry]));
const forbiddenVm = new Set(["VM/src/lvmexecute.cpp", "VM/src/lvmload.cpp"]);
for (const { name, data } of objectMembers) {
  const object = basename(name);
  const inventory = inventoryByName.get(object);
  if (!inventory) throw new Error(`runtime object has no source inventory: ${object}`);
  if (forbiddenVm.has(inventory.source))
    throw new Error(`forbidden VM source in runtime archive: ${inventory.source}`);
  if (inventory.owner === "luau" && !inventory.source.startsWith("VM/src/"))
    throw new Error(`forbidden frontend-family source in runtime archive: ${inventory.source}`);
  if (data.length < 8 || !data.subarray(0, 8).equals(Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])))
    throw new Error(`runtime archive member is not a wasm v1 object: ${object}`);
}

const actualMembers = objectMembers.map(({ name, data }) => {
  const inventory = inventoryByName.get(basename(name));
  return { ...inventory, sha256: createHash("sha256").update(data).digest("hex") };
}).sort((a, b) => a.name.localeCompare(b.name));

const canonicalDigest = createHash("sha256")
  .update(actualMembers.map(({ name, sha256 }) => `${name} ${sha256}\n`).join(""))
  .digest("hex");

const actualManifest = {
  schema_version: 1,
  generator_version: "luauc-runtime-object-inventory-v2",
  status: "relocatable_archive_verified",
  target: "wasm32-wasi",
  object_format: "WebAssembly relocatable object version 1",
  toolchain: {
    zig_version: "0.16.0",
    mode: "release_small",
    bazel_compilation_mode: "opt",
    threaded: "single",
    cxx_flags: ["-DLUAUC_RUNTIME=1", "-fno-exceptions", "-fno-rtti"],
    sysroot_selection: ["-lc", "-lc++"],
  },
  archive: {
    bazel_target: "//runtime:runtime_archive_wasm32",
    member_count: actualMembers.length,
    upstream_member_count: retainedSources.length,
    project_adapter_member_count: 1,
    member_name_policy: "sorted Luau source index plus project adapter label",
    canonical_member_set_sha256: canonicalDigest,
  },
  members: actualMembers,
  forbidden_members: [
    "VM/src/lvmexecute.cpp",
    "VM/src/lvmload.cpp",
    "any Ast, Bytecode, Compiler, CodeGen, Analysis, or Config source",
  ],
};

const emitPath = process.argv.find((argument) => argument.startsWith("--emit="))?.slice(7);
if (emitPath) {
  writeFileSync(emitPath, `${JSON.stringify(actualManifest, null, 2)}\n`);
} else if (JSON.stringify(canonicalize(actualManifest)) !== JSON.stringify(canonicalize(objectManifest))) {
  throw new Error(`runtime object manifest drift\nexpected=${JSON.stringify(objectManifest)}\nactual=${JSON.stringify(actualManifest)}`);
}

console.log(`verified strict wasm runtime archive (${actual.length} objects, ${canonicalDigest})`);
