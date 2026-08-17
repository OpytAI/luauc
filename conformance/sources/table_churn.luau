return function(n, text)
    local t = { seed = text, n = n }
    local limit = n
    if limit < 0 then
        limit = -limit
    end
    if limit > 32 then
        limit = 32
    end
    for i = 1, limit do
        t[i] = i
        t["k" .. i] = text
        table.insert(t, i)
    end
    return #t, text
end
