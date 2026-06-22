-- =============================================================================
-- RenaOT RTCaster — unified client-side bot (Heal / Friends / Target / Shooter / Tools)
-- Single tick loop driving all features. Spells/runes/potions are pickable with
-- icons (see openPicker), like vBot/RubinOT RTC.
-- =============================================================================

-- Constants ------------------------------------------------------------------

local NUM_SHOOTER_SLOTS  = 5
local NUM_HEAL_SPELL     = 3
local NUM_HP_POTION      = 3
local NUM_MANA_POTION    = 3
local NUM_FRIEND_RULES   = 3
local MAX_MONSTERS       = 20

-- Curated item ids used to seed the item picker. Runes are added automatically
-- from SpellRunesData (gamelib/spells.lua), so we only list potions here.
local HP_POTIONS = {
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

local CHANGE_GOLD_INTERVAL_MS = 1500
local AUTO_EAT_INTERVAL_MS    = 5000   -- check every 5s; only eats if hungry state
local EXERCISE_INTERVAL_MS    = 2000
local RECONNECT_DELAY_MS      = 5000

-- Common food item ids (used in order)
local FOOD_IDS = { 3582, 3577, 3578, 3600, 3601, 3607, 3589, 3725, 3585 }

-- Money item ids
local GOLD_COIN     = 3031
local PLATINUM_COIN = 3035
local CRYSTAL_COIN  = 3043

-- Built at init() once the gamelib spell/rune tables are available.
local ITEM_DB      = {}   -- { {id, name, cat}, ... } sorted, for the item picker
local ITEM_NAME    = {}   -- [id] = name
local RT_SPELL_DB  = {}   -- { {name, words, clientId, type, group, needTarget}, ... }

-- State ----------------------------------------------------------------------

local state = {
  -- Shooter
  presets = nil,
  currentPreset = 'Default',
  shooterEnabled = false,
  autoUtito = false,
  hotkeys = { shooter = nil, target = nil, utito = nil, rune = nil },

  -- Quick Rune Attack (dedicated toggle, standalone from the shooter rotation)
  runeAttack = { enabled = false, action = nil, creatures = 1 },

  -- TargetBot
  target = {
    enabled    = false,
    strategy   = 'nearest',
    onlyListed = false,
    monsters   = {},   -- { {name, priority, dist, action}, ... }
  },

  -- Healing (self)
  healEnabled     = false,
  healSpells      = nil,    -- 3 slots of {action, hpPct, manaPct}
  healHpPotions   = nil,    -- 3 slots of {itemId, action, hpPct}
  healManaPotions = nil,    -- 3 slots of {itemId, action, manaPct}

  -- Friend / party healing
  friendHeal = {
    enabled = false,
    party   = true,
    names   = '',
    rules   = nil,   -- 3 slots of {action, hpPct}
  },

  -- Tools
  manaTrain     = { enabled = false, spell = '', spellAction = nil, manaPct = 80 },
  autoHaste     = { enabled = false, pz = false, spell = 'utani hur', spellAction = nil },
  exercise      = { enabled = false, itemId = '28552' },
  manaShield    = { enabled = false, pz = false, spell = 'utamo vita', spellAction = nil },
  antiParalyze  = { enabled = false, spell = 'utani gran hur', spellAction = nil },
  autoSwap      = { enabled = false, amuletId = '0', ringId = '0' },
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
local pickerWin   = nil
local tickEvent   = nil
local reconnectEv = nil
local lastCastAt  = 0
local lastChangeGoldAt = 0
local lastAutoEatAt    = 0
local lastExerciseAt   = 0
local lastPotionAt     = 0
local lastSwapAt       = 0
local lastRuneAt  = {}            -- [itemId] = millis of last rune use
local boundKeys   = {}
local isRefreshing = false
local comboCursor  = 1
local activeTab    = 'shooter'   -- 'healing' | 'friends' | 'target' | 'shooter' | 'tools'
local manualLogout = false

local pickerState = { onSelect = nil, onClear = nil, allow = nil, mode = 'spell', category = 'all', search = '' }

-- Cooldown tracking (live, not persisted) ------------------------------------

local spellCdExpire = {}     -- [iconId]  = millis when cooldown ends
local groupCdExpire = {}     -- [groupId] = millis when cooldown ends

-- Forward decls --------------------------------------------------------------

local refreshAll, refreshStatus, refreshPresetCombo
local refreshShooterSlots, refreshHealRows, refreshFriendRows, refreshToolsFields, refreshKeyLabels
local refreshUtitoStatus, refreshTargetFields, rebuildMonsterRows, refreshRuneAttack, switchTab
local openWindow, closeWindow
local openPicker, closePicker, rebuildPickerList, buildPickerCatOptions
local setActionVisual, bindActionSlot

-- =============================================================================
-- Item / Spell databases (for the pickers)
-- =============================================================================

local function titleCase(s)
  if not s or s == '' then return s end
  return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

local function buildItemDb()
  ITEM_DB = {}
  ITEM_NAME = {}
  local seen = {}
  local function add(id, name, cat)
    id = tonumber(id)
    if not id or id <= 0 or seen[id] then return end
    seen[id] = true
    ITEM_NAME[id] = name
    table.insert(ITEM_DB, { id = id, name = name, cat = cat })
  end
  for _, p in ipairs(HP_POTIONS)   do add(p.id, p.name, 'Potions') end
  for _, p in ipairs(MANA_POTIONS) do add(p.id, p.name, 'Potions') end
  if SpellRunesData then
    for id, d in pairs(SpellRunesData) do
      local cat = (d.group == 2) and 'Healing Runes'
               or (d.group == 3) and 'Support Runes'
               or 'Attack Runes'
      add(id, titleCase(d.name or ('rune ' .. id)), cat)
    end
  end
  table.sort(ITEM_DB, function(a, b)
    if a.cat ~= b.cat then return a.cat < b.cat end
    return a.name < b.name
  end)
end

local function buildSpellDb()
  RT_SPELL_DB = {}
  local data = SpellInfo and SpellInfo['Default'] or {}
  for name, s in pairs(data) do
    local grp = 0
    if type(s.group) == 'table' then
      for k, _ in pairs(s.group) do grp = k; break end
    end
    table.insert(RT_SPELL_DB, {
      name = name, words = s.words, clientId = tonumber(s.clientId) or 0,
      type = s.type, group = grp, needTarget = s.needTarget,
    })
  end
  table.sort(RT_SPELL_DB, function(a, b) return a.name < b.name end)
end

local function itemName(id)
  id = tonumber(id) or 0
  return ITEM_NAME[id] or ('item ' .. id)
end

local function resolveSpellAction(words)
  if not words or words == '' then return nil end
  if Spells and Spells.getSpellByWords then
    local s = Spells.getSpellByWords(words)
    if s then
      return { kind = 'spell', words = s.words, clientId = tonumber(s.clientId) or 0, name = s.name }
    end
  end
  return { kind = 'spell', words = words, clientId = 0, name = words }
end

-- =============================================================================
-- Persistence
-- =============================================================================

local function newShooterPreset()
  local slots = {}
  for i = 1, NUM_SHOOTER_SLOTS do
    slots[i] = { action = nil, manaPct = 80, creatures = 1, priority = i }
  end
  return { slots = slots }
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
    if not fixed[i] then fixed[i] = defaultFn(i) end
  end
  return fixed
end

local function normalizeAction(a)
  if type(a) ~= 'table' then return nil end
  if a.kind == 'spell' then
    return { kind = 'spell', words = a.words or '', clientId = tonumber(a.clientId) or 0, name = a.name or a.words }
  elseif a.kind == 'item' then
    local id = tonumber(a.itemId) or 0
    if id <= 0 then return nil end
    return { kind = 'item', itemId = id, name = a.name or itemName(id) }
  end
  return nil
end

local function normalizeShooterPresets()
  if type(state.presets) ~= 'table' then state.presets = {} end
  for _, preset in pairs(state.presets) do
    preset.slots = normalizeArrayTable(preset.slots, NUM_SHOOTER_SLOTS, function(i)
      return { action = nil, manaPct = 80, creatures = 1, priority = i }
    end)
    for i, s in ipairs(preset.slots) do
      -- migrate legacy {spell = 'words'}
      if not s.action and s.spell and s.spell ~= '' then s.action = resolveSpellAction(s.spell) end
      s.action    = normalizeAction(s.action)
      s.spell     = nil
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

  -- Heal spells
  state.healSpells = normalizeArrayTable(state.healSpells, NUM_HEAL_SPELL, function(i)
    return { action = nil, hpPct = 70, manaPct = 30 }
  end)
  for _, s in ipairs(state.healSpells) do
    if not s.action and s.spell and s.spell ~= '' then s.action = resolveSpellAction(s.spell) end
    s.action  = normalizeAction(s.action)
    s.spell   = nil
    s.hpPct   = tonumber(s.hpPct)   or 70
    s.manaPct = tonumber(s.manaPct) or 30
  end

  -- HP potions
  state.healHpPotions = normalizeArrayTable(state.healHpPotions, NUM_HP_POTION, function(i)
    return { itemId = 0, action = nil, hpPct = 50 }
  end)
  for _, s in ipairs(state.healHpPotions) do
    s.itemId = tonumber(s.itemId) or 0
    if not s.action and s.itemId > 0 then s.action = { kind = 'item', itemId = s.itemId, name = itemName(s.itemId) } end
    s.action = normalizeAction(s.action)
    s.itemId = s.action and s.action.itemId or 0
    s.hpPct  = tonumber(s.hpPct)  or 50
  end

  -- Mana potions
  state.healManaPotions = normalizeArrayTable(state.healManaPotions, NUM_MANA_POTION, function(i)
    return { itemId = 0, action = nil, manaPct = 30 }
  end)
  for _, s in ipairs(state.healManaPotions) do
    s.itemId = tonumber(s.itemId) or 0
    if not s.action and s.itemId > 0 then s.action = { kind = 'item', itemId = s.itemId, name = itemName(s.itemId) } end
    s.action  = normalizeAction(s.action)
    s.itemId  = s.action and s.action.itemId or 0
    s.manaPct = tonumber(s.manaPct) or 30
  end

  -- Friend heal
  state.friendHeal = state.friendHeal or {}
  local fh = state.friendHeal
  fh.enabled = fh.enabled and true or false
  if fh.party == nil then fh.party = true end
  fh.names = fh.names or ''
  fh.rules = normalizeArrayTable(fh.rules, NUM_FRIEND_RULES, function(i)
    return { action = nil, hpPct = 70 }
  end)
  for _, r in ipairs(fh.rules) do
    r.action = normalizeAction(r.action)
    r.hpPct  = tonumber(r.hpPct) or 70
  end

  -- TargetBot
  state.target = state.target or {}
  state.target.enabled    = state.target.enabled and true or false
  state.target.strategy   = state.target.strategy or 'nearest'
  state.target.onlyListed = state.target.onlyListed and true or false
  if type(state.target.monsters) ~= 'table' then state.target.monsters = {} end
  do
    local fixed = {}
    for _, m in pairs(state.target.monsters) do
      if type(m) == 'table' and m.name and m.name ~= '' then
        table.insert(fixed, {
          name     = tostring(m.name),
          priority = tonumber(m.priority) or 1,
          dist     = tonumber(m.dist) or 0,
          action   = normalizeAction(m.action),
        })
      end
      if #fixed >= MAX_MONSTERS then break end
    end
    state.target.monsters = fixed
  end

  -- Quick Rune Attack
  state.runeAttack = state.runeAttack or {}
  state.runeAttack.enabled   = state.runeAttack.enabled and true or false
  state.runeAttack.action    = normalizeAction(state.runeAttack.action)
  state.runeAttack.creatures = tonumber(state.runeAttack.creatures) or 1
  -- only an item/rune makes sense here; drop a stray spell action
  if state.runeAttack.action and state.runeAttack.action.kind ~= 'item' then
    state.runeAttack.action = nil
  end

  -- Tools
  state.manaTrain     = state.manaTrain     or { enabled = false, spell = '', manaPct = 80 }
  state.autoHaste     = state.autoHaste     or { enabled = false, pz = false, spell = 'utani hur' }
  state.exercise      = state.exercise      or { enabled = false, itemId = '28552' }
  state.manaShield    = state.manaShield    or { enabled = false, pz = false, spell = 'utamo vita' }
  state.antiParalyze  = state.antiParalyze  or { enabled = false, spell = 'utani gran hur' }
  state.autoSwap      = state.autoSwap      or { enabled = false, amuletId = '0', ringId = '0' }
  -- coerce persisted numeric/string sub-fields even on a partial (legacy) table,
  -- mirroring the slot normalization above (else e.g. manaPct=nil -> tryManaTrain
  -- threshold 0 -> drains mana). '' stays '' since empty string is truthy in Lua.
  state.manaTrain.manaPct  = tonumber(state.manaTrain.manaPct) or 80
  state.manaTrain.spell    = tostring(state.manaTrain.spell or '')
  state.autoHaste.spell    = tostring(state.autoHaste.spell or 'utani hur')
  state.manaShield.spell   = tostring(state.manaShield.spell or 'utamo vita')
  state.antiParalyze.spell = tostring(state.antiParalyze.spell or 'utani gran hur')
  state.exercise.itemId    = tostring(state.exercise.itemId or '28552')
  state.autoSwap.amuletId  = tostring(state.autoSwap.amuletId or '0')
  state.autoSwap.ringId    = tostring(state.autoSwap.ringId or '0')
  -- rebuild tool spell action visuals from words
  for _, t in ipairs({ state.manaTrain, state.autoHaste, state.manaShield, state.antiParalyze }) do
    if not t.spellAction and t.spell and t.spell ~= '' then t.spellAction = resolveSpellAction(t.spell) end
    t.spellAction = normalizeAction(t.spellAction)
  end

  state.hotkeys = state.hotkeys or { shooter = nil, target = nil, utito = nil, rune = nil }
  state.stats   = state.stats   or { total = 0, perSpell = {}, perItem = {} }
end

local function saveConfig()
  if isRefreshing then return end
  g_settings.setNode(SETTINGS_KEY, {
    presets        = state.presets,
    currentPreset  = state.currentPreset,
    autoUtito      = state.autoUtito,
    hotkeys        = state.hotkeys,
    stats          = state.stats,
    target          = state.target,
    runeAttack      = state.runeAttack,
    healEnabled     = state.healEnabled,
    healSpells      = state.healSpells,
    healHpPotions   = state.healHpPotions,
    healManaPotions = state.healManaPotions,
    friendHeal    = state.friendHeal,
    manaTrain     = state.manaTrain,
    autoHaste     = state.autoHaste,
    exercise      = state.exercise,
    manaShield    = state.manaShield,
    antiParalyze  = state.antiParalyze,
    autoSwap      = state.autoSwap,
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
    state.autoUtito      = data.autoUtito      and true or false
    state.hotkeys        = data.hotkeys        or { shooter = nil, target = nil, utito = nil, rune = nil }
    state.stats          = data.stats          or { total = 0, perSpell = {}, perItem = {} }
    state.target          = data.target          or nil
    state.runeAttack      = data.runeAttack      or nil
    state.healEnabled     = data.healEnabled     and true or false
    state.healSpells      = data.healSpells      or nil
    state.healHpPotions   = data.healHpPotions   or nil
    state.healManaPotions = data.healManaPotions or nil
    state.friendHeal    = data.friendHeal    or nil
    state.manaTrain     = data.manaTrain     or nil
    state.autoHaste     = data.autoHaste     or nil
    state.exercise      = data.exercise      or nil
    state.manaShield    = data.manaShield    or nil
    state.antiParalyze  = data.antiParalyze  or nil
    state.autoSwap      = data.autoSwap      or nil
    state.changeGold    = data.changeGold    and true or false
    state.autoEat       = data.autoEat       and true or false
    state.autoReconnect = data.autoReconnect and true or false
    activeTab           = data.activeTab     or 'shooter'
  end
  -- legacy migration: old single autoTarget / targetStrategy fields
  if data and (data.autoTarget ~= nil or data.targetStrategy) then
    state.target = state.target or {}
    if state.target.enabled == nil then state.target.enabled = data.autoTarget and true or false end
    state.target.strategy = state.target.strategy or data.targetStrategy or 'nearest'
    if data.hotkeys and data.hotkeys.autoTarget and not state.hotkeys.target then
      state.hotkeys.target = data.hotkeys.autoTarget
    end
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
  return Spells.getSpellByWords(words)
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
-- Cast / use helpers
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

local function castFriendSpell(words, name, now)
  if not words or words == '' or not name or name == '' then return false end
  if (now - lastCastAt) < CAST_FAILSAFE_MS then return false end
  local meta = lookupSpell(words)
  if not isSpellReady(meta, now) then return false end
  g_game.talk(words .. ' "' .. name)
  recordCastCooldown(meta, now)
  lastCastAt = now
  recordCastStat(words)
  return true
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

-- Use a rune/item on a specific creature, honoring the rune's own exhaustion.
local function useItemOnCreature(itemId, creature, now)
  local id = tonumber(itemId)
  if not id or id <= 0 then return false end
  if not creature or creature:isDead() then return false end
  if (now - lastCastAt) < CAST_FAILSAFE_MS then return false end
  local data = SpellRunesData and SpellRunesData[id]
  local cd = (data and data.exhaustion) or 1000
  if lastRuneAt[id] and (now - lastRuneAt[id]) < cd then return false end
  g_game.useInventoryItemWith(id, creature)
  lastRuneAt[id] = now
  lastCastAt = now
  recordItemStat(id)
  return true
end

local function useRuneOnTarget(itemId, now)
  local target = g_game.getAttackingCreature()
  if not target then return false end
  return useItemOnCreature(itemId, target, now)
end

-- =============================================================================
-- Action slot UI (icon + name, click to open picker)
-- =============================================================================

setActionVisual = function(slot, action)
  if not slot then return end
  local itemIcon  = slot:getChildById('itemIcon')
  local spellIcon = slot:getChildById('spellIcon')
  local nameLbl   = slot:getChildById('actionName')
  if action and action.kind == 'spell' then
    spellIcon:setImageClip(Spells.getImageClip(action.clientId or 0))
    spellIcon:setVisible(true)
    itemIcon:setVisible(false)
    itemIcon:setItemId(0)
    nameLbl:setText(action.name or action.words or '?')
    nameLbl:setColor('#dcd0a0')
  elseif action and action.kind == 'item' then
    itemIcon:setItemId(tonumber(action.itemId) or 0)
    itemIcon:setVisible(true)
    spellIcon:setVisible(false)
    nameLbl:setText(action.name or ('item ' .. tostring(action.itemId)))
    nameLbl:setColor('#a8c8e8')
  else
    spellIcon:setVisible(false)
    itemIcon:setVisible(false)
    itemIcon:setItemId(0)
    nameLbl:setText('(none)')
    nameLbl:setColor('#808080')
  end
end

bindActionSlot = function(slot, opts)
  if not slot then return end
  slot.onClick = function()
    openPicker({
      allow    = opts.allow,
      category = opts.category,
      onSelect = function(action)
        opts.set(action)
        setActionVisual(slot, action)
        saveConfig()
      end,
      onClear = function()
        opts.set(nil)
        setActionVisual(slot, nil)
        saveConfig()
      end,
    })
  end
end

-- =============================================================================
-- Picker popup
-- =============================================================================

local function pickerSpellMatchesCat(s, cat)
  if cat == 'all' then return true end
  if cat == 'attack'  then return s.group == 1 end
  if cat == 'healing' then return s.group == 2 end
  if cat == 'support' then return s.group == 3 end
  if cat == 'conjure' then return s.type == 'Conjure' end
  return true
end

closePicker = function()
  if pickerWin then pickerWin:destroy(); pickerWin = nil end
end

rebuildPickerList = function()
  if not pickerWin then return end
  local list = pickerWin:getChildById('list')
  list:destroyChildren()
  local search = (pickerState.search or ''):lower()
  local cat    = pickerState.category or 'all'
  local LIMIT  = 120
  local count  = 0

  if pickerState.mode == 'spell' then
    for _, s in ipairs(RT_SPELL_DB) do
      if count >= LIMIT then break end
      if pickerSpellMatchesCat(s, cat)
         and (search == '' or s.name:lower():find(search, 1, true) or s.words:lower():find(search, 1, true)) then
        local row = g_ui.createWidget('RTCasterPickerSpellRow', list)
        row:getChildById('icon'):setImageClip(Spells.getImageClip(s.clientId or 0))
        row:getChildById('name'):setText(s.name .. '  (' .. s.words .. ')')
        row.onClick = function()
          if pickerState.onSelect then
            pickerState.onSelect({ kind = 'spell', words = s.words, clientId = s.clientId or 0, name = s.name })
          end
          closePicker()
        end
        count = count + 1
      end
    end
  else
    for _, it in ipairs(ITEM_DB) do
      if count >= LIMIT then break end
      if (cat == 'all' or it.cat == cat)
         and (search == '' or it.name:lower():find(search, 1, true) or tostring(it.id):find(search, 1, true)) then
        local row = g_ui.createWidget('RTCasterPickerItemRow', list)
        row:getChildById('icon'):setItemId(it.id)
        row:getChildById('name'):setText(it.name .. '  [' .. it.id .. ']')
        row.onClick = function()
          if pickerState.onSelect then
            pickerState.onSelect({ kind = 'item', itemId = it.id, name = it.name })
          end
          closePicker()
        end
        count = count + 1
      end
    end
    -- allow picking any custom item id by typing the number
    local cid = tonumber(search)
    if cid and cid > 0 and not ITEM_NAME[cid] then
      local row = g_ui.createWidget('RTCasterPickerItemRow', list)
      row:getChildById('icon'):setItemId(cid)
      row:getChildById('name'):setText('Custom id ' .. cid)
      row.onClick = function()
        if pickerState.onSelect then
          pickerState.onSelect({ kind = 'item', itemId = cid, name = 'item ' .. cid })
        end
        closePicker()
      end
    end
  end
end

buildPickerCatOptions = function()
  if not pickerWin then return end
  local combo = pickerWin:getChildById('catFilter')
  combo:clearOptions()
  local valid = {}
  if pickerState.mode == 'spell' then
    local opts = { { 'All', 'all' }, { 'Attack', 'attack' }, { 'Healing', 'healing' }, { 'Support', 'support' }, { 'Conjure', 'conjure' } }
    for _, o in ipairs(opts) do combo:addOption(o[1], o[2]); valid[o[2]] = true end
  else
    combo:addOption('All', 'all'); valid['all'] = true
    local seen = {}
    for _, it in ipairs(ITEM_DB) do
      if not seen[it.cat] then seen[it.cat] = true; combo:addOption(it.cat, it.cat); valid[it.cat] = true end
    end
  end
  if not valid[pickerState.category] then pickerState.category = 'all' end
  combo:setCurrentOptionByData(pickerState.category, true)
end

openPicker = function(opts)
  closePicker()
  pickerWin = g_ui.createWidget('RTCasterPicker', rootWidget)
  pickerState.onSelect = opts.onSelect
  pickerState.onClear  = opts.onClear
  pickerState.allow    = opts.allow or { spell = true, item = true }
  pickerState.search   = ''
  pickerState.mode     = pickerState.allow.spell and 'spell' or 'item'
  pickerState.category = opts.category or 'all'

  local modeSpells = pickerWin:getChildById('modeSpells')
  local modeItems  = pickerWin:getChildById('modeItems')
  modeSpells:setVisible(pickerState.allow.spell and true or false)
  modeItems:setVisible(pickerState.allow.item and true or false)

  local function paintModes()
    modeSpells:setColor(pickerState.mode == 'spell' and '#ffd700' or '#c0c0c0')
    modeItems:setColor(pickerState.mode == 'item' and '#ffd700' or '#c0c0c0')
  end

  local function setMode(m)
    pickerState.mode = m
    if m == 'item' and not (pickerState.category == 'all') then pickerState.category = 'all' end
    paintModes()
    buildPickerCatOptions()
    rebuildPickerList()
  end

  modeSpells.onClick = function() setMode('spell') end
  modeItems.onClick  = function() setMode('item') end

  local search = pickerWin:getChildById('search')
  search.onTextChange = function(_, t) pickerState.search = t or ''; rebuildPickerList() end

  pickerWin:getChildById('catFilter').onOptionChange = function(_, _, data)
    pickerState.category = data or 'all'; rebuildPickerList()
  end

  pickerWin:getChildById('clearBtn').onClick = function()
    if pickerState.onClear then pickerState.onClear() end
    closePicker()
  end
  pickerWin:getChildById('closeBtn').onClick = function() closePicker() end
  pickerWin.onKeyDown = function(_, keyCode)
    if keyCode == KeyEscape then closePicker(); return true end
  end

  paintModes()
  buildPickerCatOptions()
  rebuildPickerList()
  search:focus()
end

-- =============================================================================
-- Combat scanning + TargetBot
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

local function inBox(dx, dy) return math.abs(dx) <= 1 and math.abs(dy) <= 1 end

local TARGET_STRATEGIES = {
  nearest      = { filter = nil,    score = function(c, dx, dy) return -math.max(math.abs(dx), math.abs(dy)) end },
  farthest     = { filter = nil,    score = function(c, dx, dy) return  math.max(math.abs(dx), math.abs(dy)) end },
  most_hp      = { filter = nil,    score = function(c)         return  creatureHp(c) end },
  least_hp     = { filter = nil,    score = function(c)         return -creatureHp(c) end },
  most_hp_box  = { filter = inBox,  score = function(c)         return  creatureHp(c) end },
  least_hp_box = { filter = inBox,  score = function(c)         return -creatureHp(c) end },
}

local STRATEGY_MARGIN = {
  most_hp = 5, least_hp = 5, most_hp_box = 5, least_hp_box = 5,
}

local function monsterLookup()
  local map = {}
  for _, m in ipairs(state.target.monsters or {}) do
    if m.name and m.name ~= '' then map[m.name:lower()] = m end
  end
  return map
end

-- Base strategy score (distance/hp), or nil if creature is not an eligible mob.
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

-- Combined score = listed-priority dominates strategy score. Returns nil if
-- ineligible (or filtered out by onlyListed / per-monster max distance).
local function combinedScore(creature, strategy, lookup, onlyListed)
  local s = scoreForStrategy(creature, strategy)
  if not s then return nil end
  local entry = lookup[creature:getName():lower()]
  if onlyListed and not entry then return nil end
  if entry and entry.dist and entry.dist > 0 then
    local player = g_game.getLocalPlayer()
    local pos, cpos = player:getPosition(), creature:getPosition()
    local d = math.max(math.abs(cpos.x - pos.x), math.abs(cpos.y - pos.y))
    if d > entry.dist then return nil end
  end
  local prio = entry and entry.priority or 0
  return prio * 100000 + s
end

local function pickTarget(strategy)
  local player = g_game.getLocalPlayer()
  if not player then return nil, -math.huge end
  local pos = player:getPosition()
  if not pos then return nil, -math.huge end

  local lookup     = monsterLookup()
  local onlyListed = state.target.onlyListed and true or false
  local spectators = g_map.getSpectators(pos, false) or {}
  local best, bestScore = nil, -math.huge
  for _, c in ipairs(spectators) do
    local s = combinedScore(c, strategy, lookup, onlyListed)
    if s and s > bestScore then bestScore = s; best = c end
  end
  return best, bestScore
end

local function ensureAttackTarget()
  if not state.target.enabled then return end
  local strategy = state.target.strategy or 'nearest'
  local newTarget, newScore = pickTarget(strategy)
  if not newTarget then return end

  local current = g_game.getAttackingCreature()
  if current == newTarget then return end

  if current then
    local lookup     = monsterLookup()
    local onlyListed = state.target.onlyListed and true or false
    local currentScore = combinedScore(current, strategy, lookup, onlyListed)
    if currentScore then
      local margin = STRATEGY_MARGIN[strategy] or 0
      if (newScore - currentScore) < margin then
        return  -- not enough improvement; keep current
      end
    end
  end

  g_game.attack(newTarget)
end

-- per-monster dedicated attack on the current target, if configured
local function tryMonsterAction(now)
  local target = g_game.getAttackingCreature()
  if not target then return false end
  local entry = monsterLookup()[target:getName():lower()]
  if not entry or not entry.action then return false end
  if entry.action.kind == 'spell' then
    return tryCastSpell(entry.action.words, now)
  elseif entry.action.kind == 'item' then
    return useItemOnCreature(entry.action.itemId, target, now)
  end
  return false
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
-- Healing logic (self)
-- =============================================================================

local function tickHealing(player, now, hpPct, manaPct)
  if not state.healEnabled then return false end

  for _, slot in ipairs(state.healSpells) do
    local act = slot.action
    if act and hpPct <= (slot.hpPct or 100) and manaPct >= (slot.manaPct or 0) then
      if act.kind == 'spell' then
        if tryCastSpell(act.words, now) then return true end
      elseif act.kind == 'item' then
        if (now - lastPotionAt) >= 1000 and useItemOnSelf(act.itemId) then
          lastPotionAt = now; return true
        end
      end
    end
  end

  if (now - lastPotionAt) >= 1000 then
    for _, slot in ipairs(state.healHpPotions) do
      if slot.itemId and slot.itemId > 0 and hpPct <= (slot.hpPct or 0) then
        if useItemOnSelf(slot.itemId) then lastPotionAt = now; return true end
      end
    end
    for _, slot in ipairs(state.healManaPotions) do
      if slot.itemId and slot.itemId > 0 and manaPct <= (slot.manaPct or 0) then
        if useItemOnSelf(slot.itemId) then lastPotionAt = now; return true end
      end
    end
  end

  return false
end

-- =============================================================================
-- Friend / party healing
-- =============================================================================

local function parseNamesSet(str)
  local set = {}
  if type(str) ~= 'string' then return set end
  for part in string.gmatch(str, '[^,]+') do
    local n = part:gsub('^%s*(.-)%s*$', '%1'):lower()
    if n ~= '' then set[n] = true end
  end
  return set
end

local function collectFriends()
  local me = g_game.getLocalPlayer()
  if not me then return {} end
  local pos = me:getPosition()
  if not pos then return {} end
  local names = parseNamesSet(state.friendHeal.names)
  local wantParty = state.friendHeal.party and true or false
  local list = {}
  for _, c in ipairs(g_map.getSpectators(pos, false) or {}) do
    if c and not c:isLocalPlayer() and c.isPlayer and c:isPlayer() and not c:isDead() then
      local cpos = c:getPosition()
      if cpos and cpos.z == pos.z then
        local eligible = false
        if wantParty and c.isPartyMember and c:isPartyMember() then eligible = true end
        if not eligible and names[c:getName():lower()] then eligible = true end
        if eligible then table.insert(list, c) end
      end
    end
  end
  return list
end

local function tickFriendHeal(now)
  local f = state.friendHeal
  if not f.enabled then return false end
  if (now - lastCastAt) < CAST_FAILSAFE_MS then return false end
  local friends = collectFriends()
  if #friends == 0 then return false end

  for _, rule in ipairs(f.rules) do
    local act = rule.action
    if act and rule.hpPct and rule.hpPct > 0 then
      -- most injured friend at/below this rule's threshold
      local pick, pickHp = nil, 101
      for _, c in ipairs(friends) do
        local hp = c:getHealthPercent() or 100
        if hp <= rule.hpPct and hp < pickHp then pick = c; pickHp = hp end
      end
      if pick then
        if act.kind == 'spell' then
          if castFriendSpell(act.words, pick:getName(), now) then return true end
        elseif act.kind == 'item' then
          if useItemOnCreature(act.itemId, pick, now) then return true end
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

local function hasManaShield(player)
  return player:hasState(PlayerStates.ManaShield)
      or player:hasState(PlayerStates.NewManaShield)
end

local function tryManaShield(player, now)
  local m = state.manaShield
  if not m or not m.enabled then return false end
  if not m.spell or m.spell == '' then return false end
  if hasManaShield(player) then return false end
  if isInPz(player) and not m.pz then return false end
  return tryCastSpell(m.spell, now)
end

local function tryAntiParalyze(player, now)
  local a = state.antiParalyze
  if not a or not a.enabled then return false end
  if not a.spell or a.spell == '' then return false end
  if not player:hasState(PlayerStates.Paralyze) then return false end
  return tryCastSpell(a.spell, now)
end

local function tryAutoSwap(player, now)
  local s = state.autoSwap
  if not s or not s.enabled then return false end
  if (now - lastSwapAt) < 300 then return false end
  local function ensureSlot(slot, rawId)
    local id = tonumber(rawId) or 0
    if id <= 0 then return false end
    if player:getInventoryItem(slot) then return false end
    g_game.equipItemId(id)
    lastSwapAt = now
    return true
  end
  if ensureSlot(InventorySlotNeck, s.amuletId) then return true end
  if ensureSlot(InventorySlotFinger, s.ringId) then return true end
  return false
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

-- Canary's change_gold action only converts a FULL stack (item.type == 100).
-- g_game.useInventoryItem(id) makes the SERVER pick an arbitrary stack of that id
-- (often a partial one), so it silently does nothing when a non-100 stack is found
-- first. Instead we locate the exact 100-count stack in an open container and use
-- that specific item, so the server converts the right one.
local function findFullCoinStack(player, coinId)
  for _, item in ipairs(player:getItems(coinId) or {}) do
    if item:getCount() == 100 then return item end
  end
  return nil
end

local function tryChangeGold(player, now)
  if not state.changeGold then return false end
  if (now - lastChangeGoldAt) < CHANGE_GOLD_INTERVAL_MS then return false end
  local coin = findFullCoinStack(player, GOLD_COIN)
            or findFullCoinStack(player, PLATINUM_COIN)
  if not coin then return false end
  -- Coins are flagged multiUse, so a plain "use" is rejected server-side
  -- (RETURNVALUE_CANNOTUSETHISOBJECT, before actions run). The change_gold action
  -- only fires through the "use with" path AND only when the target is an
  -- item/tile (playerUseItemEx) — NOT a creature (playerUseWithCreature). So we
  -- replicate the working manual flow: "use with" the coin onto the ground tile
  -- under the player. change_gold ignores the target. useWith() also sends the
  -- coin's real slot position, so it hits the exact 100-stack.
  local pos = player:getPosition()
  local tile = pos and g_map.getTile(pos)
  local target = tile and (tile:getGround() or tile:getTopUseThing())
  if not target or target:isCreature() then return false end
  g_game.useWith(coin, target)
  recordItemStat(coin:getId())
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
-- Shooter (spell / rune rotation)
-- =============================================================================

local function tickShooter(player, now, manaPct)
  if not state.shooterEnabled then return false end

  -- dedicated per-monster attack first (if the current target has one)
  if tryMonsterAction(now) then return true end

  local mobs = countNearbyMonsters()
  local p = currentPresetData()
  if not p then return false end

  local sorted = {}
  for _, slot in ipairs(p.slots) do
    if slot.action then table.insert(sorted, slot) end
  end
  if #sorted == 0 then return false end
  table.sort(sorted, function(a, b) return (a.priority or 99) < (b.priority or 99) end)

  if comboCursor < 1 or comboCursor > #sorted then comboCursor = 1 end
  for offset = 0, #sorted - 1 do
    local idx = ((comboCursor - 1 + offset) % #sorted) + 1
    local slot = sorted[idx]
    local act = slot.action
    if mobs >= (slot.creatures or 1) then
      if act.kind == 'spell' then
        if manaPct >= (slot.manaPct or 0) then
          local meta = lookupSpell(act.words)
          if isSpellReady(meta, now) and (now - lastCastAt) >= CAST_FAILSAFE_MS then
            castSpell(act.words, now)
            comboCursor = (idx % #sorted) + 1
            return true
          end
        end
      elseif act.kind == 'item' then
        if useRuneOnTarget(act.itemId, now) then
          comboCursor = (idx % #sorted) + 1
          return true
        end
      end
    end
  end
  return false
end

-- Dedicated rune-attack toggle: throw the chosen rune at the current target as
-- soon as it's off cooldown. Standalone from the shooter rotation, own hotkey.
local function tryRuneAttack(now)
  local r = state.runeAttack
  if not r or not r.enabled then return false end
  if not r.action or r.action.kind ~= 'item' then return false end
  if countNearbyMonsters() < (r.creatures or 1) then return false end
  return useRuneOnTarget(r.action.itemId, now)
end

-- =============================================================================
-- Main tick — drives all features
-- =============================================================================

local function anyFeatureActive()
  if state.shooterEnabled or state.autoUtito or state.healEnabled
     or state.autoEat or state.changeGold
     or (state.target      and state.target.enabled)
     or (state.runeAttack  and state.runeAttack.enabled)
     or (state.friendHeal  and state.friendHeal.enabled)
     or (state.manaTrain    and state.manaTrain.enabled)
     or (state.autoHaste    and state.autoHaste.enabled)
     or (state.exercise     and state.exercise.enabled)
     or (state.manaShield   and state.manaShield.enabled)
     or (state.antiParalyze and state.antiParalyze.enabled)
     or (state.autoSwap     and state.autoSwap.enabled) then
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

  -- Self-preservation first
  if tickHealing(player, now, hpPct, manaPct) then return end
  if tryAntiParalyze(player, now)           then return end
  if tryManaShield(player, now)             then return end

  -- Keep allies alive
  if tickFriendHeal(now)                    then return end

  -- Maintain attack target (side effect; doesn't consume the cast budget)
  ensureAttackTarget()

  -- Buffs
  if tryAutoUtito(player, now, manaCur)    then return end
  if tryAutoHaste(player, now)              then return end

  -- Damage rotation
  if tickShooter(player, now, manaPct)      then return end
  if tryRuneAttack(now)                     then return end

  -- Background utilities
  tryAutoEat(player, now)
  tryChangeGold(player, now)
  tryExercise(player, now)
  tryAutoSwap(player, now)
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

local function setTargetEnabled(v)
  state.target.enabled = v and true or false
  updateLoopState(); refreshStatus(); saveConfig()
end

local function setAutoUtito(v)
  state.autoUtito = v and true or false
  updateLoopState(); refreshStatus(); refreshUtitoStatus(); saveConfig()
end

local function setHealEnabled(v)
  state.healEnabled = v and true or false
  updateLoopState(); refreshStatus(); saveConfig()
end

local function setFriendEnabled(v)
  state.friendHeal.enabled = v and true or false
  updateLoopState(); refreshStatus(); saveConfig()
end

local function setRuneAttackEnabled(v)
  state.runeAttack.enabled = v and true or false
  updateLoopState(); refreshStatus(); saveConfig()
end

local function setToolFlag(name, v)
  if name == 'manaTrain'    then state.manaTrain.enabled    = v and true or false
  elseif name == 'autoHaste' then state.autoHaste.enabled    = v and true or false
  elseif name == 'autoHastePz' then state.autoHaste.pz       = v and true or false
  elseif name == 'exercise' then state.exercise.enabled     = v and true or false
  elseif name == 'manaShield' then state.manaShield.enabled  = v and true or false
  elseif name == 'antiParalyze' then state.antiParalyze.enabled = v and true or false
  elseif name == 'autoSwap'  then state.autoSwap.enabled     = v and true or false
  elseif name == 'changeGold'    then state.changeGold      = v and true or false
  elseif name == 'autoEat'       then state.autoEat         = v and true or false
  elseif name == 'autoReconnect' then state.autoReconnect   = v and true or false
  end
  updateLoopState(); refreshStatus(); saveConfig()
end

local function toggleShooter()    setShooterEnabled(not state.shooterEnabled) end
local function toggleTarget()     setTargetEnabled(not state.target.enabled) end
local function toggleAutoUtito()  setAutoUtito(not state.autoUtito) end
local function toggleRuneAttack() setRuneAttackEnabled(not state.runeAttack.enabled) end

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
  bindHotkey(h.shooter, toggleShooter)
  bindHotkey(h.target,  toggleTarget)
  bindHotkey(h.utito,   toggleAutoUtito)
  bindHotkey(h.rune,    toggleRuneAttack)
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
      table.insert(irows, { name = itemName(itemId), count = count })
    end
    table.sort(irows, function(a, b) return a.count > b.count end)
    for _, row in ipairs(irows) do
      local lbl = g_ui.createWidget('Label', list)
      lbl:setText(string.format('  %s — %d', row.name, row.count))
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

local TABS = { 'healing', 'friends', 'target', 'shooter', 'tools' }
local TAB_PANEL = {
  healing = 'panelHealing', friends = 'panelFriends', target = 'panelTarget',
  shooter = 'panelShooter', tools = 'panelTools',
}
local TAB_BUTTON = {
  healing = 'tabHealing', friends = 'tabFriends', target = 'tabTarget',
  shooter = 'tabShooter', tools = 'tabTools',
}

switchTab = function(name)
  activeTab = name
  if not window then return end
  for _, t in ipairs(TABS) do
    window:getChildById(TAB_PANEL[t]):setVisible(t == name)
    local btn = window:getChildById(TAB_BUTTON[t])
    if btn then btn:setColor(t == name and '#ffd700' or '#c0c0c0') end
  end
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
    local slot    = row:getChildById('action')
    local manaBox = row:getChildById('mana')
    local mobsBox = row:getChildById('creatures')
    local prioBox = row:getChildById('priority')

    for pct = 100, 0, -5 do manaBox:addOption(pct .. '%', pct) end
    for n = 1, NUM_SHOOTER_SLOTS do
      mobsBox:addOption(n .. '+', n)
      prioBox:addOption(tostring(n), n)
    end

    row.actionSlot, row.manaBox, row.mobsBox, row.prioBox = slot, manaBox, mobsBox, prioBox

    bindActionSlot(slot, {
      allow = { spell = true, item = true },
      category = 'attack',
      set = function(action)
        local p = currentPresetData(); if not p then return end
        p.slots[i].action = action; comboCursor = 1
      end,
    })
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
    local slot = p.slots[i] or { action = nil, manaPct = 80, creatures = 1, priority = i }
    setActionVisual(row.actionSlot, slot.action)
    row.manaBox:setCurrentOptionByData(slot.manaPct or 80, true)
    row.mobsBox:setCurrentOptionByData(slot.creatures or 1, true)
    row.prioBox:setCurrentOptionByData(slot.priority or i, true)
  end
  isRefreshing = false
end

refreshRuneAttack = function()
  if not window then return end
  isRefreshing = true
  local en = window:recursiveGetChildById('runeAttackEnable')
  if en then en:setChecked(state.runeAttack.enabled) end
  setActionVisual(window:recursiveGetChildById('runeAttackSlot'), state.runeAttack.action)
  local ram = window:recursiveGetChildById('runeAttackMobs')
  if ram then ram:setCurrentOptionByData(state.runeAttack.creatures or 1, true) end
  isRefreshing = false
end

-- =============================================================================
-- UI: Healing tab rows
-- =============================================================================

local function buildPotionRows(panel, count, stateTable, fieldName)
  panel:destroyChildren()
  for i = 1, count do
    local row = g_ui.createWidget('RTCasterPotionRow', panel)
    local slot   = row:getChildById('action')
    local thrBox = row:getChildById('threshold')
    for pct = 100, 0, -5 do thrBox:addOption(pct .. '%', pct) end
    row.actionSlot, row.thrBox = slot, thrBox

    bindActionSlot(slot, {
      allow = { item = true },
      category = 'all',
      set = function(action)
        stateTable[i].action = action
        stateTable[i].itemId = action and action.itemId or 0
      end,
    })
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
    local slot    = row:getChildById('action')
    local hpBox   = row:getChildById('hp')
    local manaBox = row:getChildById('mana')
    for pct = 100, 0, -5 do
      hpBox:addOption(pct .. '%', pct)
      manaBox:addOption(pct .. '%', pct)
    end
    row.actionSlot, row.hpBox, row.manaBox = slot, hpBox, manaBox
    bindActionSlot(slot, {
      allow = { spell = true, item = true },
      category = 'healing',
      set = function(action) state.healSpells[i].action = action end,
    })
    hpBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      state.healSpells[i].hpPct = data; saveConfig()
    end
    manaBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      state.healSpells[i].manaPct = data; saveConfig()
    end
  end

  buildPotionRows(hpp, NUM_HP_POTION,   state.healHpPotions,   'hpPct')
  buildPotionRows(mpp, NUM_MANA_POTION, state.healManaPotions, 'manaPct')
end

refreshHealRows = function()
  if not window then return end
  local sp  = window:recursiveGetChildById('healSpellSlots')
  local hpp = window:recursiveGetChildById('healHpPotionSlots')
  local mpp = window:recursiveGetChildById('healManaPotionSlots')
  if not sp or not hpp or not mpp then return end

  isRefreshing = true
  for i, row in ipairs(sp:getChildren()) do
    local slot = state.healSpells[i] or { action = nil, hpPct = 70, manaPct = 30 }
    setActionVisual(row.actionSlot, slot.action)
    row.hpBox:setCurrentOptionByData(slot.hpPct or 70, true)
    row.manaBox:setCurrentOptionByData(slot.manaPct or 30, true)
  end
  for i, row in ipairs(hpp:getChildren()) do
    local slot = state.healHpPotions[i] or { itemId = 0, hpPct = 50 }
    setActionVisual(row.actionSlot, slot.action)
    row.thrBox:setCurrentOptionByData(slot.hpPct or 50, true)
  end
  for i, row in ipairs(mpp:getChildren()) do
    local slot = state.healManaPotions[i] or { itemId = 0, manaPct = 30 }
    setActionVisual(row.actionSlot, slot.action)
    row.thrBox:setCurrentOptionByData(slot.manaPct or 30, true)
  end
  isRefreshing = false

  local cb = window:recursiveGetChildById('healEnabled')
  if cb then cb:setChecked(state.healEnabled) end
end

-- =============================================================================
-- UI: Friends tab rows
-- =============================================================================

local function buildFriendRows()
  if not window then return end
  local panel = window:recursiveGetChildById('friendSlots')
  if not panel then return end
  panel:destroyChildren()
  for i = 1, NUM_FRIEND_RULES do
    local row = g_ui.createWidget('RTCasterFriendRow', panel)
    local slot  = row:getChildById('action')
    local hpBox = row:getChildById('hp')
    for pct = 100, 0, -5 do hpBox:addOption(pct .. '%', pct) end
    row.actionSlot, row.hpBox = slot, hpBox
    bindActionSlot(slot, {
      allow = { spell = true, item = true },
      category = 'healing',
      set = function(action) state.friendHeal.rules[i].action = action end,
    })
    hpBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      state.friendHeal.rules[i].hpPct = data; saveConfig()
    end
  end
end

refreshFriendRows = function()
  if not window then return end
  local panel = window:recursiveGetChildById('friendSlots')
  if not panel then return end
  isRefreshing = true
  for i, row in ipairs(panel:getChildren()) do
    local rule = state.friendHeal.rules[i] or { action = nil, hpPct = 70 }
    setActionVisual(row.actionSlot, rule.action)
    row.hpBox:setCurrentOptionByData(rule.hpPct or 70, true)
  end
  local fe = window:recursiveGetChildById('friendEnable')
  if fe then fe:setChecked(state.friendHeal.enabled) end
  local fp = window:recursiveGetChildById('friendParty')
  if fp then fp:setChecked(state.friendHeal.party) end
  local fn = window:recursiveGetChildById('friendNames')
  if fn then fn:setText(state.friendHeal.names or '') end
  isRefreshing = false
end

-- =============================================================================
-- UI: Target tab (monster list)
-- =============================================================================

rebuildMonsterRows = function()
  if not window then return end
  local panel = window:recursiveGetChildById('monsterSlots')
  if not panel then return end
  panel:destroyChildren()

  for i, m in ipairs(state.target.monsters) do
    local row = g_ui.createWidget('RTCasterMonsterRow', panel)
    local nameEdit = row:getChildById('mname')
    local prioBox  = row:getChildById('priority')
    local slot     = row:getChildById('action')
    local removeBtn = row:getChildById('removeBtn')

    for n = 0, 9 do prioBox:addOption(tostring(n), n) end

    isRefreshing = true
    nameEdit:setText(m.name or '')
    prioBox:setCurrentOptionByData(m.priority or 1, true)
    setActionVisual(slot, m.action)
    isRefreshing = false

    nameEdit.onTextChange = function(_, t)
      if isRefreshing then return end
      m.name = t or ''; saveConfig()
    end
    prioBox.onOptionChange = function(_, _, data)
      if isRefreshing then return end
      m.priority = data; saveConfig()
    end
    bindActionSlot(slot, {
      allow = { spell = true, item = true },
      category = 'attack',
      set = function(action) m.action = action end,
    })
    removeBtn.onClick = function()
      for idx, mm in ipairs(state.target.monsters) do
        if mm == m then table.remove(state.target.monsters, idx); break end
      end
      rebuildMonsterRows(); saveConfig()
    end
  end
end

local function addMonster(name)
  if #state.target.monsters >= MAX_MONSTERS then return end
  table.insert(state.target.monsters, { name = name or '', priority = 1, dist = 0, action = nil })
  rebuildMonsterRows(); saveConfig()
end

local function addCurrentTarget()
  local target = g_game.getAttackingCreature()
  local name = target and target:getName() or nil
  if not name and g_game.getFollowingCreature then
    local follow = g_game.getFollowingCreature()
    name = follow and follow:getName() or nil
  end
  addMonster(name or '')
end

refreshTargetFields = function()
  if not window then return end
  isRefreshing = true
  local te = window:recursiveGetChildById('targetEnable')
  if te then te:setChecked(state.target.enabled) end
  local ol = window:recursiveGetChildById('targetOnlyListed')
  if ol then ol:setChecked(state.target.onlyListed) end
  local modeCombo = window:recursiveGetChildById('targetMode')
  if modeCombo then modeCombo:setCurrentOptionByData(state.target.strategy or 'nearest', true) end
  isRefreshing = false
end

-- =============================================================================
-- UI: Tools tab fields
-- =============================================================================

local function attachToolsHandlers()
  if not window then return end

  local mt = window:recursiveGetChildById('manaTrainEnable')
  mt.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('manaTrain', c) end end
  bindActionSlot(window:recursiveGetChildById('manaTrainSpell'), {
    allow = { spell = true }, category = 'all',
    set = function(a) state.manaTrain.spellAction = a; state.manaTrain.spell = (a and a.kind == 'spell') and a.words or '' end,
  })
  local mtm = window:recursiveGetChildById('manaTrainMana')
  for pct = 100, 0, -5 do mtm:addOption(pct .. '%', pct) end
  mtm.onOptionChange = function(_, _, data) if not isRefreshing then state.manaTrain.manaPct = data; saveConfig() end end

  local ah = window:recursiveGetChildById('autoHasteEnable')
  ah.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('autoHaste', c) end end
  local ahpz = window:recursiveGetChildById('autoHastePz')
  ahpz.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('autoHastePz', c) end end
  bindActionSlot(window:recursiveGetChildById('autoHasteSpell'), {
    allow = { spell = true }, category = 'support',
    set = function(a) state.autoHaste.spellAction = a; state.autoHaste.spell = (a and a.kind == 'spell') and a.words or '' end,
  })

  local ex = window:recursiveGetChildById('exerciseEnable')
  ex.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('exercise', c) end end
  local exi = window:recursiveGetChildById('exerciseItemId')
  exi.onTextChange = function(_, t) if not isRefreshing then state.exercise.itemId = t or ''; saveConfig() end end

  local ms = window:recursiveGetChildById('manaShieldEnable')
  if ms then ms.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('manaShield', c) end end end
  bindActionSlot(window:recursiveGetChildById('manaShieldSpell'), {
    allow = { spell = true }, category = 'support',
    set = function(a) state.manaShield.spellAction = a; state.manaShield.spell = (a and a.kind == 'spell') and a.words or '' end,
  })
  local mspz = window:recursiveGetChildById('manaShieldPz')
  if mspz then mspz.onCheckChange = function(_, c) if not isRefreshing then state.manaShield.pz = c and true or false; saveConfig() end end end

  local ap = window:recursiveGetChildById('antiParalyzeEnable')
  if ap then ap.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('antiParalyze', c) end end end
  bindActionSlot(window:recursiveGetChildById('antiParalyzeSpell'), {
    allow = { spell = true }, category = 'support',
    set = function(a) state.antiParalyze.spellAction = a; state.antiParalyze.spell = (a and a.kind == 'spell') and a.words or '' end,
  })

  local sw = window:recursiveGetChildById('autoSwapEnable')
  if sw then sw.onCheckChange = function(_, c) if not isRefreshing then setToolFlag('autoSwap', c) end end end
  local swa = window:recursiveGetChildById('autoSwapAmulet')
  if swa then swa.onTextChange = function(_, t) if not isRefreshing then state.autoSwap.amuletId = t or '0'; saveConfig() end end end
  local swr = window:recursiveGetChildById('autoSwapRing')
  if swr then swr.onTextChange = function(_, t) if not isRefreshing then state.autoSwap.ringId = t or '0'; saveConfig() end end end

  window:recursiveGetChildById('changeGoldEnable').onCheckChange     = function(_, c) if not isRefreshing then setToolFlag('changeGold', c) end end
  window:recursiveGetChildById('autoEatEnable').onCheckChange        = function(_, c) if not isRefreshing then setToolFlag('autoEat', c) end end
  window:recursiveGetChildById('autoReconnectEnable').onCheckChange  = function(_, c) if not isRefreshing then setToolFlag('autoReconnect', c) end end
end

refreshToolsFields = function()
  if not window then return end
  isRefreshing = true

  window:recursiveGetChildById('manaTrainEnable'):setChecked(state.manaTrain.enabled)
  setActionVisual(window:recursiveGetChildById('manaTrainSpell'), state.manaTrain.spellAction)
  window:recursiveGetChildById('manaTrainMana'):setCurrentOptionByData(state.manaTrain.manaPct or 80, true)

  window:recursiveGetChildById('autoHasteEnable'):setChecked(state.autoHaste.enabled)
  window:recursiveGetChildById('autoHastePz'):setChecked(state.autoHaste.pz)
  setActionVisual(window:recursiveGetChildById('autoHasteSpell'), state.autoHaste.spellAction)

  window:recursiveGetChildById('exerciseEnable'):setChecked(state.exercise.enabled)
  window:recursiveGetChildById('exerciseItemId'):setText(state.exercise.itemId or '')

  local function setIf(id, fn) local w = window:recursiveGetChildById(id); if w then fn(w) end end
  setIf('manaShieldEnable',  function(w) w:setChecked(state.manaShield.enabled) end)
  setIf('manaShieldPz',      function(w) w:setChecked(state.manaShield.pz) end)
  setIf('manaShieldSpell',   function(w) setActionVisual(w, state.manaShield.spellAction) end)
  setIf('antiParalyzeEnable',function(w) w:setChecked(state.antiParalyze.enabled) end)
  setIf('antiParalyzeSpell', function(w) setActionVisual(w, state.antiParalyze.spellAction) end)
  setIf('autoSwapEnable',    function(w) w:setChecked(state.autoSwap.enabled) end)
  setIf('autoSwapAmulet',    function(w) w:setText(tostring(state.autoSwap.amuletId or '0')) end)
  setIf('autoSwapRing',      function(w) w:setText(tostring(state.autoSwap.ringId or '0')) end)

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
  lbl('targetKeyLabel', state.hotkeys.target)
  lbl('enableKeyLabel', state.hotkeys.shooter)
  lbl('utitoKeyLabel',  state.hotkeys.utito)
  lbl('runeAttackKeyLabel', state.hotkeys.rune)
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
    chk('enableCheck',   state.shooterEnabled)
    chk('targetEnable',  state.target.enabled)
    chk('autoUtitoCheck',state.autoUtito)
    chk('healEnabled',   state.healEnabled)
    chk('friendEnable',  state.friendHeal.enabled)
    chk('runeAttackEnable', state.runeAttack.enabled)
    local modeCombo = window:recursiveGetChildById('targetMode')
    if modeCombo then modeCombo:setCurrentOptionByData(state.target.strategy or 'nearest', true) end
    isRefreshing = false

    local parts = {}
    if state.shooterEnabled     then table.insert(parts, 'Shooter') end
    if state.runeAttack.enabled then table.insert(parts, 'Rune') end
    if state.target.enabled     then table.insert(parts, 'Target') end
    if state.healEnabled        then table.insert(parts, 'Heal') end
    if state.friendHeal.enabled then table.insert(parts, 'Friends') end
    if state.autoUtito          then table.insert(parts, 'Utito') end
    if state.autoHaste.enabled  then table.insert(parts, 'Haste') end
    if state.manaTrain.enabled  then table.insert(parts, 'ManaTrain') end
    if state.exercise.enabled   then table.insert(parts, 'Exercise') end
    if state.autoEat            then table.insert(parts, 'Eat') end
    if state.changeGold         then table.insert(parts, 'Gold') end
    if state.autoReconnect      then table.insert(parts, 'Reconnect') end

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
  refreshRuneAttack()
  refreshHealRows()
  refreshFriendRows()
  refreshToolsFields()
  refreshTargetFields()
  rebuildMonsterRows()
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
  buildFriendRows()
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
  window:getChildById('tabFriends').onClick = function() switchTab('friends') end
  window:getChildById('tabTarget').onClick  = function() switchTab('target') end
  window:getChildById('tabShooter').onClick = function() switchTab('shooter') end
  window:getChildById('tabTools').onClick   = function() switchTab('tools') end

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

  window:recursiveGetChildById('enableCheck').onCheckChange = function(_, c)
    if isRefreshing then return end; setShooterEnabled(c)
  end
  window:recursiveGetChildById('autoUtitoCheck').onCheckChange = function(_, c)
    if isRefreshing then return end; setAutoUtito(c)
  end
  window:recursiveGetChildById('enableSetKey').onClick = function() openKeyCapture('shooter') end
  window:recursiveGetChildById('utitoSetKey').onClick  = function() openKeyCapture('utito') end

  -- Quick Rune Attack (dedicated toggle + hotkey)
  bindActionSlot(window:recursiveGetChildById('runeAttackSlot'), {
    allow = { item = true },
    category = 'Attack Runes',
    set = function(action) state.runeAttack.action = action end,
  })
  local ram = window:recursiveGetChildById('runeAttackMobs')
  for n = 1, NUM_SHOOTER_SLOTS do ram:addOption(n .. '+', n) end
  ram.onOptionChange = function(_, _, data)
    if isRefreshing then return end
    state.runeAttack.creatures = data; saveConfig()
  end
  window:recursiveGetChildById('runeAttackEnable').onCheckChange = function(_, c)
    if isRefreshing then return end; setRuneAttackEnabled(c)
  end
  window:recursiveGetChildById('runeAttackSetKey').onClick = function() openKeyCapture('rune') end

  -- Target panel
  window:recursiveGetChildById('targetEnable').onCheckChange = function(_, c)
    if isRefreshing then return end; setTargetEnabled(c)
  end
  window:recursiveGetChildById('targetOnlyListed').onCheckChange = function(_, c)
    if isRefreshing then return end; state.target.onlyListed = c and true or false; saveConfig()
  end
  local modeCombo = window:recursiveGetChildById('targetMode')
  modeCombo:addOption('Nearest',        'nearest')
  modeCombo:addOption('Farthest',       'farthest')
  modeCombo:addOption('Most HP',        'most_hp')
  modeCombo:addOption('Least HP',       'least_hp')
  modeCombo:addOption('Most HP (box)',  'most_hp_box')
  modeCombo:addOption('Least HP (box)', 'least_hp_box')
  modeCombo.onOptionChange = function(_, _, data)
    if isRefreshing then return end
    state.target.strategy = data or 'nearest'; saveConfig()
  end
  window:recursiveGetChildById('targetSetKey').onClick    = function() openKeyCapture('target') end
  window:recursiveGetChildById('targetAddCurrent').onClick = function() addCurrentTarget() end
  window:recursiveGetChildById('targetAddEmpty').onClick   = function() addMonster('') end

  -- Healing panel
  window:recursiveGetChildById('healEnabled').onCheckChange = function(_, c)
    if isRefreshing then return end; setHealEnabled(c)
  end

  -- Friends panel
  window:recursiveGetChildById('friendEnable').onCheckChange = function(_, c)
    if isRefreshing then return end; setFriendEnabled(c)
  end
  window:recursiveGetChildById('friendParty').onCheckChange = function(_, c)
    if isRefreshing then return end; state.friendHeal.party = c and true or false; saveConfig()
  end
  window:recursiveGetChildById('friendNames').onTextChange = function(_, t)
    if isRefreshing then return end; state.friendHeal.names = t or ''; saveConfig()
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
  closePicker()
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

function init()
  g_logger.info('[renaot_rtcaster] init()')
  g_ui.importStyle('rtcaster.otui')
  buildItemDb()
  buildSpellDb()
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
  closePicker()
  closeWindow()
  if statsWin   then statsWin:destroy();   statsWin   = nil end
  if captureWin then captureWin:destroy(); captureWin = nil end
  if miniPanel  then miniPanel:destroy();  miniPanel  = nil end
end
