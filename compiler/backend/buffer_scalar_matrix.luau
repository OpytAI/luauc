local function matrix(bytes, base, value8, value16, value32, valuef32, valuef64, value64)
    buffer.writei8(bytes, base, value8)
    buffer.writei16(bytes, base + 1, value16)
    buffer.writei32(bytes, base + 3, value32)
    buffer.writef32(bytes, base + 7, valuef32)
    buffer.writef64(bytes, base + 11, valuef64)
    buffer.writeinteger(bytes, base + 19, value64)

    return buffer.readi8(bytes, base), buffer.readu8(bytes, base), buffer.readi16(bytes, base + 1), buffer.readu16(bytes, base + 1), buffer.readi32(bytes, base + 3), buffer.readu32(bytes, base + 3), buffer.readf32(bytes, base + 7), buffer.readf64(bytes, base + 11), buffer.readinteger(bytes, base + 19)
end

local function stringArguments(bytes, offset, value)
    buffer.writei16(bytes, offset, value)
    return buffer.readi16(bytes, offset), buffer.readu16(bytes, offset), offset, value
end

local function createInteger(value)
    return integer.create(value)
end

local function outOfBounds(bytes)
    return buffer.readi32(bytes, 62)
end

local function wrongBuffer(value)
    return buffer.readi8(value, 0)
end

local function wrongOffset(bytes, value)
    return buffer.readi8(bytes, value)
end

local function wrongValue(bytes, value)
    buffer.writei8(bytes, 0, value)
end

return function(mode, ...)
    if mode == 1 then
        return matrix(...)
    elseif mode == 2 then
        return stringArguments(...)
    elseif mode == 3 then
        local value, fraction, huge = ...
        return createInteger(value), createInteger(fraction), createInteger(huge)
    elseif mode == 4 then
        local bytes = ...
        local bad = {}
        local boundsOk, boundsError = pcall(outOfBounds, bytes)
        local bufferOk, bufferError = pcall(wrongBuffer, bad)
        local offsetOk, offsetError = pcall(wrongOffset, bytes, bad)
        local valueOk, valueError = pcall(wrongValue, bytes, bad)
        return boundsOk, boundsError, bufferOk, bufferError, offsetOk, offsetError, valueOk, valueError, buffer.readi8(bytes, 0)
    end
    error("invalid buffer scalar mode")
end
