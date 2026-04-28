local function setPlayerScale(data)
    local player = data.player
    local scale  = data.scale

    if player and player:isValid() then
        player:setScale(scale)
    end
end

return {
    eventHandlers = {
        FPV_SetPlayerScale = setPlayerScale,
    }
}