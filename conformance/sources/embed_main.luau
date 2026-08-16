local run = require("lib")
local protoIdentity = require("proto_identity")
local userdataHooks = require("userdata_hooks")

return function(value, text)
    local number, resultText = run(value, text)
    local hooked = userdataHooks(embed.vec2(value))
    local length = #text
    return number + protoIdentity(value % 2 ~= 0, value, length) + hooked, resultText
end
