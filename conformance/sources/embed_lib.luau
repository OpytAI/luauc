return function(value, text)
    local records = {
        { amount = value },
        { amount = value + 1 },
        { amount = value + 2 },
    }
    local sum = 0
    for index, record in ipairs(records) do
        sum += index * record.amount
    end

    local ok, message = pcall(function()
        error("embed-error:" .. text)
    end)
    if ok then
        error("protected error unexpectedly succeeded")
    end

    local thread = coroutine.create(function(first)
        local second = coroutine.yield(first + 2)
        return second * 2
    end)
    local yielded, suspended = coroutine.resume(thread, value)
    if not yielded then
        error(suspended)
    end

    local directHits = 0
    local tableIndexHits = 0
    local functionIndexHits = 0

    local function callStep(receiver, amount)
        return receiver:step(amount)
    end

    local function storeTwoAndRead(object, first, second)
        object.x = first
        object.y = second
        return object.x
    end

    local direct = {
        bias = value + 3,
        step = function(self, amount)
            directHits += 1
            return amount + self.bias
        end,
    }
    for index = 1, 24 do
        direct["slot" .. tostring(index)] = value + index
    end
    direct.slot7 = nil
    direct.slot19 = value * 3
    local directFirst = callStep(direct, value)
    direct.step = function(self, amount)
        directHits += 1
        return amount * 2 + self.bias
    end
    local directSecond = callStep(direct, value + 1)

    local inherited = {
        step = function(self, amount)
            tableIndexHits += 1
            return amount - self.bias
        end,
    }
    local tableReceiver = setmetatable({ bias = value - 2 }, { __index = inherited })
    local tableResult = callStep(tableReceiver, value + 4)

    local functionReceiver = { bias = 5 }
    setmetatable(functionReceiver, {
        __index = function(_, key)
            functionIndexHits += 1
            if key == "step" then
                return function(self, amount)
                    functionIndexHits += 10
                    coroutine.yield("gc-boundary")
                    return amount + self.bias + string.len(text)
                end
            end
            return nil
        end,
    })
    local functionResult = callStep(functionReceiver, value + 2)

    local missingReceiver = setmetatable({}, { __index = {} })
    local missingOk, missingMessage = pcall(function()
        return callStep(missingReceiver, value)
    end)
    if missingOk or string.len(missingMessage) == 0 then
        error("missing method unexpectedly succeeded")
    end

    local nodeValue = storeTwoAndRead({}, value + 3, text)
    if nodeValue ~= value + 3 then
        error("cached node value changed")
    end

    local resumed, finished = coroutine.resume(thread, value + 1)
    if not resumed then
        error(finished)
    end

    return sum + suspended + finished + directFirst + directSecond + tableResult + functionResult
            + directHits + tableIndexHits + functionIndexHits
            + (string.len(message) > 0 and 1 or 0) + (missingOk and 0 or 1),
        text .. ":" .. tostring(records[2].amount) .. ":" .. tostring(directHits)
            .. "/" .. tostring(tableIndexHits) .. "/" .. tostring(functionIndexHits) .. ":missing"
end
