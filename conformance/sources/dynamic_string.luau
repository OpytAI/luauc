return function(a,b,c)
    local joined = a .. b .. c
    return function()
        return joined, #joined, joined == a
    end
end
