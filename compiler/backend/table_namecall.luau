return function()
    local total = 11

    local function bump(self, amount)
        total = total + amount
        return self, total
    end

    local function invoke(receiver, amount)
        return receiver:bump(amount)
    end

    return invoke, bump
end
