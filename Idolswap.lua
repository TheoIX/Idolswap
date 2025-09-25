-- IdolSwap.lua (Turtle WoW 1.12)
-- Druid version of our LibramSwap addon. Mirrors logic/structure nearly 1:1
-- and swaps *idols* in the relic slot (18) just before a spell is cast, but
-- ONLY when the spell is actually ready (no CD/GCD). Uses a bag index cache
-- for O(1) lookups and a conservative generic throttle to reduce hitching.
--
-- Differences vs LibramSwap:
--  • Paladin-only rules removed (no Judgement ≤35% gating, no Consecration toggle).
--  • Spell→Idol map (IdolMap) below reflects Druid spells/forms.
--  • Slash command is /idolswap.
--
-- =====================
-- Locals / Aliases
-- =====================
local GetContainerNumSlots  = GetContainerNumSlots
local GetContainerItemLink  = GetContainerItemLink
local UseContainerItem      = UseContainerItem
local GetInventoryItemLink  = GetInventoryItemLink
local GetSpellName          = GetSpellName
local GetSpellCooldown      = GetSpellCooldown
local GetTime               = GetTime
local string_find           = string.find
local BOOKTYPE_SPELL        = BOOKTYPE_SPELL or "spell"

-- === Bag Index ===
local NameIndex   = {}  -- [itemName] = {bag=#, slot=#, link="|Hitem:..|h[Name]|h|r"}
local IdIndex     = {}  -- [itemID]   = {bag=#, slot=#, link=...}  (optional use later)

-- Safety: block swaps when vendor/bank/auction/trade/mail/quest/gossip is open
local function IsInteractionBusy()
    return (MerchantFrame and MerchantFrame:IsVisible())
        or (BankFrame and BankFrame:IsVisible())
        or (AuctionFrame and AuctionFrame:IsVisible())
        or (TradeFrame and TradeFrame:IsVisible())
        or (MailFrame and MailFrame:IsVisible())
        or (QuestFrame and QuestFrame:IsVisible())
        or (GossipFrame and GossipFrame:IsVisible())
end

local IdolSwapEnabled = false
local lastEquippedIdol = nil

-- Global (generic) throttle for GCD-based swaps
local lastSwapTime = 0

-- =====================
-- Config
-- =====================
-- Keep original generic throttle for GCD spells (tuned to 1.12 GCD ~1.5s)
local SWAP_THROTTLE_GENERIC = 1.48

-- Per-spell throttles were Paladin-specific in LibramSwap (e.g., Judgement/Consecration).
-- For Druid we start with none; you can add entries here later if desired.
local PER_SPELL_THROTTLE = {
    -- ["Some Druid Spell"] = seconds,
}

-- =====================
-- Map spells -> preferred Idol name (bag/equipped link substring match)
-- =====================
local IdolMap = {
    -- Healing / Restoration
    ["Regrowth"]           = "Idol of the Forgotten Wilds",
    ["Healing Touch"]      = "Idol of Health",
    ["Rejuvenation"]       = "Idol of Rejuvenation",
    ["Thorns"]             = "Idol of Evergrowth",
    ["Entangling Roots"]   = "Idol of the Thorned Grove",

    -- Balance
    ["Starfire"]           = "Idol of Ebb and Flow",
    ["Moonfire"]           = "Idol of the Moon",
    ["Insect Swarm"]       = "Idol of Propagation",

    -- Feral (Bear/Cat)
    ["Demoralizing Roar"]  = "Idol of the Apex Predator",
    ["Rake"]               = "Idol of Savagery",
    ["Rip"]                = "Idol of Savagery",
    ["Claw"]               = "Idol of Ferocity",
    ["Maul"]               = "Idol of Brutality",
    ["Swipe"]              = "Idol of Brutality",
    ["Shred"]              = "Idol of the Moonfang",
    ["Savage Bite"]        = "Idol of the Moonfang",
    ["Ferocious Bite"]     = "Idol of the Emerald Rot",
    
    -- Forms
    ["Aquatic Form"]       = "Idol of Fluidity",
    ["Travel Form"]        = "Idol of the Wildshifter",
    ["Cat Form"]           = "Idol of the Wildshifter",
    ["Bear Form"]          = "Idol of the Wildshifter",
    ["Moonkin Form"]       = "Idol of the Wildshifter",
    ["Tree of Life Form"]  = "Idol of the Wildshifter",
}

-- Build set of idol names we care about for the bag index (O(1) lookups)
local WatchedNames = {}
for _, idolName in pairs(IdolMap) do
    WatchedNames[idolName] = true
end

-- Extract numeric itemID from an item link (1.12 safe)
local function ItemIDFromLink(link)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    return id and tonumber(id) or nil
end

local function BuildBagIndex()
    -- wipe current
    for k in pairs(NameIndex) do NameIndex[k] = nil end
    for k in pairs(IdIndex)   do IdIndex[k]   = nil end

    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    -- Extract plain item name safely
                    local _, _, bracketName = string.find(link, "%[(.-)%]")
                    if bracketName and WatchedNames[bracketName] then
                        NameIndex[bracketName] = { bag = bag, slot = slot, link = link }
                        local id = ItemIDFromLink(link)
                        if id then
                            IdIndex[id] = { bag = bag, slot = slot, link = link }
                        end
                    end
                end
            end
        end
    end
end

local IdolSwapFrame = CreateFrame("Frame")
IdolSwapFrame:RegisterEvent("PLAYER_LOGIN")
IdolSwapFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
IdolSwapFrame:RegisterEvent("BAG_UPDATE")

IdolSwapFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        BuildBagIndex()
    elseif event == "BAG_UPDATE" then
        -- simple & safe: rebuild immediately (cost is tiny since we only watch idols)
        BuildBagIndex()
    end
end)

-- =====================
-- Spell Readiness (1.12-safe)
-- =====================
-- Returns: ready:boolean, start:number, duration:number
local function IsSpellReady(spellName)
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if spellName == name or (rank and (spellName == (name .. "(" .. rank .. ")"))) then
            local start, duration, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if not start or not duration then return false end
            if enabled == 0 then return false end
            if start == 0 or duration == 0 then return true, 0, 0 end
            local remaining = (start + duration) - GetTime()
            return remaining <= 0, start, duration
        end
    end
    return false
end

-- =====================
-- Helpers
-- =====================
-- Returns bag, slot or nil
local function HasItemInBags(itemName)
    -- 1) Try cached slot first
    local ref = NameIndex[itemName]
    if ref then
        local current = GetContainerItemLink(ref.bag, ref.slot)
        if current and string_find(current, itemName, 1, true) then
            return ref.bag, ref.slot
        end
        -- It moved; rebuild and try again
        BuildBagIndex()
        ref = NameIndex[itemName]
        if ref then
            local verify = GetContainerItemLink(ref.bag, ref.slot)
            if verify and string_find(verify, itemName, 1, true) then
                return ref.bag, ref.slot
            end
        end
        return nil
    end

    -- 2) Slow path (first time seeing this name in-session)
    --    We keep it for resiliency; BuildBagIndex will capture it for next time.
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link and string_find(link, itemName, 1, true) then
                    -- Update cache so future lookups are O(1)
                    NameIndex[itemName] = { bag = bag, slot = slot, link = link }
                    local id = ItemIDFromLink(link)
                    if id then IdIndex[id] = { bag = bag, slot = slot, link = link } end
                    return bag, slot
                end
            end
        end
    end
    return nil
end

-- Relic slot index is 18 in 1.12 (same as librams/idols/totems)
local RELIC_SLOT = 18

-- Per-spell throttle state (same behavior as LibramSwap; initially unused)
local perSpellHasSwapped = {}   -- spellName -> true after first successful swap
local perSpellLastSwap   = {}   -- spellName -> last swap time (after first)

-- Core equip with throttle policy
local function EquipIdolForSpell(spellName, itemName)
    -- Already equipped?
    local equipped = GetInventoryItemLink("player", RELIC_SLOT)
    if equipped and string_find(equipped, itemName, 1, true) then
        lastEquippedIdol = itemName
        return false
    end

    -- Block swaps if an interaction UI is open (prevents accidental selling/moving)
    if IsInteractionBusy() then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5555[IdolSwap]: Swap blocked (interaction window open).|r")
        return false
    end

    -- Throttle selection
    local now = GetTime()
    local perDur = PER_SPELL_THROTTLE[spellName]
    if perDur then
        -- Apply throttle ONLY after the first successful swap for this spell
        if perSpellHasSwapped[spellName] then
            local last = perSpellLastSwap[spellName] or 0
            if (now - last) < perDur then
                return false
            end
        end
    else
        -- Generic GCD-based throttle for other spells
        if (now - lastSwapTime) < SWAP_THROTTLE_GENERIC then
            return false
        end
    end

    local bag, slot = HasItemInBags(itemName)
    if bag and slot then
        if CursorHasItem and CursorHasItem() then
            return false
        end
        UseContainerItem(bag, slot)
        lastEquippedIdol = itemName
        if perDur then
            -- mark first swap and update per-spell timestamp
            if not perSpellHasSwapped[spellName] then
                perSpellHasSwapped[spellName] = true
            end
            perSpellLastSwap[spellName] = now
        else
            lastSwapTime = now
        end
        -- Reduce spam if desired by commenting this out
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[IdolSwap]: Equipped|r " .. itemName .. " |cFF888888(" .. spellName .. ")|r")
        return true
    end
    return false
end

local function ResolveIdolForSpell(spellName)
    local idol = IdolMap[spellName]
    if not idol then return nil end
    -- (Optional: add fallbacks here if you maintain multiple idols for a spell family.)
    return idol
end

-- =====================
-- Hooks (CastSpellByName / CastSpell)
-- =====================
local Original_CastSpellByName = CastSpellByName
function CastSpellByName(spellName, bookType)
    if IdolSwapEnabled then
        local idol = ResolveIdolForSpell(spellName)
        if idol then
            local ready = IsSpellReady(spellName)
            if ready then
                EquipIdolForSpell(spellName, idol)
            end
        end
    end
    return Original_CastSpellByName(spellName, bookType)
end

local Original_CastSpell = CastSpell
function CastSpell(spellIndex, bookType)
    if IdolSwapEnabled and bookType == BOOKTYPE_SPELL then
        local name, rank = GetSpellName(spellIndex, BOOKTYPE_SPELL)
        if name then
            local idol = ResolveIdolForSpell(name)
            if idol then
                local ready = IsSpellReady(name)
                if ready then
                    EquipIdolForSpell(name, idol)
                end
            end
        end
    end
    return Original_CastSpell(spellIndex, bookType)
end

-- =====================
-- Slash Command
-- =====================
SLASH_IDOLSWAP1 = "/idolswap"
SlashCmdList["IDOLSWAP"] = function()
    IdolSwapEnabled = not IdolSwapEnabled
    if IdolSwapEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("IdolSwap ENABLED", 0, 1, 0)
    else
        DEFAULT_CHAT_FRAME:AddMessage("IdolSwap DISABLED", 1, 0, 0)
    end
end
