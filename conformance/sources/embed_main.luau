local run = require("lib")
local protoIdentity = require("proto_identity")

return function(value, text)
    local number, resultText = run(value, text)
    return number + protoIdentity(value % 2 ~= 0, value, #text), resultText
end
