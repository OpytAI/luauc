-- One natural source package exercises Luau's complete generic-iteration protocol and keeps the
-- behavior in compiled code. The host supplies only the opened yield/error closures and, for the
-- userdata path, one genuine public-API userdata whose metatable receives the compiled __iter.
return function(yielder, raise)
    local function sequenceIterator(state, control)
        local index = control + 1
        local value = state[index]
        if value ~= nil then
            return index, value, index + value
        end
        return nil
    end

    local function oneResult(_, control)
        if control == 0 then
            return 1
        end
        return nil
    end

    local function twoResults(state, control)
        if control == 0 then
            return 1, state
        end
        return nil
    end

    local function threeResults(state, control)
        if control == 0 then
            return 1, state, state + 1
        end
        return nil
    end

    local function runMatrix(a, b, c, allocationCount, callable, provider, xnextRunner)
        local values = { a, b, c }
        provider.values = values

        local pairsTotal = 0
        local pairsCount = 0
        for index, value in pairs(values) do
            pairsTotal += index * value
            pairsCount += 1
        end

        local nextTotal = 0
        local nextCount = 0
        local key = nil
        while true do
            local value
            key, value = next(values, key)
            if key == nil then
                break
            end
            nextTotal += key * value
            nextCount += 1
        end

        local ipairsTotal = 0
        local ipairsCount = 0
        for index, value in ipairs({ a, nil, c }) do
            ipairsTotal += index * value
            ipairsCount += 1
        end

        local adjusted = 0
        for first in oneResult, nil, 0 do
            adjusted += first
        end
        local oneMissing = false
        for first, second, third in oneResult, nil, 0 do
            adjusted += first
            oneMissing = second == nil and third == nil
        end
        local twoMissing = false
        for first, second, third in twoResults, b, 0 do
            adjusted += first + second
            twoMissing = third == nil
        end
        local threePresent = false
        for first, second, third in threeResults, c, 0 do
            adjusted += first + second + third
            threePresent = third == c + 1
        end

        local compiledTotal = 0
        for index, value, combined in sequenceIterator, values, 0 do
            compiledTotal += index + value + combined
        end

        local callableTotal = 0
        for index, value, combined in callable, values, 0 do
            callableTotal += index + value + combined
        end

        local iterMetatableTotal = 0
        for index, value, combined in provider do
            iterMetatableTotal += index + value + combined
        end
        local xnextTotal = xnextRunner(values)

        -- Keep a wide collectable graph alive until the compiled function returns. Every child is
        -- reachable both through the array and through a record edge, exercising forward/back
        -- table writes under allocation pressure without manufacturing test-only objects.
        local allocations = {}
        local allocationTotal = 0
        for index = 1, allocationCount do
            local child = { index, index + a, label = "iteration-node" }
            allocations[index] = { child = child, value = b + index }
            allocationTotal += allocations[index].child[2] + allocations[index].value
        end

        return pairsTotal, pairsCount, nextTotal, nextCount,
            ipairsTotal, ipairsCount, adjusted,
            oneMissing, twoMissing, threePresent,
            compiledTotal, callableTotal, iterMetatableTotal, allocationTotal, xnextTotal
    end

    local function yieldingIterator(state, control)
        local index = control + 1
        if index <= state then
            local resumed = yielder(index)
            return index, resumed, index + resumed
        end
        return nil
    end

    local function runYield(limit)
        local total = 0
        for index, resumed, combined in yieldingIterator, limit, 0 do
            total += index + resumed + combined
        end
        return total
    end

    local function runErrors(badProvider, badXnextRunner)
        local function invalidPrep()
            for _ in 42 do
            end
        end

        local function invalidIterator()
            for _ in badProvider do
            end
        end

        local function failingIterator(_, control)
            local index = control + 1
            if index == 2 then
                raise("iterator boom", 0)
            elseif index <= 3 then
                return index
            end
            return nil
        end
        local function iteratorFailure()
            for _ in failingIterator, nil, 0 do
            end
        end

        local prepOk, prepMessage = pcall(invalidPrep)
        local iteratorValueOk, iteratorValueMessage = pcall(invalidIterator)
        local iteratorCallOk, iteratorCallMessage = pcall(iteratorFailure)
        local xnextOk, xnextMessage = pcall(badXnextRunner, { 1, 2, 3 })

        local recovery = 0
        for index, value in sequenceIterator, { 4, 5, 6 }, 0 do
            recovery += index * value
        end
        return prepOk,
            prepMessage,
            iteratorValueOk,
            iteratorValueMessage,
            iteratorCallOk,
            iteratorCallMessage,
            xnextOk,
            xnextMessage,
            recovery
    end

    local function userdataIterator(self)
        local function iterate(state, control)
            local index = control + 1
            if index <= 3 then
                return index, state:read(index)
            end
            return nil
        end
        return iterate, self, 0
    end

    local function callableIterator(_, state, control)
        return sequenceIterator(state, control)
    end

    local function providerIterator(self)
        return sequenceIterator, self.values, 0
    end

    local function badProviderIterator()
        return nil
    end

    local function runUserdata(object)
        local iterTotal = 0
        for index, value in object do
            iterTotal += index * value
        end
        return iterTotal, object:read(4)
    end

    local function xnextRunner(state)
        local total = 0
        for index, value in next, state do
            total += index * value
        end
        return total
    end

    local function badXnextRunner(state)
        for _ in next, state do
        end
    end

    return runMatrix, runYield, runErrors, userdataIterator, runUserdata,
        callableIterator, providerIterator, badProviderIterator, xnextRunner, badXnextRunner
end
