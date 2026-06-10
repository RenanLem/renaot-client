-- =============================================================================
-- RenaOT RTCaster — unified client-side bot (Healing / Tools / Shooter)
-- Replaces vBot. Three tabs. Single tick loop driving all features.
-- =============================================================================

-- Constants ------------------------------------------------------------------

local NUM_SHOOTER_SLOTS  = 5
local NUM_HEAL_SPELL     = 3
local NUM_HP_POTION      = 3
local NUM_MANA_POTION    = 3

-- Selectable potion lists, mirroring data/items/items.xml from Canary.
-- First entry (id 0) is "none" so a row can be cleared without losing the slot.
local HP_POTIONS = {
  { id = 0,     name = '-- none --' },
  { id = 7876,  name = 'Small Health Potion' },
  { id = 266,   name = 'Health Potion' },
  { id = 236,   name = 'Strong Health Potion' },
  { id = 239,   name = 'Great Health Potion' },
  { id = 7643,  name = 'Ultimate Health Potion' },
  { id = 23375, name = 'Supreme Health Potion' },
  { id = 7642,  name = 'Great Spirit Potion' },
  { id = 23374, name = 'Ultimate Spirit Potion' },
}

local MANA_POTIONS = {
  { id = 0,     name = '-- none --' },
  { id = 268,   name = 'Mana Potion' },
  { id = 237,   name = 'Strong Mana Potion' },
  { id = 238,   name = 'Great Mana Potion' },
  { id = 23373, name = 'Ultimate Mana Potion' },
  { id = 7642,  name = 'Great Spirit Potion' },
  { id = 23374, name = 'Ultimate Spirit Potion' },
}
local TICK_MS            = 150
local CAST_FAILSAFE_MS   = 180     -- min gap between any two casts client-side
local SCAN_RANGE_X       = 7
local SCAN_RANGE_Y       = 5
local SETTINGS_KEY       = 'renaot_rtcaster'

local UTITO_WORDS        = 'utito tempo'
local UTITO_MANA         = 290
-- Canary sends vocation clientid (not the internal server id).
-- Knight clientid=1, Elite Knight clientid=11 (per data/XML/vocations.xml).
local KNIGHT_VOCS        = { [1] = true, [11] = true }

local CHANGE_GOLD_INTERVAL_MS = 30000
local AUTO_EAT_INTERVAL_MS    = 5000   -- check every 5s; only eats if hungry state
local EXERCISE_INTERVAL_MS    = 2000
local RECONNECT_DELAY_MS      = 5000

-- Common food item ids (used in order)
local FOOD_IDS = { 3582, 3577, 3578, 3600, 3601, 3607, 3589, 3725, 3585 }

-- Money item ids
local GOLD_COIN     = 3031
local PLATINUM_COIN = 3035
local CRYSTAL_COIN  = 3043

-- State ----------------------------------------------------------------------

local state = {
  -- Shooter
  presets = nil,
  currentPreset = 'Default',
  shooterEnabled = false,
  autoTarget = false,
  targetStrategy = 'nearest',   -- 'nearest' | 'farthest' | 'most_hp' | 'least_hp'
  autoUtito = false,
  hotkeys = { shooter = nil, autoTarget = nil, utito = nil },

  -- Healing
  healEnabled     = false,
  healSpells      = nil,    -- 3 slots of {spell, hpPct, manaPct}
  healHpPotions   = nil,    -- 3 slots of {itemId, hpPct}    — fires when HP <= hpPct
  healManaPotions = nil,    -- 3 slots of {itemId, manaPct}  — fires when mana% <= manaPct

  -- Tools
  manaTrain     = { enabled = false, spell = '', manaPct = 80 },
  autoHaste     = { enabled = false, pz = false, spell = 'utani hur' },
  exercise      = { enabled = false, itemId = '28552' },
  changeGold    = false,
  autoEat       = false,
  autoReconnect = false,

  -- Stats
  stats = { total = 0, perSpell = {}, perItem = {} },
}

-- Runtime (not persisted) ----------------------------------------------------

local window      = nil
local miniPanel   = nil
local statsWin    = nil
local captureWin  = nil
local tickEvent   = nil
local reconnectEv = nil
local lastCastAt  = 0
local lastChangeGoldAt = 0
local lastAutoEatAt    = 0
local lastExerciseAt   = 0
local lastPotionAt     = 0
local boundKeys   = {}
local isRefreshing = false
local comboCursor  = 1
local activeTab    = 'shooter'   -- 'healing' | 'tools' | 'shooter'
local manualLogout = false       -- set when user logs out on purpose, to skip auto-reconnect

-- Cooldown tracking (live, not persisted) ------------------------------------

local spellCdExpire = {}     -- [iconId]  = millis when cooldown ends
local groupCdExpire = {}     -- [groupId] = millis when cooldown ends

-- Forward decls --------------------------------------------------------------

local refreshAll, refreshStatus, refreshPresetCombo
local refreshShooterSlots, refreshHealRows, refreshToolsFields, refreshKeyLabels
local refreshUtitoStatus, switchTab
local openWindow, closeWindow

-- =============================================================================
-- Persistence
-- =============================================================================

local function newShooterPreset()
  local slots = {}
  for i = 1, NUM_SHOOTER_SLOTS do
    slots[i] = { spell = '', manaPct = 80, creatures = 1, priority = i }
  end
  return { slots = slots }
end

local function defaultHealSpells()
  local t = {}
  for i = 1, NUM_HEAL_SPELL do
    t[i] = { spell = '', hpPct = 70, manaPct = 30 }
  end
  return t
end

local function defaultHpPotions()
  local t = {}
  for i = 1, NUM_HP_POTION do
    t[i] = { itemId = 0, hpPct = 50 }
  end
  return t
end

local function defaultManaPotions()
  local t = {}
  for i = 1, NUM_MANA_POTION do
    t[i] = { itemId = 0, manaPct = 30 }
  end
  return t
end

-- Re-key string-indexed slots back to integers; fill in missing.
local function normalizeArrayTable(raw, count, defaultFn)
  raw = raw or {}
  local fixed = {}
  for k, v in pairs(raw) do
    local ik = tonumber(k)
    if ik and ik >= 1 and ik <= count and type(v) == 'table' then
      fixed[ik] = v
    end
  end
  for i = 1, count do
    if not fixed[i] then
      fixed[i] = defaultFn(i)
    end
  end
  return fixed
end

local function normalizeShooterPresets()
  if type(state.presets) ~= 'table' then state.presets = {} end
  for _, preset in pairs(state.presets) do
    preset.slots = normalizeArrayTable(preset.slots, NUM_SHOOTER_SLOTS, function(i)
      return { spell = '', manaPct = 80, creatures = 1, priority = i }
    end)
    for i, s in ipairs(preset.slots) do
      s.spell     = s.spell or ''
      s.manaPct   = tonumber(s.manaPct)   or 80
      s.creatures = tonumber(s.creatures) or 1
      s.priority  = tonumber(s.priority)  or i
    end
  end
end

local function ensureDefaults()
  if not state.presets or not next(state.presets) then
    state.presets = { Default = newShooterPreset() }
    state.currentPreset = 'Default'
  end
  normalizeShooterPresets()
  if not state.presets[state.currentPreset] then
    state.currentPreset = next(state.presets)
  end

  state.healSpells = normalizeArrayTable(state.healSpells, NUM_HEAL_SPELL, function(i)
    return { spell = '', hpPct = 70, manaPct = 30 }
  end)
  for _, s in ipairs(state.healSpells) do
    s.spell   = s.spell or ''
    s.hpPct   = tonumber(s.hpPct)   or 70
    s.manaPct = tonumber(s.manaPct) or 30
  end

  state.healHpPotions = normalizeArrayTable(state.healHpPotions, NUM_HP_POTION, function(i)
    return { itemId = 0, hpPct = 50 }
  end)
  for _, s in ipairs(state.healHpPotions) do
    s.itemId = tonumber(s.itemId) or 0
    s.hpPct  = tonumber(s.hpPct)  or 50
  end

  state.healManaPotions = normalizeArrayTable(state.healManaPotions, NUM_MANA_POTION, function(i)
    return { itemId = 0, manaPct = 30 }
  end)
  for _, s in ipairs(state.healManaPotions) do
    s.itemId  = tonumber(s.itemId)  or 0
    s.manaPct = tonumber(s.manaPct) or 30
  end

  state.manaTrain     = state.manaTrain     or { enabled = false, spell = '', manaPct = 80 }
  state.autoHaste     = state.autoHaste     or { enabled = false, pz = false, spell = 'utani hur' }
  state.exercise      = state.exercise      or { enabled = false, itemId = '28552' }
  state.hotkeys       = state.hotkeys       or { shooter = nil, autoTarget = nil }
  state.stats         = state.stats         or { total = 0, perSpell = {}, perItem = {} }
end

local function saveConfig()
  if isRefreshing then return end
  g_settings.setNode(SETTINGS_KEY, {
    presets        = state.presets,
    currentPreset  = state.currentPreset,
    autoTarget     = state.autoTarget,
    targetStrategy = state.targetStrategy,
    autoUtito      = state.autoUtito,
    hotkeys       = state.hotkeys,
    stats         = state.stats,
    healSpells      = state.healSpells,
    healHpPotions   = state.healHpPotions,
    healManaPotions = state.healManaPotions,
    manaTrain     = state.manaTrain,
    autoHaste     = state.autoHaste,
    exercise      = state.exercise,
    changeGold    = state.changeGold,
    autoEat       = state.autoEat,
    autoReconnect = state.autoReconnect,
    activeTab     = activeTab,
  })
  g_settings.save()
end

local function loadConfig()
  local data = g_settings.getNode(SETTINGS_KEY)
  if type(data) == 'table' then
    state.presets        = data.presets        or nil
    state.currentPreset  = data.currentPreset  or 'Default'
    state.autoTarget     = data.autoTarget     and true or false
    state.targetStrategy = data.targetStrategy or 'nearest'
    state.autoUtito      = data.autoUtito      and true or false
    state.hotkeys       = data.hotkeys       or { shooter = nil, autoTarget = nil }
    state.stats         = data.stats         or { total = 0, perSpell = {}, perItem = {} }
    state.healSpells      = data.healSpells      or nil
    state.healHpPotions   = data.healHpPotions   or nil
    state.healManaPotions = data.healManaPotions or nil
    state.manaTrain     = data.manaTrain     or nil
    state.autoHaste     = data.autoHaste     or nil
    state.exercise      = data.exercise      or nil
    state.changeGold    = data.changeGold    and true or false
    state.autoEat       = data.autoEat       and true or false
    state.autoReconnect = data.autoReconnect and true or false
    activeTab           = data.activeTab     or 'shooter'
  end
  ensureDefaults()
end

local function currentPresetData()
  ensureDefaults()
  return state.presets[state.currentPreset]
end

-- =============================================================================
-- Spell DB + cooldown tracking
-- =============================================================================

local function lookupSpell(words)
  if not words or words == '' or not Spells or not Spells.getSpellByWords then
    return nil
  end
  local spell = Spells.getSpellByWords(words)
  return spell
end

local function isSpellReady(spell, now)
  if not spell then return true end
  now = now or g_clock.millis()
  if spellCdExpire[spell.id] and spellCdExpire[spell.id] > now then
    return false
  end
  if type(spell.group) == 'table' then
    for groupId, _ in pairs(spell.group) do
      if groupCdExpire[groupId] and groupCdExpire[groupId] > now then
        return false
      end
    end
  end
  return true
end

local function recordCastCooldown(spell, now)
  if not spell then return end
  now = now or g_clock.millis()
  if spell.exhaustion and spell.exhaustion > 0 then
    spellCdExpire[spell.id] = math.max(spellCdExpire[spell.id] or 0, now + spell.exhaustion)
  end
  if type(spell.group) == 'table' then
    for groupId, dur in pairs(spell.group) do
      if dur and dur > 0 then
        groupCdExpire[groupId] = math.max(groupCdExpire[groupId] or 0, now + dur)
      end
    end
  end
end

local function onSpellCooldownEvent(iconId, duration)
  spellCdExpire[iconId] = g_clock.millis() + (duration or 0)
end

local function onSpellGroupCooldownEvent(groupId, duration)
  groupCdExpire[groupId] = g_clock.millis() + (duration or 0)
end

-- =============================================================================
-- Cast helpers
-- =============================================================================

local function recordCastStat(spellWords)
  state.stats.total = (state.stats.total or 0) + 1
  state.stats.perSpell[spellWords] = (state.stats.perSpell[spellWords] or 0) + 1
end

local function recordItemStat(itemId)
  state.stats.perItem = state.stats.perItem or {}
  state.stats.perItem[tostring(itemId)] = (state.stats.perItem[tostring(itemId)] or 0) + 1
end

local function castSpell(words, now)
  local meta = lookupSpell(words)
  g_game.talk(words)
  recordCastCooldown(meta, now)
  lastCastAt = now
  recordCastStat(words)
  return true
end

local function tryCastSpell(words, now)
  if not words or words == '' then return false end
  if (now - lastCastAt) < CAST_FAILSAFE_MS then return false end
  local meta = lookupSpell(words)
  if not isSpellReady(meta, now) then return false end
  return castSpell(words, now)
end

local function useItemOnSelf(itemId)
  local id = tonumber(itemId)
  if not id or id <= 0 then return false end
  local player = g_game.getLocalPlayer()
  if not player then return false end
  g_game.useInventoryItemWith(id, player)
  recordItemStat(id)
  return true
end

local function useItemSelf(itemId)
  local id = tonumber(itemId)
  if not id or id <= 0 then return false end
  g_game.useInventoryItem(id)
  recordItemStat(id)
  return true
end

-- =============================================================================
-- Combat scanning
-- =============================================================================

local function countNearbyMonsters()
  local player = g_game.getLocalPlayer()
  if not player then return 0 end
  local pos = player:getPosition()
  if not pos then return 0 end

  local spectators = g_map.getSpectators(pos, false) or {}
  local count = 0
  for _, c in ipairs(spectators) do
    if c and not c:isLocalPlayer() and c:isMonster() and not c:isDead() then
      local cpos = c:getPosition()
      if cpos and cpos.z == pos.z then
        if math.abs(cpos.x - pos.x) <= SCAN_RANGE_X
           and math.abs(cpos.y - pos.y) <= SCAN_RANGE_Y then
          count = count + 1
        end
      end
    end
  end
  return count
end

local function creatureHp(c)
  if c.getHealthPercent then return c:getHealthPercent() or 0 end
  return 0
end

-- Each strategy = { filter, score }. score returns a number to MAXIMISE.
-- filter returns true if the candidate is eligible. nil filter = no extra check.
-- "*_box" strategies only consider creatures adjacent (≤1 SQM) to the player.
local function inBox(dx, dy) return math.abs(dx) <= 1 and math.abs(dy) <= 1 end

local TARGET_STRATEGIES = {
  nearest      = { filter = nil,    score = function(c, dx, dy) return -math.max(math.abs(dx), math.abs(dy)) end },
  farthest     = { filter = nil,    score = function(c, dx, dy) return  math.max(math.abs(dx), math.abs(dy)) end },
  most_hp      = { filter = nil,    score = function(c)         return  creatureHp(c) end },
  least_hp     = { filter = nil,    score = function(c)         return -creatureHp(c) end },
  most_hp_box  = { filter = inBox,  score = function(c)         return  creatureHp(c) end },
  least_hp_box = { filter = inBox,  score = function(c)         return -creatureHp(c) end },
}

-- Hysteresis: keep the current target unless a new one beats its score by this
-- much. Prevents thrashing when two mobs have similar HP and one tick swaps
-- them. HP-based strategies use 5 (5% HP); distance ones don't need it.
local STRATEGY_MARGIN = {
  most_hp      = 5,
  least_hp     = 5,
  most_hp_box  = 5,
  least_hp_box = 5,
}

-- Returns the score for `creature` under `strategy`, or nil if it's not
-- eligible (dead, off-floor, out of range, fails strategy filter, etc).
local function scoreForStrategy(creature, strategy)
  if not creature or creature:isDead() or creature:isLocalPlayer() then return nil end
  if not creature:isMonster() then return nil end
  local player = g_game.getLocalPlayer()
  if not player then return nil end
  local pos  = player:getPosition()
  local cpos = creature:getPosition()
  if not pos or not cpos or pos.z ~= cpos.z then return nil end
  local dx, dy = cpos.x - pos.x, cpos.y - pos.y
  if math.abs(dx) > SCAN_RANGE_X or math.abs(dy) > SCAN_RANGE_Y then return nil end
  local strat = TARGET_STRATEGIES[strategy] or TARGET_STRATEGIES.nearest
  if strat.filter and not strat.filter(dx, dy) then return nil end
  return strat.score(creature, dx, dy)
end

local function pickTarget(strategy)
  local player = g_game.getLocalPlayer()
  if not player then return nil, -math.huge end
  local pos = player:getPosition()
  if not pos then return nil, -math.huge end

  local spectators = g_map.getSpectators(pos, false) or {}
  local best, bestScore = nil, -math.huge
  for _, c in ipairs(spectators) do
    local s = scoreForStrategy(c, strategy)
    if s and s > bestScore then bestScore = s; best = c end
  end
  return best, bestScore
end

local function ensureAttackTarget()
  if not state.autoTarget then return end
  local strategy = state.targetStrategy or 'nearest'
  local newTarget, newScore = pickTarget(strategy)
  if not newTarget then return end

  local current = g_game.getAttackingCreature()
  if current == newTarget then return end

  -- Hysteresis: if current target is still eligible, keep it unless the new
  -- candidate is meaningfully better (avoids HP-tick flicker).
  if current then
    local currentScore = scoreForStrategy(current, strategy)
    if currentScore then
      local margin = STRATEGY_MARGIN[strategy] or 0
      if (newScore - currentScore) < margin then
        return  -- not enough improvement; keep current
      end
    end
  end

  g_game.attack(newTarget)
end

local function isInPz(player)
  if not player or not player.hasState then return false end
  return player:hasState(PlayerStates.Pigeon)
end

local function detectVocation()
  local player = g_game.getLocalPlayer()
  if not player then return nil end
  return player:getVocation() or 0
end

-- =============================================================================
-- Healing logic
-- =============================================================================

local function tickHealing(player, now, hpPct, manaPct)
  if not state.healEnabled then return false end

  -- Spell heals: cast first slot whose HP threshold is met AND mana ≥ threshold.
  -- Slot order is evaluated top-to-bottom — put the strongest (lowest HP trigger)
  -- first if you want it to take priority during emergencies.
  for _, slot in ipairs(state.healSpells) do
    if slot.spell and slot.spell ~= ''
       and hpPct   <= (slot.hpPct   or 100)
       and manaPct >= (slot.manaPct or 0) then
      if tryCastSpell(slot.spell, now) then return true end
    end
  end

  -- HP potions: use first potion whose HP threshold is met
  if (now - lastPotionAt) >= 1000 then
    for _, slot in ipairs(state.healHpPotions) do
      if slot.itemId and slot.itemId > 0 and hpPct <= (slot.hpPct or 0) then
        if useItemOnSelf(slot.itemId) then
          lastPotionAt = now
          return true
        end
      end
    end
    -- Mana potions: use first potion whose mana% threshold is met
    for _, slot in ipairs(state.healManaPotions) do
      if slot.itemId and slot.itemId > 0 and manaPct <= (slot.manaPct or 0) then
        if useItemOnSelf(slot.itemId) then
          lastPotionAt = now
          return true
        end
      end
    end
  end

  return false
end

-- =============================================================================
-- Tools logic
-- =============================================================================

local function tryAutoHaste(player, now)
  local h = state.autoHaste
  if not h.enabled then return false end
  if not h.spell or h.spell == '' then return false end
  if player:hasState(PlayerStates.Haste) then return false end
  if isInPz(player) and not h.pz then return false end
  return tryCastSpell(h.spell, now)
end

local function tryManaTrain(player, now, manaPct)
  local m = state.manaTrain
  if not m.enabled then return false end
  if not m.spell or m.spell == '' then return false end
  if manaPct < (m.manaPct or 0) then return false end
  return tryCastSpell(m.spell, now)
end

local function tryExercise(player, now)
  if not state.exercise.enabled then return false end
  if (now - lastExerciseAt) < EXERCISE_INTERVAL_MS then return false end
  if useItemSelf(state.exercise.itemId) then
    lastExerciseAt = now
    return true
  end
  return false
end

local function tryAutoEat(player, now)
  if not state.autoEat then return false end
  if (now - lastAutoEatAt) < AUTO_EAT_INTERVAL_MS then return false end
  if not player:hasState(PlayerStates.Hungry) then return false end
  for _, foodId in ipairs(FOOD_IDS) do
    g_game.useInventoryItem(foodId)
  end
  lastAutoEatAt = now
  return true
end

local function tryChangeGold(player, now)
  if not state.changeGold then return false end
  if (now - lastChangeGoldAt) < CHANGE_GOLD_INTERVAL_MS then return false end
  -- Server-dependent: using a gold coin "of 100" stack triggers the server's
  -- change-money flow on Canary/OTServBR. We just send the use, server handles it.
  g_game.useInventoryItem(GOLD_COIN)
  g_game.useInventoryItem(PLATINUM_COIN)
  lastChangeGoldAt = now
  return true
end

local function tryAutoUtito(player, now, manaCur)
  if not state.autoUtito then return false end
  local voc = detectVocation()
  if not voc or not KNIGHT_VOCS[voc] then return false end
  if player:hasState(PlayerStates.PartyBuff) then return false end
  if manaCur < UTITO_MANA then return false end
  local spell = lookupSpell(UTITO_WORDS)
  if not isSpellReady(spell, now) then return false end
  return castSpell(UTITO_WORDS, now)
end

-- =============================================================================
-- Shooter (spell combo)
-- =============================================================================

local function tickShooter(player, now, manaPct)
  if not state.shooterEnabled then return false end

  ensureAttackTarget()

  local mobs = countNearbyMonsters()
  local p = currentPresetData()
  if not p then return false end

  local sorted = {}
  for _, slot in ipairs(p.slots) do
    if slot.spell and slot.spell ~= '' then
      table.insert(sorted, slot)
    end
  end
  if #sorted == 0 then return false end
  table.sort(sorted, function(a, b) return (a.priority or 99) < (b.priority or 99) end)

  if comboCursor < 1 or comboCursor > #sorted then comboCursor = 1 end
  for offset = 0, #sorted - 1 do
    local idx = ((comboCursor - 1 + offset) % #sorted) + 1
    local slot = sorted[idx]
    if manaPct >= (slot.manaPct or 0) and mobs >= (slot.creatures or 1) then
      local meta = lookupSpell(slot.spell)
      if isSpellReady(meta, now) then
        castSpell(slot.spell, now)
        comboCursor = (idx % #sorted) + 1
        return true
      end
    end
  end
  return false
end

-- =============================================================================
-- Main tick — drives all features
-- =============================================================================

local function anyFeatureActive()
  if state.shooterEnabled or state.autoUtito or state.healEnabled
     or state.autoEat or state.changeGold
     or (state.manaTrain    and state.manaTrain.enabled)
     or (state.autoHaste    and state.autoHaste.enabled)
     or (state.exercise     and state.exercise.enabled) then
    return true
  end
  return false
end

local function tick()
  if not g_game.isOnline() then return end
  local player = g_game.getLocalPlayer()
  if not player then return end

  local now     = g_clock.millis()
  local maxMana = player:getMaxMana() or 0
  local manaCur = player:getMana()    or 0
  local manaPct = (maxMana > 0) and math.floor(100 * manaCur / maxMana) or 0
  local maxHp   = player:getMaxHealth() or 0
  local hpCur   = player:getHealth()    or 0
  local hpPct   = (maxHp   > 0) and math.floor(100 * hpCur   / maxHp)   or 100

  -- Healing has the highest priority (don't die while bot-combat'ing)
  if tickHealing(player, now, hpPct, manaPct) then return end

  -- Buff / utility casts before damage rotation
  if tryAutoUtito(player, now, manaCur)    then return end
  if tryAutoHaste(player, now)              then return end

  -- Damage rotation
  if tickShooter(player, now, manaPct)      then return end

  -- Background utilities (don't compete with cast budget)
  tryAutoEat(player, now)
  tryChangeGold(player, now)
  tryExercise(player, now)

  -- Lowest priority — only trains mana if nothing else needed the slot
  tryManaTrain(player, now, manaPct)
end

local function startLoop()
  if tickEvent then return end
  local function loop()
    local ok, err = pcall(tick)
    if not ok then g_logger.error('[rtcaster] tick error: ' .. tostring(err)) end
    tickEvent = scheduleEvent(loop, TICK_MS)
  end
  loop()
end

local function stopLoop()
  if tickEvent then removeEvent(tickEvent); tickEvent = nil end
end

local function updateLoopState()
  if anyFeatureActive() then startLoop() else stopLoop() end
end

-- =============================================================================
-- Feature setters
-- =============================================================================

local function setShooterEnabled(v)
  state.shooterEnabled = v and true or false
  if state.shooterEnabled then comboCursor = 1 end
  updateLoopState(); refreshStatus(); saveConfig()
end

local function setAutoTarget(v)
  state.autoTarget = v and true or false
  refreshStatus(); saveConfig()
end

local function setAutoUtito(v)
  state.autoUtito = v and true or false
  updateLoopState(); refreshStatus(); refreshUtitoStatus(); saveConfig()
end

local function setHealEnabled(v)
  state.healEnabled = v and true or false
  updateLoopState(); refreshStatus(); saveConfig()
end

local function setToolFlag(name, v)
  if name == 'manaTrain'    then state.manaTrain.enabled    = v and true or false
  elseif name == 'autoHaste' then state.autoHaste.enabled    = v and true or false
  elseif name == 'autoHastePz' then state.autoHaste.pz       = v and true or false
  elseif name == 'exercise' then state.exercise.enabled     = v and true or false
  elseif name == 'changeGold'    then state.changeGold      = v and true or false
  elseif name == 'autoEat'       then state.autoEat         = v and true or false
  elseif name == 'autoReconnect' then state.autoReconnect   = v and true or false
  end
  updateLoopState(); refreshStatus(); saveConfig()
end

local function toggleShooter()    setShooterEnabled(not state.shooterEnabled) end
local function toggleAutoTarget() setAutoTarget(not state.autoTarget) end
local function toggleAutoUtito()  setAutoUtito(not state.autoUtito) end

-- =============================================================================
-- Hotkeys
-- =============================================================================

local function unbindAllHotkeys()
  for combo, cb in pairs(boundKeys) do
    if combo and cb then
      pcall(function() g_keyboard.unbindKeyPress(combo, cb) end)
    end
  end
  boundKeys = {}
end

local function bindHotkey(combo, callback)
  if not combo or combo == '' or not callback then return end
  g_keyboard.bindKeyPress(combo, callback)
  boundKeys[combo] = callback
end

local function rebindAllHotkeys()
  unbindAllHotkeys()
  local h = state.hotkeys or {}
  bindHotkey(h.shooter,    toggleShooter)
  bindHotkey(h.autoTarget, toggleAutoTarget)
  bindHotkey(h.utito,      toggleAutoUtito)
end

-- =============================================================================
-- Key capture dialog
-- =============================================================================

local function openKeyCapture(slotName)
  if captureWin then captureWin:destroy(); captureWin = nil end
  captureWin = g_ui.createWidget('RTCasterKeyCapture', rootWidget)
  captureWin:grabKeyboard()

  local preview = captureWin:getChildById('comboPreview')

  captureWin.onKeyDown = function(self, keyCode, modifiers)
    if keyCode == KeyEscape then
      self:destroy(); captureWin = nil; return true
    end
    local combo = determineKeyComboDesc(keyCode, modifiers)
    preview:setText(combo)
    state.hotkeys[slotName] = combo
    rebindAllHotkeys(); refreshKeyLabels(); saveConfig()
    scheduleEvent(function()
      if captureWin then captureWin:destroy(); captureWin = nil end
    end, 200)
    return true
  end

  captureWin:getChildById('cancelButton').onClick = function()
    captureWin:destroy(); captureWin = nil
  end
  captureWin:getChildById('clearButton').onClick = function()
    state.hotkeys[slotName] = nil
    rebindAllHotkeys(); refreshKeyLabels(); saveConfig()
    captureWin:destroy(); captureWin = nil
  end
end

-- =============================================================================
-- Stats window
-- =============================================================================

local function openStatsWindow()
  if statsWin then statsWin:destroy(); statsWin = nil end
  statsWin = g_ui.createWidget('RTCasterStatsWindow', rootWidget)
  local list = statsWin:getChildById('statsList')
  list:destroyChildren()

  local header = g_ui.createWidget('Label', list)
  header:setText(string.format('Total casts: %d', state.stats.total or 0))
  header:setColor('#ffd700')

  local rows = {}
  for spell, count in pairs(state.stats.perSpell or {}) do
    table.insert(rows, { name = spell, count = count })
  end
  table.sort(rows, function(a, b) return a.count > b.count end)
  for _, row in ipairs(rows) do
    local lbl = g_ui.createWidget('Label', list)
    lbl:setText(string.format('  %s — %d', row.name, row.count))
  end

  if next(state.stats.perItem or {}) then
    local sep = g_ui.createWidget('Label', list)
    sep:setText('Items used:')
    sep:setColor('#ffd700')
    local irows = {}
    for itemId, count in pairs(state.stats.perItem or {}) do
      table.insert(irows, { name = itemId, count = count })
    end
    table.sort(irows, function(a, b) return a.count > b.count end)
    for _, row in ipairs(irows) do
      local lbl = g_ui.createWidget('Label', list)
      lbl:setText(string.format('  item %s — %d', row.name, row.count))
    end
  end

  statsWin:getChildById('closeStats').onClick = function()
    statsWin:destroy(); statsWin = nil
  end
  statsWin:getChildById('resetStats').onClick = function()
    state.stats = { total = 0, perSpell = {}, perItem = {} }
    saveConfig(); openStatsWindow()
  end
end

-- =============================================================================
-- Tab switching
-- =============================================================================

switchTab = function(name)
  activeTab = name
  if not window then return end
  window:getChildById('panelHealing'):setVisible(name == 'healing')
  window:getChildById('panelTools'):setVisible(name == 'tools')
  window:getChildById('panelShooter'):setVisible(name == 'shooter')

  local function highlight(btn, on)
    if not btn then return end
    if on then
      btn:setColor('#ffd700')
    else
      btn:setColor('#c0c0c0')
    end
  end
  highlight(window:getChildById('tabHealing'), name == 'healing')
  highlight(window:getChildById('tabTools'),   name == 'tools')
  highlight(window:getChildById('tabShooter'), name == 'shooter')
  saveConfig()
end

-- =============================================================================
-- UI: Shooter tab rows
-- =============================================================================

local function buildShooterSlots()
  if not window then return end
  local panel = window:recursiveGetChildById('slotsPanel')
  if not panel then return end
  panel:destroyChildren()

  for i = 1, NUM_SHOOTER_SLOTS do
    local row = g_ui.createWidget('RTCasterSlotRow', panel)
    local spellEdit = row:getChildById('spell')
    local manaBox   = row:getChildById('mana')
    local mobsBox   = row:getChildById('creatures')
    local prioBox   = row:getChildById('priority')

    for pct = 100, 0, -5 do manaBox:addOption(pct .. '%', pct) end
    for n = 1, NUM_SHOOTER_SLOTS do
      mobsBox:addOption(n .. '+', n)
      prioBox:addOption(tostring(n), n)
    end

    row.spellEdit, row.manaBox, row.mobsBox, row.prioBox = spellEdit, manaBox, mobsBox, prioBox

    spellEdit.onTextChange = function(_, t)
      if isRefreshing then return end
      local p = currentPresetData(); if not p then return end
      p.slots[i].spell = t or ''; comboCursor = 1; saveConfig()
    end
    manaBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      local p = currentPresetData(); if not p then return end
      p.slots[i].manaPct = data; comboCursor = 1; saveConfig()
    end
    mobsBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      local p = currentPresetData(); if not p then return end
      p.slots[i].creatures = data; comboCursor = 1; saveConfig()
    end
    prioBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      local p = currentPresetData(); if not p then return end
      p.slots[i].priority = data; comboCursor = 1; saveConfig()
    end
  end
end

refreshShooterSlots = function()
  if not window then return end
  local panel = window:recursiveGetChildById('slotsPanel')
  if not panel then return end
  local p = currentPresetData(); if not p then return end
  isRefreshing = true
  for i, row in ipairs(panel:getChildren()) do
    local slot = p.slots[i] or { spell = '', manaPct = 80, creatures = 1, priority = i }
    row.spellEdit:setText(slot.spell or '')
    row.manaBox:setCurrentOptionByData(slot.manaPct or 80, true)
    row.mobsBox:setCurrentOptionByData(slot.creatures or 1, true)
    row.prioBox:setCurrentOptionByData(slot.priority or i, true)
  end
  isRefreshing = false
end

-- =============================================================================
-- UI: Healing tab rows
-- =============================================================================

local function buildPotionRows(panel, count, potionList, stateTable, fieldName)
  panel:destroyChildren()
  for i = 1, count do
    local row = g_ui.createWidget('RTCasterPotionRow', panel)
    local potionBox = row:getChildById('potionId')
    local thrBox    = row:getChildById('threshold')

    for _, p in ipairs(potionList) do potionBox:addOption(p.name, p.id) end
    for pct = 100, 0, -5 do thrBox:addOption(pct .. '%', pct) end

    row.potionBox, row.thrBox = potionBox, thrBox

    potionBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      stateTable[i].itemId = tonumber(data) or 0; saveConfig()
    end
    thrBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      stateTable[i][fieldName] = data; saveConfig()
    end
  end
end

local function buildHealRows()
  if not window then return end
  local sp  = window:recursiveGetChildById('healSpellSlots')
  local hpp = window:recursiveGetChildById('healHpPotionSlots')
  local mpp = window:recursiveGetChildById('healManaPotionSlots')
  if not sp or not hpp or not mpp then return end

  sp:destroyChildren()

  for i = 1, NUM_HEAL_SPELL do
    local row = g_ui.createWidget('RTCasterHealRow', sp)
    local spellEdit = row:getChildById('spell')
    local hpBox     = row:getChildById('hp')
    local manaBox   = row:getChildById('mana')
    for pct = 100, 0, -5 do
      hpBox:addOption(pct .. '%', pct)
      manaBox:addOption(pct .. '%', pct)
    end
    row.spellEdit, row.hpBox, row.manaBox = spellEdit, hpBox, manaBox
    spellEdit.onTextChange = function(_, t)
      if isRefreshing then return end
      state.healSpells[i].spell = t or ''; saveConfig()
    end
    hpBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      state.healSpells[i].hpPct = data; saveConfig()
    end
    manaBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      state.healSpells[i].manaPct = data; saveConfig()
    end
  end

  buildPotionRows(hpp, NUM_HP_POTION,   HP_POTIONS,   state.healHpPotions,   'hpPct')
  buildPotionRows(mpp, NUM_MANA_POTION, MANA_POTIONS, state.healManaPotions, 'manaPct')
end

refreshHealRows = function()
  if not window then return end
  local sp  = window:recursiveGetChildById('healSpellSlots')
  local hpp = window:recursiveGetChildById('healHpPotionSlots')
  local mpp = window:recursiveGetChildById('healManaPotionSlots')
  if not sp or not hpp or not mpp then return end

  isRefreshing = true
  for i, row in ipairs(sp:getChildren()) do
    local slot = state.healSpells[i] or { spell = '', hpPct = 70, manaPct = 30 }
    row.spellEdit:setText(slot.spell or '')
    row.hpBox:setCurrentOptionByData(slot.hpPct or 70, true)
    row.manaBox:setCurrentOptionByData(slot.manaPct or 30, true)
  end
  for i, row in ipairs(hpp:getChildren()) do
    local slot = state.healHpPotions[i] or { itemId = 0, hpPct = 50 }
    row.potionBox:setCurrentOptionByData(slot.itemId or 0, true)
    row.thrBox:setCurrentOptionByData(slot.hpPct or 50, true)
  end
  for i, row in ipairs(mpp:getChildren()) do
    local slot = state.healManaPotions[i] or { itemId = 0, manaPct = 30 }
    row.potionBox:setCurrentOptionByData(slot.itemId or 0, true)
    row.thrBox:setCurrentOptionByData(slot.manaPct or 30, true)
  end
  isRefreshing = false

  local cb = window:recursiveGetChildById('healEnabled')
  if cb then cb:setChecked(state.healEnabled) end
end

-- =============================================================================
-- UI: Tools tab fields
-- =============================================================================

local function attachToolsHandlers()
  if not window then return end

  local function set(id, getter, setter)
    local w = window:recursiveGetChildById(id)
    if w then setter(w, getter()) end
  end

  local mt = window:recursiveGetChildById('manaTrainEnable')
  mt.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('manaTrain', c) end end
  local mts = window:recursiveGetChildById('manaTrainSpell')
  mts.onTextChange = function(_, t) if not isRefreshing then state.manaTrain.spell = t or ''; saveConfig() end end
  local mtm = window:recursiveGetChildById('manaTrainMana')
  for pct = 100, 0, -5 do mtm:addOption(pct .. '%', pct) end
  mtm.onOptionChange = function(_, _, data) if not isRefreshing then state.manaTrain.manaPct = data; saveConfig() end end

  local ah = window:recursiveGetChildById('autoHasteEnable')
  ah.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('autoHaste', c) end end
  local ahpz = window:recursiveGetChildById('autoHastePz')
  ahpz.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('autoHastePz', c) end end
  local ahs = window:recursiveGetChildById('autoHasteSpell')
  ahs.onTextChange = function(_, t) if not isRefreshing then state.autoHaste.spell = t or ''; saveConfig() end end

  local ex = window:recursiveGetChildById('exerciseEnable')
  ex.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('exercise', c) end end
  local exi = window:recursiveGetChildById('exerciseItemId')
  exi.onTextChange = function(_, t) if not isRefreshing then state.exercise.itemId = t or ''; saveConfig() end end

  window:recursiveGetChildById('changeGoldEnable').onCheckChange     = function(_, c) if not isRefreshing then setToolFlag('changeGold', c) end end
  window:recursiveGetChildById('autoEatEnable').onCheckChange        = function(_, c) if not isRefreshing then setToolFlag('autoEat', c) end end
  window:recursiveGetChildById('autoReconnectEnable').onCheckChange  = function(_, c) if not isRefreshing then setToolFlag('autoReconnect', c) end end
end

refreshToolsFields = function()
  if not window then return end
  isRefreshing = true

  window:recursiveGetChildById('manaTrainEnable'):setChecked(state.manaTrain.enabled)
  window:recursiveGetChildById('manaTrainSpell'):setText(state.manaTrain.spell or '')
  window:recursiveGetChildById('manaTrainMana'):setCurrentOptionByData(state.manaTrain.manaPct or 80, true)

  window:recursiveGetChildById('autoHasteEnable'):setChecked(state.autoHaste.enabled)
  window:recursiveGetChildById('autoHastePz'):setChecked(state.autoHaste.pz)
  window:recursiveGetChildById('autoHasteSpell'):setText(state.autoHaste.spell or '')

  window:recursiveGetChildById('exerciseEnable'):setChecked(state.exercise.enabled)
  window:recursiveGetChildById('exerciseItemId'):setText(state.exercise.itemId or '')

  window:recursiveGetChildById('changeGoldEnable'):setChecked(state.changeGold)
  window:recursiveGetChildById('autoEatEnable'):setChecked(state.autoEat)
  window:recursiveGetChildById('autoReconnectEnable'):setChecked(state.autoReconnect)

  isRefreshing = false
end

-- =============================================================================
-- UI: Presets
-- =============================================================================

refreshPresetCombo = function()
  if not window then return end
  local combo = window:recursiveGetChildById('presetCombo')
  if not combo then return end
  isRefreshing = true
  combo:clearOptions()
  local names = {}
  for n, _ in pairs(state.presets) do table.insert(names, n) end
  table.sort(names)
  for _, n in ipairs(names) do combo:addOption(n, n) end
  if state.currentPreset and state.presets[state.currentPreset] then
    combo:setCurrentOption(state.currentPreset, true)
  end
  isRefreshing = false
end

local function onPresetNew()
  displayTextInputBox('New Preset', 'Name:', function(name)
    if not name or name == '' then return end
    if state.presets[name] then return end
    state.presets[name] = newShooterPreset()
    state.currentPreset = name
    refreshPresetCombo(); refreshShooterSlots(); saveConfig()
  end, nil)
end

local function onPresetRename()
  if not state.currentPreset then return end
  local oldName = state.currentPreset
  displayInputBox('Rename Preset', 'New name:', function(newName)
    if not newName or newName == '' or newName == oldName then return end
    if state.presets[newName] then return end
    state.presets[newName] = state.presets[oldName]
    state.presets[oldName] = nil
    state.currentPreset = newName
    refreshPresetCombo(); refreshShooterSlots(); saveConfig()
  end, nil, oldName)
end

local function onPresetDelete()
  if not state.currentPreset then return end
  local count = 0
  for _ in pairs(state.presets) do count = count + 1 end
  if count <= 1 then return end
  state.presets[state.currentPreset] = nil
  state.currentPreset = next(state.presets)
  refreshPresetCombo(); refreshShooterSlots(); saveConfig()
end

-- =============================================================================
-- Status / labels
-- =============================================================================

refreshKeyLabels = function()
  if not window then return end
  local function lbl(id, key)
    local w = window:recursiveGetChildById(id)
    if w then w:setText(key and key ~= '' and key or '(none)') end
  end
  lbl('autoTargetKeyLabel', state.hotkeys.autoTarget)
  lbl('enableKeyLabel',     state.hotkeys.shooter)
  lbl('utitoKeyLabel',      state.hotkeys.utito)
end

refreshUtitoStatus = function()
  if not window then return end
  local lbl = window:recursiveGetChildById('autoUtitoStatus')
  if not lbl then return end
  if not state.autoUtito then
    lbl:setText('--'); lbl:setColor('#a0a0a0'); return
  end
  local voc = detectVocation()
  if not voc or not KNIGHT_VOCS[voc] then
    lbl:setText('not a knight'); lbl:setColor('#ff9090'); return
  end
  local p = g_game.getLocalPlayer()
  if p and p.hasState and p:hasState(PlayerStates.PartyBuff) then
    lbl:setText('buff: ACTIVE'); lbl:setColor('#80ff80')
  else
    lbl:setText('buff: MISSING'); lbl:setColor('#ffd070')
  end
end

refreshStatus = function()
  if window then
    isRefreshing = true
    local function chk(id, val)
      local w = window:recursiveGetChildById(id)
      if w then w:setChecked(val) end
    end
    chk('enableCheck',     state.shooterEnabled)
    chk('autoTargetCheck', state.autoTarget)
    chk('autoUtitoCheck',  state.autoUtito)
    chk('healEnabled',     state.healEnabled)
    local modeCombo = window:recursiveGetChildById('autoTargetMode')
    if modeCombo then
      modeCombo:setCurrentOptionByData(state.targetStrategy or 'nearest', true)
    end
    isRefreshing = false

    local parts = {}
    if state.shooterEnabled then table.insert(parts, 'Shooter') end
    if state.healEnabled    then table.insert(parts, 'Heal') end
    if state.autoUtito      then table.insert(parts, 'Utito') end
    if state.autoHaste.enabled then table.insert(parts, 'Haste') end
    if state.manaTrain.enabled then table.insert(parts, 'ManaTrain') end
    if state.exercise.enabled  then table.insert(parts, 'Exercise') end
    if state.autoEat       then table.insert(parts, 'Eat') end
    if state.changeGold    then table.insert(parts, 'Gold') end
    if state.autoReconnect then table.insert(parts, 'Reconnect') end

    local status = window:recursiveGetChildById('statusLabel')
    if #parts > 0 then
      status:setText('ON: ' .. table.concat(parts, ', '))
      status:setColor('#80ff80')
    else
      status:setText('Status: Disabled')
      status:setColor('#ff7070')
    end
  end

  if miniPanel then
    local btn = miniPanel:recursiveGetChildById('quickToggle')
    if btn then
      if state.shooterEnabled then
        btn:setText('SHOOTER: ON');  btn:setColor('#80ff80')
      else
        btn:setText('SHOOTER: OFF'); btn:setColor('#ff7070')
      end
    end
  end

  refreshUtitoStatus()
end

refreshAll = function()
  refreshPresetCombo()
  refreshShooterSlots()
  refreshHealRows()
  refreshToolsFields()
  refreshKeyLabels()
  refreshStatus()
end

-- =============================================================================
-- Window open/close
-- =============================================================================

local function attachWindowHandlers()
  if not window then return end
  buildShooterSlots()
  buildHealRows()
  attachToolsHandlers()

  window:getChildById('closeButton').onClick = function() closeWindow() end
  window:getChildById('helperStats').onClick = openStatsWindow
  window:getChildById('saveButton').onClick  = function()
    ensureDefaults()
    local was = isRefreshing; isRefreshing = false
    saveConfig(); isRefreshing = was
    local btn = window:getChildById('saveButton'); local original = btn:getText()
    btn:setText('Saved!')
    scheduleEvent(function()
      if window and window:getChildById('saveButton') then
        window:getChildById('saveButton'):setText(original)
      end
    end, 800)
  end

  window:getChildById('tabHealing').onClick = function() switchTab('healing') end
  window:getChildById('tabTools').onClick   = function() switchTab('tools') end
  window:getChildById('tabShooter').onClick = function() switchTab('shooter') end

  -- Shooter panel
  window:recursiveGetChildById('presetCombo').onOptionChange = function(_, _, data)
    if isRefreshing then return end
    if data and state.presets[data] then
      state.currentPreset = data; comboCursor = 1
      refreshShooterSlots(); saveConfig()
    end
  end
  window:recursiveGetChildById('presetNew').onClick    = onPresetNew
  window:recursiveGetChildById('presetDelete').onClick = onPresetDelete
  window:recursiveGetChildById('presetRename').onClick = onPresetRename

  window:recursiveGetChildById('autoTargetCheck').onCheckChange = function(_, c)
    if isRefreshing then return end; setAutoTarget(c)
  end

  local modeCombo = window:recursiveGetChildById('autoTargetMode')
  modeCombo:addOption('Nearest',       'nearest')
  modeCombo:addOption('Farthest',      'farthest')
  modeCombo:addOption('Most HP',       'most_hp')
  modeCombo:addOption('Least HP',      'least_hp')
  modeCombo:addOption('Most HP (box)', 'most_hp_box')
  modeCombo:addOption('Least HP (box)', 'least_hp_box')
  modeCombo.onOptionChange = function(_, _, data)
    if isRefreshing then return end
    state.targetStrategy = data or 'nearest'
    saveConfig()
  end
  window:recursiveGetChildById('enableCheck').onCheckChange = function(_, c)
    if isRefreshing then return end; setShooterEnabled(c)
  end
  window:recursiveGetChildById('autoUtitoCheck').onCheckChange = function(_, c)
    if isRefreshing then return end; setAutoUtito(c)
  end
  window:recursiveGetChildById('autoTargetSetKey').onClick = function() openKeyCapture('autoTarget') end
  window:recursiveGetChildById('enableSetKey').onClick     = function() openKeyCapture('shooter') end
  window:recursiveGetChildById('utitoSetKey').onClick      = function() openKeyCapture('utito') end

  -- Healing panel
  window:recursiveGetChildById('healEnabled').onCheckChange = function(_, c)
    if isRefreshing then return end; setHealEnabled(c)
  end

  window.onKeyDown = function(_, keyCode, modifiers)
    if keyCode == KeyEscape and modifiers == KeyboardNoModifier then
      closeWindow(); return true
    end
  end

  refreshAll()
  switchTab(activeTab or 'shooter')
end

openWindow = function()
  if window then window:raise(); window:focus(); return end
  window = g_ui.createWidget('RTCasterWindow', rootWidget)
  attachWindowHandlers()
end

closeWindow = function()
  if window then window:destroy(); window = nil end
end

-- =============================================================================
-- Mini panel
-- =============================================================================

local function ensureMiniPanel()
  if miniPanel then return end
  local rightPanel = modules.game_interface
                 and modules.game_interface.getRightPanel
                 and modules.game_interface.getRightPanel() or nil
  if not rightPanel then return end
  miniPanel = g_ui.createWidget('RTCasterMiniPanel', rightPanel)
  miniPanel:setup()
  miniPanel:recursiveGetChildById('openConfig').onClick  = function() openWindow() end
  miniPanel:recursiveGetChildById('quickToggle').onClick = function() toggleShooter() end
end

-- =============================================================================
-- Auto Reconnect
-- =============================================================================

local function attemptReconnect()
  if not state.autoReconnect then return end
  if g_game.isOnline() then return end
  -- Hand off to entergame's standard flow if available.
  if modules.client_entergame and modules.client_entergame.tryLogin then
    pcall(function() modules.client_entergame.tryLogin() end)
  elseif EnterGame and EnterGame.tryLogin then
    pcall(function() EnterGame.tryLogin() end)
  end
end

-- =============================================================================
-- Lifecycle
-- =============================================================================

local function onLogin()
  manualLogout = false
  ensureMiniPanel()
  if miniPanel then miniPanel:show() end
  refreshStatus()
  rebindAllHotkeys()
  updateLoopState()
end

local function onLogout()
  stopLoop()
  state.shooterEnabled = false
  refreshStatus()
  if miniPanel then miniPanel:hide() end
  closeWindow()
  unbindAllHotkeys()

  if state.autoReconnect and not manualLogout then
    if reconnectEv then removeEvent(reconnectEv) end
    reconnectEv = scheduleEvent(function()
      reconnectEv = nil
      attemptReconnect()
    end, RECONNECT_DELAY_MS)
  end
end

-- Detect intentional logout: hook the Logout menu / close commands via keyboard
-- isn't trivial. Easier heuristic: if onGameEnd fires with no socket error,
-- assume manual. Implementation here uses the cancelLogin flag if available.
local function onLogoutManual()
  manualLogout = true
end

function init()
  g_logger.info('[renaot_rtcaster] init()')
  g_ui.importStyle('rtcaster.otui')
  loadConfig()

  connect(g_game, {
    onGameStart           = onLogin,
    onGameEnd             = onLogout,
    onSpellCooldown       = onSpellCooldownEvent,
    onSpellGroupCooldown  = onSpellGroupCooldownEvent,
  })

  if g_game.isOnline() then onLogin() end
end

function terminate()
  stopLoop()
  if reconnectEv then removeEvent(reconnectEv); reconnectEv = nil end
  unbindAllHotkeys()
  disconnect(g_game, {
    onGameStart           = onLogin,
    onGameEnd             = onLogout,
    onSpellCooldown       = onSpellCooldownEvent,
    onSpellGroupCooldown  = onSpellGroupCooldownEvent,
  })
  closeWindow()
  if statsWin   then statsWin:destroy();   statsWin   = nil end
  if captureWin then captureWin:destroy(); captureWin = nil end
  if miniPanel  then miniPanel:destroy();  miniPanel  = nil end
end
