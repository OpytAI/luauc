return function(n, text)
    local function walk(k, acc, s)
        if k <= 0 then
            return acc
        end
        return walk(k - 1, acc + k + #s, s)
    end
    local depth = n
    if depth < 0 then
        depth = -depth
    end
    if depth > 16 then
        depth = 16
    end
    local value = walk(depth, math.abs(n), text) + string.len(text)
    return value, string.lower(text)
end
