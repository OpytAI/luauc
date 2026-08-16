return function(value, text)
    local function guardBreadth(input)
        local first = integer.create(math.floor(math.abs(input)) + 18)
        local three = integer.create(3)
        local four = integer.create(4)
        local zero = integer.create(0)
        local field = math.floor(math.abs(input)) % 8

        assert(integer.tonumber(integer.div(first, three)) == math.floor(integer.tonumber(first) / 3))
        assert(integer.tonumber(integer.extract(first, zero, four)) == bit32.extract(integer.tonumber(first), 0, 4))
        assert(integer.tonumber(integer.clamp(first, integer.create(2), integer.create(5))) == 5)
        assert(bit32.extract(integer.tonumber(first), field, 4) >= 0)

        local failures = 0
        failures += pcall(function()
            integer.div(first, zero)
        end) and 0 or 1
        failures += pcall(function()
            integer.extract(first, zero, integer.create(65))
        end) and 0 or 2
        failures += pcall(function()
            bit32.extract(integer.tonumber(first), 40, 1)
        end) and 0 or 4
        failures += pcall(function()
            integer.add(first, {})
        end) and 0 or 8
        failures += pcall(function()
            assert(false, "guard assertion")
        end) and 0 or 16
        assert(failures == 31)
        return failures
    end

    local function unsafeAssert(input)
        return assert(input, "unsafe assertion")
    end
    local originalEnvironment = getfenv(unsafeAssert)
    setfenv(unsafeAssert, setmetatable({
        assert = function(input)
            coroutine.yield("gc-boundary")
            return input and 41 or 43
        end,
    }, { __index = originalEnvironment }))

    local function dynamicRoundtrip(object, key)
        local current = object[key]
        object[key] = current
        return object[key]
    end

    local function tableBreadth(input, text)
        local seedA = { input }
        local seedB = { input + 1 }
        local seedC = { input + 2 }
        local seedLen = #seedA + #seedB + #seedC
        local arr = { input, input + 1, input + 2 }
        local hash = { name = text, bias = input, extra = input + 3 }
        local hashLen = #hash
        hash[1] = input
        hash[2] = input + 1
        table.insert(arr, text)
        local first = { count = 17, kind = "seed", ready = true }
        local second = { count = 17, kind = "seed", ready = true }
        table.insert(first, input)
        local mixed = { input, name = text, extra = input + 4 }
        local extraA = { input + 5 }
        local extraB = { flag = true, more = text }
        extraA[2] = input + 6
        coroutine.yield("gc-boundary")
        return seedLen + #arr + hashLen + #hash + #mixed + first[1] + second.count + extraA[1] + extraA[2]
            + (extraB.flag and 0 or 1)
    end

    local records = {
        { amount = value },
        { amount = value + 1 },
        { amount = value + 2 },
    }
    local sum = 0
    for index, record in ipairs(records) do
        sum += index * record.amount
    end
    local secondRecord = records[2]
    records[2] = records[3]
    if records[2].amount ~= value + 2 then
        error("numeric table replacement failed")
    end
    records[2] = secondRecord
    if dynamicRoundtrip(records, 2) ~= secondRecord then
        error("dynamic numeric table roundtrip failed")
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
    local tableBreadthResult = tableBreadth(value, text)
    local guardResult = guardBreadth(value) + unsafeAssert(false)

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
            + guardResult + tableBreadthResult
            + (string.len(message) > 0 and 1 or 0) + (missingOk and 0 or 1),
        text .. ":" .. tostring(records[2].amount) .. ":" .. tostring(directHits)
            .. "/" .. tostring(tableIndexHits) .. "/" .. tostring(functionIndexHits) .. ":missing"
end
