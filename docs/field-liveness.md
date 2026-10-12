# Field-sensitive closure liveness

The compiler analyzes the complete source package before frontend lowering. It follows table and closure identities through local aliases, literal fields, unknown-key field summaries, function arguments, captures, returns, and static package imports. A monotone fixed point determines which closures can execute or remain observable.

Each module initializer remains a root. The entry result escapes to the host. Unknown calls expose their arguments. Escaping callbacks receive unknown arguments, and their returned values also escape. Escaping tables retain their contents and admit unknown field values because external code can mutate them. Dynamic reads, enumeration, metatables, and reflection do not justify deleting observable closures.

The compiler replaces unreachable, unobserved closure expressions with nil before ordinary compilation. It removes an unread function-field declaration entirely when its receiver comes from an immutable local table initializer and has not escaped. Receiver rebinding and goto prevent that field-store removal. Other initializers and module initialization side effects remain.

The source rewrite preserves source length. Removed spans retain line breaks. All bytecode and native metadata are then generated from the rewritten source together; there are no dead-function trap stubs or runtime liveness decisions. Execution remains strictly AOT.

Coverage and profile-guided inline plans disable package pruning. Environment reflection, mutable global bindings, native attributes, unsupported analysis nodes, and unresolved dynamic require also prevent pruning. Host-module collisions remain errors. Analysis has source-size, operation-count, and fixed-point limits; reaching a limit leaves the original package unchanged.

The upstream frontend also performs a scoped local-table pass for callers that compile individual source units. That pass restores its caller's AST after compilation and retains tables that escape the source unit.

Tests cover aliases, calls and returned tables across modules, namecalls, dynamic reads, escaping callbacks, multiple and vararg results, array length, enumeration, metatables, external mutation, coverage, deterministic output, and unused-method size growth.
