return function(index_a, value_a, index_b, value_b, name_a, named_a, name_b, named_b, delete_key, delete_value)
    local values = {}
    values[index_a] = value_a
    values[index_b] = value_b
    values[name_a] = named_a
    values[name_b] = named_b
    values[delete_key] = delete_value

    return function(probe_index, probe_name)
        local direct_index = values[probe_index]
        local direct_name = values[probe_name]
        local iterated_index = nil
        local iterated_name = nil
        local count = 0
        for key, value in values do
            count += 1
            if key == probe_index then
                iterated_index = value
            end
            if key == probe_name then
                iterated_name = value
            end
        end
        return direct_index, iterated_index, direct_name, iterated_name, count
    end
end
