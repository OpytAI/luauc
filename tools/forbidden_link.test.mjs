import { readFileSync } from "node:fs";
import { basename, join } from "node:path";

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
    throw new Error("artifact is not a Unix ar archive");
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
  return members;
}

const policy = JSON.parse(readFileSync(runfile(process.env.LUAUC_FORBIDDEN_LINK, "LUAUC_FORBIDDEN_LINK"), "utf8"));
const archive = readFileSync(runfile(process.env.LUAUC_FRONTEND_INTERP_ARCHIVE, "LUAUC_FRONTEND_INTERP_ARCHIVE"));
const stubBytes = readFileSync(runfile(process.env.LUAUC_EXECUTE_STUB_OBJECT, "LUAUC_EXECUTE_STUB_OBJECT"));
const stub = stubBytes.subarray(0, 8).toString("ascii") === "!<arch>\n"
  ? parseArchive(stubBytes).map(({ data }) => data).reduce((left, right) => Buffer.concat([left, right]), Buffer.alloc(0))
  : stubBytes;
const runtimeArchive = readFileSync(runfile(process.env.LUAUC_RUNTIME_ARCHIVE, "LUAUC_RUNTIME_ARCHIVE"));

const frontendMembers = parseArchive(archive);
for (const member of frontendMembers) {
  const base = basename(member.name);
  for (const forbidden of policy.compiler_frontend_forbidden_member_basenames) {
    if (base === forbidden || base.includes(forbidden.replace(/\.cpp$/, "")))
      throw new Error(`frontend archive still contains ${forbidden}: ${member.name}`);
  }
  const text = member.data.toString("latin1");
  for (const needle of policy.dispatcher_object_substrings) {
    if (text.includes(needle))
      throw new Error(`frontend archive member ${member.name} contains dispatcher bytes ${needle}`);
  }
}

const stubText = stub.toString("latin1");
for (const symbol of policy.compiler_stub_must_define) {
  if (!stubText.includes(symbol))
    throw new Error(`stub object does not define ${symbol}`);
}

const runtimeMembers = parseArchive(runtimeArchive);
for (const member of runtimeMembers) {
  const base = basename(member.name);
  for (const forbidden of policy.runtime_pack_forbidden_object_basenames) {
    if (base === forbidden || base.includes(forbidden.replace(/\.cpp$/, "")))
      throw new Error(`runtime archive still contains ${forbidden}: ${member.name}`);
  }
}

console.log(
  `forbidden-link: frontend archive ${frontendMembers.length} members, stub defines ${policy.compiler_stub_must_define.join(", ")}`,
);
