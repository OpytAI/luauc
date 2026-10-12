# Native region sharing

The linker shares repeated straight-line Wasm regions after relocation and dispatch threading. It emits ordinary Wasm helper functions and direct calls. It does not emit bytecode, an instruction stream, or an execution dispatcher.

## Matching

The matcher normalizes local indices and i32 constants. Local types remain part of the match. Other instruction bytes, including call targets and memory offsets, must match exactly. A hash selects candidates. An exact comparison confirms each match.

A region must consume only values that it produces on the operand stack. It must leave that stack unchanged. Control instructions and indirect calls end a candidate region. The pass does not move branches, returns, continuation boundaries, or fuel guards.

Each helper receives the locals that the region reads before writing them. It returns up to four written locals through native Wasm multi-value results. The caller stores those results in reverse stack order. This preserves local values across calls, including stack-base reloads. Local indices may differ between callers, but their corresponding types must match.

## Constant arguments

The pass compares ordinary constant arguments with packed constant arguments. For packing, it computes a signed minimum and an unsigned range for each argument across the selected call sites. Small ranges share i32 parameters. A helper uses fixed shifts, masks, and additions to recover the values. Wide ranges retain a full i32 parameter.

These parameters contain values, not operation codes. Every operation and call target is fixed in the helper body. The helper cannot select or interpret a sequence of operations from its arguments.

## Selection and bounds

The pass measures the actual replacement calls, helper body, and type encoding before accepting a group. It retains a margin for section overhead. It selects non-overlapping occurrences in deterministic order.

Candidate discovery has fixed limits for instruction windows, local bindings, constant arguments, shapes, and occurrences. A per-instruction occupancy array prevents overlapping replacements. Reaching a search limit stops optimization discovery; it does not reject a supported program or change its capabilities.

Tests cover typed local bindings, constant packing at signed endpoints, deterministic output, overlapping candidates, resource limits, allocation failures, control boundaries, and host execution parity.

## Remaining opportunities

The four-result limit admits regions that the former single-result rule rejected. Further structural opportunities remain. Local liveness could exclude writes that no successor reads, reducing helper results and admitting longer regions. Typed stack inputs and outputs could share expressions that do not begin and end at an empty relative stack. Structured control-flow sharing needs explicit branch and continuation proofs; the present matcher deliberately stops at those boundaries.

Candidate ranking currently estimates unpacked argument costs before evaluating packed arguments. That can miss groups that become profitable only after packing. Discovery also uses fixed global shape and occurrence limits. Better ranking and search allocation may find additional groups, but those changes require measured total-size and compilation-time comparisons. Increasing the limits alone is not a demonstrated improvement.
