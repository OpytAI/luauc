return function(a, b, c)
    local t = {}
    t.left = a
    t.middle = b
    t.right = c
    t.middle = t.left + t.right

    return function()
        return t.left, t.middle, t.right
    end
end
