#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { compilePackage } from "./host.mjs";

function usage() {
  throw new Error("usage: luauc compile --compiler luauc.wasm --profile runtime.profile --pack runtime.pack.wasm --output program.wasm --entry module name=source.luau...");
}

const bazelExecrootPaths = process.env.LUAUC_BAZEL_EXECROOT_PATHS === "1";
const bazelExecroot = process.env.JS_BINARY__EXECROOT;
if (bazelExecrootPaths && !bazelExecroot)
  throw new Error("LUAUC_BAZEL_EXECROOT_PATHS requires rules_js to provide JS_BINARY__EXECROOT");
const filesystemPath = (path) => bazelExecrootPaths && !isAbsolute(path) ? resolve(bazelExecroot, path) : path;

function parseArguments(arguments_) {
  if (arguments_.shift() !== "compile") usage();
  const options = {};
  while (arguments_[0]?.startsWith("--")) {
    const option = arguments_.shift().slice(2);
    if (!["compiler", "profile", "pack", "output", "entry"].includes(option) || options[option] !== undefined || !arguments_.length)
      usage();
    options[option] = arguments_.shift();
  }
  if (["compiler", "profile", "pack", "output", "entry"].some((name) => !options[name]) || !arguments_.length)
    usage();
  const modules = arguments_.map((argument) => {
    const separator = argument.indexOf("=");
    if (separator <= 0 || separator === argument.length - 1) usage();
    const name = argument.slice(0, separator);
    if (!/^[a-z0-9_.\/-]+$/.test(name) || name.startsWith("/") || name.endsWith("/") || name.includes(".."))
      throw new Error(`invalid canonical module name ${JSON.stringify(name)}`);
    return { name, source: readFileSync(filesystemPath(argument.slice(separator + 1)), "utf8") };
  });
  if (new Set(modules.map(({ name }) => name)).size !== modules.length)
    throw new Error("duplicate canonical module name");
  if (!modules.some(({ name }) => name === options.entry))
    throw new Error(`entry module ${JSON.stringify(options.entry)} is absent`);
  return { options, modules };
}

const { options, modules } = parseArguments(process.argv.slice(2));
const compilation = await compilePackage(
  readFileSync(filesystemPath(options.compiler)),
  readFileSync(filesystemPath(options.profile)),
  readFileSync(filesystemPath(options.pack)),
  modules,
  options.entry,
);
writeFileSync(filesystemPath(options.output), compilation.artifact);
const hex = (value) => [...value].map((byte) => byte.toString(16).padStart(2, "0")).join("");
process.stdout.write(`${JSON.stringify({
  artifact_bytes: compilation.artifact.length,
  artifact_sha256: hex(compilation.provenance.artifactDigest),
  generated_object_sha256: hex(compilation.provenance.objectDigest),
  module_count: modules.length,
  runtime_pack_sha256: hex(compilation.provenance.packDigest),
  runtime_profile_sha256: hex(compilation.provenance.profileDigest),
})}\n`);
