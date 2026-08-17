return function(backing, raise, yield_fn)
    local method_hits = 0
    local index_hits = 0
    local env_get_hits = 0
    local env_set_hits = 0
    local operator_hits = 0

    local function method(self, amount)
        method_hits += 1
        return self.label, self.bias + amount
    end

    local function yieldingMethod(self, amount)
        local resumed = yield_fn(self.bias + amount)
        return self.label, resumed + amount
    end

    local function functionIndex(_, key)
        index_hits += 1
        if key == "method" then
            return method
        elseif key == "yielding" then
            return yieldingMethod
        end
        return backing[key]
    end

    local function envIndex(_, key)
        env_get_hits += 1
        local stored = backing[key]
        if stored ~= nil then
            return stored
        elseif key == "inherited_global" then
            return 37
        end
        return nil
    end

    local function envNewIndex(_, key, value)
        env_set_hits += 1
        backing[key] = value
    end

    local function arithmetic(left, right)
        operator_hits += 1
        if right == nil then
            right = left
        end
        return left.value + right.value
    end

    local function comparison(left, right)
        operator_hits += 1
        return left.value < right.value
    end

    local function length(value)
        operator_hits += 1
        return value.size
    end

    local function concatenate(left, right)
        operator_hits += 1
        return left.text .. "|" .. right.text
    end

    local function failOperator(...)
        raise("operator-failure", 0)
    end

    local function yieldOperator(...)
        return yield_fn("operator-yield")
    end

    local function namecallMatrix(direct, inherited, nested, callable, amount)
        local direct_label, direct_value = direct:method(amount)
        local inherited_label, inherited_value = inherited:method(amount)
        local nested_label, nested_value = nested:method(amount)
        local callable_label, callable_value = callable:method(amount)
        return direct_label, direct_value, inherited_label, inherited_value,
            nested_label, nested_value, callable_label, callable_value, method_hits, index_hits
    end

    local function yieldingNamecall(receiver, amount)
        return receiver:yielding(amount)
    end

    local function globals(delta)
        local inherited = inherited_global
        stored_global = inherited + delta
        return inherited, stored_global, env_get_hits, env_set_hits
    end

    local function operators(left, right)
        return left + right, left - right, left * right, left / right,
            left // right, left % right, left ^ right,
            -left,
            left == right, left < right, left <= right,
            #left, left .. right, operator_hits
    end

    local function addOnly(left, right)
        return left + right
    end

    local function compareOnly(left, right)
        return left < right
    end

    local function equalOnly(left, right)
        return left == right
    end

    local function lengthOnly(value, _)
        return #value
    end

    local function concatOnly(left, right)
        return left .. right
    end

    return namecallMatrix, yieldingNamecall, globals, operators,
        addOnly, compareOnly, equalOnly, lengthOnly, concatOnly,
        method, yieldingMethod, functionIndex, envIndex, envNewIndex,
        arithmetic, comparison, length, concatenate, failOperator, yieldOperator
end
