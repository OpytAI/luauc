import { readFileSync } from "node:fs";
import { join } from "node:path";
import { generateCompilerBuildDigest } from "./generate_compiler_build_digest.mjs";

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

const generated = generateCompilerBuildDigest();
const checked = JSON.parse(readFileSync(runfile(process.env.LUAUC_COMPILER_BUILD_DIGEST, "LUAUC_COMPILER_BUILD_DIGEST"), "utf8"));
if (generated.hex !== checked.sha256) {
  throw new Error(
    `compiler_build_digest is stale (checked ${checked.sha256}, generated ${generated.hex})`,
  );
}
console.log(`compiler_build_digest up to date: ${generated.hex}`);
