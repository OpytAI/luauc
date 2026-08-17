return function(seed)
    local bytes = buffer.create(16)
    buffer.writei32(bytes, 0, seed)
    buffer.writei16(bytes, 4, seed)
    buffer.writei8(bytes, 6, seed)
    local total = buffer.readi32(bytes, 0) + buffer.readi16(bytes, 4) + buffer.readi8(bytes, 6)
    buffer.writef64(bytes, 8, seed / 2)
    return total + math.floor(buffer.readf64(bytes, 8))
end
