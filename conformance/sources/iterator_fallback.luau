return function(limit, scale, bias, seed)
    local function iterator(state, control)
        local index = control + 1
        if index <= state then
            return index, index * 2
        end
        return nil
    end

    local total = 0
    for _, doubled in iterator, limit, 0 do
        total += doubled
    end
    return seed + total * scale + bias, total
end
