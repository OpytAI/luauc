# Compact semantic lowering

Modules with more than eight functions retain dynamic operations in semantic IR.
Small modules retain speculative inline lowering. This follows the backend's
existing size policy for larger groups of functions.

The compact path covers table reads and writes, global reads and writes, and
arithmetic and comparisons with unknown operand types, length, and method lookup.
It avoids constructing speculative
guard, fast-path, fallback, and rejoin blocks only to merge them again later.
Known vector operations, typed userdata hooks, and numeric chains retain their
specialized lowering.

The backend emits ordinary Wasm calls to the existing semantic runtime helpers.
Each source operation has a statically selected call site. The artifact contains
no bytecode stream, bytecode dispatcher, or interpreter fallback. Runtime table
and arithmetic helpers retain metamethods, errors, barriers, and stack relocation.

`//hosts/js:compact_semantics_test` exercises both module-size policies, generic
and constant keys, metamethods, frozen tables, globals, arithmetic coercion,
vectors, comparisons, length, method calls, errors, and a GC boundary.
Its growth budget detects renewed expansion
of repeated dynamic operations.
