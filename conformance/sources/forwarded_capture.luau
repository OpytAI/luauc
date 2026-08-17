return function(initial, left, right)
    local shared = initial
    local first = left
    local second = right

    local function makeForwarder()
        return function(delta)
            shared += delta
            return shared + first, shared + second
        end
    end

    local forwarded = makeForwarder()
    local function sibling(delta)
        shared += delta
        return shared
    end

    return forwarded, sibling
end
