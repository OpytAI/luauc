return function(a, b, c)
    local t = { a, b, c }
    t[2] = t[1] + t[3]

    return function()
        return #t, t[2]
    end
end
