return function(delta, floor)
    local globals = _G
    local next_accumulator = aot_global_accumulator + delta
    aot_global_accumulator = next_accumulator

    local maximum = globals.math.max(next_accumulator, floor)
    local kind = globals.type(next_accumulator)
    return next_accumulator, maximum, kind
end
