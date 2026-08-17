-- One source graph exercises the protected and suspended boundaries that share the strict-AOT
-- continuation substrate. The host supplies only the real opened `coroutine.yield` and `error` C
-- closures, then installs the returned compiled metamethods on ordinary Luau tables. One dispatcher
-- mode also consumes that C yield closure directly as a generic iterator.
return function(yielder, raise)
    local function arithmetic(left, right)
        return left + right
    end

    local function identity(message)
        return message
    end

    local function compiledFailure(value, bad)
        return value + bad
    end

    local function compiledMetamethodFailure()
        return raise("compiled metamethod boom")
    end

    local function forbiddenMetamethodYield(_, value)
        return yielder(value)
    end

    local function callableYield(_, value)
        local resumed = yielder(value)
        return resumed + value
    end

    local function iterator(state, control)
        local index = control + 1
        if index <= state then
            local resumed = yielder(index)
            return index, resumed
        end
        return nil
    end

    local function consume(limit)
        local total = 0
        for index, resumed in iterator, limit, 0 do
            total += index + resumed
        end
        return total
    end

    local function interruptLoop(limit)
        local total = 0
        for index = 1, limit do
            total += index
        end
        return total
    end

    local function consumeExternal(iteratorFunction, state, control)
        local total = 0
        for index, resumed in iteratorFunction, state, control do
            total += index + resumed
        end
        return total
    end

    local function entry(mode, first, second, third, fourth, fifth)
        if mode == 1 then
            local compiledOk, compiledMessage = pcall(compiledFailure, second, third)
            local xpcallOk, xpcallMessage = xpcall(compiledFailure, identity, second, third)
            local cOk, cMessage = pcall(first, "C error boom")
            local metamethodOk, metamethodMessage = pcall(arithmetic, fourth, second)
            local forbiddenYieldOk, forbiddenYieldMessage = pcall(arithmetic, fifth, second)
            local recoveryOk, recoveryResult = pcall(arithmetic, second, 1)
            return compiledOk, compiledMessage, xpcallOk, xpcallMessage, cOk, cMessage,
                metamethodOk, metamethodMessage, forbiddenYieldOk, forbiddenYieldMessage,
                recoveryOk, recoveryResult
        elseif mode == 2 then
            return pcall(first, second)
        elseif mode == 3 then
            return pcall(consume, first)
        elseif mode == 4 then
            return pcall(consumeExternal, first, second, third)
        elseif mode == 5 then
            return pcall(interruptLoop, first)
        end

        return false, "unknown protected-execution mode"
    end

    return entry, compiledMetamethodFailure, forbiddenMetamethodYield, callableYield
end
