local function hot(a, b)
    return a * 3 + b
end

local function cold(a, b)
    return a - b
end

local function dispatch(fn, a, b)
    local result = fn(a, b)
    return result
end

return function(useHot, a, b)
    return dispatch(if useHot then hot else cold, a, b)
end
