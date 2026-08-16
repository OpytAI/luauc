const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const static_package_v1 = @import("luauc_backend_static_package_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const FunctionPlan = @import("luauc_backend_plan").FunctionPlan;
const core = @import("luauc_backend_emit_core");
const scalar = @import("luauc_backend_emit_scalar");
const memory = @import("luauc_backend_emit_memory");
const allocations = @import("luauc_backend_emit_allocations");
const namecall = @import("luauc_backend_emit_namecall");
const builtin_patterns = @import("luauc_backend_emit_builtin_patterns");
const tables = @import("luauc_backend_emit_tables");
const table_values = @import("luauc_backend_emit_table_values");
const operators = @import("luauc_backend_emit_operators");
const iteration = @import("luauc_backend_emit_iteration");
const control = @import("luauc_backend_emit_control");
const calls = @import("luauc_backend_emit_calls");
const dispatch = @import("luauc_backend_emit_dispatch");

const StringKeyPool = model.StringKeyPool;
const ValueSlot = model.ValueSlot;
const CallContinuation = model.CallContinuation;

pub const Context = struct {
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    function: snapshot_v1.IrFunction,
    plan: *const FunctionPlan,
    slots: []const ValueSlot,
    builtin_number_sources: []u32,
    coverage_site_ids: []const u32,
    body: *wasm.Body,
    return_: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    coverage_hit: ?wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    compare_any: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_capture: ?wasm.FunctionRef,
    get_upvalue: ?wasm.FunctionRef,
    set_upvalue: ?wasm.FunctionRef,
    close_upvalues: ?wasm.FunctionRef,
    call: ?wasm.FunctionRef,
    exchange_continuation: ?wasm.FunctionRef,
    set_location: ?wasm.FunctionRef,
    new_table: ?wasm.FunctionRef,
    new_table_deferred: ?wasm.FunctionRef,
    check_gc: ?wasm.FunctionRef,
    load_constant: ?wasm.FunctionRef,
    dup_table: ?wasm.FunctionRef,
    table_insert_append: ?wasm.FunctionRef,
    namecall_plain: ?wasm.FunctionRef,
    set_list: ?wasm.FunctionRef,
    array_set: ?wasm.FunctionRef,
    array_get: ?wasm.FunctionRef,
    table_len: ?wasm.FunctionRef,
    concat: ?wasm.FunctionRef,
    do_len: ?wasm.FunctionRef,
    forg_prep: ?wasm.FunctionRef,
    forg_loop: ?wasm.FunctionRef,
    forg_loop_call: ?wasm.FunctionRef,
    forg_loop_finish: ?wasm.FunctionRef,
    forgprep_xnext_fallback: ?wasm.FunctionRef,
    new_userdata: ?wasm.FunctionRef,
    check_userdata_tag: ?wasm.FunctionRef,
    barrier_object: ?wasm.FunctionRef,
    barrier_table_back: ?wasm.FunctionRef,
    barrier_table_forward: ?wasm.FunctionRef,
    hash_node_addr: ?wasm.FunctionRef,
    slot_node_addr: ?wasm.FunctionRef,
    node_slot_match: ?wasm.FunctionRef,
    try_get_tm: ?wasm.FunctionRef,
    check_node_no_next: ?wasm.FunctionRef,
    check_node_value: ?wasm.FunctionRef,
    closure_matches_proto_id: ?wasm.FunctionRef,
    check_readonly: ?wasm.FunctionRef,
    table_set_string: ?wasm.FunctionRef,
    table_get_string: ?wasm.FunctionRef,
    table_set: ?wasm.FunctionRef,
    table_get: ?wasm.FunctionRef,
    table_set_number: ?wasm.FunctionRef,
    table_get_number: ?wasm.FunctionRef,
    table_array_set: ?wasm.FunctionRef,
    table_array_get: ?wasm.FunctionRef,
    get_global: ?wasm.FunctionRef,
    set_global: ?wasm.FunctionRef,
    check_safe_env: ?wasm.FunctionRef,
    fastcall: ?wasm.FunctionRef,
    type_name: ?wasm.FunctionRef,
    libm: ?wasm.FunctionRef,
    builtin_type_error: ?wasm.FunctionRef,
    builtin_number: ?wasm.FunctionRef,
    buffer_bounds_error: ?wasm.FunctionRef,
    prep_varargs: ?wasm.FunctionRef,
    get_varargs_fixed: ?wasm.FunctionRef,
    get_varargs_multret: ?wasm.FunctionRef,
    require_static: ?wasm.FunctionRef,
    static_package: ?static_package_v1.Package,
    function_id_base: u32,
    proto_id_by_bytecode_id: []const u32,
    base_local: u32,
    dispatch_local: u32,
    status_local: u32,
    continuation_local: u32,
    table_index_local: u32,
    call_continuations: []const CallContinuation,
    string_keys: *StringKeyPool,

    // core
    pub const instruction = core.instruction;
    pub const operand = core.operand;
    pub const constant = core.constant;
    pub const requireOperandCount = core.requireOperandCount;
    pub const vmRegisterOffset = core.vmRegisterOffset;
    pub const vmRegisterIndex = core.vmRegisterIndex;
    pub const valueOperandEncoding = core.valueOperandEncoding;
    pub const emitReloadBase = core.emitReloadBase;
    pub const requireSingleBytecodeBlockRange = core.requireSingleBytecodeBlockRange;
    pub const requireSingleCompilableBlockRange = core.requireSingleCompilableBlockRange;
    pub const requireSingleCallBlockRange = core.requireSingleCallBlockRange;
    pub const loadedTValueRegister = core.loadedTValueRegister;
    pub const initializedClosureValueCapture = core.initializedClosureValueCapture;
    pub const newClosurePattern = core.newClosurePattern;
    pub const requireClosureCaptureAddress = core.requireClosureCaptureAddress;
    pub const requireInstructionStore = core.requireInstructionStore;
    pub const requireTValueStore = core.requireTValueStore;
    pub const initializedCapture = core.initializedCapture;
    pub const newClosurePatternContaining = core.newClosurePatternContaining;
    pub const isDupClosureCapture = core.isDupClosureCapture;
    pub const setUpvaluePattern = core.setUpvaluePattern;
    pub const emitCopyTValueRegisters = core.emitCopyTValueRegisters;
    pub const emitStoreTValueOperand = core.emitStoreTValueOperand;
    pub const emitCopyTValueRegisterToAddress = core.emitCopyTValueRegisterToAddress;
    pub const emitStoreSplitTValue = core.emitStoreSplitTValue;
    pub const emitVmConstantAddress = core.emitVmConstantAddress;
    pub const emitI32Value = core.emitI32Value;
    pub const emitPointerValue = core.emitPointerValue;
    pub const vmConstantTag = core.vmConstantTag;
    pub const vmConstantParts = core.vmConstantParts;
    pub const emitTValueAddress = core.emitTValueAddress;
    pub const tvalueByteOffset = core.tvalueByteOffset;
    pub const emitI64Value = core.emitI64Value;
    pub const emitF32Value = core.emitF32Value;
    pub const emitF64Value = core.emitF64Value;
    pub const emitTagValue = core.emitTagValue;
    pub const tvalueSlot = core.tvalueSlot;
    pub const emitTValuePart = core.emitTValuePart;
    pub const emitTValueTag = core.emitTValueTag;
    pub const emitTValuePayloadI32 = core.emitTValuePayloadI32;
    pub const emitTValueTruthy = core.emitTValueTruthy;
    pub const requireCompiledTarget = core.requireCompiledTarget;
    pub const requireDispatchTarget = core.requireDispatchTarget;

    // scalar
    pub const emitStatusReturn = scalar.emitStatusReturn;
    pub const emitInstructionResultSet = scalar.emitInstructionResultSet;
    pub const emitLoadTag = scalar.emitLoadTag;
    pub const emitLoadI32 = scalar.emitLoadI32;
    pub const emitLoadI64 = scalar.emitLoadI64;
    pub const emitLoadFloat = scalar.emitLoadFloat;
    pub const storesVmRegister = scalar.storesVmRegister;
    pub const classifyBuiltinNumberLoads = scalar.classifyBuiltinNumberLoads;
    pub const emitLoadDouble = scalar.emitLoadDouble;
    pub const emitLoadTValue = scalar.emitLoadTValue;
    pub const emitStoreTag = scalar.emitStoreTag;
    pub const emitStoreDouble = scalar.emitStoreDouble;
    pub const emitStoreI32 = scalar.emitStoreI32;
    pub const emitStoreI64 = scalar.emitStoreI64;
    pub const emitStoreVector = scalar.emitStoreVector;
    pub const emitStoreTValue = scalar.emitStoreTValue;
    pub const emitGetUpvalue = scalar.emitGetUpvalue;
    pub const emitNewClosure = scalar.emitNewClosure;
    pub const emitCaptureCall = scalar.emitCaptureCall;
    pub const emitSetUpvalue = scalar.emitSetUpvalue;
    pub const emitCloseUpvalues = scalar.emitCloseUpvalues;
    pub const emitAddNumber = scalar.emitAddNumber;
    pub const emitUnaryI32 = scalar.emitUnaryI32;
    pub const emitUnaryI64 = scalar.emitUnaryI64;
    pub const emitUnaryF32 = scalar.emitUnaryF32;
    pub const emitUnaryF64 = scalar.emitUnaryF64;
    pub const emitBinaryI32 = scalar.emitBinaryI32;
    pub const emitBinaryI64 = scalar.emitBinaryI64;
    pub const emitInvalidI64DivisionGuard = scalar.emitInvalidI64DivisionGuard;
    pub const emitZeroI64DivisorGuard = scalar.emitZeroI64DivisorGuard;
    pub const emitSignedDivisionI64 = scalar.emitSignedDivisionI64;
    pub const emitUnsignedDivisionI64 = scalar.emitUnsignedDivisionI64;
    pub const emitSignedRemainderI64 = scalar.emitSignedRemainderI64;
    pub const emitNotI32 = scalar.emitNotI32;
    pub const emitNotI64 = scalar.emitNotI64;
    pub const emitSignedI64Shift = scalar.emitSignedI64Shift;
    pub const emitByteSwapI32 = scalar.emitByteSwapI32;
    pub const emitAdjacentByteSwapI64 = scalar.emitAdjacentByteSwapI64;
    pub const emitByteSwapI64 = scalar.emitByteSwapI64;
    pub const emitBinaryF32 = scalar.emitBinaryF32;
    pub const emitBinaryF64 = scalar.emitBinaryF64;
    pub const emitMulAddNumber = scalar.emitMulAddNumber;
    pub const emitFloorDivisionNumber = scalar.emitFloorDivisionNumber;
    pub const emitModNumber = scalar.emitModNumber;
    pub const emitMinMaxNumber = scalar.emitMinMaxNumber;
    pub const emitRoundNumber = scalar.emitRoundNumber;
    pub const emitSignNumber = scalar.emitSignNumber;
    pub const emitMinMaxFloat = scalar.emitMinMaxFloat;
    pub const emitSignFloat = scalar.emitSignFloat;
    pub const vectorSlot = scalar.vectorSlot;
    pub const emitVectorLaneBits = scalar.emitVectorLaneBits;
    pub const emitVectorLane = scalar.emitVectorLane;
    pub const emitVectorPackPrefix = scalar.emitVectorPackPrefix;
    pub const emitVectorLaneBitsSet = scalar.emitVectorLaneBitsSet;
    pub const emitVectorLaneSet = scalar.emitVectorLaneSet;
    pub const emitVectorUnary = scalar.emitVectorUnary;
    pub const emitVectorBinary = scalar.emitVectorBinary;
    pub const emitFloorDivisionVector = scalar.emitFloorDivisionVector;
    pub const emitMulAddVector = scalar.emitMulAddVector;
    pub const emitMinMaxVector = scalar.emitMinMaxVector;
    pub const emitDotVector = scalar.emitDotVector;
    pub const emitExtractVector = scalar.emitExtractVector;
    pub const emitFloatToVector = scalar.emitFloatToVector;
    pub const emitTagVector = scalar.emitTagVector;
    pub const conditionOperand = scalar.conditionOperand;
    pub const emitIntegerCondition = scalar.emitIntegerCondition;
    pub const emitInt64Condition = scalar.emitInt64Condition;
    pub const emitFloatCondition = scalar.emitFloatCondition;
    pub const emitComparisonI32 = scalar.emitComparisonI32;
    pub const emitComparisonI64 = scalar.emitComparisonI64;
    pub const emitComparisonTag = scalar.emitComparisonTag;
    pub const emitSplitTValueComparison = scalar.emitSplitTValueComparison;
    pub const emitSelectNumber = scalar.emitSelectNumber;
    pub const emitSelectInt64 = scalar.emitSelectInt64;
    pub const emitSelectVector = scalar.emitSelectVector;
    pub const emitSelectIfTruthy = scalar.emitSelectIfTruthy;
    pub const emitCopyI32 = scalar.emitCopyI32;
    pub const emitNotAny = scalar.emitNotAny;

    // memory
    pub const emitCheckDivInt64 = memory.emitCheckDivInt64;
    pub const emitBuiltinTypeError = memory.emitBuiltinTypeError;
    pub const emitCheckTag = memory.emitCheckTag;
    pub const emitInvalidSignedConversion = memory.emitInvalidSignedConversion;
    pub const emitNumToInt = memory.emitNumToInt;
    pub const emitNumToInt64 = memory.emitNumToInt64;
    pub const emitNumToUint = memory.emitNumToUint;
    pub const emitBufferLengthCheck = memory.emitBufferLengthCheck;
    pub const emitBufferAddress = memory.emitBufferAddress;
    pub const emitUnalignedMemoryOp = memory.emitUnalignedMemoryOp;
    pub const emitBufferRead = memory.emitBufferRead;
    pub const emitBufferWrite = memory.emitBufferWrite;
    pub const emitUserdataWrite = memory.emitUserdataWrite;
    pub const loadedPointerRegister = memory.loadedPointerRegister;
    pub const rootedTablePointerRegister = memory.rootedTablePointerRegister;
    pub const emitRegisterTagMismatch = memory.emitRegisterTagMismatch;
    pub const emitCheckUserdataTag = memory.emitCheckUserdataTag;
    pub const emitInternalErrorIf = memory.emitInternalErrorIf;
    pub const emitBarrierObject = memory.emitBarrierObject;
    pub const emitBarrierTableBack = memory.emitBarrierTableBack;
    pub const requireLiveNode = memory.requireLiveNode;
    pub const emitGetHashNodeAddr = memory.emitGetHashNodeAddr;
    pub const emitGetSlotNodeAddr = memory.emitGetSlotNodeAddr;
    pub const emitJumpSlotMatch = memory.emitJumpSlotMatch;
    pub const emitCheckSlotMatch = memory.emitCheckSlotMatch;
    pub const emitTryCallFastGetTm = memory.emitTryCallFastGetTm;
    pub const emitCheckNodeNoNext = memory.emitCheckNodeNoNext;
    pub const emitCheckNodeValue = memory.emitCheckNodeValue;
    pub const emitJumpCompareProtoId = control.emitJumpCompareProtoId;
    pub const emitCheckReadonly = memory.emitCheckReadonly;
    pub const emitBufferAdjustStack = memory.emitBufferAdjustStack;
    pub const emitGuardFailure = memory.emitGuardFailure;
    pub const emitCheckTruthy = memory.emitCheckTruthy;
    pub const emitCheckCompareNumber = memory.emitCheckCompareNumber;
    pub const emitCheckCompareInteger = memory.emitCheckCompareInteger;
    pub const emitCheckCompareInt64 = memory.emitCheckCompareInt64;
    pub const savedPc = memory.savedPc;
    pub const uintConstant = memory.uintConstant;
    pub const intConstant = memory.intConstant;
    pub const nonnegativeConstant = memory.nonnegativeConstant;
    pub const genericIterationAux = memory.genericIterationAux;
    pub const sameOperand = memory.sameOperand;
    pub const operandIntConstant = memory.operandIntConstant;
    pub const compilableBlockContaining = memory.compilableBlockContaining;
    pub const bufferAccessWidth = memory.bufferAccessWidth;
    pub const bufferIndexOffset = memory.bufferIndexOffset;
    pub const bufferOperationOwnedByRange = memory.bufferOperationOwnedByRange;
    pub const integerCreatePatternAt = memory.integerCreatePatternAt;
    pub const emitIntegerCreate = memory.emitIntegerCreate;

    // general table/value IR
    pub const emitTryNumberToIndex = table_values.emitTryNumberToIndex;
    pub const emitGetArrayAddress = table_values.emitGetArrayAddress;
    pub const emitTableLayoutGuard = table_values.emitTableLayoutGuard;
    pub const emitForwardTableBarrier = table_values.emitForwardTableBarrier;
    pub const emitGeneralTableOperation = table_values.emitGeneralTableOperation;
    pub const supportsGeneralTableFallback = table_values.supportsGeneralTableFallback;

    // allocations
    pub const tableAllocationPatternAt = allocations.tableAllocationPatternAt;
    pub const isDeferredTableInitializationCommand = allocations.isDeferredTableInitializationCommand;
    pub const checkGcClosesDeferredTableAllocation = allocations.checkGcClosesDeferredTableAllocation;
    pub const userdataWriteWidth = allocations.userdataWriteWidth;
    pub const userdataAllocationPatternAt = allocations.userdataAllocationPatternAt;
    pub const userdataAllocationPatternContaining = allocations.userdataAllocationPatternContaining;
    pub const materializedConstantTag = allocations.materializedConstantTag;
    pub const constantLoadPatternAt = allocations.constantLoadPatternAt;
    pub const constantLoadPatternContaining = allocations.constantLoadPatternContaining;
    pub const emitConstantLoad = allocations.emitConstantLoad;
    pub const constantTruthyFallbackPatternAt = allocations.constantTruthyFallbackPatternAt;
    pub const constantTruthyFallbackPatternContaining = allocations.constantTruthyFallbackPatternContaining;
    pub const emitConstantTruthyFallback = allocations.emitConstantTruthyFallback;
    pub const dupTablePatternAt = allocations.dupTablePatternAt;
    pub const dupTablePatternContaining = allocations.dupTablePatternContaining;
    pub const emitDupTable = allocations.emitDupTable;
    pub const tableRegisterForPointer = allocations.tableRegisterForPointer;
    pub const dupTableRegisterForPointer = allocations.dupTableRegisterForPointer;
    pub const literalFieldSetPatternAt = allocations.literalFieldSetPatternAt;
    pub const literalFieldSetPatternContaining = allocations.literalFieldSetPatternContaining;
    pub const emitLiteralFieldSet = allocations.emitLiteralFieldSet;
    pub const tableInsertAppendPatternAt = allocations.tableInsertAppendPatternAt;
    pub const tableInsertAppendPatternContaining = allocations.tableInsertAppendPatternContaining;
    pub const emitTableInsertAppend = allocations.emitTableInsertAppend;

    // namecall
    pub const blockReferenceCount = namecall.blockReferenceCount;
    pub const plainTableNamecallPattern = namecall.plainTableNamecallPattern;
    pub const isBypassedPlainTableNamecallBlock = namecall.isBypassedPlainTableNamecallBlock;
    pub const emitPlainTableNamecallBlock = namecall.emitPlainTableNamecallBlock;
    pub const emitFallbackNamecall = namecall.emitFallbackNamecall;
    pub const emitPlainTableNamecallOperation = namecall.emitPlainTableNamecallOperation;
    pub const tableAllocationPatternContaining = namecall.tableAllocationPatternContaining;
    pub const emitTableAllocation = namecall.emitTableAllocation;
    pub const emitUserdataAllocationInstruction = namecall.emitUserdataAllocationInstruction;
    pub const emitSetList = namecall.emitSetList;
    pub const commandRangeMatches = namecall.commandRangeMatches;
    pub const concatPatternAt = namecall.concatPatternAt;
    pub const concatPatternContaining = namecall.concatPatternContaining;
    pub const emitConcat = namecall.emitConcat;

    // builtin_patterns
    pub const uintOperandEquals = builtin_patterns.uintOperandEquals;
    pub const intOperandEquals = builtin_patterns.intOperandEquals;
    pub const stringKey = builtin_patterns.stringKey;
    pub const stringFallbackRejoin = builtin_patterns.stringFallbackRejoin;
    pub const fastcallValueOperand = builtin_patterns.fastcallValueOperand;
    pub const fastcallPatternAt = builtin_patterns.fastcallPatternAt;
    pub const stringLengthPattern = builtin_patterns.stringLengthPattern;
    pub const hasPreservedStringGuard = builtin_patterns.hasPreservedStringGuard;
    pub const preservesRegisterToConsumer = builtin_patterns.preservesRegisterToConsumer;
    pub const rangeHasPreservedStringGuard = builtin_patterns.rangeHasPreservedStringGuard;
    pub const instructionWritesRegister = builtin_patterns.instructionWritesRegister;
    pub const hasPublishedTValue = builtin_patterns.hasPublishedTValue;
    pub const compilableOwnerBlock = builtin_patterns.compilableOwnerBlock;
    pub const publishedNumberPayloadRegister = builtin_patterns.publishedNumberPayloadRegister;
    pub const typeNamePattern = builtin_patterns.typeNamePattern;
    pub const stringSetPattern = builtin_patterns.stringSetPattern;
    pub const stringGetPattern = builtin_patterns.stringGetPattern;
    pub const inlineStringGetPatternAt = builtin_patterns.inlineStringGetPatternAt;
    pub const inlineGeneralStringSetPatternAt = builtin_patterns.inlineGeneralStringSetPatternAt;
    pub const inlinePreloadedStringSetPatternAt = builtin_patterns.inlinePreloadedStringSetPatternAt;
    pub const inlineStringSetPatternAt = builtin_patterns.inlineStringSetPatternAt;
    pub const stringTablePattern = builtin_patterns.stringTablePattern;

    // tables
    pub const globalFallback = tables.globalFallback;
    pub const globalPatternFor = tables.globalPatternFor;
    pub const globalPattern = tables.globalPattern;
    pub const globalHeadPatternAt = tables.globalHeadPatternAt;
    pub const genericTableFallback = tables.genericTableFallback;
    pub const inlineGenericTableSetPatternAt = tables.inlineGenericTableSetPatternAt;
    pub const inlineGenericTableSetPatternContaining = tables.inlineGenericTableSetPatternContaining;
    pub const semanticTableReloadPatternAt = tables.semanticTableReloadPatternAt;
    pub const semanticTableReloadPatternContaining = tables.semanticTableReloadPatternContaining;
    pub const emitSemanticTableReload = tables.emitSemanticTableReload;
    pub const emitDirectGenericTableOperation = tables.emitDirectGenericTableOperation;
    pub const genericTableSetPattern = tables.genericTableSetPattern;
    pub const genericTableGetPattern = tables.genericTableGetPattern;
    pub const constantGenericTableGetPattern = tables.constantGenericTableGetPattern;
    pub const inlineConstantTableGetPatternAt = tables.inlineConstantTableGetPatternAt;
    pub const inlineConstantTableGetPatternContaining = tables.inlineConstantTableGetPatternContaining;
    pub const genericTablePattern = tables.genericTablePattern;
    pub const arraySetPattern = tables.arraySetPattern;
    pub const arrayGetPattern = tables.arrayGetPattern;
    pub const trustedArrayGetPattern = tables.trustedArrayGetPattern;
    pub const trustedArrayAddress = tables.trustedArrayAddress;
    pub const inlineArrayGetPatternAt = tables.inlineArrayGetPatternAt;
    pub const inlineArrayGetPatternContaining = tables.inlineArrayGetPatternContaining;
    pub const emitInlineArrayGet = tables.emitInlineArrayGet;
    pub const tableLenPattern = tables.tableLenPattern;
    pub const dynamicLengthPattern = tables.dynamicLengthPattern;

    // operators
    pub const powPattern = operators.powPattern;
    pub const powValueRegister = operators.powValueRegister;
    pub const numericCommandMetamethod = operators.numericCommandMetamethod;
    pub const constantArithmeticPattern = operators.constantArithmeticPattern;
    pub const integerPowExponent = operators.integerPowExponent;
    pub const constantPowPattern = operators.constantPowPattern;
    pub const linearizedPowPattern = operators.linearizedPowPattern;
    pub const emitPowBlock = operators.emitPowBlock;
    pub const emitConstantArithmeticBlock = operators.emitConstantArithmeticBlock;
    pub const emitDynamicLengthBlock = operators.emitDynamicLengthBlock;
    pub const emitDynamicLength = operators.emitDynamicLength;

    // iteration
    pub const genericIterationFallbackPattern = iteration.genericIterationFallbackPattern;
    pub const genericIterationPattern = iteration.genericIterationPattern;
    pub const xnextPreparationPattern = iteration.xnextPreparationPattern;
    pub const xnextCanonicalPublish = iteration.xnextCanonicalPublish;
    pub const xnextFastPreparationPattern = iteration.xnextFastPreparationPattern;
    pub const emitXnextFastPreparationBlock = iteration.emitXnextFastPreparationBlock;
    pub const emitXnextPreparationBlock = iteration.emitXnextPreparationBlock;
    pub const supportsGenericIterationFallback = iteration.supportsGenericIterationFallback;
    pub const supportsSpecializedIpairsFallback = iteration.supportsSpecializedIpairsFallback;
    pub const specializedIpairsPattern = iteration.specializedIpairsPattern;
    pub const isBypassedSpecializedIpairsPublishBlock = iteration.isBypassedSpecializedIpairsPublishBlock;
    pub const emitGenericIterationCall = iteration.emitGenericIterationCall;
    pub const emitGenericIterationFinish = iteration.emitGenericIterationFinish;
    pub const emitGenericIterationFallbackCall = iteration.emitGenericIterationFallbackCall;
    pub const emitGenericIterationBlock = iteration.emitGenericIterationBlock;
    pub const emitGenericIterationPrep = iteration.emitGenericIterationPrep;
    pub const emitArrayOperationBlock = iteration.emitArrayOperationBlock;
    pub const emitArrayOperation = iteration.emitArrayOperation;
    pub const semanticArrayOperation = iteration.semanticArrayOperation;
    pub const emitStringTableOperationBlock = iteration.emitStringTableOperationBlock;
    pub const emitStringTableOperation = iteration.emitStringTableOperation;
    pub const emitStringTableHelper = iteration.emitStringTableHelper;
    pub const emitGlobalOperationBlock = iteration.emitGlobalOperationBlock;
    pub const emitGlobalOperation = iteration.emitGlobalOperation;
    pub const emitGenericTableFallbackCall = iteration.emitGenericTableFallbackCall;
    pub const emitGenericTableDirectAttempt = iteration.emitGenericTableDirectAttempt;
    pub const emitGenericTableOperationBlock = iteration.emitGenericTableOperationBlock;
    pub const emitInlineGenericTableSet = iteration.emitInlineGenericTableSet;
    pub const isBypassedStringLinearizedBlock = iteration.isBypassedStringLinearizedBlock;
    pub const isBypassedGenericTableLinearizedBlock = iteration.isBypassedGenericTableLinearizedBlock;
    pub const isBypassedGlobalLinearizedBlock = iteration.isBypassedGlobalLinearizedBlock;
    pub const isBypassedPowLinearizedBlock = iteration.isBypassedPowLinearizedBlock;
    pub const isBypassedConstantArithmeticLinearizedBlock = iteration.isBypassedConstantArithmeticLinearizedBlock;
    pub const isBypassedStringEqualityBlock = iteration.isBypassedStringEqualityBlock;

    // control
    pub const sourceLine = control.sourceLine;
    pub const emitSavedPcLocation = control.emitSavedPcLocation;
    pub const emitPcLocation = control.emitPcLocation;
    pub const emitDoArith = control.emitDoArith;
    pub const comparisonOperation = control.comparisonOperation;
    pub const emitCompareAny = control.emitCompareAny;
    pub const stringEqualityPattern = control.stringEqualityPattern;
    pub const emitStringEqualityBlock = control.emitStringEqualityBlock;
    pub const supportsArithmeticFallback = control.supportsArithmeticFallback;
    pub const supportsComparisonFallback = control.supportsComparisonFallback;
    pub const supportsMaterializedComparisonFallback = control.supportsMaterializedComparisonFallback;
    pub const supportsFallback = control.supportsFallback;
    pub const supportsNamecallFallback = control.supportsNamecallFallback;
    pub const supportsOrdinaryCallFallback = control.supportsOrdinaryCallFallback;
    pub const isOwnedSemanticTableFallbackBlock = control.isOwnedSemanticTableFallbackBlock;
    pub const isOwnedDynamicLengthFallbackBlock = control.isOwnedDynamicLengthFallbackBlock;
    pub const isBypassedEmissionBlock = control.isBypassedEmissionBlock;
    pub const isBypassedXnextFastPreparationBlock = control.isBypassedXnextFastPreparationBlock;
    pub const isFastcallFallbackBlock = control.isFastcallFallbackBlock;
    pub const emitInterrupt = control.emitInterrupt;
    pub const emitCoverage = control.emitCoverage;
    pub const emitJump = control.emitJump;
    pub const emitConditionalDispatch = control.emitConditionalDispatch;
    pub const emitJumpIfTruthy = control.emitJumpIfTruthy;
    pub const emitJumpEqualTag = control.emitJumpEqualTag;
    pub const emitJumpCompareInteger = control.emitJumpCompareInteger;
    pub const emitJumpEqualPointer = control.emitJumpEqualPointer;
    pub const emitJumpCompareFloat = control.emitJumpCompareFloat;
    pub const emitNumericCondition = control.emitNumericCondition;
    pub const emitJumpCompareNumber = control.emitJumpCompareNumber;
    pub const emitJumpFornLoopCondition = control.emitJumpFornLoopCondition;
    pub const emitReturn = control.emitReturn;
    pub const emitDupClosure = control.emitDupClosure;
    pub const callContinuation = control.callContinuation;
    pub const emitExchangeContinuation = control.emitExchangeContinuation;
    pub const emitUnexpectedContinuationReturn = control.emitUnexpectedContinuationReturn;
    pub const emitClearContinuation = control.emitClearContinuation;
    pub const emitCall = control.emitCall;

    // calls
    pub const emitPrepVarargs = calls.emitPrepVarargs;
    pub const emitGetVarargs = calls.emitGetVarargs;
    pub const vmString = calls.vmString;
    pub const builtinIdentityMatches = calls.builtinIdentityMatches;
    pub const builtinFallback = calls.builtinFallback;
    pub const emitSingleGlobalImport = calls.emitSingleGlobalImport;
    pub const staticRequireTarget = calls.staticRequireTarget;
    pub const emitStaticRequire = calls.emitStaticRequire;
    pub const isTableInsertAppendSafeEnv = calls.isTableInsertAppendSafeEnv;
    pub const emitStatusCheckedCall = calls.emitStatusCheckedCall;
    pub const emitSafeEnvCheck = calls.emitSafeEnvCheck;
    pub const emitAdjustStackConstant = calls.emitAdjustStackConstant;
    pub const emitAdjustStackDynamic = calls.emitAdjustStackDynamic;
    pub const emitAdjustStackToTop = calls.emitAdjustStackToTop;
    pub const emitDirectFastcall = calls.emitDirectFastcall;
    pub const emitFastcallCluster = calls.emitFastcallCluster;
    pub const isFastcallFallback = calls.isFastcallFallback;
    pub const emitFastcallFallbackBlock = calls.emitFastcallFallbackBlock;
    pub const emitLibm = calls.emitLibm;
    pub const emitStringLen = calls.emitStringLen;
    pub const emitTypeName = calls.emitTypeName;

    // dispatch
    pub const emitInstruction = dispatch.emitInstruction;
    pub const emitInstructionRange = dispatch.emitInstructionRange;
    pub const emitBlock = dispatch.emitBlock;
    pub const emitCallContinuation = dispatch.emitCallContinuation;
};
