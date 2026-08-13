return function(value)
    local first = {count = 11, label = "seed", ready = true}
    local second = {count = 11, label = "seed", ready = true}
    table.insert(first, value)
    return first, second
end
