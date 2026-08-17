return function(seed: vec2)
    local unit: vec2 = seed.Unit
    return seed:Mark({ 0 }) + unit:Mark({ 0 })
end


