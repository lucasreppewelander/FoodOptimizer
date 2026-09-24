-- Food Optimizer
-- Picks which food/drink to consume. Default order: the item type you hold the
-- fewest of goes first (frees a bag slot soonest), ties broken by the lowest
-- amount restored. The order can be changed by hand in the panel (/fo).
-- Consuming is done through secure buttons (click them, or /click them from a
-- macro), because addons are not allowed to use items on their own.

local ADDON_NAME = ...

local NUM_BAGS = NUM_BAG_SLOTS or 4
local EMPTY_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local CONSUMABLE_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Consumable) or 0

local CATEGORIES = {
    { key = "food",  label = "Food",  stat = "hp",   statLabel = "health",
      buttonName = "FoodOptimizerFoodButton",  macroName = "FO Food" },
    { key = "drink", label = "Drink", stat = "mana", statLabel = "mana",
      buttonName = "FoodOptimizerDrinkButton", macroName = "FO Drink" },
}

local DB     -- FoodOptimizerDB (account-wide: food order, ignored items), set on ADDON_LOADED
local CharDB -- FoodOptimizerCharDB (per character: button position, shown, locked)

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66Food Optimizer:|r " .. msg)
end

-- API compatibility (C_Container / C_Item on modern clients, globals otherwise)
local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function GetSlotInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            return info.itemID, info.stackCount, info.iconFileID, info.hyperlink
        end
    else
        local icon, count, _, _, _, _, link, _, _, itemID = GetContainerItemInfo(bag, slot)
        return itemID, count, icon, link
    end
end

---------------------------------------------------------------------------
-- Tooltip scanning: figure out if an item is food/drink and how much it restores
---------------------------------------------------------------------------

local scanTip = CreateFrame("GameTooltip", "FoodOptimizerScanTooltip", nil, "GameTooltipTemplate")

-- itemID -> { hp = number|nil, mana = number|nil, reqLevel = number|nil }, or false if neither
local itemCache = {}
-- itemID -> number of scans that found an incomplete tooltip
local incompleteScans = {}
-- Right after login the "Use:" text may not be loaded yet; after this many tries, give up on the item
local MAX_INCOMPLETE_SCANS = 10

local RequestLoadItemData = C_Item and C_Item.RequestLoadItemDataByID

-- Called when an item's tooltip isn't complete yet. Returns nil (retry later) until the item
-- has been retried too often; then false for this scan, without caching, so the next bag
-- change tries again.
local function Incomplete(itemID)
    local tries = (incompleteScans[itemID] or 0) + 1
    incompleteScans[itemID] = tries
    if tries < MAX_INCOMPLETE_SCANS then
        return nil
    end
    incompleteScans[itemID] = nil
    return false
end

local function ParseNumber(s)
    return tonumber((s:gsub(",", "")))
end

-- Returns the cached entry, false if not food/drink, or nil if the item data isn't loaded yet
-- (in which case it is requested and the caller should retry later).
local function ScanItem(bag, slot, itemID)
    local cached = itemCache[itemID]
    if cached ~= nil then
        return cached
    end

    -- Only consumables; recipes would otherwise match via the crafted item's tooltip
    local classID = select(6, GetItemInfoInstant(itemID))
    if classID ~= CONSUMABLE_CLASS_ID then
        itemCache[itemID] = false
        return false
    end

    -- On a fresh login item data isn't cached yet and the tooltip comes back incomplete
    if not GetItemInfo(itemID) then
        if RequestLoadItemData then
            RequestLoadItemData(itemID)
        end
        return Incomplete(itemID)
    end

    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetBagItem(bag, slot)

    local numLines = scanTip:NumLines()
    if numLines == 0 then
        return Incomplete(itemID)
    end

    local hp, mana, reqLevel, hasUseLine
    for i = 2, numLines do
        local fontString = _G["FoodOptimizerScanTooltipTextLeft" .. i]
        local text = fontString and fontString:GetText()
        if text then
            if text:find("^Use:") then
                hasUseLine = true
            end
            -- "Use: Restores 61 health over 18 sec."
            -- "Use: Restores 151 mana over 21 sec."
            -- "Use: Restores 2148 health and 4410 mana over 30 sec."
            -- Requiring "over <n>" skips instant potions ("Restores 140 to 180 health.")
            if text:find(" over %d") then
                local h = text:match("Restores ([%d,%.]+) health")
                if h then hp = ParseNumber(h) end
                local m = text:match("([%d,%.]+) mana over")
                if m then mana = ParseNumber(m) end
            end
            local lvl = text:match("Requires Level (%d+)")
            if lvl then
                reqLevel = tonumber(lvl)
            end
        end
    end
    scanTip:Hide()

    -- The "Use:" text (from spell data) can load later than the item itself
    if not hasUseLine then
        return Incomplete(itemID)
    end
    incompleteScans[itemID] = nil

    local result = (hp or mana) and { hp = hp, mana = mana, reqLevel = reqLevel } or false
    itemCache[itemID] = result
    return result
end

---------------------------------------------------------------------------
-- Ranking
---------------------------------------------------------------------------

local rankings = {} -- category key -> sorted list of entries
local waitingForItemInfo = false

local function IsIgnored(cat, itemID)
    return DB.ignored[cat.key][itemID] and true or false
end

local function MakeComparator(cat)
    local position = {}
    for i, id in ipairs(DB.order[cat.key]) do
        position[id] = i
    end
    local stat = cat.stat

    return function(a, b)
        -- Ignored items sink to the bottom
        local ia, ib = IsIgnored(cat, a.itemID), IsIgnored(cat, b.itemID)
        if ia ~= ib then
            return ib
        end
        -- Hand-ordered items first, in the chosen order
        local pa, pb = position[a.itemID], position[b.itemID]
        if pa and pb then
            return pa < pb
        elseif pa or pb then
            return pa ~= nil
        end
        -- Automatic: fewest first, then lowest restore amount
        if a.total ~= b.total then
            return a.total < b.total
        end
        if a[stat] ~= b[stat] then
            return a[stat] < b[stat]
        end
        return a.itemID < b.itemID
    end
end

local function BuildRankings()
    local byID = {}
    local all = {}
    local level = UnitLevel("player")
    waitingForItemInfo = false

    for bag = 0, NUM_BAGS do
        for slot = 1, GetNumSlots(bag) or 0 do
            local itemID, count, icon, link = GetSlotInfo(bag, slot)
            if itemID then
                local info = ScanItem(bag, slot, itemID)
                if info == nil then
                    waitingForItemInfo = true
                elseif info and not (info.reqLevel and info.reqLevel > level) then
                    local entry = byID[itemID]
                    if not entry then
                        entry = {
                            itemID = itemID, hp = info.hp, mana = info.mana,
                            icon = icon, link = link, total = 0,
                        }
                        byID[itemID] = entry
                        all[#all + 1] = entry
                    end
                    count = count or 1
                    entry.total = entry.total + count
                    -- Use the smallest stack so that slot empties first
                    if not entry.bag or count < entry.stackCount then
                        entry.bag, entry.slot, entry.stackCount = bag, slot, count
                    end
                end
            end
        end
    end

    for _, cat in ipairs(CATEGORIES) do
        local list = {}
        for _, entry in ipairs(all) do
            if entry[cat.stat] then
                list[#list + 1] = entry
            end
        end
        table.sort(list, MakeComparator(cat))
        rankings[cat.key] = list
    end
end

local function GetBest(cat)
    local best = rankings[cat.key] and rankings[cat.key][1]
    if best and not IsIgnored(cat, best.itemID) then
        return best
    end
end

---------------------------------------------------------------------------
-- Secure use buttons (one per category)
---------------------------------------------------------------------------

local buttons = {}
local pendingUpdate = false
local UpdateMacros -- defined in the Macros section

local BUTTON_SIZE, BUTTON_GAP = 36, 4

-- Holder for the buttons; moving it moves them all together
local anchor = CreateFrame("Frame", "FoodOptimizerAnchor", UIParent)
anchor:SetSize(#CATEGORIES * BUTTON_SIZE + (#CATEGORIES - 1) * BUTTON_GAP, BUTTON_SIZE)
anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
anchor:SetClampedToScreen(true)
anchor:SetMovable(true)

local function StartMovingAnchor()
    if not InCombatLockdown() then
        anchor:StartMoving()
    end
end

local function StopMovingAnchor()
    anchor:StopMovingOrSizing()
    local point, _, relPoint, x, y = anchor:GetPoint()
    CharDB.anchor = { point, relPoint, x, y }
    -- StartMoving marks the frame user-placed, which makes WoW also store its position in the
    -- character's layout cache and re-apply it at login, fighting our saved position.
    anchor:SetUserPlaced(false)
end

-- Drag handle shown above the buttons while they are unlocked
local handle = CreateFrame("Frame", nil, anchor)
handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
handle:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 2)
handle:SetHeight(14)
handle:EnableMouse(true)
handle:RegisterForDrag("LeftButton")
handle:SetScript("OnDragStart", StartMovingAnchor)
handle:SetScript("OnDragStop", StopMovingAnchor)

handle.bg = handle:CreateTexture(nil, "BACKGROUND")
handle.bg:SetAllPoints()
handle.bg:SetColorTexture(0, 0, 0, 0.6)

handle.text = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
handle.text:SetPoint("CENTER")
handle.text:SetText("Drag")

handle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Food Optimizer")
    GameTooltip:AddLine("Drag to move the buttons.", 1, 1, 1)
    GameTooltip:AddLine("Lock them in the /fo panel to hide this handle.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
handle:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function RestorePosition()
    if InCombatLockdown() then return end
    local p = CharDB.anchor
    anchor:SetUserPlaced(false)
    anchor:ClearAllPoints()
    if p then
        anchor:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
end

local function ApplyLock()
    handle:SetShown(not CharDB.locked)
end

local function CreateUseButton(cat, index)
    local button = CreateFrame("Button", cat.buttonName, anchor, "SecureActionButtonTemplate")
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetPoint("LEFT", (index - 1) * (BUTTON_SIZE + BUTTON_GAP), 0)
    -- "/click Button" sends only an up-click, but with the default ActionButtonUseKeyDown=1 the
    -- secure template ignores up-clicks. Forcing useOnKeyDown off makes it act on up-clicks
    -- (macros and mouse) regardless of that setting.
    button:RegisterForClicks("AnyUp")
    button:SetAttribute("useOnKeyDown", false)
    button:RegisterForDrag("RightButton")
    -- Only left click uses the item; right button is reserved for dragging
    button:SetAttribute("type1", "item")

    button.icon = button:CreateTexture(nil, "BACKGROUND")
    button.icon:SetAllPoints()
    button.icon:SetTexture(EMPTY_ICON)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.count:SetPoint("BOTTOMRIGHT", -2, 2)

    button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local best = GetBest(cat)
        if best then
            GameTooltip:SetBagItem(best.bag, best.slot)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(string.format("Food Optimizer: %d left, %s %s",
                best.total, best[cat.stat], cat.statLabel), 0.4, 1, 0.4)
        else
            GameTooltip:SetText("Food Optimizer - " .. cat.label)
            GameTooltip:AddLine("Nothing usable in your bags.", 1, 1, 1)
        end
        GameTooltip:AddLine("Left-click to use. /fo to set the order.", 0.7, 0.7, 0.7)
        if not CharDB.locked then
            GameTooltip:AddLine("Right-drag to move.", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    button:SetScript("OnDragStart", function()
        if not CharDB.locked then
            StartMovingAnchor()
        end
    end)
    button:SetScript("OnDragStop", StopMovingAnchor)

    buttons[cat.key] = button
end

for i, cat in ipairs(CATEGORIES) do
    CreateUseButton(cat, i)
end

local function ApplyToButtons()
    if InCombatLockdown() then
        pendingUpdate = true
        return
    end
    pendingUpdate = false

    for _, cat in ipairs(CATEGORIES) do
        local button = buttons[cat.key]
        local best = GetBest(cat)
        if best then
            button:SetAttribute("item", best.bag .. " " .. best.slot)
            button.icon:SetTexture(best.icon)
            button.icon:SetDesaturated(false)
            button.count:SetText(best.total)
        else
            button:SetAttribute("item", nil)
            button.icon:SetTexture(EMPTY_ICON)
            button.icon:SetDesaturated(true)
            button.count:SetText("")
        end
    end
    UpdateMacros()
end

local function SetButtonsShown(shown)
    if InCombatLockdown() then
        Print("Can't do that in combat.")
        return false
    end
    CharDB.hidden = not shown
    anchor:SetShown(shown)
    return true
end

---------------------------------------------------------------------------
-- Macros
---------------------------------------------------------------------------

-- The question mark icon lets #showtooltip swap in the next item's icon, tooltip and count
local MACRO_ICON = "INV_Misc_QuestionMark"

local function MacroBody(cat)
    local best = GetBest(cat)
    local name = best and best.link and best.link:match("%[(.-)%]")
    local tooltip = best and ("#showtooltip " .. (name or ("item:" .. best.itemID))) or "#showtooltip"
    return tooltip .. "\n/click " .. cat.buttonName
end

-- Keeps existing macros pointing at the current best item. Call out of combat only.
UpdateMacros = function()
    for _, cat in ipairs(CATEGORIES) do
        local index = GetMacroIndexByName(cat.macroName)
        if index and index > 0 then
            local body = MacroBody(cat)
            if GetMacroBody(index) ~= body then
                EditMacro(index, cat.macroName, MACRO_ICON, body)
            end
        end
    end
end

local function CreateOrUpdateMacro(cat)
    if InCombatLockdown() then
        Print("Can't create macros in combat.")
        return
    end
    local body = MacroBody(cat)
    local icon = MACRO_ICON

    local index = GetMacroIndexByName(cat.macroName)
    if index and index > 0 then
        EditMacro(index, cat.macroName, icon, body)
    else
        if GetNumMacros() >= (MAX_ACCOUNT_MACROS or 120) then
            Print("Your general macro list is full.")
            return
        end
        index = CreateMacro(cat.macroName, icon, body, nil)
    end
    PickupMacro(index)
    Print(string.format("Macro \"%s\" is on your cursor - drop it on an action bar.", cat.macroName))
end

---------------------------------------------------------------------------
-- Order panel
---------------------------------------------------------------------------

local ROW_HEIGHT = 30
local selectedCat = CATEGORIES[1]
local RefreshPanel -- forward declaration

local panel = CreateFrame("Frame", "FoodOptimizerPanel", UIParent, "BasicFrameTemplateWithInset")
panel:SetSize(380, 440)
panel:SetPoint("CENTER")
panel:SetFrameStrata("DIALOG")
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:Hide()
tinsert(UISpecialFrames, "FoodOptimizerPanel") -- close with Escape

panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
panel.title:SetPoint("TOP", 0, -5)
panel.title:SetText("Food Optimizer")

-- Tabs
local tabButtons = {}
for i, cat in ipairs(CATEGORIES) do
    local tab = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    tab:SetSize(80, 22)
    tab:SetPoint("TOPLEFT", 12 + (i - 1) * 84, -30)
    tab:SetText(cat.label)
    tab:SetScript("OnClick", function()
        selectedCat = cat
        RefreshPanel()
    end)
    tabButtons[cat.key] = tab
end

local macroButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
macroButton:SetSize(150, 22)
macroButton:SetPoint("TOPRIGHT", -12, -30)
macroButton:SetScript("OnClick", function() CreateOrUpdateMacro(selectedCat) end)

-- Column headers
local function Header(text, x)
    local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 14 + x, -60)
    fs:SetText(text)
    return fs
end
Header("Item", 52)
local statHeader = Header("", 186)
Header("Order", 262)
Header("Use", 306)

-- Scrolling list
local scroll = CreateFrame("ScrollFrame", "FoodOptimizerPanelScroll", panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -76)
scroll:SetPoint("BOTTOMRIGHT", -32, 86)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(330, 1)
scroll:SetScrollChild(content)

local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
emptyText:SetPoint("TOP", 0, -20)

local rows = {}

local function MoveEntry(index, delta)
    local list = rankings[selectedCat.key]
    local target = index + delta
    if not list[target] then return end

    -- Freeze the currently visible order (with the swap) as the hand-picked order,
    -- keeping remembered items that aren't in the bags right now at the end.
    local newOrder, seen = {}, {}
    for i, entry in ipairs(list) do
        local e = (i == index and list[target]) or (i == target and list[index]) or entry
        newOrder[#newOrder + 1] = e.itemID
        seen[e.itemID] = true
    end
    for _, id in ipairs(DB.order[selectedCat.key]) do
        if not seen[id] then
            newOrder[#newOrder + 1] = id
        end
    end
    DB.order[selectedCat.key] = newOrder

    BuildRankings()
    ApplyToButtons()
    RefreshPanel()
end

local function ArrowButton(parent, direction)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)
    local base = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. direction .. "Button-"
    b:SetNormalTexture(base .. "Up")
    b:SetPushedTexture(base .. "Down")
    b:SetDisabledTexture(base .. "Disabled")
    b:SetHighlightTexture(base .. "Highlight", "ADD")
    return b
end

local function CreateRow(i)
    local row = CreateFrame("Button", nil, content)
    row:SetSize(330, ROW_HEIGHT - 2)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.rank:SetPoint("LEFT", 2, 0)
    row.rank:SetWidth(18)
    row.rank:SetJustifyH("RIGHT")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 24, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", 52, 0)
    row.name:SetWidth(130)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.info:SetPoint("LEFT", 186, 0)
    row.info:SetWidth(72)
    row.info:SetJustifyH("LEFT")

    row.up = ArrowButton(row, "Up")
    row.up:SetPoint("LEFT", 262, 0)
    row.up:SetScript("OnClick", function() MoveEntry(row.index, -1) end)

    row.down = ArrowButton(row, "Down")
    row.down:SetPoint("LEFT", 282, 0)
    row.down:SetScript("OnClick", function() MoveEntry(row.index, 1) end)

    row.use = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.use:SetSize(24, 24)
    row.use:SetPoint("LEFT", 304, 0)
    row.use:SetScript("OnClick", function(self)
        DB.ignored[selectedCat.key][row.entry.itemID] = (not self:GetChecked()) or nil
        BuildRankings()
        ApplyToButtons()
        RefreshPanel()
    end)

    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetBagItem(self.entry.bag, self.entry.slot)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rows[i] = row
    return row
end

-- Bottom controls
local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hint:SetPoint("BOTTOMLEFT", 14, 62)
hint:SetPoint("BOTTOMRIGHT", -14, 62)
hint:SetJustifyH("LEFT")
hint:SetText("The top item is used first. Unticked items are never used.")

local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
resetButton:SetSize(150, 22)
resetButton:SetPoint("BOTTOMLEFT", 12, 32)
resetButton:SetText("Reset to automatic")
resetButton:SetScript("OnClick", function()
    DB.order[selectedCat.key] = {}
    BuildRankings()
    ApplyToButtons()
    RefreshPanel()
end)

local autoHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
autoHint:SetPoint("LEFT", resetButton, "RIGHT", 8, 0)
autoHint:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
autoHint:SetJustifyH("LEFT")
autoHint:SetText("Automatic: fewest first, then lowest amount")

local showCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
showCheck:SetSize(24, 24)
showCheck:SetPoint("BOTTOMLEFT", 10, 6)
showCheck:SetScript("OnClick", function(self)
    if not SetButtonsShown(self:GetChecked()) then
        self:SetChecked(not self:GetChecked())
    end
end)
local showLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
showLabel:SetPoint("LEFT", showCheck, "RIGHT", 2, 0)
showLabel:SetText("Show on-screen buttons")

local lockCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
lockCheck:SetSize(24, 24)
lockCheck:SetPoint("BOTTOMLEFT", 190, 6)
lockCheck:SetScript("OnClick", function(self)
    CharDB.locked = self:GetChecked() and true or false
    ApplyLock()
end)
local lockLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
lockLabel:SetPoint("LEFT", lockCheck, "RIGHT", 2, 0)
lockLabel:SetText("Lock button position")

RefreshPanel = function()
    if not panel:IsShown() then return end
    local cat = selectedCat
    local list = rankings[cat.key] or {}

    for key, tab in pairs(tabButtons) do
        tab:SetEnabled(key ~= cat.key)
    end
    macroButton:SetText("Create " .. cat.label .. " macro")
    statHeader:SetText(cat.label == "Food" and "Qty / HP" or "Qty / Mana")
    showCheck:SetChecked(not CharDB.hidden)
    lockCheck:SetChecked(CharDB.locked)

    local numUsable = 0
    for _, entry in ipairs(list) do
        if not IsIgnored(cat, entry.itemID) then
            numUsable = numUsable + 1
        end
    end

    for i, entry in ipairs(list) do
        local row = rows[i] or CreateRow(i)
        local ignored = IsIgnored(cat, entry.itemID)
        row.entry, row.index = entry, i

        row.rank:SetText(ignored and "-" or (i .. "."))
        if i == 1 and not ignored then
            row.rank:SetTextColor(0.4, 1, 0.4)
        else
            row.rank:SetTextColor(1, 1, 1)
        end
        row.icon:SetTexture(entry.icon)
        row.name:SetText(entry.link and entry.link:match("%[(.-)%]") or GetItemInfo(entry.itemID) or entry.itemID)
        row.info:SetText(string.format("x%d / %s", entry.total, entry[cat.stat]))
        row.use:SetChecked(not ignored)
        row.up:SetEnabled(not ignored and i > 1)
        row.down:SetEnabled(not ignored and i < numUsable)
        row:SetAlpha(ignored and 0.5 or 1)
        row:Show()
    end
    for i = #list + 1, #rows do
        rows[i]:Hide()
    end

    content:SetHeight(math.max(1, #list * ROW_HEIGHT))
    emptyText:SetText(#list == 0 and ("No " .. cat.label:lower() .. " in your bags.") or "")
end

panel:SetScript("OnShow", function()
    BuildRankings()
    RefreshPanel()
end)

---------------------------------------------------------------------------
-- Refresh + events
---------------------------------------------------------------------------

local function Refresh()
    BuildRankings()
    ApplyToButtons()
    RefreshPanel()
end

-- Collapse bursts of bag events into a single refresh
local refreshQueued = false
local function QueueRefresh(delay)
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(delay or 0.2, function()
        refreshQueued = false
        Refresh()
        -- Keep retrying while some tooltips are still incomplete (item/spell data loading)
        if waitingForItemInfo then
            QueueRefresh(1)
        end
    end)
end

local function InitDB()
    FoodOptimizerDB = FoodOptimizerDB or {}
    DB = FoodOptimizerDB
    -- Old position formats (buttons are now moved together via an anchor)
    DB.point = nil
    DB.points = nil
    DB.order = DB.order or {}
    DB.ignored = DB.ignored or {}
    for _, cat in ipairs(CATEGORIES) do
        DB.order[cat.key] = DB.order[cat.key] or {}
        DB.ignored[cat.key] = DB.ignored[cat.key] or {}
    end

    FoodOptimizerCharDB = FoodOptimizerCharDB or {}
    CharDB = FoodOptimizerCharDB
    -- Button settings used to be account-wide; start each character from those once
    if not CharDB.initialized then
        CharDB.anchor = DB.anchor
        CharDB.hidden = DB.hidden
        CharDB.locked = DB.locked
        CharDB.initialized = true
    end
end

-- What the saved variables looked like when each load event fired (for /fo debug)
local loadLog = {}

local function Describe(tbl)
    if type(tbl) ~= "table" then
        return tostring(tbl)
    end
    local a = tbl.anchor
    return string.format("table (anchor=%s, locked=%s, hidden=%s, initialized=%s)",
        a and string.format("%s %.0f,%.0f", tostring(a[1]), a[3] or 0, a[4] or 0) or "nil",
        tostring(tbl.locked), tostring(tbl.hidden), tostring(tbl.initialized))
end

local function LogLoadState(event)
    loadLog[#loadLog + 1] = string.format("%s: CharDB=%s, AccountDB=%s%s", event,
        Describe(FoodOptimizerCharDB), type(FoodOptimizerDB),
        (CharDB and FoodOptimizerCharDB ~= CharDB) and " (CharDB table was replaced)" or "")
end

-- Position, lock and visibility of the on-screen buttons
local function ApplyButtonSettings()
    if InCombatLockdown() then return end
    RestorePosition()
    ApplyLock()
    anchor:SetShown(not CharDB.hidden)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        LogLoadState(event)
        InitDB()
        ApplyButtonSettings()
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        LogLoadState(event)
        -- If the client (re)assigned the saved variables after ADDON_LOADED, switch to its tables
        if FoodOptimizerDB ~= DB or FoodOptimizerCharDB ~= CharDB then
            InitDB()
        end
        -- Re-apply after the UI has finished loading, in case anything moved the frame meanwhile
        ApplyButtonSettings()
        RefreshPanel()
        QueueRefresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingUpdate then
            Refresh()
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if waitingForItemInfo then
            QueueRefresh(0.5)
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- UnitLevel can lag behind the event slightly
        QueueRefresh(1)
    else
        QueueRefresh()
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

-- Copyable text window for /fo debug (chat text can't be selected)
local debugFrame

local function ShowDebugWindow(text)
    if not debugFrame then
        debugFrame = CreateFrame("Frame", "FoodOptimizerDebugFrame", UIParent, "BasicFrameTemplateWithInset")
        debugFrame:SetSize(560, 340)
        debugFrame:SetPoint("CENTER")
        debugFrame:SetFrameStrata("DIALOG")
        debugFrame:SetClampedToScreen(true)
        debugFrame:SetMovable(true)
        debugFrame:EnableMouse(true)
        debugFrame:RegisterForDrag("LeftButton")
        debugFrame:SetScript("OnDragStart", debugFrame.StartMoving)
        debugFrame:SetScript("OnDragStop", debugFrame.StopMovingOrSizing)
        tinsert(UISpecialFrames, "FoodOptimizerDebugFrame")

        local title = debugFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
        title:SetText("Food Optimizer - Debug")

        local scroll = CreateFrame("ScrollFrame", "FoodOptimizerDebugScroll", debugFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -30)
        scroll:SetPoint("BOTTOMRIGHT", -32, 34)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(510)
        edit:SetScript("OnEscapePressed", function() debugFrame:Hide() end)
        -- Read-only: put the text back if it gets edited
        edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(debugFrame.text)
                self:HighlightText()
            end
        end)
        scroll:SetScrollChild(edit)
        debugFrame.edit = edit

        local hint = debugFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOM", 0, 14)
        hint:SetText("The text is selected - press Cmd+C (Mac) or Ctrl+C (Windows) to copy it.")
    end

    debugFrame.text = text
    debugFrame.edit:SetText(text)
    debugFrame:Show()
    debugFrame.edit:SetFocus()
    debugFrame.edit:HighlightText()
end

local function BuildDebugText()
    local lines = {}
    local function add(fmt, ...)
        lines[#lines + 1] = string.format(fmt, ...)
    end

    local version, build, _, tocVersion = GetBuildInfo()
    add("Client: %s (build %s), interface %s", tostring(version), tostring(build), tostring(tocVersion))

    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local getInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    if getInfo then
        local _, _, _, loadable, reason = getInfo(ADDON_NAME)
        add("Addon: version %s, loadable=%s, reason=%s", tostring(getMetadata and getMetadata(ADDON_NAME, "Version")),
            tostring(loadable), tostring(reason))
    end
    add("Character: %s - %s", tostring(UnitName("player")), tostring(GetRealmName()))

    for _, line in ipairs(loadLog) do
        add("%s", line)
    end
    add("Now: CharDB=%s, same table as saved: %s", Describe(CharDB), tostring(CharDB == FoodOptimizerCharDB))

    local point, _, relPoint, x, y = anchor:GetPoint()
    add("Buttons at: %s/%s %.0f,%.0f, shown=%s, handle shown=%s",
        tostring(point), tostring(relPoint), x or 0, y or 0, tostring(anchor:IsShown()), tostring(handle:IsShown()))

    return table.concat(lines, "\n")
end

SLASH_FOODOPTIMIZER1 = "/fo"
SLASH_FOODOPTIMIZER2 = "/foodoptimizer"
SlashCmdList.FOODOPTIMIZER = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")

    if cmd == "" then
        panel:SetShown(not panel:IsShown())
    elseif cmd == "show" or cmd == "hide" then
        SetButtonsShown(cmd == "show")
    elseif cmd == "reset" then
        if InCombatLockdown() then
            Print("Can't do that in combat.")
            return
        end
        CharDB.anchor = nil
        RestorePosition()
    elseif cmd == "lock" or cmd == "unlock" then
        CharDB.locked = (cmd == "lock")
        ApplyLock()
        RefreshPanel()
    elseif cmd == "debug" then
        ShowDebugWindow(BuildDebugText())
    else
        Print("/fo - open the order panel")
        Print("/fo show | hide - toggle the on-screen buttons")
        Print("/fo lock | unlock - lock or unlock the button position")
        Print("/fo reset - reset the button position")
        Print("/fo debug - show how the saved settings were loaded")
    end
end
