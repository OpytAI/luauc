return function(yield_function, before)
    local function suspend(value)
        local resumed = yield_function(value)
        return resumed + value
    end

    return suspend(before)
end
