-- Weapon Proficiency window — RubinOT-style polish v2.
--
-- Server protocol:
--   GameServerWeaponProficiencyExperience (92 / 0x5C):  itemId, exp
--   GameServerWeaponProficiencyInfo       (196 / 0xC4): itemId, exp, [{level, perkSlot}]
--   ClientWeaponProficiencyAction         (234 / 0xEA): action, itemId, [level, [slot]]

g_logger.info('[game_proficiency] script file evaluated')

ProficiencyController = Controller:new()

local WIN_PATH = 'game_proficiency'
local MAX_LEVEL = 7
local PERKS_PER_LEVEL = 3
local MASTERY_SLOTS = 7
local KNOWN_KEY = 'renaot_proficiency_known_v1'  -- g_settings key

local CURVES = {
  knight   = { 1250, 6000, 30000, 150000, 750000, 4000000, 20000000 },
  generic  = { 1750, 9000, 45000, 225000, 1125000, 6000000, 30000000 },
  distance = { 600, 3000, 15000, 75000, 375000, 2000000, 10000000 },
}

local CATEGORY_SAMPLES = {
  Swords   = 3299,
  Axes     = 3274,
  Clubs    = 3263,
  Distance = 3350,
  Magic    = 3074,
  Fist     = 32385,
}

local function iconFor(label)
  local l = (label or ''):lower()
  if l:find('crit dmg')                 then return '/images/game/wheel/icon-modgrade3' end
  if l:find('crit')                     then return '/images/game/wheel/icon-crit' end
  if l:find('l%.leech') or l:find('leech') then return '/images/game/wheel/icon-modgrade1' end
  if l:find('ml')                       then return '/images/game/wheel/icon-modgrade4' end
  if l:find('skill')                    then return '/images/game/wheel/icon-modgrade2' end
  return '/images/game/wheel/icon-spelldamage'
end

local PERK_DEFS_KNIGHT = {
  [1] = { { label = '+3% dmg',     tip = '+3% damage' },          { label = '+2 skill',      tip = '+2 weapon skill' },        { label = '+1% crit',     tip = '+1% crit chance' } },
  [2] = { { label = '+5% dmg',     tip = '+5% damage' },          { label = '+4 skill',      tip = '+4 weapon skill' },        { label = '+2% crit',     tip = '+2% crit chance' } },
  [3] = { { label = '+5% leech c', tip = '+5% life leech chance' }, { label = '+8% crit dmg',  tip = '+8% critical damage' }, { label = '+3% dmg',      tip = '+3% damage' } },
  [4] = { { label = '+8% dmg',     tip = '+8% damage' },          { label = '+6 skill',      tip = '+6 weapon skill' },        { label = '+3% crit',     tip = '+3% crit chance' } },
  [5] = { { label = '+4% leech',   tip = '+4% life leech amount' }, { label = '+12% crit dmg', tip = '+12% critical damage' }, { label = '+5% dmg',      tip = '+5% damage' } },
  [6] = { { label = '+10 skill',   tip = '+10 weapon skill' },    { label = '+5% m.leech',   tip = '+5% mana leech amount' },  { label = '+5% crit',     tip = '+5% crit chance' } },
  [7] = { { label = '+15% dmg',    tip = '+15% damage' },         { label = '+25% crit dmg', tip = '+25% critical damage' },   { label = '+8% leech',    tip = '+8% life leech amount' } },
}
local PERK_DEFS_DISTANCE = {
  [1] = { { label = '+3% dmg',     tip = '+3% damage' },          { label = '+3 skill',      tip = '+3 distance skill' },      { label = '+1.5% crit',   tip = '+1.5% crit chance' } },
  [2] = { { label = '+5% dmg',     tip = '+5% damage' },          { label = '+5 skill',      tip = '+5 distance skill' },      { label = '+3% crit',     tip = '+3% crit chance' } },
  [3] = { { label = '+6% crit dmg',tip = '+6% critical damage' }, { label = '+3% leech c',   tip = '+3% life leech chance' },  { label = '+4 skill',     tip = '+4 distance skill' } },
  [4] = { { label = '+7% dmg',     tip = '+7% damage' },          { label = '+7 skill',      tip = '+7 distance skill' },      { label = '+5% crit',     tip = '+5% crit chance' } },
  [5] = { { label = '+15% crit dmg',tip = '+15% critical damage' },{ label = '+3% leech',    tip = '+3% life leech amount' },  { label = '+6% dmg',      tip = '+6% damage' } },
  [6] = { { label = '+12 skill',   tip = '+12 distance skill' },  { label = '+7% crit',      tip = '+7% crit chance' },        { label = '+4% m.leech',  tip = '+4% mana leech amount' } },
  [7] = { { label = '+18% dmg',    tip = '+18% damage' },         { label = '+30% crit dmg', tip = '+30% critical damage' },   { label = '+15 skill',    tip = '+15 distance skill' } },
}
local PERK_DEFS_MAGIC = {
  [1] = { { label = '+3% dmg',     tip = '+3% magic damage' },    { label = '+1 ML',         tip = '+1 magic level' },         { label = '+1% crit',     tip = '+1% crit chance' } },
  [2] = { { label = '+5% dmg',     tip = '+5% magic damage' },    { label = '+2 ML',         tip = '+2 magic level' },         { label = '+2% crit',     tip = '+2% crit chance' } },
  [3] = { { label = '+5% m.leech c', tip = '+5% mana leech chance' },{ label = '+7% crit dmg', tip = '+7% critical damage' }, { label = '+3% dmg',      tip = '+3% magic damage' } },
  [4] = { { label = '+8% dmg',     tip = '+8% magic damage' },    { label = '+3 ML',         tip = '+3 magic level' },         { label = '+3.5% crit',   tip = '+3.5% crit chance' } },
  [5] = { { label = '+6% m.leech', tip = '+6% mana leech amount' },{ label = '+13% crit dmg',tip = '+13% critical damage' },  { label = '+5% dmg',      tip = '+5% magic damage' } },
  [6] = { { label = '+5 ML',       tip = '+5 magic level' },      { label = '+8% m.leech',   tip = '+8% mana leech amount' },  { label = '+6% crit',     tip = '+6% crit chance' } },
  [7] = { { label = '+17% dmg',    tip = '+17% magic damage' },   { label = '+28% crit dmg', tip = '+28% critical damage' },   { label = '+8 ML',        tip = '+8 magic level' } },
}
local PERK_DEFS_FIST = {
  [1] = { { label = '+4% dmg',     tip = '+4% damage' },          { label = '+2 skill',      tip = '+2 fist skill' },          { label = '+1.5% crit',   tip = '+1.5% crit chance' } },
  [2] = { { label = '+6% dmg',     tip = '+6% damage' },          { label = '+4 skill',      tip = '+4 fist skill' },          { label = '+2.5% crit',   tip = '+2.5% crit chance' } },
  [3] = { { label = '+6% leech c', tip = '+6% life leech chance' },{ label = '+9% crit dmg', tip = '+9% critical damage' },    { label = '+4% dmg',      tip = '+4% damage' } },
  [4] = { { label = '+9% dmg',     tip = '+9% damage' },          { label = '+6 skill',      tip = '+6 fist skill' },          { label = '+4% crit',     tip = '+4% crit chance' } },
  [5] = { { label = '+5% leech',   tip = '+5% life leech amount' },{ label = '+14% crit dmg',tip = '+14% critical damage' },  { label = '+6% dmg',      tip = '+6% damage' } },
  [6] = { { label = '+10 skill',   tip = '+10 fist skill' },      { label = '+7% leech',     tip = '+7% life leech amount' },  { label = '+6% crit',     tip = '+6% crit chance' } },
  [7] = { { label = '+17% dmg',    tip = '+17% damage' },         { label = '+27% crit dmg', tip = '+27% critical damage' },   { label = '+9% leech',    tip = '+9% life leech amount' } },
}

local function perksFor(category)
  if category == 'Distance' then return PERK_DEFS_DISTANCE end
  if category == 'Magic'    then return PERK_DEFS_MAGIC    end
  if category == 'Fist'     then return PERK_DEFS_FIST     end
  return PERK_DEFS_KNIGHT
end

-- =====================================================================
-- Public
-- =====================================================================

function requestOpenWindow(item)
  if not item then return end
  local id = item:getId()
  ProficiencyController.pendingItemId = id
  ProficiencyController.activeItem = item
  g_game.weaponProficiencyAction(0, id, 0, 0)
end

-- =====================================================================
-- Lifecycle
-- =====================================================================

local proficiencyTopButton = nil

function init()
  g_logger.info('[game_proficiency] init() entered')
  ProficiencyController:init()
  if modules.game_mainpanel then
    proficiencyTopButton = modules.game_mainpanel.addToggleButton(
      'proficiencyButton',
      tr('Weapon Proficiency'),
      '/images/options/button_proficiency',
      function() ProficiencyController:toggleFromButton() end,
      false,
      11
    )
    if proficiencyTopButton then proficiencyTopButton:setOn(false) end
  end
end

function terminate()
  if proficiencyTopButton then
    proficiencyTopButton:destroy()
    proficiencyTopButton = nil
  end
  ProficiencyController:terminate()
end

function ProficiencyController:onGameStart()
  if g_game.getClientVersion() < 1281 then
    self:scheduleEvent(function()
      g_modules.getModule('game_proficiency'):unload()
    end, 100, 'unloadProf')
    return
  end
  self:registerEvents(g_game, {
    onParseWeaponProficiencyInfo = function(itemId, exp, perks)
      self:onInfo(itemId, exp, perks)
    end,
    onParseWeaponProficiencyExperience = function(itemId, exp)
      self:onExperience(itemId, exp)
    end,
  })
end

function ProficiencyController:onGameEnd()
  self.state = nil
  self.selectedCategory = nil
  self:hide()
end

function ProficiencyController:onTerminate()
  self:hide()
end

function ProficiencyController:toggleFromButton()
  if self.ui and self.ui:isVisible() then self:hide() return end
  local player = g_game.getLocalPlayer()
  if not player then return end
  local item = player:getInventoryItem(InventorySlotLeft) or player:getInventoryItem(InventorySlotRight)
  if item then
    if proficiencyTopButton then proficiencyTopButton:setOn(true) end
    requestOpenWindow(item)
    return
  end
  if proficiencyTopButton then proficiencyTopButton:setOn(true) end
  self:openCategory('Swords')
end

-- =====================================================================
-- Known-weapons cache (client-side, persists across sessions)
-- =====================================================================

local function loadKnownCache()
  local raw = g_settings.getNode(KNOWN_KEY)
  if type(raw) ~= 'table' then return {} end
  return raw
end

local function saveKnownCache(cache)
  g_settings.setNode(KNOWN_KEY, cache)
  g_settings.save()
end

local function rememberWeapon(itemId, exp)
  if not itemId or itemId <= 0 then return end
  -- Only remember weapons that actually have XP; skip cosmetic 0-XP samples.
  if (exp or 0) <= 0 then return end
  local cache = loadKnownCache()
  cache[tostring(itemId)] = math.max(cache[tostring(itemId)] or 0, exp)
  saveKnownCache(cache)
end

-- =====================================================================
-- Incoming packets
-- =====================================================================

function ProficiencyController:onInfo(itemId, exp, perks)
  local active = {}
  for _, encoded in ipairs(perks or {}) do
    local n = tonumber(encoded) or 0
    local level = math.floor(n / 256)
    local slot = n % 256
    if level > 0 then active[level] = slot end
  end
  local prevExp = (self.state and self.state.itemId == itemId) and self.state.exp or 0
  self.state = { itemId = itemId, exp = tonumber(exp) or 0, active = active }
  rememberWeapon(itemId, self.state.exp)

  if self.pendingItemId == itemId then
    self.pendingItemId = nil
    self:show()
  elseif self.ui and self.ui:isVisible() and self.windowItemId == itemId then
    self:render()
    if self.state.exp > prevExp then self:flashXp(prevExp, self.state.exp) end
  end
end

function ProficiencyController:onExperience(itemId, exp)
  if not (self.ui and self.ui:isVisible() and self.windowItemId == itemId) then
    -- Even without window open, remember it for the dropdown later.
    rememberWeapon(itemId, tonumber(exp) or 0)
    return
  end
  if self.state and self.state.itemId == itemId then
    local prevExp = self.state.exp
    self.state.exp = tonumber(exp) or self.state.exp
    rememberWeapon(itemId, self.state.exp)
    self:render()
    if self.state.exp > prevExp then self:flashXp(prevExp, self.state.exp) end
  end
end

-- =====================================================================
-- Window
-- =====================================================================

function ProficiencyController:show()
  if not self.state then return end
  if not self.ui then
    local ok, ui = pcall(g_ui.displayUI, WIN_PATH)
    if not ok or not ui then
      g_logger.error('[game_proficiency] displayUI failed: ' .. tostring(ui))
      return
    end
    self.ui = ui
    local wOk, wErr = pcall(function() self:wireUI() end)
    if not wOk then g_logger.error('[game_proficiency] wireUI failed: ' .. tostring(wErr)) end
    self.ui.onKeyPress = function(_, keyCode)
      if keyCode == KeyEscape then self:hide(); return true end
      return false
    end
  end
  self.windowItemId = self.state.itemId
  local rOk, rErr = pcall(function() self:render() end)
  if not rOk then g_logger.error('[game_proficiency] render failed: ' .. tostring(rErr)) end
  self.ui:show()
  self.ui:raise()
  self.ui:focus()
end

function ProficiencyController:hide()
  if self.ui then
    self.ui:destroy()
    self.ui = nil
  end
  self.windowItemId = nil
  if proficiencyTopButton then proficiencyTopButton:setOn(false) end
end

function ProficiencyController:wireUI()
  local btns = {
    applyButton = function() self:refresh() end,
    resetButton = function() self:resetAll() end,
    closeButton = function() self:hide() end,
  }
  for id, fn in pairs(btns) do
    local b = self.ui:recursiveGetChildById(id)
    if b then b.onClick = fn end
  end
  local tabMap = {
    tabSwords='Swords', tabAxes='Axes', tabClubs='Clubs',
    tabDistance='Distance', tabMagic='Magic', tabFist='Fist',
  }
  for tabId, cat in pairs(tabMap) do
    local tab = self.ui:recursiveGetChildById(tabId)
    if tab then tab.onClick = function() self:openCategory(cat) end end
  end

end


function ProficiencyController:openCategory(category)
  local player = g_game.getLocalPlayer()
  local chosenItem

  if player then
    local function maybe(it)
      if not it or chosenItem then return end
      local tt = g_things.getThingType(it:getId(), ThingCategoryItem)
      if tt and categoryFromName(tt:getName()) == category then chosenItem = it end
    end
    maybe(player:getInventoryItem(InventorySlotLeft))
    maybe(player:getInventoryItem(InventorySlotRight))
    for _, c in pairs(g_game.getContainers() or {}) do
      for _, it in pairs(c:getItems() or {}) do maybe(it) end
    end
  end

  if chosenItem then requestOpenWindow(chosenItem); return end

  local chosenId = CATEGORY_SAMPLES[category]
  if not chosenId then return end
  self.selectedCategory = category
  self.state = { itemId = chosenId, exp = 0, active = {} }
  self.pendingItemId = chosenId
  g_game.weaponProficiencyAction(0, chosenId, 0, 0)
  self:show()
end

function ProficiencyController:refresh()
  if self.state then g_game.weaponProficiencyAction(0, self.state.itemId, 0, 0) end
end

function ProficiencyController:resetAll()
  if not (self.state and self.state.itemId) then return end
  for lvl = 1, MAX_LEVEL do
    if (self.state.active[lvl] or 0) ~= 0 then
      g_game.weaponProficiencyAction(2, self.state.itemId, lvl, 0)
    end
  end
end

-- =====================================================================
-- Bonus summary (parse perk labels into typed numeric sums)
-- =====================================================================

local function addBonus(map, key, n)
  if not n then return end
  map[key] = (map[key] or 0) + n
end

local function parsePerk(label)
  -- Returns category, numeric_value, is_percentage
  local l = (label or ''):lower()
  -- Match "+X%" or "+X.Y%" prefix
  local num = l:match('^%+([%d%.]+)%%')
  if num then
    local v = tonumber(num)
    if v then
      if l:find('crit dmg') then return 'critDmg', v, true end
      if l:find('crit')     then return 'crit',    v, true end
      if l:find('m%.leech') then return 'mLeech',  v, true end
      if l:find('leech c')  then return 'lLeechC', v, true end
      if l:find('leech')    then return 'lLeech',  v, true end
      if l:find('dmg')      then return 'dmg',     v, true end
    end
  end
  -- Match "+X skill", "+X ML", "+X" (non-percent)
  num = l:match('^%+(%d+)%s')
  if num then
    local v = tonumber(num)
    if v then
      if l:find('ml')    then return 'magicLevel', v, false end
      if l:find('skill') then return 'skill',      v, false end
    end
  end
  return nil
end

local BONUS_ORDER = { 'dmg', 'crit', 'critDmg', 'skill', 'magicLevel', 'lLeech', 'lLeechC', 'mLeech' }
local BONUS_LABELS = {
  dmg        = 'Damage',
  crit       = 'Crit Chance',
  critDmg    = 'Crit Damage',
  skill      = 'Weapon Skill',
  magicLevel = 'Magic Level',
  lLeech     = 'Life Leech',
  lLeechC    = 'Life Leech Chance',
  mLeech     = 'Mana Leech',
}
local BONUS_PERCENT = { dmg=true, crit=true, critDmg=true, lLeech=true, lLeechC=true, mLeech=true }

function ProficiencyController:computeBonuses(category)
  local s = self.state
  if not s then return {} end
  local defs = perksFor(category)
  local bonuses = {}
  for lvl = 1, MAX_LEVEL do
    local slot = s.active[lvl]
    if slot and slot > 0 then
      local def = (defs[lvl] or {})[slot]
      if def then
        local key, val = parsePerk(def.label)
        if key then addBonus(bonuses, key, val) end
      end
    end
  end
  return bonuses
end

function ProficiencyController:renderBonuses(category)
  local grid = self.ui:recursiveGetChildById('bonusGrid')
  if not grid then return end
  grid:destroyChildren()
  local bonuses = self:computeBonuses(category)
  local anyShown = false
  for _, key in ipairs(BONUS_ORDER) do
    local v = bonuses[key]
    if v and v > 0 then
      local label = g_ui.createWidget('BonusLine', grid)
      local suffix = BONUS_PERCENT[key] and '%' or ''
      label:setText(string.format('+%s%s %s', tostring(v):gsub('%.0$', ''), suffix, BONUS_LABELS[key]))
      anyShown = true
    end
  end
  if not anyShown then
    local label = g_ui.createWidget('BonusLine', grid)
    label:setText('(no perks selected)')
    label:setColor('#888888')
  end
end

-- =====================================================================
-- Animations
-- =====================================================================

function ProficiencyController:flashXp(prevExp, newExp)
  if not self.ui or self.ui:isDestroyed() then return end

  local function alive(w) return w and not w:isDestroyed() end

  local bar = self.ui:recursiveGetChildById('xpBar')
  if alive(bar) then
    pcall(function() bar:setBackgroundColor('#d4a040') end)
    scheduleEvent(function()
      if alive(bar) then pcall(function() bar:setBackgroundColor('#1c1c1c') end) end
    end, 350)
  end

  local s = self.state
  if not s then return end
  local itemType = g_things.getThingType(s.itemId, ThingCategoryItem)
  local weaponName = itemType and itemType:getName() or ''
  local curve = pickCurve(weaponName)
  local function levelFor(exp)
    local l = 0
    for i = MAX_LEVEL, 1, -1 do
      if exp >= curve[i] then l = i; break end
    end
    return l
  end
  local prevLvl, newLvl = levelFor(prevExp), levelFor(newExp)
  if newLvl > prevLvl then
    local row = self.ui:recursiveGetChildById('starsRow')
    if alive(row) then
      local star = row:getChildByIndex(newLvl)
      if alive(star) then
        for i = 1, 3 do
          scheduleEvent(function()
            if alive(star) then
              pcall(function() star:setOpacity(0.3) end)
              scheduleEvent(function()
                if alive(star) then pcall(function() star:setOpacity(1.0) end) end
              end, 120)
            end
          end, (i - 1) * 250)
        end
      end
    end
  end
end

-- =====================================================================
-- Render
-- =====================================================================

function pickCurve(weaponName)
  local n = (weaponName or ''):lower()
  if n:find('sword') or n:find('axe') or n:find('club') or n:find('mace') or n:find('hammer')
     or n:find('sabre') or n:find('blade') or n:find('razor') or n:find('katana')
     or n:find('halberd') or n:find('hatchet') or n:find('cleaver') or n:find('cudgel')
     or n:find('morningstar') or n:find('flail') or n:find('cutlass') or n:find('falchion')
     or n:find('scimitar') or n:find('rapier') then
    return CURVES.knight
  elseif n:find('bow') or n:find('crossbow') or n:find('javelin') or n:find('spear') or n:find('throw') then
    return CURVES.distance
  end
  return CURVES.generic
end

function categoryFromName(weaponName)
  local n = (weaponName or ''):lower()
  if n:find('sword') or n:find('sabre') or n:find('blade') or n:find('rapier')
     or n:find('razor') or n:find('katana') or n:find('cutlass') or n:find('falchion')
     or n:find('scimitar')                                                        then return 'Swords' end
  if n:find('axe') or n:find('halberd') or n:find('hatchet') or n:find('cleaver') then return 'Axes' end
  if n:find('club') or n:find('mace') or n:find('hammer') or n:find('staff')
     or n:find('cudgel') or n:find('morningstar') or n:find('flail')              then return 'Clubs' end
  if n:find('bow') or n:find('crossbow') or n:find('javelin') or n:find('spear')
     or n:find('throw')                                                           then return 'Distance' end
  if n:find('wand') or n:find('rod')                                              then return 'Magic' end
  if n:find('fist') or n:find('glove') or n:find('knuckle')                       then return 'Fist' end
  return 'Swords'
end

function ProficiencyController:_humanNum(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format('%.2fM', n / 1000000) end
  if n >= 1000    then return string.format('%.1fk', n / 1000) end
  return tostring(n)
end

local function setVisible(w, v) if w then w:setVisible(v) end end

local function starStyleFor(level, mastery)
  if level > mastery then return 'StarIconDim' end
  if level >= 5 then return 'StarIconGold' end
  if level >= 3 then return 'StarIconSilver' end
  return 'StarIconBronze'
end

function ProficiencyController:render()
  local s = self.state
  if not s or not self.ui then return end

  local itemType = g_things.getThingType(s.itemId, ThingCategoryItem)
  local weaponName = itemType and itemType:getName() or string.format('Item %d', s.itemId)
  local curve = pickCurve(weaponName)
  local category = categoryFromName(weaponName)

  local level = 0
  for i = MAX_LEVEL, 1, -1 do
    if s.exp >= curve[i] then level = i; break end
  end
  local prevThr = level > 0 and curve[level] or 0
  local nextThr = curve[math.min(level + 1, MAX_LEVEL)]
  local pct = (level < MAX_LEVEL and nextThr > prevThr) and (s.exp - prevThr) / (nextThr - prevThr) or 1

  local preview = self.ui:recursiveGetChildById('itemPreview')
  if preview then preview:setItemId(s.itemId) end
  self.ui:recursiveGetChildById('itemName'):setText(weaponName)
  self.ui:recursiveGetChildById('xpLabel'):setText(
    string.format('%s / %s', self:_humanNum(s.exp), self:_humanNum(level < MAX_LEVEL and nextThr or curve[MAX_LEVEL])))
  local toGo = (level < MAX_LEVEL) and (nextThr - s.exp) or 0
  self.ui:recursiveGetChildById('xpToNext'):setText(
    (level < MAX_LEVEL) and (self:_humanNum(toGo) .. ' XP for next level') or 'MAX LEVEL')
  self.ui:recursiveGetChildById('xpBar'):setPercent(math.floor(pct * 100))
  self.ui:recursiveGetChildById('categoryLabel'):setText('Weapons: ' .. category)

  local selectedPerks = 0
  for lvl = 1, MAX_LEVEL do
    if (s.active[lvl] or 0) ~= 0 then selectedPerks = selectedPerks + 1 end
  end
  self.ui:recursiveGetChildById('levelText'):setText(
    string.format('Mastery Level: %d / %d', level, MAX_LEVEL))
  self.ui:recursiveGetChildById('totalPerksText'):setText(
    string.format('Perks selected: %d / %d', selectedPerks, MAX_LEVEL))

  local map = { tabSwords='Swords', tabAxes='Axes', tabClubs='Clubs',
                tabDistance='Distance', tabMagic='Magic', tabFist='Fist' }
  for tabId, cat in pairs(map) do
    local t = self.ui:recursiveGetChildById(tabId)
    if t then t:setChecked(cat == category) end
  end

  local starsRow = self.ui:recursiveGetChildById('starsRow')
  starsRow:destroyChildren()
  for i = 1, MAX_LEVEL do g_ui.createWidget(starStyleFor(i, level), starsRow) end

  local lvlHdr = self.ui:recursiveGetChildById('levelHeaderRow')
  lvlHdr:destroyChildren()
  for i = 1, MAX_LEVEL do
    local lab = g_ui.createWidget('ColumnHeader', lvlHdr)
    lab:setText('Lv ' .. i)
    lab:setColor(i <= level and '#d4a040' or '#707070')
  end

  local perkDefs = perksFor(category)
  local perksGrid = self.ui:recursiveGetChildById('perksGrid')
  perksGrid:destroyChildren()
  for slot = 1, PERKS_PER_LEVEL do
    for lvl = 1, MAX_LEVEL do
      local cell = g_ui.createWidget('PerkSlot', perksGrid)
      local def = (perkDefs[lvl] or {})[slot] or { label = '?', tip = '' }
      cell:setText(def.label)
      cell:setTooltip(string.format('Level %d  •  %s', lvl, def.tip or def.label))

      local icon = g_ui.createWidget('PerkSlotIcon', cell)
      if icon then icon:setImageSource(iconFor(def.label)) end

      local unlocked = lvl <= level
      local isActive = (s.active[lvl] or 0) == slot
      cell:setEnabled(unlocked)
      cell:setOn(isActive)
      cell.onClick = function()
        if not unlocked then return end
        if isActive then
          g_game.weaponProficiencyAction(2, s.itemId, lvl, 0)
        else
          g_game.weaponProficiencyAction(3, s.itemId, lvl, slot)
        end
      end
    end
  end

  local lockRow = self.ui:recursiveGetChildById('lockRow')
  lockRow:destroyChildren()
  for i = 1, MASTERY_SLOTS do
    local container = g_ui.createWidget('UIWidget', lockRow)
    container:setSize({ width = 72, height = 22 })
    local lock = g_ui.createWidget(i <= level and 'LockIconOpen' or 'LockIcon', container)
    lock:addAnchor(AnchorHorizontalCenter, 'parent', AnchorHorizontalCenter)
    lock:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
  end

  setVisible(self.ui:recursiveGetChildById('statusBanner'), level == 0)

  self:renderBonuses(category)
  self:renderItemList(category)
end

function ProficiencyController:renderItemList(currentCategory)
  local list = self.ui:recursiveGetChildById('itemList')
  if not list then return end
  list:destroyChildren()

  local player = g_game.getLocalPlayer()
  if not player then return end

  local seen = {}
  local items = {}
  local function consider(it)
    if not it then return end
    local id = it:getId()
    if seen[id] then return end
    local tt = g_things.getThingType(id, ThingCategoryItem)
    if not tt then return end
    if categoryFromName(tt:getName()) == currentCategory then
      seen[id] = true
      items[#items + 1] = it
    end
  end
  consider(player:getInventoryItem(InventorySlotLeft))
  consider(player:getInventoryItem(InventorySlotRight))
  for _, container in pairs(g_game.getContainers() or {}) do
    for _, it in pairs(container:getItems() or {}) do consider(it) end
  end

  for _, it in ipairs(items) do
    local cell = g_ui.createWidget('UIItem', list)
    cell:setSize({ width = 32, height = 32 })
    cell:setItemId(it:getId())
    cell:setVirtual(true)
    local tt = g_things.getThingType(it:getId(), ThingCategoryItem)
    cell:setTooltip(tt and tt:getName() or '')
    local capturedItem = it
    cell.onClick = function() requestOpenWindow(capturedItem) end
  end

  if #items == 0 then
    local sampleId = CATEGORY_SAMPLES[currentCategory]
    if sampleId then
      local cell = g_ui.createWidget('UIItem', list)
      cell:setSize({ width = 32, height = 32 })
      cell:setItemId(sampleId)
      cell:setVirtual(true)
      cell:setTooltip(currentCategory .. ' — sample weapon')
      cell.onClick = function() self:openCategory(currentCategory) end
    end
  end
end
