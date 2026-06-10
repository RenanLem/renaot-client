-- RenaOT Quick Loot
-- One-toggle auto-loot: when a monster dies within range, opens the corpse.
-- The Tibia client will trigger its native loot flow on the opened container.

local LOOT_RANGE = 3      -- tiles around the player
local LOOT_DELAY_MS = 250 -- wait for corpse to appear on tile
local TICK_COOLDOWN_MS = 250

local panel = nil
local enabled = false
local lastLootAt = 0
local pending = {}

local function inRange(pos)
  local player = g_game.getLocalPlayer()
  if not player then return false end
  local pp = player:getPosition()
  if not pp or not pos or pp.z ~= pos.z then return false end
  return math.abs(pp.x - pos.x) <= LOOT_RANGE and math.abs(pp.y - pos.y) <= LOOT_RANGE
end

local function lootAt(pos)
  if not g_game.isOnline() then return end
  if g_clock.millis() - lastLootAt < TICK_COOLDOWN_MS then return end

  local tile = g_map.getTile(pos)
  if not tile then return end

  -- Top movable thing on the tile is the freshly-spawned corpse in nearly all cases.
  local thing = tile:getTopMoveThing()
  if not thing or not thing:isItem() then return end
  if not thing:isContainer() then return end

  lastLootAt = g_clock.millis()
  g_game.open(thing)
end

local function onCreatureDisappear(creature)
  if not enabled then return end
  if not creature or not creature:isMonster() then return end
  local pos = creature:getPosition()
  if not pos or not inRange(pos) then return end

  local key = string.format('%d:%d:%d:%d', pos.x, pos.y, pos.z, g_clock.millis())
  if pending[key] then return end
  pending[key] = true

  scheduleEvent(function()
    pending[key] = nil
    lootAt(pos)
  end, LOOT_DELAY_MS)
end

local function updateUI()
  if not panel then return end
  local btn = panel:recursiveGetChildById('toggle')
  if not btn then return end
  if enabled then
    btn:setText('QUICK-LOOT: ON')
    btn:setColor('#80ff80ff')
  else
    btn:setText('QUICK-LOOT: OFF')
    btn:setColor('#ff7070ff')
  end
end

local function onToggle()
  enabled = not enabled
  updateUI()
end

local function ensurePanel()
  if panel then return end
  local rightPanel = modules.game_interface and modules.game_interface.getRightPanel and modules.game_interface.getRightPanel() or nil
  if not rightPanel then return end
  panel = g_ui.createWidget('QuickLootPanel', rightPanel)
  panel:setup()
  local btn = panel:recursiveGetChildById('toggle')
  if btn then btn.onClick = onToggle end
end

local function onLogin()
  ensurePanel()
  if panel then panel:show() end
  updateUI()
end

local function onLogout()
  enabled = false
  pending = {}
  if panel then panel:hide() end
end

function init()
  g_logger.info('[renaot_quickloot] init()')
  g_ui.importStyle('quickloot.otui')
  connect(g_game, {
    onGameStart = onLogin,
    onGameEnd   = onLogout,
  })
  connect(Creature, {
    onDisappear = onCreatureDisappear,
  })
  if g_game.isOnline() then onLogin() end
end

function terminate()
  disconnect(g_game, {
    onGameStart = onLogin,
    onGameEnd   = onLogout,
  })
  disconnect(Creature, {
    onDisappear = onCreatureDisappear,
  })
  if panel then panel:destroy(); panel = nil end
end
