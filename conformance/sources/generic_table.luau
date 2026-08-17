return function(key_a, value_a, key_b, value_b, key_c, value_c)
    local values = {}
    values[key_a] = value_a
    values[key_b] = value_b
    values[key_c] = value_c

    return function(probe)
        local direct = values[probe]
        local iterated = nil
        local count = 0
        for key, value in values do
            count += 1
            if key == probe then
                iterated = value
            end
        end
        return direct, iterated, count
    end
end
