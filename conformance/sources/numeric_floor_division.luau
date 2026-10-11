return function(value, text)
    local divisor = tonumber(text)
    return value // divisor, text
end
