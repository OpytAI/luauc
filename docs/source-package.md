# SourcePackageV1

The compiler request is a canonical, length-delimited closed package. Module IDs are logical names;
the compiler performs no filesystem or network discovery.

## Header (240 bytes)

| Offset | Field |
| ---: | --- |
| 0 | magic `LUAUCS1\0` |
| 8 | `u16 abi_version = 1` |
| 10 | `u16 header_size = 240` |
| 12 | `u32 total_size` |
| 16 | `u32 module_count` (1–128) |
| 20 | `u32 entry_module_id` |
| 24 | `u32 record_size = 64` |
| 28 | `u32 coverage_level` (`0` none, `1` statement, `2` expression) |
| 32 | request ID (16 bytes) |
| 48 | compiler-contract SHA-256 |
| 80 | runtime-profile SHA-256 |
| 112 | runtime-pack SHA-256 |
| 144 | canonical manifest SHA-256 |
| 176 | `u32 output_kind` (`0` executable module) |
| 180 | `u32 allowed_import_ceiling` |
| 184 | `u32 feature_ceiling` |
| 188 | `u32 compile_budget_instructions` |
| 192 | `u32 compile_budget_functions` |
| 196 | `u32 compile_budget_bytes` |
| 200 | `u32 optimization_options` |
| 204 | `u32 debug_and_source_map_options` |
| 208 | 32 zero reserved bytes |

A 160-byte header is `InvalidHeader`. A version other than 1 is `UnsupportedVersion`.

The header is followed by `module_count` 64-byte records and then one tightly packed payload region.
Total request size is limited to 16 MiB.

## Module record (64 bytes)

The record contains offset/size pairs for canonical module name, canonical source name, and UTF-8
source content, followed by the 32-byte content SHA-256 and `plan_offset` / `plan_count`. Inline
plans are first-class; `plan_count` may be 0. Payloads must be contiguous in name, source name,
content, then optional plan bytes.

Module names are nonempty UTF-8 containing only lowercase ASCII letters, digits, `_`, `-`, `.`, and
`/`; they cannot be absolute, end in `/`, or contain `..`. Records are strictly sorted by name and
unique. Source name is exactly `@<module>.luau`.

The manifest digest hashes module count and entry ID followed by each length-prefixed name,
length-prefixed source name, content digest, plan count, and plan bytes. The request ID is the first
16 bytes of SHA-256 over `"luauc-source-request-v1\0"`, coverage, compiler-contract, profile, pack,
and manifest digests, then output kind, ceilings, budgets, options, and per-module plan count/bytes.
Closed-module resolution admits only `require("id")` of another package module; any other require or
`load` shape fail-closes in the backend. Coverage therefore participates in canonical request identity and deterministic
artifact identity.

The JavaScript reference implementation is in [host.mjs](../hosts/js/host.mjs); the Wasmtime host
contains an independent Rust encoder. Cross-host equality therefore checks the byte contract rather
than sharing one host-side builder.
