local calc = require("mathlib")

return function(n, text)
    local result = calc(n)
    return result, text .. ":" .. tostring(result)
end
