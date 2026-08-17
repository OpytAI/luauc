local function runtime_entry(value, bad)
    local function nested_failure(left, right)
        return left + right
    end

    return nested_failure(value, bad)
end

return runtime_entry
