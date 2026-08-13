local function split(value)
    return math.frexp(value)
end

local function render(value)
    return tostring(split(value))
end

local function rejectedMath(value)
    return math.sin(value)
end

local function rejectedString(value)
    return string.len(value)
end

local function rejectedInteger(value)
    return integer.tonumber(value)
end

local function rejectedVector(value)
    return vector.magnitude(value)
end

local function rejectedRaw(value)
    return rawget(value, "missing")
end

local function rejectionMask()
    local math_ok = pcall(rejectedMath, {})
    local string_ok = pcall(rejectedString, {})
    local integer_ok = pcall(rejectedInteger, {})
    local vector_ok = pcall(rejectedVector, {})
    local raw_ok = pcall(rejectedRaw, 1)
    return (math_ok and 0 or 1)
        + (string_ok and 0 or 2)
        + (integer_ok and 0 or 4)
        + (vector_ok and 0 or 8)
        + (raw_ok and 0 or 16)
end

local function mathBreadth(value, square)
    local positive = math.abs(value) + 1
    local normalized = value / positive
    local mantissa, exponent = math.frexp(value)
    local integral, fractional = math.modf(value)
    return math.acos(normalized)
        + math.asin(normalized)
        + math.atan(value)
        + math.atan2(value, positive)
        + math.ceil(value)
        + math.cosh(normalized)
        + math.cos(value)
        + math.deg(value)
        + math.exp(normalized)
        + math.floor(value)
        + math.fmod(value, positive)
        + math.ldexp(value, 2)
        + math.log(positive)
        + math.log10(positive)
        + math.max(value, square, positive)
        + math.min(value, square, positive)
        + math.pow(positive, 0.5)
        + math.rad(value)
        + math.sign(value)
        + math.sinh(normalized)
        + math.sin(value)
        + math.sqrt(square)
        + math.tanh(value)
        + math.tan(normalized)
        + math.round(value)
        + math.clamp(value, -10, 10)
        + math.lerp(value, square, 0.25)
        + mantissa
        + exponent
        + integral
        + fractional
        + (math.isnan(value) and 1 or 0)
        + (math.isinf(value) and 1 or 0)
        + (math.isfinite(value) and 1 or 0)
end

local function bitBreadth(value, square, text)
    local first = math.floor(math.abs(value) * 1000)
    local second = math.floor(math.abs(square)) + 1
    local field = string.len(text) % 16
    local width = math.min(8, 32 - field)
    return bit32.arshift(first, field)
        + bit32.band(first, second)
        + bit32.bnot(first)
        + bit32.bor(first, second)
        + bit32.bxor(first, second)
        + (bit32.btest(first, second) and 1 or 0)
        + bit32.extract(first, field, width)
        + bit32.lrotate(first, field)
        + bit32.lshift(first, field)
        + bit32.replace(first, second, field, width)
        + bit32.rrotate(first, field)
        + bit32.rshift(first, field)
        + bit32.countlz(first)
        + bit32.countrz(first)
        + bit32.byteswap(first)
end

local function stringBreadth(text)
    local first, second = string.byte(text, 1, math.min(2, string.len(text)))
    local generated = string.char(first, second or first)
    local selected = select(2, first, second or first, string.len(generated))
    return string.len(text) + string.len(string.sub(text, 1, -1)) + first + (second or 0) + selected
end

local function tableBreadth(value)
    local target = { 3, 5 }
    rawset(target, "value", value)
    table.insert(target, 7)
    local first, second = table.unpack(target)
    local inherited = setmetatable({}, { __index = target })
    return first + second + rawlen(target) + (rawequal(rawget(target, "value"), value) and 1 or 0)
        + (getmetatable(inherited) ~= nil and 1 or 0)
        + select("#", first, second, inherited.value)
end

local function integerBreadth(value, square, text)
    local first = integer.create(math.floor(value))
    local second = integer.create(math.max(1, math.floor(square)))
    local amount = integer.create(string.len(text) % 16)
    local width = integer.create(3)
    local total = integer.tonumber(integer.neg(first))
        + integer.tonumber(integer.add(first, second))
        + integer.tonumber(integer.sub(first, second))
        + integer.tonumber(integer.mul(first, second))
        + integer.tonumber(integer.div(first, second))
        + integer.tonumber(integer.min(first, second))
        + integer.tonumber(integer.max(first, second))
        + integer.tonumber(integer.rem(first, second))
        + integer.tonumber(integer.idiv(first, second))
        + integer.tonumber(integer.udiv(first, second))
        + integer.tonumber(integer.urem(first, second))
        + integer.tonumber(integer.mod(first, second))
        + integer.tonumber(integer.clamp(first, integer.neg(second), second))
        + integer.tonumber(integer.band(first, second))
        + integer.tonumber(integer.bor(first, second))
        + integer.tonumber(integer.bnot(first))
        + integer.tonumber(integer.bxor(first, second))
        + integer.tonumber(integer.lshift(first, amount))
        + integer.tonumber(integer.rshift(first, amount))
        + integer.tonumber(integer.arshift(first, amount))
        + integer.tonumber(integer.lrotate(first, amount))
        + integer.tonumber(integer.rrotate(first, amount))
        + integer.tonumber(integer.extract(first, amount, width))
        + integer.tonumber(integer.countrz(first))
        + integer.tonumber(integer.countlz(first))
        + integer.tonumber(integer.bswap(first))
    return total
        + (integer.btest(first, second) and 1 or 0)
        + (integer.lt(first, second) and 1 or 0)
        + (integer.le(first, second) and 1 or 0)
        + (integer.ult(first, second) and 1 or 0)
        + (integer.ule(first, second) and 1 or 0)
        + (integer.gt(first, second) and 1 or 0)
        + (integer.ge(first, second) and 1 or 0)
        + (integer.ugt(first, second) and 1 or 0)
        + (integer.uge(first, second) and 1 or 0)
end

local function vectorBreadth(value, square, text)
    local first = vector.create(value, square, string.len(text))
    local second = vector.create(string.len(text), value, square)
    local low = vector.create(-100, -100, -100)
    local high = vector.create(100, 100, 100)
    return vector.magnitude(first)
        + vector.magnitude(vector.normalize(first))
        + vector.magnitude(vector.cross(first, second))
        + vector.dot(first, second)
        + vector.magnitude(vector.floor(first))
        + vector.magnitude(vector.ceil(first))
        + vector.magnitude(vector.abs(first))
        + vector.magnitude(vector.sign(first))
        + vector.magnitude(vector.clamp(first, low, high))
        + vector.magnitude(vector.min(first, second))
        + vector.magnitude(vector.max(first, second))
        + vector.magnitude(vector.lerp(first, second, 0.5))
end

return function(value, square, text, dynamic)
    local mantissa, exponent = split(value)
    local rejected = rejectionMask()
    assert(rejected == 31)
    return math.abs(value),
        math.floor(value),
        math.sqrt(square),
        math.sin(value),
        mantissa,
        exponent,
        string.len(text),
        type(dynamic),
        typeof(dynamic),
        render(value),
        math.round(mathBreadth(value, square) * 1000000000),
        bitBreadth(value, square, text) % 1000000000,
        stringBreadth(text),
        tableBreadth(value),
        integerBreadth(value, square, text) % 1000000000,
        math.round(vectorBreadth(value, square, text) * 1000000000),
        rejected
end
