# SourcePackageV1

The compiler request is a canonical, length-delimited closed package. Module IDs are logical names;
the compiler performs no filesystem or network discovery.

## Header (160 bytes)

| Offset | Field |
| ---: | --- |
| 0 | magic `LUAUCS1\0` |
| 8 | `u16 version = 1` |
| 10 | `u16 header_size = 160` |
| 12 | `u32 total_size` |
| 16 | `u32 module_count` (1–128) |
| 20 | `u32 entry_module_id` |
| 24 | `u32 record_size = 64` |
| 28 | zero `u32` reserved |
| 32 | request ID (16 bytes) |
| 48 | runtime-profile SHA-256 |
| 80 | runtime-pack SHA-256 |
| 112 | canonical manifest SHA-256 |
| 144 | 16 zero reserved bytes |

The header is followed by `module_count` 64-byte records and then one tightly packed payload region.
Total request size is limited to 16 MiB.

## Module record (64 bytes)

The record contains offset/size pairs for canonical module name, canonical source name, and UTF-8
source content, followed by the 32-byte content SHA-256 and eight zero reserved bytes. Payloads must
be contiguous in exactly that order with no gaps, overlaps, aliases, or trailing bytes.

Module names are nonempty UTF-8 containing only lowercase ASCII letters, digits, `_`, `-`, `.`, and
`/`; they cannot be absolute, end in `/`, or contain `..`. Records are strictly sorted by name and
unique. Source name is exactly `@<module>.luau`.

The manifest digest hashes module count and entry ID followed by each length-prefixed name,
length-prefixed source name, and content digest. The request ID is the first 16 bytes of SHA-256 over
`"luauc-source-request-v1\0"`, profile digest, pack digest, and manifest digest.

The JavaScript reference implementation is in [host.mjs](../hosts/js/host.mjs); the Wasmtime host
contains an independent Rust encoder. Cross-host equality therefore checks the byte contract rather
than sharing one host-side builder.
