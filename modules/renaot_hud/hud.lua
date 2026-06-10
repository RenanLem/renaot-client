-- RenaOT Compact Session HUD
-- Shows session online time, XP/h (rolling 5-min window), kills, ETA to next level.

local WINDOW_MS = 5 * 60 * 1000  -- rolling XP-rate window
local TICK_MS = 1000

local panel = nil
local tickEvent = nil
local sessionStart = 0
local startExp = 0
local kills = 0
local samples = {} -- list of {tMs, exp}

local function expForLevel(level)
  return math.floor((50 * level * level * level) / 3 - 100 * level * level + (850 * level) / 3 - 200)
end

local function fmtDuration(ms)
  local s = math.max(0, math.floor(ms / 1000))
  local h = math.floor(s / 3600); s = s - h * 3600
  local m = math.floor(s / 60);   s = s - m * 60
  return string.format('%02d:%02d:%02d', h, m, s)
end

local function fmtNumber(n)
  if not n then return '--' end
  if n >= 1e9 then return string.format('%.2fB', n / 1e9) end
  if n >= 1e6 then return string.format('%.2fM', n / 1e6) end
  if n >= 1e3 then return string.format('%.1fK', n / 1e3) end
  return tostring(math.floor(n))
end

local function pushSample(tMs, exp)
  samples[#samples + 1] = { t = tMs, e = exp }
  -- drop samples older than the window
  local cutoff = tMs - WINDOW_MS
  while samples[1] and samples[1].t < cutoff do
    table.remove(samples, 1)
  end
end

local function computeXpPerHour()
  if #samples < 2 then return 0 end
  local first, last = samples[1], samples[#samples]
  local dt = last.t - first.t
  if dt <= 0 then return 0 end
  local de = last.e - first.e
  return de * 3600000 / dt
end

local function refresh()
  if not panel then return end
  local player = g_game.getLocalPlayer()
  if not player then return end

  local now = g_clock.millis()
  local exp = player:getExperience()
  pushSample(now, exp)

  local online = panel:recursiveGetChildById('online')
  local xph    = panel:recursiveGetChildById('xph')
  local killsW = panel:recursiveGetChildById('kills')
  local etaW   = panel:recursiveGetChildById('eta')
  local gainedW = panel:recursiveGetChildById('gained')

  if online then online:setText('Online: ' .. fmtDuration(now - sessionStart)) end

  local rate = computeXpPerHour()
  if xph then xph:setText('XP/h: ' .. fmtNumber(rate)) end

  if killsW then killsW:setText('Kills: ' .. tostring(kills)) end

  if etaW then
    local level = player:getLevel()
    local need = expForLevel(level + 1) - exp
    if need <= 0 then
      etaW:setText('Next level: ready!')
    elseif rate > 0 then
      local etaMs = (need / rate) * 3600000
      etaW:setText('Next lvl: ' .. fmtDuration(etaMs) .. ' (' .. fmtNumber(need) .. ')')
    else
      etaW:setText('Next lvl: ' .. fmtNumber(need) .. ' exp')
    end
  end

  if gainedW then gainedW:setText('XP gained: ' .. fmtNumber(exp - startExp)) end
end

local function loop()
  tickEvent = nil
  if not g_game.isOnline() then return end
  refresh()
  tickEvent = scheduleEvent(loop, TICK_MS)
end

local function startLoop()
  if tickEvent then return end
  loop()
end

local function stopLoop()
  if tickEvent then removeEvent(tickEvent); tickEvent = nil end
end

local function ensurePanel()
  if panel then return end
  local rightPanel = modules.game_interface and modules.game_interface.getRightPanel and modules.game_interface.getRightPanel() or nil
  if not rightPanel then return end
  panel = g_ui.createWidget('SessionHudPanel', rightPanel)
  panel:setup()
end

local function onCreatureDisappear(creature)
  if not creature or not creature:isMonster() then return end
  if not g_game.isOnline() then return end
  local player = g_game.getLocalPlayer()
  if not player then return end
  local pp = player:getPosition()
  local cp = creature:getPosition()
  if not pp or not cp or pp.z ~= cp.z then return end
  if math.abs(pp.x - cp.x) > 7 or math.abs(pp.y - cp.y) > 5 then return end
  kills = kills + 1
end

local function onLogin()
  ensurePanel()
  if panel then panel:show() end
  sessionStart = g_clock.millis()
  kills = 0
  samples = {}
  local player = g_game.getLocalPlayer()
  startExp = player and player:getExperience() or 0
  startLoop()
end

local function onLogout()
  stopLoop()
  if panel then panel:hide() end
end

function init()
  g_logger.info('[renaot_hud] init()')
  g_ui.importStyle('hud.otui')
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
  stopLoop()
  disconnect(g_game, {
    onGameStart = onLogin,
    onGameEnd   = onLogout,
  })
  disconnect(Creature, {
    onDisappear = onCreatureDisappear,
  })
  if panel then panel:destroy(); panel = nil end
end
