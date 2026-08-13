return function(backing, inherited_proxy, locked_key, raise)
    local index_hits = 0
    local newindex_hits = 0

    local function dynamicIndex(_, requested)
        index_hits += 1
        local stored = backing[requested]
        if stored ~= nil then
            return stored
        end
        return inherited_proxy[requested]
    end

    local function dynamicNewIndex(_, requested, value)
        newindex_hits += 1
        if requested == locked_key then
            raise("locked-write", 0)
        end
        backing[requested] = value
    end

    local function prime(object, key, initial, updated)
        object[key] = initial
        local first = object[key]
        object[key] = updated
        local second = object[key]
        local recovered = object[key]

        return function(replacement)
            local inherited_value = object.inherited
            local missing_value = object.missing
            object[key] = replacement
            local final = object[key]
            return first, second, recovered, final, inherited_value, missing_value,
                index_hits, newindex_hits
        end
    end

    local function lockedWrite(object, value)
        object[locked_key] = value
    end

    local function invalidWrite(invalid_key, value)
        backing[invalid_key] = value
    end

    local function readonlyWrite(frozen, key, value)
        frozen[key] = value
    end

    return prime, dynamicIndex, dynamicNewIndex, lockedWrite, invalidWrite, readonlyWrite
end
