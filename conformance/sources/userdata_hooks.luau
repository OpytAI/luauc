return function(seed: vec2)
    local unit = seed.Unit
    local bag = { 0 }
    seed:Mark(bag)
    return if unit and seed then 1 else 0
end


