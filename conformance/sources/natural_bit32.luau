return function(seed)
    local n = bit32.band(math.floor(math.abs(seed)) + 13, 0xffff)
    local rotated = bit32.lrotate(n, 3)
    local shifted = bit32.rshift(rotated, 1)
    local xored = bit32.bxor(shifted, bit32.bor(n, 7))
    local counted = bit32.countlz(xored) + bit32.countrz(xored)
    return bit32.band(counted + bit32.bnot(n), 0xff)
end
