local SURFACE_Z = 7
local controller = Controller:new()

local function applyLight(z)
    local mapPanel = modules.game_interface.getMapPanel()
    if not mapPanel then return end

    if z > SURFACE_Z then
        mapPanel:setMinimumAmbientLight(1.0)
    else
        local userValue = modules.client_options.getOption('ambientLight') or 0
        mapPanel:setMinimumAmbientLight(userValue / 100)
    end
end

local function onPositionChange(_, newPos, oldPos)
    if not newPos then return end
    if oldPos and oldPos.z == newPos.z then return end
    applyLight(newPos.z)
end

function controller:onGameStart()
    controller:registerEvents(LocalPlayer, { onPositionChange = onPositionChange })

    local player = g_game.getLocalPlayer()
    if player then applyLight(player:getPosition().z) end
end

function controller:onGameEnd()
    local mapPanel = modules.game_interface.getMapPanel()
    if mapPanel then
        local userValue = modules.client_options.getOption('ambientLight') or 0
        mapPanel:setMinimumAmbientLight(userValue / 100)
    end
end

function init()
    controller:init()
end

function terminate()
    controller:terminate()
end
