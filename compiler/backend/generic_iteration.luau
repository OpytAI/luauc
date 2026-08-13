return function(a, b, c)
    local values = { a, b, c }
    return function()
        local total = 0
        for index, value in values do
            total += index * value
        end
        return total
    end
end
