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
    coroutine.yield("gc-boundary")
    local resumed, finished = coroutine.resume(thread, value + 1)
    if not resumed then
        error(finished)
    end

    return sum + suspended + finished + (string.len(message) > 0 and 1 or 0),
        text .. ":" .. tostring(records[2].amount)
end
