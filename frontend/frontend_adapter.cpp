#include "../schema/frontend_snapshot_v1.h"
#include "compiler_error_channel.h"
#include "frontend_identity_v1.h"

#include "lua.h"
#include "lualib.h"
#include "luacode.h"

#include "lapi.h"
#include "lobject.h"
#include "lstate.h"

#include "Luau/CodeGenOptions.h"
#include "Luau/Bytecode.h"
#include "Luau/BytecodeBuilder.h"
#include "Luau/BytecodeCallInliner.h"
#include "Luau/BytecodeGraph.h"
#include "Luau/BytecodeUtils.h"
#include "Luau/Common.h"
#include "Luau/Compiler.h"
#include "Luau/IrAnalysis.h"
#include "Luau/IrBuilder.h"
#include "Luau/IrData.h"
#include "Luau/IrUtils.h"
#include "Luau/OptimizeConstProp.h"

#include <algorithm>
#include <optional>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

using namespace Luau::CodeGen;

LUAU_FASTFLAG(LuauEmitCallFeedback)

// Host userdata types follow the pinned Luau HostIrHooks contract (same class as CALLFB /
// inline_plans): the production frontend emits NEW_USERDATA / CHECK_USERDATA_TAG / BARRIER_OBJ /
// BARRIER_TABLE_BACK from ordinary typed Luau. Names must match CompileOptions.userdataTypes.
static const char *const kUserdataCompileTypes[] = {"extra", "color", "vec2", "mat3", "vertex", nullptr};
constexpr uint8_t kUserdataVec2Index = 2;
constexpr int kTagVec2 = 12;
constexpr int kVec2ByteSize = 8;

static bool sourceMentionsUserdataType(const char *source, size_t size) {
    // Only the types this frontend actually lowers. Do not scan "extra"/"color": those
    // strings appear as ordinary identifiers in existing sources.
    // Require a type annotation (`: vec2`) so constructor names like embed.vec2 do not
    // enable typeInfoLevel for unrelated modules.
    static const char kNeeded[] = ": vec2";
    const size_t nameSize = sizeof(kNeeded) - 1;
    if (nameSize > size)
        return false;
    for (size_t index = 0; index + nameSize <= size; ++index) {
        if (memcmp(source + index, kNeeded, nameSize) == 0)
            return true;
    }
    static const char kNeededTight[] = ":vec2";
    const size_t tightSize = sizeof(kNeededTight) - 1;
    for (size_t index = 0; index + tightSize <= size; ++index) {
        if (memcmp(source + index, kNeededTight, tightSize) == 0)
            return true;
    }
    return false;
}

template <typename Options>
void applyUserdataCompileOptions(Options &options, const char *source, size_t size) {
    options.userdataTypes = kUserdataCompileTypes;
    if (sourceMentionsUserdataType(source, size))
        options.typeInfoLevel = 1;
}

static bool compareMemberName(const char *member, size_t memberLength, const char *expected) {
    const size_t expectedLength = strlen(expected);
    return memberLength == expectedLength && memcmp(member, expected, expectedLength) == 0;
}

static uint8_t typeToUserdataIndex(uint8_t type) {
    return uint8_t(type - LBC_TYPE_TAGGED_USERDATA_BASE);
}

static uint8_t userdataIndexToType(uint8_t userdataIndex) {
    return uint8_t(LBC_TYPE_TAGGED_USERDATA_BASE + userdataIndex);
}

static bool isHookedUserdataType(uint8_t type) {
    return type == LBC_TYPE_USERDATA ||
           (type >= LBC_TYPE_TAGGED_USERDATA_BASE && type < LBC_TYPE_TAGGED_USERDATA_END);
}

static uint8_t userdataAccessBytecodeType(uint8_t type, const char *member, size_t memberLength) {
    if (isHookedUserdataType(type) && compareMemberName(member, memberLength, "Unit"))
        return userdataIndexToType(kUserdataVec2Index);
    if (isHookedUserdataType(type) && compareMemberName(member, memberLength, "Hold"))
        return LBC_TYPE_TABLE;
    return LBC_TYPE_ANY;
}

static uint8_t userdataNamecallBytecodeType(uint8_t type, const char *member, size_t memberLength) {
    if (isHookedUserdataType(type) && compareMemberName(member, memberLength, "Mark"))
        return LBC_TYPE_NUMBER;
    if (isHookedUserdataType(type) && compareMemberName(member, memberLength, "Store"))
        return LBC_TYPE_TABLE;
    return LBC_TYPE_ANY;
}

// embed.vec2 contract: Unit = normalize; Mark returns payload[0].
// Keep frontend_adapter.cpp, interpreter/main.cpp, provider_entry.c identical.
static bool userdataAccess(IrBuilder &build, uint8_t type, const char *member, size_t memberLength,
                           int resultReg, int sourceReg, int pcpos) {
    (void)pcpos;
    if (!isHookedUserdataType(type))
        return false;
    if (compareMemberName(member, memberLength, "Hold")) {
        IrOp udata = build.inst(IrCmd::LOAD_POINTER, build.vmReg(sourceReg));
        build.inst(IrCmd::CHECK_USERDATA_TAG, udata, build.constUint(kTagVec2), build.undef());
        build.inst(IrCmd::CHECK_GC);
        IrOp created = build.inst(IrCmd::NEW_TABLE, build.constUint(0), build.constUint(0));
        build.inst(IrCmd::STORE_POINTER, build.vmReg(resultReg), created);
        build.inst(IrCmd::STORE_TAG, build.vmReg(resultReg), build.constTag(LUA_TTABLE));
        build.inst(IrCmd::BARRIER_OBJ, udata, build.vmReg(resultReg), build.undef());
        return true;
    }
    if (!compareMemberName(member, memberLength, "Unit"))
        return false;

    IrOp udata = build.inst(IrCmd::LOAD_POINTER, build.vmReg(sourceReg));
    build.inst(IrCmd::CHECK_USERDATA_TAG, udata, build.constUint(kTagVec2), build.undef());
    IrOp x = build.inst(IrCmd::BUFFER_READF32, udata, build.constUint(0), build.constTag(LUA_TUSERDATA));
    IrOp y = build.inst(IrCmd::BUFFER_READF32, udata, build.constUint(4), build.constTag(LUA_TUSERDATA));
    IrOp x64 = build.inst(IrCmd::FLOAT_TO_NUM, x);
    IrOp y64 = build.inst(IrCmd::FLOAT_TO_NUM, y);
    IrOp len = build.inst(IrCmd::SQRT_NUM, build.inst(IrCmd::ADD_NUM,
        build.inst(IrCmd::MUL_NUM, x64, x64), build.inst(IrCmd::MUL_NUM, y64, y64)));
    IrOp zero = build.constDouble(0.0);
    IrOp nx = build.inst(IrCmd::SELECT_NUM, build.inst(IrCmd::DIV_NUM, x64, len), zero, len, zero);
    IrOp ny = build.inst(IrCmd::SELECT_NUM, build.inst(IrCmd::DIV_NUM, y64, len), zero, len, zero);
    IrOp nx_f = build.inst(IrCmd::NUM_TO_FLOAT, nx);
    IrOp ny_f = build.inst(IrCmd::NUM_TO_FLOAT, ny);
    build.inst(IrCmd::CHECK_GC);
    IrOp created = build.inst(IrCmd::NEW_USERDATA, build.constUint(kVec2ByteSize), build.constUint(kTagVec2));
    build.inst(IrCmd::BUFFER_WRITEF32, created, build.constUint(0), nx_f, build.constTag(LUA_TUSERDATA));
    build.inst(IrCmd::BUFFER_WRITEF32, created, build.constUint(4), ny_f, build.constTag(LUA_TUSERDATA));
    build.inst(IrCmd::STORE_POINTER, build.vmReg(resultReg), created);
    build.inst(IrCmd::STORE_TAG, build.vmReg(resultReg), build.constTag(LUA_TUSERDATA));
    return true;
}

static bool userdataNamecall(IrBuilder &build, uint8_t type, const char *member, size_t memberLength,
                             int argResReg, int sourceReg, int params, int results, int pcpos) {
    if (!isHookedUserdataType(type))
        return false;
    if (compareMemberName(member, memberLength, "Store")) {
        if (params >= 0 && params < 2)
            return false;
        IrOp udata = build.inst(IrCmd::LOAD_POINTER, build.vmReg(sourceReg));
        build.inst(IrCmd::CHECK_USERDATA_TAG, udata, build.constUint(kTagVec2), build.undef());
        build.loadAndCheckTag(build.vmReg(argResReg + 2), LUA_TTABLE, build.undef());
        build.inst(IrCmd::SET_SAVEDPC, build.constUint(uint32_t(pcpos) + 1));
        build.inst(IrCmd::CHECK_GC);
        IrOp created = build.inst(IrCmd::NEW_TABLE, build.constUint(0), build.constUint(0));
        build.inst(IrCmd::STORE_POINTER, build.vmReg(argResReg), created);
        build.inst(IrCmd::STORE_TAG, build.vmReg(argResReg), build.constTag(LUA_TTABLE));
        IrOp table = build.inst(IrCmd::LOAD_POINTER, build.vmReg(argResReg + 2));
        build.inst(IrCmd::BARRIER_TABLE_BACK, table);
        if (results == LUA_MULTRET)
            build.inst(IrCmd::ADJUST_STACK_TO_REG, build.vmReg(argResReg), build.constInt(1));
        return true;
    }
    if (!compareMemberName(member, memberLength, "Mark"))
        return false;

    // sourceReg stays the live receiver.
    if (params >= 0 && params < 2)
        return false;

    IrOp udata = build.inst(IrCmd::LOAD_POINTER, build.vmReg(sourceReg));
    build.inst(IrCmd::CHECK_USERDATA_TAG, udata, build.constUint(kTagVec2), build.undef());
    build.loadAndCheckTag(build.vmReg(argResReg + 2), LUA_TTABLE, build.undef());
    build.inst(IrCmd::SET_SAVEDPC, build.constUint(uint32_t(pcpos) + 1));
    build.inst(IrCmd::SET_TABLE, build.vmReg(sourceReg), build.vmReg(argResReg + 2), build.constUint(1));
    IrOp table = build.inst(IrCmd::LOAD_POINTER, build.vmReg(argResReg + 2));
    build.inst(IrCmd::BARRIER_TABLE_BACK, table);
    IrOp x = build.inst(IrCmd::BUFFER_READF32, udata, build.constUint(0), build.constTag(LUA_TUSERDATA));
    build.inst(IrCmd::STORE_DOUBLE, build.vmReg(argResReg), build.inst(IrCmd::FLOAT_TO_NUM, x));
    build.inst(IrCmd::STORE_TAG, build.vmReg(argResReg), build.constTag(LUA_TNUMBER));
    if (results == LUA_MULTRET)
        build.inst(IrCmd::ADJUST_STACK_TO_REG, build.vmReg(argResReg), build.constInt(1));
    return true;
}

static HostIrHooks makeHostIrHooks() {
    HostIrHooks hooks{};
    hooks.cacheIndependentImports = true;
    hooks.userdataAccessBytecodeType = userdataAccessBytecodeType;
    hooks.userdataNamecallBytecodeType = userdataNamecallBytecodeType;
    hooks.userdataAccess = userdataAccess;
    hooks.userdataNamecall = userdataNamecall;
    return hooks;
}

static_assert(sizeof(IrCmd) == 1, "FrontendSnapshotV1 pins IrCmd to one byte");
static_assert(unsigned(IrCmd::JUMP_CMP_PROTOID) == 215, "IrCmd pin drift");
static_assert(unsigned(IrOpKind::VmExit) == 9, "IrOpKind pin drift");
static_assert(unsigned(IrBlockKind::Dead) == 5, "IrBlockKind pin drift");
static_assert(unsigned(IrConstKind::Import) == 5, "IrConstKind pin drift");

namespace {

constexpr size_t kMaxSourceBytes = 16 * 1024 * 1024;
constexpr size_t kMaxBytecodeBytes = 64 * 1024 * 1024;
constexpr size_t kMaxSnapshotBytes = 256 * 1024 * 1024;
constexpr size_t kMaxProtos = 4096;
constexpr size_t kMaxInstructions = 1'048'576;
constexpr size_t kMaxBlocksPerFunction = 32'768;
constexpr size_t kMaxInstructionsPerBlock = 65'536;
constexpr size_t kMaxStrings = 1 * 1024 * 1024;
constexpr uint32_t kMaxInlinePlans = 4096;

constexpr uint8_t kLuauPinSha256[32] = {
    0xe5, 0x1e, 0xad, 0x5f, 0x54, 0x16, 0x33, 0x69, 0x3d, 0x54, 0x80, 0x57, 0xe0, 0x43, 0x19, 0x27,
    0xf3, 0x03, 0x6c, 0x13, 0xb1, 0x85, 0xfd, 0xb3, 0x7f, 0xbc, 0x3f, 0x5a, 0x26, 0x1e, 0x66, 0x76,
};

constexpr uint8_t kPatchsetSha256[32] = {
    0x7a, 0x8e, 0x67, 0xca, 0x0b, 0xa7, 0x6c, 0x14, 0x2d, 0x3f, 0x20, 0xe6, 0x24, 0xd2, 0x14, 0xbc,
    0xac, 0x86, 0x8c, 0x42, 0x3c, 0x07, 0xa8, 0x27, 0xe5, 0x55, 0x8b, 0xe8, 0x9a, 0x4f, 0x33, 0x71,
};

constexpr uint8_t kIrEnumSha256[32] = {
    0x76, 0x5f, 0x91, 0x88, 0xe0, 0x7a, 0x38, 0x86, 0xc2, 0x9b, 0x5b, 0xb1, 0x46, 0x24, 0x12, 0x86,
    0xd1, 0xf9, 0x5c, 0x80, 0x1a, 0x89, 0x07, 0xaa, 0x03, 0x14, 0x7d, 0xf5, 0x24, 0xe7, 0xc3, 0x99,
};

constexpr uint8_t kLayoutSha256[32] = {
    0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
    0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
};

struct SectionData {
    uint16_t kind;
    uint32_t recordSize;
    std::vector<uint8_t> bytes;
};

struct ProtoRef {
    Proto *proto;
    uint32_t parent;
};

struct StringTable {
    SectionData &records;
    SectionData &bytes;
    std::vector<std::string> values;
    bool failed = false;

    uint32_t intern(const char *data, size_t size) {
        if (!data)
            return LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID;

        for (size_t index = 0; index < values.size(); ++index) {
            if (values[index].size() == size && memcmp(values[index].data(), data, size) == 0)
                return uint32_t(index);
        }

        if (values.size() >= kMaxStrings || size > UINT32_MAX ||
            bytes.bytes.size() + size > kMaxSnapshotBytes) {
            failed = true;
            return LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID;
        }

        uint64_t byteOffset = bytes.bytes.size();
        values.emplace_back(data, size);
        bytes.bytes.insert(bytes.bytes.end(), data, data + size);

        size_t record = appendRecord(records);
        putU64(records.bytes, record + LUAUC_SNAPSHOT_V1_STRING_BYTE_OFFSET, byteOffset);
        putU32(records.bytes, record + LUAUC_SNAPSHOT_V1_STRING_BYTE_LENGTH, uint32_t(size));
        return uint32_t(values.size() - 1);
    }

    uint32_t intern(TString *string) {
        return string ? intern(getstr(string), string->len) : LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID;
    }

    static size_t appendRecord(SectionData &section) {
        size_t offset = section.bytes.size();
        section.bytes.resize(offset + section.recordSize, 0);
        return offset;
    }

    static void putU32(std::vector<uint8_t> &output, size_t offset, uint32_t value) {
        for (unsigned shift = 0; shift < 32; shift += 8)
            output[offset + shift / 8] = uint8_t(value >> shift);
    }

    static void putU64(std::vector<uint8_t> &output, size_t offset, uint64_t value) {
        for (unsigned shift = 0; shift < 64; shift += 8)
            output[offset + shift / 8] = uint8_t(value >> shift);
    }
};

void putU16(std::vector<uint8_t> &output, size_t offset, uint16_t value) {
    output[offset] = uint8_t(value);
    output[offset + 1] = uint8_t(value >> 8);
}

void putU32(std::vector<uint8_t> &output, size_t offset, uint32_t value) {
    for (unsigned shift = 0; shift < 32; shift += 8)
        output[offset + shift / 8] = uint8_t(value >> shift);
}

void putU64(std::vector<uint8_t> &output, size_t offset, uint64_t value) {
    for (unsigned shift = 0; shift < 64; shift += 8)
        output[offset + shift / 8] = uint8_t(value >> shift);
}

size_t appendRecord(SectionData &section) {
    size_t offset = section.bytes.size();
    section.bytes.resize(offset + section.recordSize, 0);
    return offset;
}

uint32_t recordCount(const SectionData &section) {
    return uint32_t(section.bytes.size() / section.recordSize);
}

void appendU32Record(SectionData &section, uint32_t value) {
    size_t offset = appendRecord(section);
    putU32(section.bytes, offset, value);
}

void appendBytes(SectionData &section, const void *bytes, size_t size) {
    const uint8_t *first = static_cast<const uint8_t *>(bytes);
    section.bytes.insert(section.bytes.end(), first, first + size);
}

uint32_t protoId(const std::vector<ProtoRef> &protos, Proto *wanted) {
    for (size_t index = 0; index < protos.size(); ++index) {
        if (protos[index].proto == wanted)
            return uint32_t(index);
    }
    return LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID;
}

bool collectProtos(Proto *proto, uint32_t parent, std::vector<ProtoRef> &output) {
    if (!proto)
        return false;

    uint32_t existing = protoId(output, proto);
    if (existing != LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID)
        return true;
    if (output.size() >= kMaxProtos)
        return false;

    output.push_back({proto, parent});
    uint32_t current = uint32_t(output.size() - 1);
    for (int index = 0; index < proto->sizep; ++index) {
        if (!collectProtos(proto->p[index], current, output))
            return false;
    }
    return true;
}

struct ImportDescriptor {
    bool present = false;
    uint8_t count = 0;
    uint32_t stringConstants[3] = {};
};

bool decodeImportDescriptors(Proto *proto, std::vector<ImportDescriptor> &imports,
                             std::string &error) {
    imports.resize(proto->sizek);

    for (int pc = 0; pc < proto->sizecode;) {
        Instruction instruction = proto->code[pc];
        LuauOpcode opcode = LuauOpcode(LUAU_INSN_OP(instruction));
        int opLength = Luau::getOpLength(opcode);
        if (opLength <= 0 || pc > proto->sizecode - opLength) {
            error = "invalid bytecode while decoding import constants";
            return false;
        }

        if (opcode == LOP_GETIMPORT) {
            if (opLength != 2) {
                error = "invalid GETIMPORT instruction length";
                return false;
            }
            int cacheConstant = LUAU_INSN_D(instruction);
            uint32_t descriptor = proto->code[pc + 1];
            uint32_t count = descriptor >> 30;
            uint32_t stringConstants[3] = {
                (descriptor >> 20) & 1023,
                (descriptor >> 10) & 1023,
                descriptor & 1023,
            };
            uint32_t unusedMask = count == 1 ? 0x000fffff : count == 2 ? 0x000003ff : 0;
            if (cacheConstant < 0 || cacheConstant >= proto->sizek || count < 1 || count > 3 ||
                (descriptor & unusedMask) != 0) {
                error = "invalid GETIMPORT constant descriptor";
                return false;
            }

            for (uint32_t index = 0; index < count; ++index) {
                if (stringConstants[index] >= uint32_t(proto->sizek) ||
                    !ttisstring(&proto->k[stringConstants[index]])) {
                    error = "GETIMPORT descriptor references a non-string constant";
                    return false;
                }
            }

            ImportDescriptor &decoded = imports[cacheConstant];
            if (decoded.present) {
                if (decoded.count != count) {
                    error = "conflicting GETIMPORT descriptors share one cache constant";
                    return false;
                }
                for (uint32_t index = 0; index < count; ++index) {
                    if (decoded.stringConstants[index] != stringConstants[index]) {
                        error = "conflicting GETIMPORT descriptors share one cache constant";
                        return false;
                    }
                }
            } else {
                decoded.present = true;
                decoded.count = uint8_t(count);
                for (uint32_t index = 0; index < count; ++index)
                    decoded.stringConstants[index] = stringConstants[index];
            }
        }

        pc += opLength;
    }

    return true;
}

void setDiagnostic(LuaucFrontendSnapshotV1Result *result, uint32_t status, const char *data,
                   size_t size) {
    result->status = status;
    result->diagnostic = static_cast<char *>(malloc(size + 1));
    if (!result->diagnostic) {
        result->diagnostic_size = 0;
        return;
    }

    memcpy(result->diagnostic, data, size);
    result->diagnostic[size] = '\0';
    result->diagnostic_size = size;
}

void setDiagnostic(LuaucFrontendSnapshotV1Result *result, uint32_t status,
                   const std::string &message) {
    setDiagnostic(result, status, message.data(), message.size());
}

void setDiagnostic(LuaucFrontendSnapshotV1Result *result, uint32_t status, const char *message) {
    setDiagnostic(result, status, message, strlen(message));
}

std::vector<SectionData> makeSections() {
    const uint32_t sizes[] = {
        LUAUC_SNAPSHOT_V1_STRING_SIZE,
        1,
        LUAUC_SNAPSHOT_V1_PROTO_SIZE,
        LUAUC_SNAPSHOT_V1_CHILD_SIZE,
        LUAUC_SNAPSHOT_V1_BYTECODE_WORD_SIZE,
        LUAUC_SNAPSHOT_V1_VM_CONSTANT_SIZE,
        LUAUC_SNAPSHOT_V1_VM_CONSTANT_ITEM_SIZE,
        LUAUC_SNAPSHOT_V1_LOCAL_SIZE,
        LUAUC_SNAPSHOT_V1_UPVALUE_NAME_SIZE,
        1,
        1,
        LUAUC_SNAPSHOT_V1_ABSLINE_SIZE,
        1,
        LUAUC_SNAPSHOT_V1_FEEDBACK_SIZE,
        LUAUC_SNAPSHOT_V1_IR_FUNCTION_SIZE,
        LUAUC_SNAPSHOT_V1_IR_BLOCK_SIZE,
        LUAUC_SNAPSHOT_V1_IR_INSTRUCTION_SIZE,
        LUAUC_SNAPSHOT_V1_IR_OPERAND_SIZE,
        LUAUC_SNAPSHOT_V1_IR_CONSTANT_SIZE,
        LUAUC_SNAPSHOT_V1_BC_MAPPING_SIZE,
        1,
    };

    std::vector<SectionData> sections;
    sections.reserve(sizeof(sizes) / sizeof(sizes[0]));
    for (uint16_t index = 0; index < sizeof(sizes) / sizeof(sizes[0]); ++index)
        sections.push_back({uint16_t(index + 1), sizes[index], {}});
    return sections;
}

SectionData &section(std::vector<SectionData> &sections, uint16_t kind) {
    return sections[kind - 1];
}

bool isSerializableTableScalar(const TValue &value) {
    return ttisnil(&value) || ttisboolean(&value) || ttisnumber(&value) ||
           ttisinteger(&value) || ttisvector(&value) || ttisstring(&value);
}

bool sameTableScalar(const TValue &left, const TValue &right) {
    if (ttype(&left) != ttype(&right) || !isSerializableTableScalar(left))
        return false;

    if (ttisnil(&left))
        return true;
    if (ttisboolean(&left))
        return bvalue(&left) == bvalue(&right);
    if (ttisnumber(&left)) {
        uint64_t leftBits = 0;
        uint64_t rightBits = 0;
        double leftNumber = nvalue(&left);
        double rightNumber = nvalue(&right);
        memcpy(&leftBits, &leftNumber, sizeof(leftBits));
        memcpy(&rightBits, &rightNumber, sizeof(rightBits));
        return leftBits == rightBits;
    }
    if (ttisinteger(&left))
        return lvalue(&left) == lvalue(&right);
    if (ttisvector(&left))
        return memcmp(vvalue(&left), vvalue(&right), sizeof(float) * LUA_VECTOR_SIZE) == 0;
    if (ttisstring(&left)) {
        TString *leftString = tsvalue(&left);
        TString *rightString = tsvalue(&right);
        return leftString->len == rightString->len &&
               memcmp(getstr(leftString), getstr(rightString), leftString->len) == 0;
    }

    return false;
}

uint32_t localScalarConstantId(Proto *proto, const TValue &wanted) {
    for (int index = 0; index < proto->sizek; ++index) {
        if (sameTableScalar(proto->k[index], wanted))
            return uint32_t(index);
    }
    return LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID;
}

bool serializeTableConstant(Proto *proto, LuaTable *table, size_t record,
                            SectionData &constants, SectionData &constantItems,
                            std::string &error) {
    if (!table || table->metatable || table->sizearray != 0 || !table->node ||
        table->lsizenode >= 31) {
        error = "unsupported loader table constant shape";
        return false;
    }

    struct TableItem {
        uint32_t key;
        uint32_t value;
    };
    std::vector<TableItem> items;
    const uint32_t nodeCount = uint32_t(1) << table->lsizenode;
    if (nodeCount > kMaxStrings) {
        error = "frontend table constant resource limit";
        return false;
    }
    items.reserve(nodeCount);

    for (uint32_t index = 0; index < nodeCount; ++index) {
        const LuaNode &node = table->node[index];
        if (node.key.tt == LUA_TNIL)
            continue;
        if (node.key.tt == LUA_TDEADKEY || node.key.tt != LUA_TSTRING) {
            error = "loader table constant contains an unsupported key";
            return false;
        }

        TValue key = {};
        key.value = node.key.value;
        memcpy(key.extra, node.key.extra, sizeof(key.extra));
        key.tt = int(node.key.tt);
        uint32_t keyId = localScalarConstantId(proto, key);
        if (keyId == LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID) {
            error = "loader table key does not reference a local VM constant";
            return false;
        }

        uint32_t valueId = LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID;
        if (isSerializableTableScalar(node.val))
            valueId = localScalarConstantId(proto, node.val);
        else {
            error = "loader table value is not a supported scalar VM constant";
            return false;
        }

        // The loader uses number 0.0 as the value for a key-only table template. If the Proto has
        // an exactly matching scalar constant, carrying its id reconstructs the same value; if it
        // does not, NO_ID preserves the loader placeholder semantics.
        if (valueId == LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID &&
            !(ttisnumber(&node.val) && nvalue(&node.val) == 0.0)) {
            error = "loader table value does not reference a local VM constant";
            return false;
        }

        items.push_back({keyId, valueId});
    }

    std::sort(items.begin(), items.end(), [](const TableItem &left, const TableItem &right) {
        return left.key < right.key;
    });
    for (size_t index = 1; index < items.size(); ++index) {
        if (items[index - 1].key == items[index].key) {
            error = "loader table constant contains duplicate local keys";
            return false;
        }
    }
    if (items.size() > UINT32_MAX ||
        constantItems.bytes.size() + items.size() * constantItems.recordSize > kMaxSnapshotBytes) {
        error = "frontend table constant resource limit";
        return false;
    }

    constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_TABLE;
    putU32(constants.bytes, record + 4, recordCount(constantItems));
    putU32(constants.bytes, record + 8, uint32_t(items.size()));
    for (const TableItem &entry : items) {
        size_t item = appendRecord(constantItems);
        putU32(constantItems.bytes, item, entry.key);
        putU32(constantItems.bytes, item + 4, entry.value);
    }
    return true;
}

bool serializeVmConstant(Proto *proto, const TValue &value, const ImportDescriptor *import,
                          const std::vector<ProtoRef> &protos, StringTable &strings,
                         SectionData &constants, SectionData &constantItems,
                         uint32_t &failureStatus, std::string &error) {
    size_t record = appendRecord(constants);

    if (import) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_IMPORT;
        putU32(constants.bytes, record + 4, recordCount(constantItems));
        putU32(constants.bytes, record + 8, import->count);
        for (uint32_t index = 0; index < import->count; ++index) {
            size_t item = appendRecord(constantItems);
            putU32(constantItems.bytes, item, import->stringConstants[index]);
            putU32(constantItems.bytes, item + 4, LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID);
        }
    } else if (ttisnil(&value)) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_NIL;
    } else if (ttisboolean(&value)) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_BOOLEAN;
        putU32(constants.bytes, record + 4, bvalue(&value) ? 1 : 0);
    } else if (ttisnumber(&value)) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_NUMBER;
        uint64_t bits = 0;
        double number = nvalue(&value);
        memcpy(&bits, &number, sizeof(bits));
        putU64(constants.bytes, record + 24, bits);
    } else if (ttisinteger(&value)) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_INTEGER;
        putU64(constants.bytes, record + 24, uint64_t(lvalue(&value)));
    } else if (ttisvector(&value)) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_VECTOR;
        const float *vector = vvalue(&value);
        for (unsigned lane = 0; lane < LUA_VECTOR_SIZE; ++lane) {
            uint32_t bits = 0;
            memcpy(&bits, &vector[lane], sizeof(bits));
            putU32(constants.bytes, record + 4 + lane * 4, bits);
        }
    } else if (ttisstring(&value)) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_STRING;
        uint32_t id = strings.intern(tsvalue(&value));
        if (id == LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID) {
            failureStatus = LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT;
            error = "frontend string table resource limit";
            return false;
        }
        putU32(constants.bytes, record + 4, id);
    } else if (ttistable(&value)) {
        if (!serializeTableConstant(proto, hvalue(&value), record, constants, constantItems,
                                    error)) {
            constants.bytes.resize(record);
            return false;
        }
    } else if (ttisfunction(&value) && !clvalue(&value)->isC) {
        constants.bytes[record] = LUAUC_SNAPSHOT_V1_VM_CLOSURE;
        uint32_t id = protoId(protos, clvalue(&value)->l.p);
        if (id == LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID) {
            failureStatus = LUAUC_SNAPSHOT_V1_INTERNAL_ERROR;
            error = "closure constant references a Proto outside the closed graph";
            return false;
        }
        putU32(constants.bytes, record + 4, id);
    } else {
        constants.bytes.resize(record);
        error = "compound loader constant is not decoded by FrontendSnapshotV1 yet (TValue tag " +
                std::to_string(ttype(&value)) + ")";
        return false;
    }

    return true;
}

bool serializeProtoMetadata(const std::vector<ProtoRef> &protos, std::vector<SectionData> &sections,
                            StringTable &strings, uint32_t &failureStatus, std::string &error) {
    SectionData &protoRecords = section(sections, LUAUC_SNAPSHOT_V1_PROTOS);
    SectionData &children = section(sections, LUAUC_SNAPSHOT_V1_PROTO_CHILDREN);
    SectionData &code = section(sections, LUAUC_SNAPSHOT_V1_BYTECODE_WORDS);
    SectionData &constants = section(sections, LUAUC_SNAPSHOT_V1_VM_CONSTANTS);
    SectionData &constantItems = section(sections, LUAUC_SNAPSHOT_V1_VM_CONSTANT_ITEMS);
    SectionData &locals = section(sections, LUAUC_SNAPSHOT_V1_LOCALS);
    SectionData &upvalueNames = section(sections, LUAUC_SNAPSHOT_V1_UPVALUE_NAMES);
    SectionData &typeinfo = section(sections, LUAUC_SNAPSHOT_V1_TYPEINFO_BYTES);
    SectionData &lineinfo = section(sections, LUAUC_SNAPSHOT_V1_LINEINFO_BYTES);
    SectionData &abslineinfo = section(sections, LUAUC_SNAPSHOT_V1_ABSLINEINFO);
    SectionData &debugOpcodes = section(sections, LUAUC_SNAPSHOT_V1_DEBUG_OPCODES);
    SectionData &feedback = section(sections, LUAUC_SNAPSHOT_V1_FEEDBACK);

    for (size_t protoIndex = 0; protoIndex < protos.size(); ++protoIndex) {
        Proto *proto = protos[protoIndex].proto;
        std::vector<ImportDescriptor> imports;
        if (!decodeImportDescriptors(proto, imports, error))
            return false;
        size_t record = appendRecord(protoRecords);
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_ID, uint32_t(protoIndex));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_PARENT_ID,
               protos[protoIndex].parent);
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_SOURCE_STRING_ID,
               strings.intern(proto->source));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_DEBUGNAME_STRING_ID,
               strings.intern(proto->debugname));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_LINE_DEFINED,
               uint32_t(proto->linedefined));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_BYTECODE_ID,
               uint32_t(proto->bytecodeid));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_FUN_ID, proto->funid);
        protoRecords.bytes[record + LUAUC_SNAPSHOT_V1_PROTO_FLAGS] = proto->flags;
        protoRecords.bytes[record + LUAUC_SNAPSHOT_V1_PROTO_NUPS] = proto->nups;
        protoRecords.bytes[record + LUAUC_SNAPSHOT_V1_PROTO_NUM_PARAMS] = proto->numparams;
        protoRecords.bytes[record + LUAUC_SNAPSHOT_V1_PROTO_IS_VARARG] = proto->is_vararg;
        protoRecords.bytes[record + LUAUC_SNAPSHOT_V1_PROTO_MAX_STACK] = proto->maxstacksize;
        protoRecords.bytes[record + LUAUC_SNAPSHOT_V1_PROTO_LINE_GAP_LOG2] =
            proto->lineinfo ? uint8_t(proto->linegaplog2) : 0;

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_CODE_START,
               recordCount(code));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_CODE_COUNT,
               uint32_t(proto->sizecode));
        for (int index = 0; index < proto->sizecode; ++index)
            appendU32Record(code, proto->code[index]);

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_CONSTANT_START,
               recordCount(constants));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_CONSTANT_COUNT,
               uint32_t(proto->sizek));
        for (int index = 0; index < proto->sizek; ++index) {
            const ImportDescriptor *import = imports[index].present ? &imports[index] : nullptr;
            if (!serializeVmConstant(proto, proto->k[index], import, protos, strings, constants,
                                     constantItems, failureStatus, error))
                return false;
        }

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_CHILD_START,
               recordCount(children));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_CHILD_COUNT,
               uint32_t(proto->sizep));
        for (int index = 0; index < proto->sizep; ++index) {
            uint32_t child = protoId(protos, proto->p[index]);
            if (child == LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID) {
                failureStatus = LUAUC_SNAPSHOT_V1_INTERNAL_ERROR;
                error = "Proto child is outside the closed graph";
                return false;
            }
            appendU32Record(children, child);
        }

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_UPVALUE_NAME_START,
               recordCount(upvalueNames));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_UPVALUE_NAME_COUNT,
               uint32_t(proto->sizeupvalues));
        for (int index = 0; index < proto->sizeupvalues; ++index)
            appendU32Record(upvalueNames, strings.intern(proto->upvalues[index]));

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_LOCAL_START,
               recordCount(locals));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_LOCAL_COUNT,
               uint32_t(proto->sizelocvars));
        for (int index = 0; index < proto->sizelocvars; ++index) {
            const LocVar &local = proto->locvars[index];
            size_t localRecord = appendRecord(locals);
            putU32(locals.bytes, localRecord, strings.intern(local.varname));
            putU32(locals.bytes, localRecord + 4, uint32_t(local.startpc));
            putU32(locals.bytes, localRecord + 8, uint32_t(local.endpc));
            locals.bytes[localRecord + 12] = local.reg;
        }

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_TYPEINFO_START,
               recordCount(typeinfo));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_TYPEINFO_COUNT,
               uint32_t(proto->sizetypeinfo));
        if (proto->sizetypeinfo > 0)
            appendBytes(typeinfo, proto->typeinfo, size_t(proto->sizetypeinfo));

        const uint32_t lineCount = proto->lineinfo ? uint32_t(proto->sizecode) : 0;
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_LINEINFO_START,
               recordCount(lineinfo));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_LINEINFO_COUNT, lineCount);
        if (lineCount)
            appendBytes(lineinfo, proto->lineinfo, lineCount);

        const uint32_t absCount = proto->lineinfo && proto->sizecode > 0
                                      ? uint32_t(((proto->sizecode - 1) >> proto->linegaplog2) + 1)
                                      : 0;
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_ABSLINE_START,
               recordCount(abslineinfo));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_ABSLINE_COUNT, absCount);
        for (uint32_t index = 0; index < absCount; ++index)
            appendU32Record(abslineinfo, uint32_t(proto->abslineinfo[index]));

        const uint32_t debugCount = proto->debuginsn ? uint32_t(proto->sizecode) : 0;
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_DEBUG_OPCODE_START,
               recordCount(debugOpcodes));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_DEBUG_OPCODE_COUNT,
               debugCount);
        if (debugCount)
            appendBytes(debugOpcodes, proto->debuginsn, debugCount);

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_FEEDBACK_START,
               recordCount(feedback));
        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_FEEDBACK_COUNT,
               proto->feedbackvecsize);
        for (uint32_t index = 0; index < proto->feedbackvecsize; ++index) {
            size_t feedbackRecord = appendRecord(feedback);
            feedback.bytes[feedbackRecord] = uint8_t(proto->feedbackvec[index].kind);
            putU32(feedback.bytes, feedbackRecord + 4,
                   uint32_t(proto->feedbackvec[index].call_target.pc));
        }

        putU32(protoRecords.bytes, record + LUAUC_SNAPSHOT_V1_PROTO_IR_FUNCTION_ID,
               uint32_t(protoIndex));
    }

    return true;
}

bool serializeIr(const std::vector<ProtoRef> &protos, std::vector<SectionData> &sections,
                 uint32_t &failureStatus, std::string &error) {
    SectionData &functions = section(sections, LUAUC_SNAPSHOT_V1_IR_FUNCTIONS);
    SectionData &blocks = section(sections, LUAUC_SNAPSHOT_V1_IR_BLOCKS);
    SectionData &instructions = section(sections, LUAUC_SNAPSHOT_V1_IR_INSTRUCTIONS);
    SectionData &operands = section(sections, LUAUC_SNAPSHOT_V1_IR_OPERANDS);
    SectionData &constants = section(sections, LUAUC_SNAPSHOT_V1_IR_CONSTANTS);
    SectionData &mapping = section(sections, LUAUC_SNAPSHOT_V1_BC_MAPPING);

    size_t totalInstructions = 0;
    const HostIrHooks hooks = makeHostIrHooks();

    for (size_t functionIndex = 0; functionIndex < protos.size(); ++functionIndex) {
        Proto *proto = protos[functionIndex].proto;
        IrBuilder builder(hooks);
        builder.buildFunctionIr(proto);

        if (totalInstructions + builder.function.instructions.size() >= kMaxInstructions) {
            failureStatus = LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT;
            error = "frontend IR instruction resource limit";
            return false;
        }
        totalInstructions += builder.function.instructions.size();

        // This is the target-neutral prefix of pinned upstream lowerFunction. The frontend options
        // are pinned to upstream defaults: DebugCodegenOptSize=false, so linearization is always
        // enabled here. The instruction/block limits above are likewise contract values. There are
        // no fixture-dependent switches and no native-backend passes.
        killUnusedBlocks(builder.function);

        size_t liveBlocks = 0;
        size_t maxBlockInstructions = 0;
        for (const IrBlock &block : builder.function.blocks) {
            liveBlocks += block.kind != IrBlockKind::Dead;
            maxBlockInstructions =
                std::max(maxBlockInstructions, size_t(block.finish - block.start));
        }
        if (liveBlocks >= kMaxBlocksPerFunction ||
            maxBlockInstructions >= kMaxInstructionsPerBlock) {
            failureStatus = LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT;
            error = "frontend IR block resource limit";
            return false;
        }

        computeCfgInfo(builder.function);
        constPropInBlockChains(builder);
        createLinearBlocks(builder);
        computeCfgBlockEdges(builder.function);
        updateUseCounts(builder.function);

        size_t functionRecord = appendRecord(functions);
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_ID,
               uint32_t(functionIndex));
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_PROTO_ID,
               uint32_t(functionIndex));
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_ENTRY_BLOCK,
               builder.function.entryBlock);
        functions.bytes[functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_VARIADIC] =
            builder.function.variadic ? 1 : 0;

        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_BLOCK_START,
               recordCount(blocks));
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_BLOCK_COUNT,
               uint32_t(builder.function.blocks.size()));
        for (const IrBlock &block : builder.function.blocks) {
            size_t blockRecord = appendRecord(blocks);
            blocks.bytes[blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_KIND] = uint8_t(block.kind);
            blocks.bytes[blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_FLAGS] = block.flags;
            putU16(blocks.bytes, blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_USE_COUNT,
                   block.useCount);
            putU32(blocks.bytes, blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_START, block.start);
            putU32(blocks.bytes, blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_FINISH, block.finish);
            putU32(blocks.bytes, blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_SORT_KEY,
                   block.sortkey);
            putU32(blocks.bytes, blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_CHAIN_KEY,
                   block.chainkey);
            putU32(blocks.bytes, blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_EXPECTED_NEXT,
                   block.expectedNextBlock);
            putU32(blocks.bytes, blockRecord + LUAUC_SNAPSHOT_V1_IR_BLOCK_START_PC,
                   block.startpc);
        }

        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_INSTRUCTION_START,
               recordCount(instructions));
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_INSTRUCTION_COUNT,
               uint32_t(builder.function.instructions.size()));
        const uint32_t operandStart = recordCount(operands);
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_OPERAND_START,
               operandStart);
        for (const IrInst &instruction : builder.function.instructions) {
            size_t instructionRecord = appendRecord(instructions);
            instructions.bytes[instructionRecord + LUAUC_SNAPSHOT_V1_IR_INSTRUCTION_CMD] =
                uint8_t(instruction.cmd);
            putU16(instructions.bytes,
                   instructionRecord + LUAUC_SNAPSHOT_V1_IR_INSTRUCTION_USE_COUNT,
                   instruction.useCount);
            putU32(instructions.bytes,
                   instructionRecord + LUAUC_SNAPSHOT_V1_IR_INSTRUCTION_LAST_USE,
                   LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID);
            putU32(instructions.bytes,
                   instructionRecord + LUAUC_SNAPSHOT_V1_IR_INSTRUCTION_OPERAND_START,
                   recordCount(operands));
            putU32(instructions.bytes,
                   instructionRecord + LUAUC_SNAPSHOT_V1_IR_INSTRUCTION_OPERAND_COUNT,
                   uint32_t(instruction.ops.size()));
            for (const IrOp &operand : instruction.ops) {
                size_t operandRecord = appendRecord(operands);
                operands.bytes[operandRecord] = uint8_t(operand.kind);
                putU32(operands.bytes, operandRecord + 4, operand.index);
            }
        }
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_OPERAND_COUNT,
               recordCount(operands) - operandStart);

        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_CONSTANT_START,
               recordCount(constants));
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_CONSTANT_COUNT,
               uint32_t(builder.function.constants.size()));
        for (const IrConst &constant : builder.function.constants) {
            size_t constantRecord = appendRecord(constants);
            constants.bytes[constantRecord] = uint8_t(constant.kind);
            uint64_t bits = 0;
            switch (constant.kind) {
            case IrConstKind::Int:
                bits = uint64_t(int64_t(constant.valueInt));
                break;
            case IrConstKind::Int64:
                bits = uint64_t(constant.valueInt64);
                break;
            case IrConstKind::Uint:
            case IrConstKind::Import:
                bits = constant.valueUint;
                break;
            case IrConstKind::Double:
                memcpy(&bits, &constant.valueDouble, sizeof(bits));
                break;
            case IrConstKind::Tag:
                bits = constant.valueTag;
                break;
            }
            putU64(constants.bytes, constantRecord + 8, bits);
        }

        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_BC_MAPPING_START,
               recordCount(mapping));
        putU32(functions.bytes, functionRecord + LUAUC_SNAPSHOT_V1_IR_FUNCTION_BC_MAPPING_COUNT,
               uint32_t(builder.function.bcMapping.size()));
        for (const BytecodeMapping &entry : builder.function.bcMapping) {
            size_t mappingRecord = appendRecord(mapping);
            putU32(mapping.bytes, mappingRecord, entry.irLocation);
            putU32(mapping.bytes, mappingRecord + 4, entry.asmLocation);
        }
    }

    return true;
}

bool buildWireImage(std::vector<SectionData> &sections, uint32_t protoCount, uint32_t stringCount,
                    std::vector<uint8_t> &output, std::string &error) {
    const size_t directoryBytes = sections.size() * LUAUC_FRONTEND_SNAPSHOT_V1_SECTION_SIZE;
    size_t totalSize = LUAUC_FRONTEND_SNAPSHOT_V1_HEADER_SIZE + directoryBytes;
    for (const SectionData &item : sections) {
        if (item.bytes.size() % item.recordSize != 0 ||
            totalSize + item.bytes.size() > kMaxSnapshotBytes) {
            error = "frontend snapshot resource or record-size limit";
            return false;
        }
        totalSize += item.bytes.size();
    }

    output.assign(LUAUC_FRONTEND_SNAPSHOT_V1_HEADER_SIZE + directoryBytes, 0);
    memcpy(output.data() + LUAUC_SNAPSHOT_V1_H_MAGIC, LUAUC_FRONTEND_SNAPSHOT_V1_MAGIC, 8);
    putU16(output, LUAUC_SNAPSHOT_V1_H_VERSION, LUAUC_FRONTEND_SNAPSHOT_V1_VERSION);
    putU16(output, LUAUC_SNAPSHOT_V1_H_HEADER_SIZE, LUAUC_FRONTEND_SNAPSHOT_V1_HEADER_SIZE);
    putU32(output, LUAUC_SNAPSHOT_V1_H_FLAGS, LUAUC_FRONTEND_SNAPSHOT_V1_REQUIRED_FLAGS);
    putU64(output, LUAUC_SNAPSHOT_V1_H_TOTAL_SIZE, totalSize);
    memcpy(output.data() + LUAUC_SNAPSHOT_V1_H_LUAU_PIN_SHA256, kLuauPinSha256, 32);
    memcpy(output.data() + LUAUC_SNAPSHOT_V1_H_PATCHSET_SHA256, kPatchsetSha256, 32);
    memcpy(output.data() + LUAUC_SNAPSHOT_V1_H_FRONTEND_BUILD_SHA256, kFrontendBuildSha256, 32);
    memcpy(output.data() + LUAUC_SNAPSHOT_V1_H_IR_ENUM_SHA256, kIrEnumSha256, 32);
    memcpy(output.data() + LUAUC_SNAPSHOT_V1_H_LAYOUT_SHA256, kLayoutSha256, 32);
    putU32(output, LUAUC_SNAPSHOT_V1_H_MODULE_COUNT, 1);
    putU32(output, LUAUC_SNAPSHOT_V1_H_PROTO_COUNT, protoCount);
    putU32(output, LUAUC_SNAPSHOT_V1_H_IR_FUNCTION_COUNT, protoCount);
    putU32(output, LUAUC_SNAPSHOT_V1_H_STRING_COUNT, stringCount);
    putU32(output, LUAUC_SNAPSHOT_V1_H_ROOT_PROTO_ID, 0);
    putU32(output, LUAUC_SNAPSHOT_V1_H_SECTION_COUNT, uint32_t(sections.size()));

    uint64_t payloadOffset = output.size();
    for (size_t index = 0; index < sections.size(); ++index) {
        const SectionData &item = sections[index];
        size_t directory = LUAUC_FRONTEND_SNAPSHOT_V1_HEADER_SIZE +
                           index * LUAUC_FRONTEND_SNAPSHOT_V1_SECTION_SIZE;
        putU16(output, directory + LUAUC_SNAPSHOT_V1_S_KIND, item.kind);
        putU32(output, directory + LUAUC_SNAPSHOT_V1_S_RECORD_SIZE, item.recordSize);
        putU64(output, directory + LUAUC_SNAPSHOT_V1_S_OFFSET, payloadOffset);
        putU64(output, directory + LUAUC_SNAPSHOT_V1_S_LENGTH, item.bytes.size());
        putU32(output, directory + LUAUC_SNAPSHOT_V1_S_COUNT, recordCount(item));
        output.insert(output.end(), item.bytes.begin(), item.bytes.end());
        payloadOffset += item.bytes.size();
    }

    return output.size() == totalSize;
}

bool compileSource(const uint8_t *source, size_t sourceSize, uint32_t coverageLevel,
                   std::string &bytecode, LuaucFrontendSnapshotV1Result *result) {
    size_t bytecodeSize = 0;
    const char *sourceBytes = sourceSize ? reinterpret_cast<const char *>(source) : "";
    lua_CompileOptions options{};
    options.optimizationLevel = 1;
    options.debugLevel = 1;
    options.coverageLevel = int(coverageLevel);
    applyUserdataCompileOptions(options, sourceBytes, sourceSize);
    char *rawBytecode = luau_compile(sourceBytes, sourceSize, &options, &bytecodeSize);
    if (!rawBytecode || bytecodeSize == 0 || bytecodeSize > kMaxBytecodeBytes) {
        free(rawBytecode);
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_COMPILE_ERROR,
                      "luau_compile failed or exceeded bytecode limit");
        return false;
    }
    if (rawBytecode[0] == 0) {
        size_t messageOffset = 1;
        size_t messageSize = bytecodeSize > messageOffset ? bytecodeSize - messageOffset : 0;
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_COMPILE_ERROR, rawBytecode + messageOffset,
                      messageSize);
        free(rawBytecode);
        return false;
    }
    bytecode.assign(rawBytecode, bytecodeSize);
    free(rawBytecode);
    return true;
}

uint32_t snapshotBytecode(const std::string &bytecode, const uint8_t *chunkName,
                          size_t chunkNameSize, LuaucFrontendSnapshotV1Result *result) {
    if (bytecode.empty() || bytecode.size() > kMaxBytecodeBytes) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_COMPILE_ERROR,
                      "compiled bytecode is empty or exceeds the frontend limit");
        return result->status;
    }

    lua_State *state = luaL_newstate();
    if (!state) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_INTERNAL_ERROR, "luaL_newstate failed");
        return result->status;
    }

    std::string chunk = chunkNameSize
                            ? std::string(reinterpret_cast<const char *>(chunkName), chunkNameSize)
                            : std::string("=aot");
    int loadStatus = luau_load(state, chunk.c_str(), bytecode.data(), bytecode.size(), 0);
    if (loadStatus != 0) {
        const char *message = lua_tostring(state, -1);
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_LOAD_ERROR,
                      message ? message : "luau_load failed");
        lua_close(state);
        return result->status;
    }

    const TValue *loaded = luaA_toobject(state, -1);
    if (!loaded || !ttisfunction(loaded) || clvalue(loaded)->isC || !clvalue(loaded)->l.p) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_INTERNAL_ERROR, "loaded chunk has no Luau Proto");
        lua_close(state);
        return result->status;
    }

    std::vector<ProtoRef> protos;
    if (!collectProtos(clvalue(loaded)->l.p, LUAUC_FRONTEND_SNAPSHOT_V1_NO_ID, protos)) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT,
                      "Proto graph is invalid or exceeds limit");
        lua_close(state);
        return result->status;
    }

    std::vector<SectionData> sections = makeSections();
    SectionData &compiledBytecode = section(sections, LUAUC_SNAPSHOT_V1_COMPILED_BYTECODE);
    appendBytes(compiledBytecode, bytecode.data(), bytecode.size());

    StringTable strings{
        section(sections, LUAUC_SNAPSHOT_V1_STRINGS),
        section(sections, LUAUC_SNAPSHOT_V1_STRING_BYTES),
        {},
        false,
    };
    std::string error;
    uint32_t failureStatus = LUAUC_SNAPSHOT_V1_UNSUPPORTED_FRONTEND_VALUE;
    bool ok = serializeProtoMetadata(protos, sections, strings, failureStatus, error);
    if (ok && strings.failed) {
        failureStatus = LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT;
        error = "frontend string table resource limit";
        ok = false;
    }
    if (ok)
        ok = serializeIr(protos, sections, failureStatus, error);

    lua_close(state);

    if (!ok) {
        setDiagnostic(result, failureStatus, error);
        return result->status;
    }

    std::vector<uint8_t> snapshot;
    if (!buildWireImage(sections, uint32_t(protos.size()), uint32_t(strings.values.size()),
                        snapshot, error)) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT, error);
        return result->status;
    }

    result->data = static_cast<uint8_t *>(malloc(snapshot.size()));
    if (!result->data) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_INTERNAL_ERROR, "snapshot allocation failed");
        return result->status;
    }
    memcpy(result->data, snapshot.data(), snapshot.size());
    result->size = snapshot.size();
    result->status = LUAUC_SNAPSHOT_V1_OK;
    return result->status;
}

bool validCompileArguments(const uint8_t *source, size_t sourceSize, const uint8_t *chunkName,
                           size_t chunkNameSize, uint32_t coverageLevel,
                           LuaucFrontendSnapshotV1Result *result) {
    if ((!source && sourceSize != 0) || (!chunkName && chunkNameSize != 0) ||
        sourceSize > kMaxSourceBytes || chunkNameSize > 4096 || coverageLevel > 2) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT,
                      "invalid frontend source or chunk name");
        return false;
    }
    if (chunkName && memchr(chunkName, 0, chunkNameSize)) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT, "chunk name contains NUL");
        return false;
    }
    return true;
}

bool buildInlinedBytecode(const uint8_t *source, size_t sourceSize, uint32_t coverageLevel,
                          const LuaucFrontendInlinePlanV1 *plans, uint32_t planCount,
                          std::string &bytecode, LuaucFrontendSnapshotV1Result *result) {
    if (!plans || planCount == 0 || planCount > kMaxInlinePlans) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT, "invalid inline plan span");
        return false;
    }
    for (uint32_t index = 0; index < planCount; ++index) {
        const LuaucFrontendInlinePlanV1 &plan = plans[index];
        if (plan.reserved != 0 ||
            (index != 0 && (plans[index - 1].caller_function_id > plan.caller_function_id ||
                            (plans[index - 1].caller_function_id == plan.caller_function_id &&
                             plans[index - 1].feedback_slot >= plan.feedback_slot)))) {
            setDiagnostic(result, LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT,
                          "inline plans are not canonical and unique");
            return false;
        }
    }

    const bool previousFeedback = FFlag::LuauEmitCallFeedback.value;
    FFlag::LuauEmitCallFeedback.value = true;
    Luau::CompileOptions options{};
    options.optimizationLevel = 1;
    options.debugLevel = 1;
    options.coverageLevel = int(coverageLevel);
    applyUserdataCompileOptions(options, sourceSize ? reinterpret_cast<const char *>(source) : "",
                                sourceSize);
    Luau::BytecodeBuilder original;
    std::string compileDiagnostic = Luau::compileInto(
        original,
        std::string(sourceSize ? reinterpret_cast<const char *>(source) : "", sourceSize), options);
    if (!compileDiagnostic.empty()) {
        FFlag::LuauEmitCallFeedback.value = previousFeedback;
        const size_t messageOffset = compileDiagnostic[0] == 0 ? 1 : 0;
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_COMPILE_ERROR,
                      compileDiagnostic.data() + messageOffset,
                      compileDiagnostic.size() - messageOffset);
        return false;
    }
    const size_t functionCount = original.getFunctionCount();
    if (functionCount == 0 || functionCount > kMaxProtos) {
        FFlag::LuauEmitCallFeedback.value = previousFeedback;
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT,
                      "inline source function count exceeds the frontend limit");
        return false;
    }

    std::vector<std::string_view> strings = original.getStringTable();
    std::vector<Luau::Bytecode::CompTimeBcFunction> functions;
    functions.reserve(functionCount);
    for (size_t functionId = 0; functionId < functionCount; ++functionId) {
        std::optional<Luau::Bytecode::CompTimeBcFunction> function =
            Luau::Bytecode::fromFunctionBytecode(original.getFunctionData(uint32_t(functionId)),
                                                 strings);
        if (!function) {
            FFlag::LuauEmitCallFeedback.value = previousFeedback;
            setDiagnostic(result, LUAUC_SNAPSHOT_V1_INTERNAL_ERROR,
                          "upstream bytecode graph parser rejected compiler output");
            return false;
        }
        functions.push_back(std::move(*function));
    }

    for (uint32_t planId = 0; planId < planCount; ++planId) {
        const LuaucFrontendInlinePlanV1 &plan = plans[planId];
        if (plan.caller_function_id >= functions.size() ||
            plan.target_function_id >= functions.size() || plan.target_function_id == UINT32_MAX) {
            FFlag::LuauEmitCallFeedback.value = previousFeedback;
            setDiagnostic(result, LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT,
                          "inline plan references an unknown function");
            return false;
        }
        Luau::Bytecode::CompTimeBcFunction &caller = functions[plan.caller_function_id];
        Luau::Bytecode::BcOp call;
        uint32_t matches = 0;
        for (uint32_t instructionId = 0; instructionId < caller.instructions.size(); ++instructionId) {
            if (caller.instructions[instructionId].op != LOP_CALLFB)
                continue;
            Luau::Bytecode::BcOp candidate{Luau::Bytecode::BcOpKind::Inst, instructionId};
            const int32_t feedbackSlot = caller.as<Luau::Bytecode::BcCallFB<>>(candidate).FbSlot();
            if (feedbackSlot >= 0 && uint32_t(feedbackSlot) == plan.feedback_slot) {
                call = candidate;
                ++matches;
            }
        }
        const uint32_t targetProtoId = plan.target_function_id;
        if (matches != 1 ||
            !Luau::Bytecode::inlineCall(caller, functions[plan.target_function_id], call,
                                       targetProtoId)) {
            FFlag::LuauEmitCallFeedback.value = previousFeedback;
            setDiagnostic(result, LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT,
                          "inline plan does not identify an inlinable CALLFB");
            return false;
        }
    }

    Luau::BytecodeBuilder rebuilt;
    for (Luau::Bytecode::CompTimeBcFunction &function : functions) {
        if (Luau::Bytecode::toFunctionBytecode(rebuilt, function).empty()) {
            FFlag::LuauEmitCallFeedback.value = previousFeedback;
            setDiagnostic(result, LUAUC_SNAPSHOT_V1_INTERNAL_ERROR,
                          "upstream bytecode graph serializer rejected transformed function");
            return false;
        }
    }
    rebuilt.setMainFunction(original.getMainFunction());
    rebuilt.finalize();
    bytecode = rebuilt.getBytecode();
    FFlag::LuauEmitCallFeedback.value = previousFeedback;
    if (bytecode.empty() || bytecode.size() > kMaxBytecodeBytes) {
        setDiagnostic(result, LUAUC_SNAPSHOT_V1_RESOURCE_LIMIT,
                      "inlined bytecode exceeds the frontend limit");
        return false;
    }
    return true;
}

} // namespace

extern "C" uint32_t luauc_frontend_snapshot_v1_compile(const uint8_t *source, size_t sourceSize,
                                                         const uint8_t *chunkName,
                                                         size_t chunkNameSize,
                                                         uint32_t coverageLevel,
                                                         LuaucFrontendSnapshotV1Result *result) {
    if (!result)
        return LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT;
    memset(result, 0, sizeof(*result));
    if (!validCompileArguments(source, sourceSize, chunkName, chunkNameSize, coverageLevel, result))
        return result->status;
    std::string bytecode;
    if (!compileSource(source, sourceSize, coverageLevel, bytecode, result))
        return result->status;
    return snapshotBytecode(bytecode, chunkName, chunkNameSize, result);
}

extern "C" uint32_t luauc_frontend_snapshot_v1_compile_inlined(
    const uint8_t *source, size_t sourceSize, const uint8_t *chunkName, size_t chunkNameSize,
    uint32_t coverageLevel, const LuaucFrontendInlinePlanV1 *plans, uint32_t planCount,
    LuaucFrontendSnapshotV1Result *result) {
    if (!result)
        return LUAUC_SNAPSHOT_V1_INVALID_ARGUMENT;
    memset(result, 0, sizeof(*result));
    if (!validCompileArguments(source, sourceSize, chunkName, chunkNameSize, coverageLevel, result))
        return result->status;
    std::string bytecode;
    if (!buildInlinedBytecode(source, sourceSize, coverageLevel, plans, planCount, bytecode, result))
        return result->status;
    return snapshotBytecode(bytecode, chunkName, chunkNameSize, result);
}

extern "C" void luauc_frontend_snapshot_v1_free(LuaucFrontendSnapshotV1Result *result) {
    if (!result)
        return;
    free(result->data);
    free(result->diagnostic);
    memset(result, 0, sizeof(*result));
}

extern "C" const char *luauc_frontend_snapshot_v1_last_raise_message() {
    return luauc_eh::g_sticky_raise;
}

extern "C" size_t luauc_frontend_snapshot_v1_last_raise_message_size() {
    return luauc_eh::g_sticky_raise_len;
}
