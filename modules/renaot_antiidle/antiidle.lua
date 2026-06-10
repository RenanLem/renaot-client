-- RenaOT Anti-Idle
-- Rotates the character periodically so the server's idle timer never fires.
-- Uses g_game.turn which does NOT move the character — pure rotation packet.

local INTERVAL_MS = 8 * 60 * 1000 -- 8 minutes (Tibia default idle-kick is ~14m)
local DIRS = { 0, 1, 2, 3 } -- North, East, South, West

local panel = nil
local enabled = false
local tickEvent = nil
local nextFireAt = 0
local dirIdx = 1

local function fire()
  if not g_game.isOnline() then return end
  local player = g_game.getLocalPlayer()
  if not player then return end

  local dir = DIRS[dirIdx]
  dirIdx = (dirIdx % #DIRS) + 1
  g_game.turn(dir)
end

local function updateUI()
  if not panel then return end
  local toggle = panel:recursiveGetChildById('toggle')
  local status = panel:recursiveGetChildById('status')
  if toggle then
    if enabled then
      toggle:setText('ANTI-IDLE: ON')
      toggle:setColor('#80ff80ff')
    else
      toggle:setText('ANTI-IDLE: OFF')
      toggle:setColor('#ff7070ff')
    end
  end
  if status then
    if enabled and nextFireAt > 0 then
      local remain = math.max(0, nextFireAt - g_clock.millis())
      status:setText(string.format('next turn: %ds', math.floor(remain / 1000)))
    else
      status:setText('--')
    end
  end
end

local function loop()
  tickEvent = nil
  if not enabled then return end
  if g_clock.millis() >= nextFireAt then
    fire()
    nextFireAt = g_clock.millis() + INTERVAL_MS
  end
  updateUI()
  tickEvent = scheduleEvent(loop, 1000)
end

local function startLoop()
  if tickEvent then return end
  nextFireAt = g_clock.millis() + INTERVAL_MS
  loop()
end

local function stopLoop()
  if tickEvent then removeEvent(tickEvent); tickEvent = nil end
  nextFireAt = 0
end

local function onToggle()
  enabled = not enabled
  if enabled then startLoop() else stopLoop() end
  updateUI()
end

local function ensurePanel()
  if panel then return end
  local rightPanel = modules.game_interface and modules.game_interface.getRightPanel and modules.game_interface.getRightPanel() or nil
  if not rightPanel then return end
  panel = g_ui.createWidget('AntiIdlePanel', rightPanel)
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
  stopLoop()
  if panel then panel:hide() end
end

function init()
  g_logger.info('[renaot_antiidle] init()')
  g_ui.importStyle('antiidle.otui')
  connect(g_game, {
    onGameStart = onLogin,
    onGameEnd   = onLogout,
  })
  if g_game.isOnline() then onLogin() end
end

function terminate()
  stopLoop()
  disconnect(g_game, {
    onGameStart = onLogin,
    onGameEnd   = onLogout,
  })
  if panel then panel:destroy(); panel = nil end
end
