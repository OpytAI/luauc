return function(callable, a, b, c)
    local first, second = callable(a, b, c)
    return first, second
end
