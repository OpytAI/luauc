#include "Luau/Common.h"

// The pin adapter deliberately excludes native CodeGen.cpp; that TU normally owns this flag.
// The strict frontend intentionally enables the pinned integer IR translation so source-level
// integer.create/tonumber and integer operators exercise the same closed compiler/runtime tier as
// the already-enabled integer library and buffer builtins.
namespace FFlag {
Luau::FValue<bool> LuauCodegenInteger2("LuauCodegenInteger2", true, false);
}
