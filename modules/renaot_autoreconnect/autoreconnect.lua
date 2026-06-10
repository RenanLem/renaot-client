-- RenaOT Auto-Reconnect
-- Enables the built-in CharacterList autoReconnect by default and adds:
--  - retry with exponential backoff (2s, 4s, 8s, 15s, 30s, 30s, ...)
--  - max attempts cap (10) before giving up
--  - on-screen status label so the player sees what is happening

local statusLabel = nil
local retryEvent = nil
local attemptCount = 0
local origExecute = nil

local MAX_ATTEMPTS = 10
local DELAYS = { 2000, 4000, 8000, 15000, 30000 }

local function delayFor(n)
  return DELAYS[n] or 30000
end

local function ensureLabel()
  if statusLabel then return end
  statusLabel = g_ui.createWidget('ReconnectStatus', rootWidget)
end

local function setStatus(text)
  ensureLabel()
  if not statusLabel then return end
  statusLabel:setText(text)
  statusLabel:show()
  statusLabel:raise()
end

local function hideStatus()
  if statusLabel then statusLabel:hide() end
end

local function clearRetry()
  if retryEvent then
    removeEvent(retryEvent)
    retryEvent = nil
  end
end

local function tryReconnect()
  retryEvent = nil

  if g_game.isOnline() then
    attemptCount = 0
    hideStatus()
    return
  end

  if not g_settings.getBoolean('autoReconnect') then
    hideStatus()
    return
  end

  attemptCount = attemptCount + 1
  if attemptCount > MAX_ATTEMPTS then
    setStatus(string.format('Auto-reconnect: gave up after %d tries', MAX_ATTEMPTS))
    return
  end

  setStatus(string.format('Reconnecting... (attempt %d/%d)', attemptCount, MAX_ATTEMPTS))

  local cl = modules.client_entergame and modules.client_entergame.CharacterList
  if cl and cl.doLogin then
    -- doLogin is async; if it fails we'll see another onGameEnd / errorBox.
    local ok, err = pcall(cl.doLogin)
    if not ok then
      g_logger.warning('[renaot_autoreconnect] doLogin error: ' .. tostring(err))
    end
  end

  -- Schedule the next attempt as a fallback if the login does not progress.
  clearRetry()
  retryEvent = scheduleEvent(tryReconnect, delayFor(attemptCount))
end

local function onGameStart()
  attemptCount = 0
  clearRetry()
  hideStatus()
end

local function onGameEnd()
  if not g_settings.getBoolean('autoReconnect') then return end
  clearRetry()
  retryEvent = scheduleEvent(tryReconnect, delayFor(attemptCount + 1))
end

function init()
  g_ui.importStyle('autoreconnect.otui')

  -- Default to ON unless the user has explicitly turned it off.
  if g_settings.setDefault then
    g_settings.setDefault('autoReconnect', true)
  elseif g_settings.get('autoReconnect') == nil or g_settings.get('autoReconnect') == '' then
    g_settings.set('autoReconnect', true)
  end

  -- Hook the original CharacterList.executeAutoReconnect so the built-in
  -- button keeps working but our retry logic takes over.
  if rawget(_G, 'executeAutoReconnect') then
    origExecute = _G.executeAutoReconnect
    _G.executeAutoReconnect = function()
      tryReconnect()
    end
  end

  connect(g_game, {
    onGameStart = onGameStart,
    onGameEnd   = onGameEnd,
  })
end

function terminate()
  clearRetry()
  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd   = onGameEnd,
  })
  if origExecute and rawget(_G, 'executeAutoReconnect') then
    _G.executeAutoReconnect = origExecute
    origExecute = nil
  end
  if statusLabel then
    statusLabel:destroy()
    statusLabel = nil
  end
end
