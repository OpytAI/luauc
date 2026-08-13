return function(depth, seed)
    local function product(n)
        if n <= 1 then
            return 1
        end

        return n * product(n - 1)
    end

    local function sum(n, accumulator)
        if n <= 0 then
            return accumulator
        end

        return sum(n - 1, accumulator + n)
    end

    return product(depth), sum(depth, seed)
end
