local ADDON = ...
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("CONFIRM_LOOT_ROLL")
f:RegisterEvent("CONFIRM_DISENCHANT_ROLL")
f:RegisterEvent("LOOT_BIND_CONFIRM")

local QUAL_UNCOMMON, QUAL_RARE, QUAL_EPIC = 2, 3, 4

local defaults = {
  boeOnly = true,
  autoEnable = false,
  deArmor = true,
  deWeapons = true,
  greedQualities = {
    [QUAL_UNCOMMON] = true,
    [QUAL_RARE]     = true,
    [QUAL_EPIC]     = false,
  },
}

local Session = { enabled = false }

local function ApplyDefaults(t, d)
  if type(t) ~= "table" then t = {} end
  for k, v in pairs(d) do
    if type(v) == "table" then
      t[k] = ApplyDefaults(t[k], v)
    elseif t[k] == nil then
      t[k] = v
    end
  end
  return t
end

local function IsAtMaxLevel()
  local max = (type(MAX_PLAYER_LEVEL) == "number" and MAX_PLAYER_LEVEL) or 80
  return UnitLevel("player") >= max
end

local WEAPON_LOC = {
  INVTYPE_WEAPON = true,
  INVTYPE_WEAPONMAINHAND = true,
  INVTYPE_WEAPONOFFHAND = true,
  INVTYPE_2HWEAPON = true,
  INVTYPE_RANGED = true,
  INVTYPE_RANGEDRIGHT = true,
  INVTYPE_THROWN = true,
}
local ARMOR_LOC = {
  INVTYPE_HEAD = true, INVTYPE_SHOULDER = true, INVTYPE_CHEST = true, INVTYPE_ROBE = true,
  INVTYPE_WAIST = true, INVTYPE_LEGS = true, INVTYPE_FEET = true, INVTYPE_WRIST = true,
  INVTYPE_HAND = true, INVTYPE_CLOAK = true, INVTYPE_SHIELD = true,
}

local function ClassifyEquipLoc(loc)
  if not loc or loc == "" then return "other" end
  if WEAPON_LOC[loc] then return "weapon" end
  if ARMOR_LOC[loc] then return "armor" end
  return "other"
end

local rollQueue, queueTimerNext = {}, 0
local function EnqueueRoll(rollID, rollType)
  table.insert(rollQueue, {id = rollID, type = rollType})
end

local queueRunner = CreateFrame("Frame")
queueRunner:SetScript("OnUpdate", function(self, elapsed)
  if #rollQueue == 0 then return end
  if GetTime() >= queueTimerNext then
    local job = table.remove(rollQueue, 1)
    if job and job.id and job.type then
      RollOnLoot(job.id, job.type)
    end
    queueTimerNext = GetTime() + 0.3
  end
end)

local function ShouldHandleQuality(q)
  local gq = GreedMasterDB.greedQualities
  return gq and gq[q] == true
end

local timers = {}
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(self, elapsed)
  for i = #timers, 1, -1 do
    local t = timers[i]
    t.t = t.t - elapsed
    if t.t <= 0 then
      table.remove(timers, i)
      pcall(t.f)
    end
  end
end)
local function After(delay, func)
  table.insert(timers, { t = delay or 0, f = func })
end

local function ClickPopup(which)
  for i = 1, STATICPOPUP_NUMDIALOGS do
    local frame = _G["StaticPopup"..i]
    if frame and frame:IsShown() and frame.which == which then
      StaticPopup_OnClick(frame, 1)
    end
  end
end

local function ConfirmRollPopups()
  ClickPopup("CONFIRM_LOOT_ROLL")
  ClickPopup("CONFIRM_DISENCHANT_ROLL")
end

local function ConfirmLootBindPopups()
  for i = 1, STATICPOPUP_NUMDIALOGS do
    local frame = _G["StaticPopup"..i]
    if frame and frame:IsShown() and frame.which == "LOOT_BIND" then
      local slot = frame.data
      if slot then pcall(ConfirmLootSlot, slot) end
      StaticPopup_OnClick(frame, 1)
    end
  end
end

StaticPopupDialogs["GREEDMASTER_ENABLE_CONFIRM"] = {
  text = "Включить GreedMaster?\n|cffff2020Учтите, что любые проблемы с получением лута из-за аддона НЕ МОДЕРИРУЮТСЯ!!!|r",
  button1 = ENABLE,
  button2 = CANCEL,
  OnAccept = function()
    Session.enabled = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMaster включен на текущую сессию.|r")
  end,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  preferredIndex = 3,
}

local function ShowEnablePopup()
  StaticPopup_Show("GREEDMASTER_ENABLE_CONFIRM")
end

local function CreateMinimapButton()
  if GreedMasterMiniMapButton then GreedMasterMiniMapButton:Hide() end
end

local function TryAutoRoll(rollID)
  if not Session.enabled then return end
  if not IsAtMaxLevel() then return end

  local _, name, _, quality, bindOnPickUp, _, canGreed, canDisenchant = GetLootRollItemInfo(rollID)
  if not name or not quality then return end
  if not ShouldHandleQuality(quality) then return end

  if GreedMasterDB.boeOnly and bindOnPickUp then
    return
  end

  local itemLink = GetLootRollItemLink(rollID)
  local rollType

  if quality == QUAL_EPIC then
    if canGreed then rollType = 2 else return end

  else
    local equipLoc
    if itemLink then
      local _, _, _, _, _, _, _, _, loc = GetItemInfo(itemLink)
      equipLoc = loc
    end
    local kind = ClassifyEquipLoc(equipLoc)

    if kind == "weapon" then
      if canDisenchant and GreedMasterDB.deWeapons then
        rollType = 3
      elseif canGreed then
        rollType = 2
      else
        return
      end

    elseif kind == "armor" then
      if canDisenchant and GreedMasterDB.deArmor then
        rollType = 3
      elseif canGreed then
        rollType = 2
      else
        return
      end

    else
      if canDisenchant then
        rollType = 3
      elseif canGreed then
        rollType = 2
      else
        return
      end
    end
  end

  EnqueueRoll(rollID, rollType)
end

local panel
local _agId = 0
local function CreateCheck(parent, label, tooltip, x, y)
  _agId = _agId + 1
  local name = "GreedMasterCheck".._agId
  local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

  local textRegion = _G[name.."Text"]
  if textRegion then
    textRegion:SetText(label)
    cb.text = textRegion
  else
    cb.text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 0, 1)
    cb.text:SetText(label)
  end

  cb.tooltipText = label
  cb.tooltipRequirement = tooltip
  return cb
end

local function BuildOptions()
  panel = CreateFrame("Frame", "GreedMasterOptions", InterfaceOptionsFramePanelContainer)
  panel.name = "GreedMaster"

  panel.title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  panel.title:SetPoint("TOPLEFT", 16, -16)
  panel.title:SetText("GreedMaster — настройки")

  panel.sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  panel.sub:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -8)
  panel.sub:SetText("|cffff2020Учитывайте что любые возможные проблемы с лутом|r")

  panel.sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  panel.sub:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -28)
  panel.sub:SetText("|cffff2020из-за аддона НЕ МОДЕРИРУЮТСЯ!!!|r")

  local cbBoE = CreateCheck(panel, "Только BoE", "Обрабатывать только предметы без привязки при подборе (BoE).", 16, -84)
  cbBoE:SetScript("OnClick", function(self) GreedMasterDB.boeOnly = not not self:GetChecked() end)
  panel.cbBoE = cbBoE

  local cbAuto = CreateCheck(panel, "Всегда запускать при входе в игру", "Автоматически включать аддон при входе в игру.", 16, -108)
  cbAuto:SetScript("OnClick", function(self) GreedMasterDB.autoEnable = not not self:GetChecked() end)
  panel.cbAuto = cbAuto


  local headerTypes = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  headerTypes:SetPoint("TOPLEFT", 16, -136)
  headerTypes:SetText("Правила распыла:")

  local cbDEArmor = CreateCheck(panel, " Распылять экипировку", "Если возможно, вместо «Не откажусь» будет выбран «Распылить» для экипировки.", 32, -168)
  cbDEArmor:SetScript("OnClick", function(self) GreedMasterDB.deArmor = not not self:GetChecked() end)
  panel.cbDEArmor = cbDEArmor

  local cbDEWeapons = CreateCheck(panel, " Распылять оружие", "Если возможно, вместо «Не откажусь» будет выбран «Распылить» для оружия.", 32, -200)
  cbDEWeapons:SetScript("OnClick", function(self) GreedMasterDB.deWeapons = not not self:GetChecked() end)
  panel.cbDEWeapons = cbDEWeapons

  local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  header:SetPoint("TOPLEFT", 16, -236)
  header:SetText("Редкости для авторолла:")

  local cbQ2 = CreateCheck(panel, " Необычные", "", 32, -264)
  cbQ2:SetScript("OnClick", function(self) GreedMasterDB.greedQualities[QUAL_UNCOMMON] = not not self:GetChecked() end)
  panel.cbQ2 = cbQ2

  local cbQ3 = CreateCheck(panel, " Редкие", "", 32, -296)
  cbQ3:SetScript("OnClick", function(self) GreedMasterDB.greedQualities[QUAL_RARE] = not not self:GetChecked() end)
  panel.cbQ3 = cbQ3

  local cbQ4 = CreateCheck(panel, " Эпические — только «Не откажусь»", "", 32, -328)
  cbQ4:SetScript("OnClick", function(self) GreedMasterDB.greedQualities[QUAL_EPIC] = not not self:GetChecked() end)
  panel.cbQ4 = cbQ4

  local info = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  info:SetPoint("TOPLEFT", 16, -368)
  info:SetText("Работает только на максимальном уровне персонажа.")

  local info = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  info:SetPoint("TOPLEFT", 16, -400)
  info:SetText("Включение/выключение — командой /grm.")


  local info = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  info:SetPoint("TOPLEFT", 16, -368)
  info:SetText("Работает только на максимальном уровне персонажа.")

  panel.refresh = function()
    panel.cbBoE:SetChecked(GreedMasterDB.boeOnly)
    panel.cbAuto:SetChecked(GreedMasterDB.autoEnable)
    panel.cbDEArmor:SetChecked(GreedMasterDB.deArmor)
    panel.cbDEWeapons:SetChecked(GreedMasterDB.deWeapons)
    panel.cbQ2:SetChecked( GreedMasterDB.greedQualities[QUAL_UNCOMMON] )
    panel.cbQ3:SetChecked( GreedMasterDB.greedQualities[QUAL_RARE] )
    panel.cbQ4:SetChecked( GreedMasterDB.greedQualities[QUAL_EPIC] )
  end

  InterfaceOptions_AddCategory(panel)
end

SLASH_GreedMaster1 = "/greedmaster"
SLASH_GreedMaster2 = "/grm"
SlashCmdList["GreedMaster"] = function(msg)
  if Session.enabled then
    Session.enabled = false
    DEFAULT_CHAT_FRAME:AddMessage("|cffff2020GreedMaster выключен.|r")
  else
    ShowEnablePopup()
  end
end

f:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == ADDON then
      GreedMasterDB = ApplyDefaults(_G.GreedMasterDB, defaults)
      if not panel then BuildOptions() end
      CreateMinimapButton()
      Session.enabled = false
    end

  elseif event == "PLAYER_LOGIN" then
    if panel and panel.refresh then panel.refresh() end
    Session.enabled = false
    if GreedMasterDB.autoEnable then
      Session.enabled = true
      After(3.0, function()
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000GreedMaster включен автоматически, учтите, что любые проблемы с получением лута из-за аддона НЕ МОДЕРИРУЮТСЯ!!!|r")
      end)
    end

  elseif event == "START_LOOT_ROLL" then
    local rollID = ...
    TryAutoRoll(rollID)

  elseif event == "CONFIRM_LOOT_ROLL" then
    local rollID, rollType = ...
    if rollID and rollType then
      pcall(ConfirmLootRoll, rollID, rollType)
      After(0.00, function() ConfirmRollPopups() end)
      After(0.10, function() pcall(ConfirmLootRoll, rollID, rollType); ConfirmRollPopups() end)
      After(0.25, function() ConfirmRollPopups() end)
      After(0.50, function() ConfirmRollPopups() end)
    end

  elseif event == "CONFIRM_DISENCHANT_ROLL" then
    local rollID, rollType = ...
    if rollID and rollType then
      pcall(ConfirmDisenchantRoll, rollID, rollType)
      After(0.00, function() ConfirmRollPopups() end)
      After(0.10, function() pcall(ConfirmDisenchantRoll, rollID, rollType); ConfirmRollPopups() end)
      After(0.25, function() ConfirmRollPopups() end)
      After(0.50, function() ConfirmRollPopups() end)
    end

  elseif event == "LOOT_BIND_CONFIRM" then
    After(0.00, function() ConfirmLootBindPopups() end)
    After(0.15, function() ConfirmLootBindPopups() end)
    After(0.30, function() ConfirmLootBindPopups() end)
    After(0.50, function() ConfirmLootBindPopups() end)
  end
end)
