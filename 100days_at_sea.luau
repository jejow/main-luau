--[[
    Behavioral reconstruction of "Untitled_1 2(2).luau".
    Release: v58 - faster confirmed Builder cycles and isolated native Wrench callbacks

    The original program was flattened and its constants were encoded. This
    version keeps the reconstructed features but uses a local, dependency-free
    interface designed specifically for this script.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local CoreGui = game:GetService("CoreGui")
local VirtualInputManager
pcall(function()
    VirtualInputManager = game:GetService("VirtualInputManager")
end)

local localPlayer = Players.LocalPlayer

-- Lifecycle guard: rerunning the script first unloads the previous copy.
local SCRIPT_CLEANUP_KEY = "__SEA_SCRIPT_CLEANUP"
local globalEnvironment
if typeof(getgenv) == "function" then
    globalEnvironment = getgenv()
elseif type(_G) == "table" then
    globalEnvironment = _G
end

-- Persistent configuration -------------------------------------------------
-- File APIs are executor-specific, so the configuration also has a getgenv
-- fallback. v31 keeps the v28 save slot, so existing settings migrate without reset.

local Config = (function()
    local HttpService = game:GetService("HttpService")
    local CONFIG_KEY = "__SEA_SCRIPT_CONFIG_V28"
    local CONFIG_PATH = "100DaysAtSea_v28_settings.json"

    -- Configuration values intentionally have mixed types and are accessed by
    -- dynamic string keys. Keep the map open so strict Luau analyzers do not
    -- seal it to the first inferred shape.
    local DEFAULTS: { [string]: any } = {
        UiTransparency = 0.08,
        UiScale = 1,
        UiAccent = "Mint",
        UiCompactSidebar = false,
        UiPositionX = 0.5,
        UiPositionY = 0.5,
        SelectedCreature = "Buku Buku",
        SelectedChest = "Any Chest",
        SelectedIsland = "",
        SelectedTeleport = "",
        SavedTeleports = {},
        IslandTourDelay = 2,
        IslandTourRepeat = true,
        BringItems = { "Broken Crate" },
        ChestLootItems = {},
        ChestLootMode = "Smart (E / F)",
        WorldLootItems = {},
        EspItems = { "Broken Crate" },
        NpcKillSelections = {},
        NpcKillDiscovered = {},
        WalkSpeed = 16,
        FlySpeed = 50,
        AutoOpenAfterTeleport = false,
        AutoNextChest = false,
        AutoLootChestDrops = false,
        AutoChestAndLoot = false,
        ChestLootRadius = 35,
        AutoLootWorld = false,
        WorldLootRadius = 120,
        WorldLootMode = "Smart (E / F)",
        LootDiagnostics = false,
        O2Guard = false,
        EspShowChests = true,
        EspShowCreatures = true,
        AntiAfk = false,
        SmartNpcKill = false,
        EspEnabled = false,
        WalkSpeedLocked = false,
        InstantInteract = false,
        FlyEnabled = false,
        -- v29 additions. Existing v28 saves migrate naturally because these
        -- keys default OFF and use the same save slot.
        AutoBonfire = false,
        BonfireKeep = 70,
        BonfireTargetLevel = 7,
        AutoGrinder = false,
        GrinderResource = "All",
        AutoCraft = false,
        AutoCraftItem = "All",
        BuilderRemoveRadius = 25,
        AutoEat = false,
        EatThreshold = 60,
        UnlimitedAmmo = false,
        ExperimentalRapidFire = false,
        Noclip = false,
        Fullbright = false,
        EspShowPlayers = false,
        EspShowResources = false,

        -- v34 additions. Drop Here is explicit so the script never empties a
        -- Sack into SpawnIsland.Dropper by accident. StationWorldSearch may
        -- temporarily stream/travel between replicated island anchors when no
        -- matching Bonfire/Grinder item is currently visible to the client.
        DropHereSet = false,
        DropHereX = 0,
        DropHereY = 0,
        DropHereZ = 0,
        AutoEmptySack = false,
        DropSpeed = "Normal",
        ProtectDropHere = true,
        DropProtectRadius = 22,
        OpenMapAfterLoot = false,
        StationWorldSearch = true,

        -- v38: station farms use the same Sack StoreItem/DropItem transport as
        -- World Auto Loot. Selections are item names, filtered from the real
        -- BonfireFuel / Resource attributes in Floating_Item_Models.
        BonfireItems = {},
        GrinderItems = {},
        BonfireItemsInitialized = false,
        GrinderItemsInitialized = false,
        -- One-time migration for the data-driven corpse group added after v48.
        -- Individual corpse Item names are dynamic and may not exist at startup.
        GrinderCorpseGroupInitialized = false,
        WorldLootCorpseGroupInitialized = false,
    }

    local NUMBER_LIMITS: { [string]: { number } } = {
        UiTransparency = { 0, 0.85 },
        UiScale = { 0.75, 1.15 },
        UiPositionX = { 0.08, 0.92 },
        UiPositionY = { 0.08, 0.92 },
        WalkSpeed = { 0, 100 },
        FlySpeed = { 1, 500 },
        ChestLootRadius = { 10, 80 },
        WorldLootRadius = { 10, 500 },
        BonfireKeep = { 1, 100 },
        BonfireTargetLevel = { 1, 7 },
        EatThreshold = { 1, 100 },
        DropProtectRadius = { 5, 60 },
        IslandTourDelay = { 1, 20 },
        BuilderRemoveRadius = { 5, 25 },
    }

    local VALID_ACCENTS = {
        Amber = true,
        Mint = true,
        Ocean = true,
        Rose = true,
        Violet = true,
    }

    local VALID_LOOT_MODES = {
        ["Smart (E / F)"] = true,
        ["Pickup / Use (E)"] = true,
        ["Store in Sack (F)"] = true,
    }

    local VALID_DROP_SPEEDS = {
        Slow = true,
        Normal = true,
        Fast = true,
    }

    local function clone(value: any, depth: number?): any
        if type(value) ~= "table" then
            return value
        end

        if (depth or 0) >= 4 then
            return {}
        end

        local result: { [any]: any } = {}
        for key, item in pairs(value) do
            result[key] = clone(item, (depth or 0) + 1)
        end
        return result
    end

    local function sanitizeValue(key: string, value: any): any
        local defaultValue = DEFAULTS[key]
        if defaultValue == nil then
            return nil
        end

        local expectedType = type(defaultValue)
        if type(value) ~= expectedType then
            return clone(defaultValue)
        end

        if expectedType == "number" then
            if value ~= value or math.abs(value) == math.huge then
                return defaultValue
            end
            local limits = NUMBER_LIMITS[key]
            if limits then
                return math.max(limits[1], math.min(limits[2], value))
            end
            return value
        elseif expectedType == "string" then
            if key == "UiAccent" and not VALID_ACCENTS[value] then
                return defaultValue
            end
            if (key == "ChestLootMode" or key == "WorldLootMode")
                and not VALID_LOOT_MODES[value]
            then
                return defaultValue
            end
            if key == "DropSpeed" and not VALID_DROP_SPEEDS[value] then
                return defaultValue
            end
            return string.sub(value, 1, 80)
        elseif expectedType == "table" then
            local result: { any } = {}
            if key == "SavedTeleports" then
                local ids: { [string]: boolean } = {}
                for _, point in ipairs(value) do
                    if #result >= 40 then break end
                    if type(point) == "table" then
                        local valid = true
                        for _, axis in ipairs({ "x", "y", "z" }) do
                            local coordinate = point[axis]
                            if type(coordinate) ~= "number" or coordinate ~= coordinate
                                or math.abs(coordinate) > 1000000
                            then
                                valid = false
                                break
                            end
                        end
                        local id = type(point.id) == "string" and string.sub(point.id, 1, 64)
                        local name = type(point.name) == "string"
                            and string.sub(point.name:gsub("%c", " "), 1, 40)
                        if valid and id and id ~= "" and not ids[id] and name and name:find("%S") then
                            ids[id] = true
                            result[#result + 1] = {
                                id = id, name = name,
                                x = point.x, y = point.y, z = point.z,
                                placeId = type(point.placeId) == "string"
                                    and string.sub(point.placeId, 1, 32) or "",
                                jobId = type(point.jobId) == "string"
                                    and string.sub(point.jobId, 1, 64) or "",
                                mapSeed = type(point.mapSeed) == "string"
                                    and string.sub(point.mapSeed, 1, 64) or "",
                            }
                        end
                    end
                end
                return result
            end
            for _, item in ipairs(value) do
                if type(item) == "string" and #result < 100 then
                    result[#result + 1] = string.sub(item, 1, 120)
                end
            end
            return result
        end

        return value
    end

    local data: { [string]: any } = clone(DEFAULTS)

    local function merge(source: any)
        if type(source) ~= "table" then
            return
        end

        for key in pairs(DEFAULTS) do
            if source[key] ~= nil then
                data[key] = sanitizeValue(key, source[key])
            end
        end
    end

    if globalEnvironment then
        merge(rawget(globalEnvironment, CONFIG_KEY))
    end

    local canReadFile = type(readfile) == "function"
    local canWriteFile = type(writefile) == "function"

    if canReadFile then
        local success, encoded = pcall(readfile, CONFIG_PATH)
        if success and type(encoded) == "string" and encoded ~= "" then
            local decodedSuccess, decoded = pcall(function()
                return HttpService:JSONDecode(encoded)
            end)
            if decodedSuccess then
                merge(decoded)
            end
        end
    end

    local api: any = {}
    local saveGeneration = 0

    local function saveNow()
        if globalEnvironment then
            globalEnvironment[CONFIG_KEY] = clone(data)
        end

        if canWriteFile then
            local success = pcall(function()
                writefile(CONFIG_PATH, HttpService:JSONEncode(data))
            end)
            if success then
                return true, "file + session"
            end
        end

        return true, "current session"
    end

    function api:Get(key)
        return clone(data[key])
    end

    function api:Set(key, value, saveImmediately)
        if DEFAULTS[key] == nil then
            return false
        end

        data[key] = sanitizeValue(key, value)
        saveGeneration = saveGeneration + 1
        local generation = saveGeneration

        if saveImmediately then
            saveNow()
        else
            task.delay(0.25, function()
                if generation == saveGeneration then
                    saveNow()
                end
            end)
        end

        return true
    end

    function api:SaveNow()
        saveGeneration = saveGeneration + 1
        return saveNow()
    end

    function api:Reset()
        data = clone(DEFAULTS)
        saveGeneration = saveGeneration + 1
        local success, storage = saveNow()
        return clone(data), success, storage
    end

    function api:StorageLabel()
        if canWriteFile then
            return "File save supported; session fallback enabled"
        end
        return "Session save only; file API is unavailable"
    end

    return api
end)()

if globalEnvironment then
    local previousCleanup = rawget(globalEnvironment, SCRIPT_CLEANUP_KEY)
    if type(previousCleanup) == "function" then
        pcall(previousCleanup)
    end
end

local scriptAlive = true
local trackedConnections = {}
local unloadScript

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    trackedConnections[#trackedConnections + 1] = connection
    return connection
end

-- SEA UI -------------------------------------------------------------------
-- A small local UI toolkit. It intentionally avoids gradients, remote assets,
-- per-frame UI loops, and duplicated dropdown panels.

local SeaUI: any = (function()
local SEA_ACCENT_THEMES = {
    Amber = {
        Accent = Color3.fromRGB(244, 186, 86),
        AccentDark = Color3.fromRGB(82, 59, 22),
    },
    Mint = {
        Accent = Color3.fromRGB(102, 221, 164),
        AccentDark = Color3.fromRGB(28, 76, 57),
    },
    Ocean = {
        Accent = Color3.fromRGB(95, 180, 255),
        AccentDark = Color3.fromRGB(26, 59, 90),
    },
    Rose = {
        Accent = Color3.fromRGB(245, 117, 143),
        AccentDark = Color3.fromRGB(88, 35, 49),
    },
    Violet = {
        Accent = Color3.fromRGB(183, 143, 255),
        AccentDark = Color3.fromRGB(67, 43, 96),
    },
}

local SEA_ACCENT_NAMES = { "Mint", "Ocean", "Violet", "Amber", "Rose" }
local SEA_TAB_ICONS = {
    Home = "HM",
    Teleport = "TP",
    Builder = "BL",
    Loot = "LT",
    Automation = "AU",
    Combat = "CB",
    ESP = "ES",
    Player = "PL",
    Settings = "ST",
}
local initialAccentName = Config:Get("UiAccent")
local initialAccent = SEA_ACCENT_THEMES[initialAccentName]
    or SEA_ACCENT_THEMES.Mint

local SEA_UI_STATE = {
    Transparency = Config:Get("UiTransparency"),
    Scale = Config:Get("UiScale"),
    AccentName = initialAccentName,
    CompactSidebar = Config:Get("UiCompactSidebar") == true,
}

local SEA_COLORS = {
    Background = Color3.fromRGB(10, 12, 15),
    Panel = Color3.fromRGB(16, 19, 23),
    Raised = Color3.fromRGB(23, 27, 33),
    Line = Color3.fromRGB(45, 51, 59),
    Text = Color3.fromRGB(239, 242, 245),
    Muted = Color3.fromRGB(145, 155, 166),
    Accent = initialAccent.Accent,
    AccentDark = initialAccent.AccentDark,
}

local uiColorBindings = setmetatable({}, { __mode = "k" })
local uiBackgroundBindings = setmetatable({}, { __mode = "k" })

local function newGui(className, properties, parent)
    local object = Instance.new(className)
    for property, value in pairs(properties or {}) do
        object[property] = value

        for _, color in pairs(SEA_COLORS) do
            if value == color then
                local boundProperties = uiColorBindings[object]
                if not boundProperties then
                    boundProperties = {}
                    uiColorBindings[object] = boundProperties
                end
                boundProperties[#boundProperties + 1] = property
                break
            end
        end
    end

    local baseTransparency = properties and properties.BackgroundTransparency
    if properties
        and properties.BackgroundColor3
        and baseTransparency ~= 1
    then
        baseTransparency = tonumber(baseTransparency) or 0
        uiBackgroundBindings[object] = baseTransparency
        object.BackgroundTransparency = baseTransparency
            + ((1 - baseTransparency) * SEA_UI_STATE.Transparency)
    end

    object.Parent = parent
    return object
end

local function addCorner(parent, radius)
    return newGui("UICorner", {
        CornerRadius = UDim.new(0, radius or 6),
    }, parent)
end

local function addStroke(parent, color, transparency)
    return newGui("UIStroke", {
        Color = color or SEA_COLORS.Line,
        Transparency = transparency or 0,
        Thickness = 1,
    }, parent)
end

local function addPadding(parent, left, right, top, bottom)
    return newGui("UIPadding", {
        PaddingLeft = UDim.new(0, left or 0),
        PaddingRight = UDim.new(0, right or 0),
        PaddingTop = UDim.new(0, top or 0),
        PaddingBottom = UDim.new(0, bottom or 0),
    }, parent)
end

local function copyArray(source)
    local copy = {}
    for _, value in ipairs(source or {}) do
        copy[#copy + 1] = value
    end
    return copy
end

local function safeUiCallback(callback, ...)
    if type(callback) ~= "function" then
        return
    end

    local success, callbackError = pcall(callback, ...)
    if not success then
        warn("[SEA UI] " .. tostring(callbackError))
    end
end

local function chooseUiParent()
    if typeof(gethui) == "function" then
        local success, hiddenUi = pcall(gethui)
        if success and hiddenUi then
            return hiddenUi
        end
    end

    return CoreGui
end

-- UI/state bags receive controls after their constructor scope returns. Mark them
-- intentionally dynamic so strict executor language servers do not seal the table
-- and report valid later fields as "Key ... not found".
local SeaUI: any = {
    _toasts = {},
}

function SeaUI:SetTransparency(value)
    local numericValue = tonumber(value) or 0
    SEA_UI_STATE.Transparency = math.max(0, math.min(0.85, numericValue))

    for object, baseTransparency in pairs(uiBackgroundBindings) do
        if object and object.Parent then
            pcall(function()
                object.BackgroundTransparency = baseTransparency
                    + ((1 - baseTransparency) * SEA_UI_STATE.Transparency)
            end)
        end
    end
end

function SeaUI:SetScale(value)
    local numericValue = tonumber(value) or 1
    SEA_UI_STATE.Scale = math.max(0.75, math.min(1.15, numericValue))

    if self._scaleObject then
        self._scaleObject.Scale = SEA_UI_STATE.Scale
    end
    if self._fitWindow then
        self._fitWindow()
    end
end

function SeaUI:SetCompactSidebar(enabled)
    SEA_UI_STATE.CompactSidebar = enabled == true
    if self._fitWindow then
        self._fitWindow()
    end
end

function SeaUI:SetAccentTheme(name)
    local theme = SEA_ACCENT_THEMES[name]
    if not theme then
        return false
    end

    local oldAccent = SEA_COLORS.Accent
    local oldAccentDark = SEA_COLORS.AccentDark
    SEA_COLORS.Accent = theme.Accent
    SEA_COLORS.AccentDark = theme.AccentDark
    SEA_UI_STATE.AccentName = name

    for object, boundProperties in pairs(uiColorBindings) do
        if object and object.Parent then
            for _, property in ipairs(boundProperties) do
                pcall(function()
                    local current = object[property]
                    if current == oldAccent then
                        object[property] = theme.Accent
                    elseif current == oldAccentDark then
                        object[property] = theme.AccentDark
                    end
                end)
            end
        end
    end

    return true
end

function SeaUI:GetAccentNames()
    return copyArray(SEA_ACCENT_NAMES)
end

function SeaUI:ResetPosition()
    if self._main then
        self._main.Position = UDim2.fromScale(0.5, 0.5)
        Config:Set("UiPositionX", 0.5)
        Config:Set("UiPositionY", 0.5)
    end
end

local uiRoot = newGui("ScreenGui", {
    Name = "SeaTools_CustomUI",
    ResetOnSpawn = false,
    IgnoreGuiInset = false,
    DisplayOrder = 50,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

do
    local uiParent = chooseUiParent()
    local existingUi = uiParent and uiParent:FindFirstChild(uiRoot.Name)
    if existingUi then
        pcall(function()
            existingUi:Destroy()
        end)
    end

    local parented = pcall(function()
        uiRoot.Parent = uiParent
    end)

    if not parented then
        uiRoot.Parent = localPlayer:WaitForChild("PlayerGui")
    end
end

local toastHolder = newGui("Frame", {
    Name = "Toasts",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -14, 1, -14),
    Size = UDim2.fromOffset(310, 286),
    BackgroundTransparency = 1,
    ZIndex = 80,
}, uiRoot)

newGui("UIListLayout", {
    FillDirection = Enum.FillDirection.Vertical,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    Padding = UDim.new(0, 7),
}, toastHolder)

function SeaUI:Notify(config)
    local activeToasts = {}
    for _, toast in ipairs(self._toasts) do
        if toast and toast.Parent then
            activeToasts[#activeToasts + 1] = toast
        end
    end
    self._toasts = activeToasts

    if #self._toasts >= 4 then
        self._toasts[1]:Destroy()
        table.remove(self._toasts, 1)
    end

    local toast = newGui("Frame", {
        Name = "Toast",
        Size = UDim2.fromOffset(300, 64),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        ZIndex = 81,
    }, toastHolder)
    addCorner(toast, 6)
    addStroke(toast)

    newGui("Frame", {
        Size = UDim2.fromOffset(3, 64),
        BackgroundColor3 = SEA_COLORS.Accent,
        BorderSizePixel = 0,
        ZIndex = 82,
    }, toast)

    local toastTitle = newGui("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -26, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = tostring(config.Title or "SEA"),
        TextColor3 = SEA_COLORS.Text,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 82,
    }, toast)

    newGui("TextLabel", {
        Position = UDim2.fromOffset(14, 28),
        Size = UDim2.new(1, -26, 0, 28),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = tostring(config.Content or ""),
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 11,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        ZIndex = 82,
    }, toast)

    self._toasts[#self._toasts + 1] = toast

    task.delay(tonumber(config.Duration) or 2, function()
        if toast and toast.Parent then
            toast:Destroy()
        end
    end)
end

local WindowMethods: any = {}
WindowMethods.__index = WindowMethods

local TabMethods: any = {}
TabMethods.__index = TabMethods

local SectionMethods: any = {}
SectionMethods.__index = SectionMethods

local function setTabVisual(tab, active)
    tab._button.BackgroundColor3 = active and SEA_COLORS.AccentDark or SEA_COLORS.Raised
    tab._label.TextColor3 = active and SEA_COLORS.Text or SEA_COLORS.Muted
    tab._badge.BackgroundColor3 = active and SEA_COLORS.Accent or SEA_COLORS.Line
    tab._badge.TextColor3 = active and SEA_COLORS.Background or SEA_COLORS.Muted
    tab._indicator.Visible = active
end

local function makeSectionBody(page, title)
    local wrapper = newGui("Frame", {
        Name = tostring(title or "Section"),
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, page)

    newGui("Frame", {
        Position = UDim2.fromOffset(0, 8),
        Size = UDim2.fromOffset(3, 14),
        BackgroundColor3 = SEA_COLORS.Accent,
        BorderSizePixel = 0,
    }, wrapper)

    newGui("TextLabel", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -10, 0, 28),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = tostring(title or "Section"),
        TextColor3 = SEA_COLORS.Text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, wrapper)

    local body = newGui("Frame", {
        Position = UDim2.fromOffset(0, 30),
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = SEA_COLORS.Panel,
        BorderSizePixel = 0,
    }, wrapper)
    addCorner(body, 10)
    addStroke(body, SEA_COLORS.Line, 0.28)
    addPadding(body, 9, 9, 9, 9)

    newGui("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 8),
    }, body)

    return wrapper, body
end

local function makeControlRow(section, height)
    local row = newGui("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
    }, section._body)
    addCorner(row, 8)
    addStroke(row, SEA_COLORS.Line, 0.62)
    return row
end

local function addControlText(row, title, description, rightSpace)
    rightSpace = rightSpace or 0

    newGui("TextLabel", {
        Position = UDim2.fromOffset(14, 10),
        Size = UDim2.new(1, -(24 + rightSpace), 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = tostring(title or "Control"),
        TextColor3 = SEA_COLORS.Text,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)

    newGui("TextLabel", {
        Position = UDim2.fromOffset(14, 31),
        Size = UDim2.new(1, -(24 + rightSpace), 0, 25),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = tostring(description or ""),
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 10,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
    }, row)
end

function WindowMethods:_selectTab(tab)
    self._activeTab = tab
    self._activeTitle.Text = tostring(tab._title)

    for _, currentTab in ipairs(self._tabs) do
        local isActive = currentTab == tab
        currentTab._page.Visible = isActive
        setTabVisual(currentTab, isActive)
    end

    self:_closePicker()
end

function WindowMethods:_closePicker()
    self._pickerControl = nil
    self._picker.Visible = false
    self._pickerSearch.Text = ""
end

function WindowMethods:_updatePickerSummary()
    local control = self._pickerControl
    if not control then
        self._pickerCount.Text = ""
        self._pickerAll.Visible = false
        self._pickerClear.Visible = false
        return
    end

    if control._multi then
        self._pickerCount.Text = string.format(
            "%d of %d selected",
            #control._selected,
            #control._values
        )
        self._pickerAll.Visible = true
        self._pickerClear.Visible = control._allowNone
    else
        self._pickerCount.Text = control._selected[1] or "Nothing selected"
        self._pickerAll.Visible = false
        self._pickerClear.Visible = false
    end
end

function WindowMethods:_setAllPickerOptions(selected)
    local control = self._pickerControl
    if not control or not control._multi then
        return
    end

    if selected then
        control._selected = copyArray(control._values)
    elseif control._allowNone then
        control._selected = {}
    else
        return
    end

    control:_renderSummary()
    control:_emit()
    self:_updatePickerList()
end

function WindowMethods:_updatePickerList()
    local list = self._pickerList
    for _, child in ipairs(list:GetChildren()) do
        child:Destroy()
    end

    newGui("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 6),
    }, list)
    addPadding(list, 0, 3, 0, 4)

    local control = self._pickerControl
    if not control then
        return
    end

    self:_updatePickerSummary()

    local query = string.lower(self._pickerSearch.Text or "")
    for _, optionValue in ipairs(control._values) do
        local option = tostring(optionValue)
        local visible = query == ""
            or string.find(string.lower(option), query, 1, true) ~= nil

        if visible then
            local selected = control:_isSelected(option)
            local optionButton = newGui("TextButton", {
                Name = option,
                Size = UDim2.new(1, -3, 0, 42),
                BackgroundColor3 = selected and SEA_COLORS.AccentDark or SEA_COLORS.Raised,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Font = Enum.Font.Gotham,
                Text = "  " .. option,
                TextColor3 = selected and SEA_COLORS.Accent or SEA_COLORS.Text,
                TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                ZIndex = 43,
            }, list)

            local mark = newGui("TextLabel", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -12, 0.5, 0),
                Size = UDim2.fromOffset(22, 22),
                BackgroundColor3 = selected and SEA_COLORS.Accent or SEA_COLORS.Line,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamBold,
                Text = selected and "✓" or "",
                TextColor3 = SEA_COLORS.Background,
                TextSize = 13,
                ZIndex = 44,
            }, optionButton)

            -- Picker options are destroyed whenever the filter changes, so
            -- their instance-owned connections should not enter the global
            -- lifecycle list.
            optionButton.MouseButton1Click:Connect(function()
                control:_toggleOption(option)
                if control._multi then
                    self:_updatePickerList()
                else
                    self:_closePicker()
                end
            end)
        end
    end
end

function WindowMethods:_openPicker(control)
    self._pickerControl = control
    self._pickerTitle.Text = tostring(control._title)
    self._pickerSearch.Visible = control._searchEnabled or #control._values > 7
    self._pickerList.Position = self._pickerSearch.Visible
        and UDim2.fromOffset(12, 108)
        or UDim2.fromOffset(12, 64)
    self._pickerList.Size = self._pickerSearch.Visible
        and UDim2.new(1, -24, 1, -120)
        or UDim2.new(1, -24, 1, -76)
    self._pickerSearch.Text = ""
    self._picker.Visible = true
    self:_updatePickerSummary()
    self:_updatePickerList()
end

function WindowMethods:SetToggleKey(keyCode)
    self._toggleKey = keyCode
end

function WindowMethods:SetVisible(visible)
    self._visible = visible == true
    self._main.Visible = self._visible
    self._openButton.Visible = not self._visible
    if not self._visible then
        self:_closePicker()
    end
end

function WindowMethods:Toggle()
    self:SetVisible(not self._visible)
end

function WindowMethods:Destroy()
    self._destroyed = true
    if self._root and self._root.Parent then
        self._root:Destroy()
    end
end

function WindowMethods:Tab(config)
    local tab = setmetatable({
        _window = self,
        _title = config.Title or "Tab",
    }, TabMethods)

    local button = newGui("TextButton", {
        Name = tostring(tab._title),
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "",
    }, self._tabList)
    addCorner(button, 8)

    local badge = newGui("TextLabel", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 8, 0.5, 0),
        Size = UDim2.fromOffset(28, 28),
        BackgroundColor3 = SEA_COLORS.Line,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = SEA_TAB_ICONS[tab._title]
            or string.upper(string.sub(tostring(tab._title), 1, 2)),
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 9,
    }, button)
    addCorner(badge, 7)

    local label = newGui("TextLabel", {
        Position = UDim2.fromOffset(46, 0),
        Size = UDim2.new(1, -54, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = tostring(tab._title),
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, button)

    local indicator = newGui("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -2, 0.5, 0),
        Size = UDim2.fromOffset(3, 26),
        BackgroundColor3 = SEA_COLORS.Accent,
        BorderSizePixel = 0,
        Visible = false,
    }, button)
    addCorner(indicator, 2)

    local page = newGui("ScrollingFrame", {
        Name = tostring(tab._title),
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = SEA_COLORS.Line,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false,
    }, self._content)
    addPadding(page, 14, 14, 13, 18)
    newGui("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 14),
    }, page)

    tab._button = button
    tab._badge = badge
    tab._label = label
    tab._indicator = indicator
    tab._page = page
    self._tabs[#self._tabs + 1] = tab

    if self._compactSidebar then
        badge.AnchorPoint = Vector2.new(0.5, 0.5)
        badge.Position = UDim2.fromScale(0.5, 0.5)
        label.Visible = false
    end

    connect(button.MouseButton1Click, function()
        self:_selectTab(tab)
    end)

    if not self._activeTab then
        self:_selectTab(tab)
    end

    return tab
end

function TabMethods:Section(config)
    local wrapper, body = makeSectionBody(self._page, config.Title)
    return setmetatable({
        _window = self._window,
        _wrapper = wrapper,
        _body = body,
    }, SectionMethods)
end

function SectionMethods:Button(config)
    local row = makeControlRow(self, 62)
    addControlText(row, config.Title, config.Desc, 96)

    local action = newGui("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(80, 32),
        BackgroundColor3 = SEA_COLORS.Accent,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = string.upper(tostring(config.Action or "RUN")),
        TextColor3 = SEA_COLORS.Background,
        TextSize = 11,
    }, row)
    addCorner(action, 7)

    connect(action.MouseButton1Click, function()
        safeUiCallback(config.Callback)
    end)

    return {
        Instance = row,
    }
end

function SectionMethods:Toggle(config)
    local row = makeControlRow(self, 62)
    addControlText(row, config.Title, config.Desc, 66)

    local hitbox = newGui("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 3,
    }, row)

    local track = newGui("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(44, 24),
        BackgroundColor3 = SEA_COLORS.Line,
        BorderSizePixel = 0,
        ZIndex = 4,
    }, row)
    addCorner(track, 12)

    local knob = newGui("Frame", {
        Position = UDim2.fromOffset(3, 3),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = SEA_COLORS.Muted,
        BorderSizePixel = 0,
        ZIndex = 5,
    }, track)
    addCorner(knob, 9)

    local control = {
        Value = config.Value == true,
        Instance = row,
    }

    local function render()
        track.BackgroundColor3 = control.Value and SEA_COLORS.AccentDark or SEA_COLORS.Line
        knob.BackgroundColor3 = control.Value and SEA_COLORS.Accent or SEA_COLORS.Muted
        knob.Position = control.Value and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3)
    end

    function control:Set(value, emitCallback)
        self.Value = value == true
        render()
        if emitCallback ~= false then
            safeUiCallback(config.Callback, self.Value)
        end
    end

    render()
    connect(hitbox.MouseButton1Click, function()
        control:Set(not control.Value)
    end)

    return control
end


function SectionMethods:Dropdown(config)
    local row = makeControlRow(self, 98)
    addControlText(row, config.Title, config.Desc, 0)

    local selectButton = newGui("TextButton", {
        Position = UDim2.new(0, 12, 1, -42),
        Size = UDim2.new(1, -24, 0, 32),
        BackgroundColor3 = SEA_COLORS.Background,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamMedium,
        Text = "",
        TextColor3 = SEA_COLORS.Text,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    addCorner(selectButton, 7)
    addStroke(selectButton, SEA_COLORS.Line)
    addPadding(selectButton, 9, 30, 0, 0)

    newGui("TextLabel", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -9, 0.5, 0),
        Size = UDim2.fromOffset(18, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = ">",
        TextColor3 = SEA_COLORS.Accent,
        TextSize = 13,
    }, selectButton)

    local initialSelection = {}
    if config.Multi then
        if type(config.Value) == "table" then
            initialSelection = copyArray(config.Value)
        elseif config.Value ~= nil then
            initialSelection[1] = tostring(config.Value)
        end
    elseif config.Value ~= nil then
        initialSelection[1] = tostring(config.Value)
    end

    local control = {
        _window = self._window,
        _title = config.Title or "Select",
        _values = copyArray(config.Values or {}),
        _selected = initialSelection,
        _multi = config.Multi == true,
        _allowNone = config.AllowNone == true,
        _searchEnabled = config.SearchBarEnabled == true,
        _callback = config.Callback,
        Instance = row,
    }

    function control:_isSelected(value)
        for _, selectedValue in ipairs(self._selected) do
            if selectedValue == value then
                return true
            end
        end
        return false
    end

    function control:_syncSelectedProperty()
        if self._multi then
            self.Selected = copyArray(self._selected)
        else
            self.Selected = self._selected[1]
        end
    end

    function control:_renderSummary()
        if self._multi then
            if #self._selected == 0 then
                selectButton.Text = "None selected"
            elseif #self._selected == 1 then
                selectButton.Text = self._selected[1]
            else
                selectButton.Text = tostring(#self._selected) .. " selected"
            end
        else
            selectButton.Text = self._selected[1] or "Choose an option"
        end
        self:_syncSelectedProperty()
    end

    function control:_emit()
        if self._multi then
            safeUiCallback(self._callback, copyArray(self._selected))
        else
            safeUiCallback(self._callback, self._selected[1])
        end
    end

    function control:_toggleOption(value)
        if self._multi then
            local newSelection = {}
            local wasSelected = false
            for _, selectedValue in ipairs(self._selected) do
                if selectedValue == value then
                    wasSelected = true
                else
                    newSelection[#newSelection + 1] = selectedValue
                end
            end

            if not wasSelected then
                newSelection[#newSelection + 1] = value
            elseif not self._allowNone and #newSelection == 0 then
                return
            end

            self._selected = newSelection
        else
            self._selected = { value }
        end

        self:_renderSummary()
        self:_emit()
    end

    function control:Refresh(values)
        self._values = copyArray(values or {})
        local available = {}
        for _, value in ipairs(self._values) do
            available[tostring(value)] = true
        end

        local preserved = {}
        for _, value in ipairs(self._selected) do
            if available[value] then
                preserved[#preserved + 1] = value
            end
        end
        self._selected = preserved
        self:_renderSummary()

        if self._window._pickerControl == self then
            self._window:_updatePickerList()
        end
    end

    function control:Select(values, emitCallback)
        local requested = {}
        if type(values) == "table" then
            requested = copyArray(values)
        elseif values ~= nil then
            requested[1] = tostring(values)
        end

        if not self._multi and #requested > 1 then
            requested = { requested[1] }
        end

        self._selected = requested
        self:_renderSummary()
        if emitCallback ~= false then self:_emit() end
        if self._window._pickerControl == self then
            self._window:_updatePickerList()
        end
    end

    control:_renderSummary()
    connect(selectButton.MouseButton1Click, function()
        self._window:_openPicker(control)
    end)

    return control
end

function SectionMethods:Slider(config)
    local valueConfig = config.Value or {}
    local minimum = tonumber(valueConfig.Min) or 0
    local maximum = tonumber(valueConfig.Max) or 100
    local step = tonumber(config.Step) or 1
    local current = tonumber(valueConfig.Default) or minimum

    local row = makeControlRow(self, 98)
    addControlText(row, config.Title, config.Desc, 0)

    local track = newGui("Frame", {
        Position = UDim2.new(0, 12, 1, -29),
        Size = UDim2.new(1, -104, 0, 6),
        BackgroundColor3 = SEA_COLORS.Line,
        BorderSizePixel = 0,
        Active = true,
    }, row)
    addCorner(track, 3)

    local fill = newGui("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = SEA_COLORS.Accent,
        BorderSizePixel = 0,
    }, track)
    addCorner(fill, 3)

    local valueBox = newGui("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 1, -26),
        Size = UDim2.fromOffset(72, 30),
        BackgroundColor3 = SEA_COLORS.Background,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Font = Enum.Font.GothamMedium,
        Text = tostring(current),
        TextColor3 = SEA_COLORS.Text,
        PlaceholderText = "Value",
        PlaceholderColor3 = SEA_COLORS.Muted,
        TextSize = 11,
    }, row)
    addCorner(valueBox, 4)
    addStroke(valueBox)

    local control = {
        Value = current,
        Instance = row,
    }

    local function render()
        local range = maximum - minimum
        local alpha = range > 0 and (control.Value - minimum) / range or 0
        fill.Size = UDim2.fromScale(math.max(0, math.min(1, alpha)), 1)
        valueBox.Text = tostring(control.Value)
    end

    local function setValue(value, emit)
        local numericValue = tonumber(value)
        if not numericValue then
            if emit then
                safeUiCallback(config.Callback, value)
            end
            render()
            return
        end

        numericValue = math.max(minimum, math.min(maximum, numericValue))
        numericValue = minimum + math.floor(((numericValue - minimum) / step) + 0.5) * step
        control.Value = numericValue
        render()

        if emit then
            safeUiCallback(config.Callback, numericValue)
        end
    end

    function control:Set(value)
        setValue(value, true)
    end

    local dragging = false
    local function setFromInput(input)
        if track.AbsoluteSize.X <= 0 then
            return
        end

        local alpha = math.max(0, math.min(1,
            (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
        ))
        setValue(minimum + (maximum - minimum) * alpha, true)
    end

    connect(track.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging = true
            setFromInput(input)
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if dragging and (
            input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        ) then
            setFromInput(input)
        end
    end)

    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging = false
        end
    end)

    connect(valueBox.FocusLost, function()
        setValue(valueBox.Text, true)
    end)

    render()
    return control
end

function SectionMethods:Input(config)
    local row = makeControlRow(self, 98)
    addControlText(row, config.Title, config.Desc, 0)
    local input = newGui("TextBox", {
        Position = UDim2.new(0, 12, 1, -42),
        Size = UDim2.new(1, -24, 0, 32),
        BackgroundColor3 = SEA_COLORS.Background,
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        Text = tostring(config.Value or ""),
        PlaceholderText = tostring(config.Placeholder or ""),
        PlaceholderColor3 = SEA_COLORS.Muted,
        TextColor3 = SEA_COLORS.Text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        MultiLine = false,
    }, row)
    addCorner(input, 7)
    addStroke(input, SEA_COLORS.Line)
    addPadding(input, 9, 9, 0, 0)
    local control = { Instance = row, Value = input.Text }
    function control:Get()
        return string.sub(input.Text:gsub("%c", " "), 1, config.MaxLength or 120)
    end
    function control:Set(value, emitCallback)
        input.Text = string.sub(tostring(value or ""):gsub("%c", " "), 1, config.MaxLength or 120)
        self.Value = input.Text
        if emitCallback ~= false then safeUiCallback(config.Callback, self.Value) end
    end
    connect(input.FocusLost, function()
        control:Set(control:Get())
    end)
    return control
end

function SectionMethods:Paragraph(config)
    local card = newGui("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
    }, self._body)
    addCorner(card, 5)
    addPadding(card, 12, 12, 10, 11)

    newGui("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 5),
    }, card)

    local titleLabel = newGui("TextLabel", {
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = tostring(config.Title or "Info"),
        TextColor3 = SEA_COLORS.Text,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, card)

    local descriptionLabel = newGui("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = tostring(config.Desc or ""),
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 11,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
    }, card)

    return {
        Instance = card,
        Set = function(_, description, title)
            descriptionLabel.Text = tostring(description or "")
            if title ~= nil then titleLabel.Text = tostring(title) end
        end,
    }
end

function TabMethods:Paragraph(config)
    local section = self:Section({
        Title = config.Title or "Info",
    })
    return section:Paragraph(config)
end

function SeaUI:CreateWindow(config)
    local window = setmetatable({
        _root = uiRoot,
        _tabs = {},
        _visible = true,
        _toggleKey = config.ToggleKey or Enum.KeyCode.RightShift,
    }, WindowMethods)

    local main = newGui("Frame", {
        Name = "Main",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(
            Config:Get("UiPositionX") or 0.5,
            Config:Get("UiPositionY") or 0.5
        ),
        Size = UDim2.fromOffset(720, 480),
        BackgroundColor3 = SEA_COLORS.Background,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, uiRoot)
    addCorner(main, 12)
    addStroke(main, SEA_COLORS.Line, 0.12)

    local mainScale = newGui("UIScale", {
        Scale = SEA_UI_STATE.Scale,
    }, main)
    SeaUI._main = main
    SeaUI._scaleObject = mainScale

    local header = newGui("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 64),
        BackgroundColor3 = SEA_COLORS.Panel,
        BorderSizePixel = 0,
        Active = true,
    }, main)

    newGui("TextLabel", {
        Position = UDim2.fromOffset(18, 9),
        Size = UDim2.fromOffset(82, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "SEA TOOLS",
        TextColor3 = SEA_COLORS.Accent,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)

    local versionBadge = newGui("TextLabel", {
        Position = UDim2.fromOffset(98, 8),
        Size = UDim2.fromOffset(34, 18),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = "v58",
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 9,
    }, header)
    addCorner(versionBadge, 5)

    local activeTitle = newGui("TextLabel", {
        Position = UDim2.fromOffset(18, 30),
        Size = UDim2.new(1, -180, 0, 19),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = tostring(config.Title or "Tools"),
        TextColor3 = SEA_COLORS.Text,
        TextSize = 17,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)

    local hotkeyBadge = newGui("TextLabel", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -62, 0.5, 0),
        Size = UDim2.fromOffset(72, 24),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        Text = "RSHIFT",
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, header)
    addCorner(hotkeyBadge, 6)

    local hideButton = newGui("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        Size = UDim2.fromOffset(34, 28),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "—",
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 14,
    }, header)
    addCorner(hideButton, 7)

    newGui("Frame", {
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = SEA_COLORS.Line,
        BorderSizePixel = 0,
    }, header)

    local sidebar = newGui("Frame", {
        Name = "Sidebar",
        Position = UDim2.fromOffset(0, 64),
        Size = UDim2.new(0, 156, 1, -64),
        BackgroundColor3 = SEA_COLORS.Panel,
        BorderSizePixel = 0,
    }, main)
    addPadding(sidebar, 12, 12, 14, 14)

    local tabList = newGui("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = SEA_COLORS.Muted,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, sidebar)
    newGui("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 7),
    }, tabList)

    local content = newGui("Frame", {
        Name = "Content",
        Position = UDim2.fromOffset(156, 64),
        Size = UDim2.new(1, -156, 1, -64),
        BackgroundColor3 = SEA_COLORS.Background,
        BorderSizePixel = 0,
    }, main)

    local picker = newGui("Frame", {
        Name = "Picker",
        Position = UDim2.fromOffset(156, 64),
        Size = UDim2.new(1, -156, 1, -64),
        BackgroundColor3 = SEA_COLORS.Background,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 40,
    }, main)

    local pickerTitle = newGui("TextLabel", {
        Position = UDim2.fromOffset(14, 9),
        Size = UDim2.new(1, -198, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "Select",
        TextColor3 = SEA_COLORS.Text,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 42,
    }, picker)

    local pickerCount = newGui("TextLabel", {
        Position = UDim2.fromOffset(14, 31),
        Size = UDim2.new(1, -198, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "",
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 42,
    }, picker)

    local pickerClose = newGui("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -14, 0, 11),
        Size = UDim2.fromOffset(58, 30),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "DONE",
        TextColor3 = SEA_COLORS.Accent,
        TextSize = 10,
        ZIndex = 42,
    }, picker)
    addCorner(pickerClose, 7)

    local pickerClear = newGui("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -78, 0, 11),
        Size = UDim2.fromOffset(48, 30),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "CLEAR",
        TextColor3 = SEA_COLORS.Muted,
        TextSize = 9,
        Visible = false,
        ZIndex = 42,
    }, picker)
    addCorner(pickerClear, 7)

    local pickerAll = newGui("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -132, 0, 11),
        Size = UDim2.fromOffset(38, 30),
        BackgroundColor3 = SEA_COLORS.AccentDark,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "ALL",
        TextColor3 = SEA_COLORS.Accent,
        TextSize = 9,
        Visible = false,
        ZIndex = 42,
    }, picker)
    addCorner(pickerAll, 7)

    local pickerSearch = newGui("TextBox", {
        Position = UDim2.fromOffset(12, 62),
        Size = UDim2.new(1, -28, 0, 34),
        BackgroundColor3 = SEA_COLORS.Raised,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Font = Enum.Font.Gotham,
        Text = "",
        PlaceholderText = "Search",
        PlaceholderColor3 = SEA_COLORS.Muted,
        TextColor3 = SEA_COLORS.Text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 42,
    }, picker)
    addCorner(pickerSearch, 7)
    addStroke(pickerSearch)
    addPadding(pickerSearch, 10, 10, 0, 0)

    local pickerList = newGui("ScrollingFrame", {
        Position = UDim2.fromOffset(12, 108),
        Size = UDim2.new(1, -24, 1, -120),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = SEA_COLORS.Line,
        ZIndex = 42,
    }, picker)

    local openButton = newGui("TextButton", {
        Name = "OpenButton",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -16, 1, -16),
        Size = UDim2.fromOffset(52, 42),
        BackgroundColor3 = SEA_COLORS.Panel,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "SEA",
        TextColor3 = SEA_COLORS.Accent,
        TextSize = 10,
        Visible = false,
        ZIndex = 70,
    }, uiRoot)
    addCorner(openButton, 12)
    addStroke(openButton, SEA_COLORS.Line, 0.15)

    window._main = main
    window._header = header
    window._sidebar = sidebar
    window._tabList = tabList
    window._content = content
    window._activeTitle = activeTitle
    window._picker = picker
    window._pickerTitle = pickerTitle
    window._pickerCount = pickerCount
    window._pickerAll = pickerAll
    window._pickerClear = pickerClear
    window._pickerSearch = pickerSearch
    window._pickerList = pickerList
    window._openButton = openButton

    connect(hideButton.MouseButton1Click, function()
        window:SetVisible(false)
    end)

    local openButtonMoved = false
    connect(openButton.MouseButton1Click, function()
        if not openButtonMoved then
            window:SetVisible(true)
        end
        openButtonMoved = false
    end)

    connect(pickerClose.MouseButton1Click, function()
        window:_closePicker()
    end)

    connect(pickerAll.MouseButton1Click, function()
        window:_setAllPickerOptions(true)
    end)

    connect(pickerClear.MouseButton1Click, function()
        window:_setAllPickerOptions(false)
    end)

    connect(pickerSearch:GetPropertyChangedSignal("Text"), function()
        if not window._picker.Visible then
            return
        end

        window._pickerSearchGeneration = (window._pickerSearchGeneration or 0) + 1
        local searchGeneration = window._pickerSearchGeneration
        task.delay(0.06, function()
            if not window._destroyed
                and window._picker.Parent
                and window._picker.Visible
                and window._pickerSearchGeneration == searchGeneration
            then
                window:_updatePickerList()
            end
        end)
    end)

    connect(UserInputService.InputBegan, function(input, processed)
        if processed or UserInputService:GetFocusedTextBox() then
            return
        end

        if input.KeyCode == window._toggleKey then
            window:Toggle()
        end
    end)

    local draggingMain = false
    local dragInput
    local dragStart
    local mainStart

    local function saveMainPosition()
        local camera = workspace.CurrentCamera
        if not camera or typeof(camera.ViewportSize) ~= "Vector2" then
            return
        end

        local viewport = camera.ViewportSize
        if viewport.X <= 0 or viewport.Y <= 0 then
            return
        end

        local position = main.Position
        local positionX = math.max(0.08, math.min(
            0.92,
            position.X.Scale + (position.X.Offset / viewport.X)
        ))
        local positionY = math.max(0.08, math.min(
            0.92,
            position.Y.Scale + (position.Y.Offset / viewport.Y)
        ))

        main.Position = UDim2.fromScale(positionX, positionY)
        Config:Set("UiPositionX", positionX)
        Config:Set("UiPositionY", positionY)
    end

    connect(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            draggingMain = true
            dragInput = input
            dragStart = input.Position
            mainStart = main.Position
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if draggingMain and (
            input == dragInput
            or input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        ) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                mainStart.X.Scale,
                mainStart.X.Offset + delta.X,
                mainStart.Y.Scale,
                mainStart.Y.Offset + delta.Y
            )
        end
    end)

    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            local shouldSavePosition = draggingMain
            draggingMain = false
            dragInput = nil
            if shouldSavePosition then
                saveMainPosition()
            end
        end
    end)

    local draggingOpenButton = false
    local openDragStart
    local openButtonStart

    connect(openButton.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            draggingOpenButton = true
            openButtonMoved = false
            openDragStart = input.Position
            openButtonStart = openButton.Position
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if draggingOpenButton and (
            input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        ) then
            local delta = input.Position - openDragStart
            if delta.Magnitude > 5 then
                openButtonMoved = true
            end
            openButton.Position = UDim2.new(
                openButtonStart.X.Scale,
                openButtonStart.X.Offset + delta.X,
                openButtonStart.Y.Scale,
                openButtonStart.Y.Offset + delta.Y
            )
        end
    end)

    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            draggingOpenButton = false
        end
    end)

    local function fitWindowToViewport()
        local camera = workspace.CurrentCamera
        if not camera or typeof(camera.ViewportSize) ~= "Vector2" then
            return
        end

        local viewport = camera.ViewportSize
        local scale = SEA_UI_STATE.Scale
        local width = math.max(340, math.min(720, (viewport.X - 24) / scale))
        local height = math.max(320, math.min(480, (viewport.Y - 28) / scale))
        local compact = SEA_UI_STATE.CompactSidebar or width < 560
        local sidebarWidth = compact and 72 or 156
        window._compactSidebar = compact

        main.Size = UDim2.fromOffset(width, height)
        sidebar.Size = UDim2.new(0, sidebarWidth, 1, -64)
        content.Position = UDim2.fromOffset(sidebarWidth, 64)
        content.Size = UDim2.new(1, -sidebarWidth, 1, -64)
        picker.Position = UDim2.fromOffset(sidebarWidth, 64)
        picker.Size = UDim2.new(1, -sidebarWidth, 1, -64)

        for _, tab in ipairs(window._tabs) do
            tab._label.Visible = not compact
            if compact then
                tab._badge.AnchorPoint = Vector2.new(0.5, 0.5)
                tab._badge.Position = UDim2.fromScale(0.5, 0.5)
            else
                tab._badge.AnchorPoint = Vector2.new(0, 0.5)
                tab._badge.Position = UDim2.new(0, 8, 0.5, 0)
            end
        end
    end

    SeaUI._fitWindow = fitWindowToViewport
    fitWindowToViewport()
    local currentCamera = workspace.CurrentCamera
    if currentCamera then
        connect(currentCamera:GetPropertyChangedSignal("ViewportSize"), fitWindowToViewport)
    end

    return window
end

return SeaUI
end)()

local function notify(title, content, duration)
    SeaUI:Notify({
        Title = title,
        Content = content,
        Duration = duration,
    })
end

local function getCharacter()
    return localPlayer.Character
end

local function getHumanoid()
    local character = getCharacter()
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function getHumanoidRootPart()
    local character = getCharacter()
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function normalizeInstanceName(name)
    -- Makes "Warrior Chest", "WarriorChest", and "warrior_chest" comparable.
    return string.lower((tostring(name):gsub("[^%w]", "")))
end

local function canContainTeleportPosition(instance)
    return instance:IsA("Model")
        or instance:IsA("BasePart")
        or instance:IsA("Folder")
end

local function findNamedTarget(name, allowPartialMatch)
    local normalizedTargetName = normalizeInstanceName(name)
    local partialMatch

    for _, descendant in ipairs(workspace:GetDescendants()) do
        if canContainTeleportPosition(descendant) then
            local normalizedDescendantName = normalizeInstanceName(descendant.Name)

            if normalizedDescendantName == normalizedTargetName then
                return descendant
            end

            if allowPartialMatch
                and not partialMatch
                and string.find(normalizedDescendantName, normalizedTargetName, 1, true)
            then
                partialMatch = descendant
            end
        end
    end

    return partialMatch
end

local function getTargetPart(target: any, preferredPartName: any): any
    if not target then
        return nil
    end

    if target:IsA("BasePart") then
        return target
    end

    if preferredPartName then
        local preferredPart = target:FindFirstChild(preferredPartName, true)
        if preferredPart and preferredPart:IsA("BasePart") then
            return preferredPart
        end
    end

    -- Models in this place generally assign PrimaryPart to their functional
    -- root (chests, interactables, creature visuals). Prefer it over an arbitrary
    -- descendant such as a lid, decoration, or effect part.
    if target:IsA("Model") and target.PrimaryPart then
        return target.PrimaryPart
    end

    return target:FindFirstChildWhichIsA("BasePart", true)
end

local function findNamedModel(name)
    local target = findNamedTarget(name, false)
    if not target then
        return nil
    end

    if target:IsA("Model") then
        return target
    end

    return target:FindFirstAncestorOfClass("Model")
end

local function firstSelectedValue(value)
    -- Accept both a single dropdown value and a one-item selection array.
    if type(value) == "table" then
        return value[1]
    end

    return value
end

local function buildCreatureNames()
    local names = {}
    local seen = {}

    local function addName(name)
        if type(name) ~= "string" or name == "" then
            return
        end
        local normalized = normalizeInstanceName(name)
        if normalized == "" or seen[normalized] then
            return
        end
        seen[normalized] = true
        names[#names + 1] = name
    end

    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local creatures = assets and assets:FindFirstChild("Creatures")
    if creatures then
        for _, template in ipairs(creatures:GetChildren()) do
            if template:IsA("Model") and not template.Name:match("_CLIENT$") then
                addName(template.Name)
            end
        end
    end

    -- Fallback keeps the finder usable if Assets.Creatures replicates late.
    for _, name in ipairs({ "Buku Buku", "Buku Poku", "Crab", "Seagull", "GhostPirate" }) do
        addName(name)
    end

    table.sort(names, function(left, right)
        return string.lower(left) < string.lower(right)
    end)
    return names
end

local CREATURE_NAMES = buildCreatureNames()

-- Manual/player navigation increments this revision. Long-running automation
-- checks the token before moving the player again, preventing a late snap-back.
local Travel: any
local movementRevision = 0
local function interruptAutomationMovement()
    movementRevision = movementRevision + 1
    return movementRevision
end

local function getMovementRevision()
    return movementRevision
end

-- Every player travel hop uses two writes separated by a physics frame. A new
-- travel request, respawn, unload or cancelled worker invalidates the second
-- write. Chest routes/loot explicitly keep their original single-write method.
local teleportWrites = setmetatable({}, { __mode = "k" })
local function teleportPlayer(root, destination, canContinue, chestTeleport)
    if not root or typeof(destination) ~= "CFrame" then return false end
    local token = getMovementRevision()
    local ticket = {}
    teleportWrites[root] = ticket
    for pass = 1, (chestTeleport == true and 1 or 2) do
        if not scriptAlive or not root.Parent or root ~= getHumanoidRootPart()
            or getMovementRevision() ~= token or teleportWrites[root] ~= ticket
            or (canContinue and not canContinue())
        then return false end
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.CFrame = destination
        if pass == 1 and chestTeleport ~= true then RunService.Heartbeat:Wait() end
    end
    return true
end

-- Loot, Bring, Auto Eat, Bonfire, and Grinder can touch the same replicated
-- Interactable. Serialize those operations so two automations never compete for
-- ownership or consume/move the same item at the same time.
local SharedInteraction = {
    owner = nil :: any,
    holder = nil :: any,
    touchedAt = 0,
    staleAfter = 12,
    chestPriorityUntil = 0,
    chestPrioritySession = nil :: any,
}

function SharedInteraction.TryAcquire(owner)
    local now = os.clock()
    local holder = coroutine.running() or SharedInteraction
    if SharedInteraction.owner
        and SharedInteraction.holder ~= holder
        and now - SharedInteraction.touchedAt >= SharedInteraction.staleAfter
    then
        warn("[SEA Interaction Recovery] releasing stale owner: " .. tostring(SharedInteraction.owner))
        SharedInteraction.owner = nil
        SharedInteraction.holder = nil
        SharedInteraction.touchedAt = 0
    end
    if SharedInteraction.owner
        and (
            SharedInteraction.owner ~= owner
            or SharedInteraction.holder ~= holder
        )
    then
        return false
    end
    SharedInteraction.owner = owner
    SharedInteraction.holder = holder
    SharedInteraction.touchedAt = now
    return true
end

function SharedInteraction.Touch(owner)
    local holder = coroutine.running() or SharedInteraction
    if SharedInteraction.owner == owner and SharedInteraction.holder == holder then
        SharedInteraction.touchedAt = os.clock()
        return true
    end
    return false
end

function SharedInteraction.Release(owner, force)
    local holder = coroutine.running() or SharedInteraction
    if SharedInteraction.owner == owner
        and (force == true or SharedInteraction.holder == holder)
    then
        SharedInteraction.owner = nil
        SharedInteraction.holder = nil
        SharedInteraction.touchedAt = 0
        return true
    end
    return false
end

local CHEST_NAMES = {
    "Any Chest",
    "Chest",
    "Small Survivor Chest",
    "Large Survivor Chest",
    "Treasure Chest 01",
    "Treasure Chest 02",
    "Fishermans Chest",
    "Warrior Chest",
    "Pirate Chest",
    "Magma Chest",
    "Frost Chest",
    "Alien Chest",
    "Ghost Chest",
    "Large Log Chest",
    "Small Log Chest",
    "Quest Chest",
    "Modern Large Chest",
    "Modern Small Chest",
    "Treasure Island Chest",
    "Corrupted Chest",
    "Corrupted Boss Chest",
    "Box",
}

-- Friendly dropdown labels mapped to the names used by the game.
local CHEST_ALIASES = {
    ["Chest"] = { "Chest" },
    ["Small Survivor Chest"] = { "SmallChest_Survivor", "Small Survivor Chest" },
    ["Large Survivor Chest"] = { "LargeChest_Survivor", "Large Survivor Chest" },
    ["Treasure Chest 01"] = { "TreasureChest_01", "Treasure Chest 01" },
    ["Treasure Chest 02"] = { "TreasureChest_02", "Treasure Chest 02" },
    ["Fishermans Chest"] = { "Fishermans Chest", "FishermansChest" },
    ["Warrior Chest"] = { "Warrior Chest", "WarriorChest" },
    ["Pirate Chest"] = { "Pirate Chest", "PirateChest" },
    ["Magma Chest"] = { "MagmaChest", "Magma Chest" },
    ["Frost Chest"] = { "FrostChest", "Frost Chest", "Ice Chest" },
    ["Alien Chest"] = { "AlienChest", "Alien Chest" },
    ["Ghost Chest"] = { "GhostChest", "Ghost Chest" },
    ["Large Log Chest"] = { "LargeLogChest", "Large Log Chest" },
    ["Small Log Chest"] = { "SmallLogChest", "Small Log Chest" },
    ["Quest Chest"] = { "QuestChest", "Quest Chest" },
    ["Modern Large Chest"] = { "ModernChest_Large", "Modern Large Chest" },
    ["Modern Small Chest"] = { "ModernSmallChest", "Modern Small Chest" },
    ["Treasure Island Chest"] = { "TreasureIslandChest", "Treasure Island Chest" },
    ["Corrupted Chest"] = { "CorruptedChest", "Corrupted Chest" },
    ["Corrupted Boss Chest"] = { "CorruptedBossChest", "Corrupted Boss Chest" },
    ["Box"] = { "Box" },
}

local CHEST_NORMALIZED_ALIASES = {}

for displayName, aliases in pairs(CHEST_ALIASES) do
    local normalizedAliases = {}
    CHEST_NORMALIZED_ALIASES[displayName] = normalizedAliases

    for _, alias in ipairs(aliases) do
        local normalizedAlias = normalizeInstanceName(alias)
        normalizedAliases[normalizedAlias] = true
    end
end

local ITEM_NAMES = {
    "Broken Crate",
    "Big Broken Crate",
    "Small Broken Crate",
    "Car Battery",
    "Gas Can",
    "Big Gas Can",
    "Small Gas Can",
    "Gas Drum",
    "Scrap Metal",
    "Metal Scrap",
    "Pallet",
    "Wood Plank",
    "Potato",
    "Propellor",
    "Broken Propeller",
    "Stew",
    "Stool",
    "Sushi",
    "Cooked Bird",
    "Fish Fillet",
    "Fish Filet",
    "Meat",
    "Crab Sticks",
    "Orange",
    "Calamari",
    "Machete",
    "Medkit",
    "Bandage",
    "Ancient Tablet",
    "Quest Key",
}

-- Display names do not always match the substring used for the in-game part.
local ITEM_PATTERNS = {
    ["Broken Crate"] = { "Broken Crate", "Big Broken Crate", "Small Broken Crate" },
    ["Car Battery"] = "CarBattery",
    ["Gas Can"] = { "Gas Can", "Small Gas Can", "Big Gas Can", "Gas Drum" },
    ["Scrap Metal"] = { "Scrap Metal", "Metal Scrap" },
    ["Pallet"] = "Pallet",
    ["Wood Plank"] = "Plank",
    ["Potato"] = "Potato",
    ["Propellor"] = { "Propellor", "Propeller", "Broken Propeller" },
    ["Stew"] = "Stew",
    ["Stool"] = "Stool",
    ["Sushi"] = "Sushi",
    ["Cooked Bird"] = "Bird",
    ["Fish Fillet"] = { "Fish Fillet", "Fish Filet" },
    ["Meat"] = "Meat",
    ["Crab Sticks"] = "CrabSticks",
    ["Orange"] = "Orange",
    ["Calamari"] = "Calamari",
    ["Machete"] = "Machete",
    ["Medkit"] = "Medkit",
    ["Bandage"] = "Bandage",
    ["Ancient Tablet"] = "AncientTablet",
    ["Quest Key"] = "Key",
}

local LOOT_MODES = {
    "Smart (E / F)",
    "Pickup / Use (E)",
    "Store in Sack (F)",
}

local DropManager: any
local ChestLoot: any = (function()
    local api: any = {
        Catalog = {},
        Selected = Config:Get("ChestLootItems") or {},
        Enabled = Config:Get("AutoLootChestDrops") == true,
        Radius = Config:Get("ChestLootRadius") or 35,
        Mode = Config:Get("ChestLootMode") or "Smart (E / F)",
        DiagnosticsEnabled = Config:Get("LootDiagnostics") == true,
    }
    local catalogSet = {}
    local handled = setmetatable({}, { __mode = "k" })
    local inFlight = setmetatable({}, { __mode = "k" })
    local interactionBatchActive = false
    local interactionBatchEpoch = 0
    local interactionBatchTouchedAt = 0
    local dropdowns = {}
    local collectGeneration = 0
    local debrisBirthTimes = setmetatable({}, { __mode = "k" })
    -- Strong references are intentional: ChildRemoved and the validation pass
    -- perform cleanup, so garbage collection can never silently erase live loot.
    local liveDebrisItems = {}
    local debrisRevision = 0
    local debrisMetadataRefreshScheduled = false
    local activeChestDropSession
    local itemNameAttributes = {
        "Item",
        "ItemName",
        "Loot",
        "Sack",
        "Tool",
        "ToolName",
        "Weapon",
        "WeaponName",
    }
    local genericItemNames = {
        handle = true,
        interactable = true,
        item = true,
        main = true,
        meshpart = true,
        part = true,
        primary = true,
    }

    local debrisContainerNames = {
        debrisfield = true,
        droppeditems = true,
        drops = true,
        itemcontainer = true,
        items = true,
        loot = true,
    }
    local debrisContainerSet = {}
    local diagnosticEntries = {}
    local DIAGNOSTIC_LIMIT = 32

    local function appendChestDropEvent(session, instance, bornAt)
        if not session
            or session.closed
            or not instance
            or session.queued[instance]
        then
            return
        end

        session.queued[instance] = true
        local spawnPart = getTargetPart(instance)
        session.events[#session.events + 1] = {
            instance = instance,
            bornAt = bornAt,
            spawnPosition = spawnPart and spawnPart.Position or nil,
        }
        session.lastEventAt = bornAt

        -- A chest never emits anywhere close to this many objects. Keeping only
        -- the newest events prevents an abandoned manual-open watcher from
        -- retaining an unlimited list while the player travels around the map.
        if #session.events > 128 then
            local removed = table.remove(session.events, 1)
            if removed then
                session.queued[removed.instance] = nil
            end
        end
    end

    local function trackDebrisBirth(instance)
        if not instance then
            return
        end
        local container = instance.Parent
        if not container
            or container.Parent ~= workspace
            or not debrisContainerSet[container]
        then
            return
        end

        local bornAt = os.clock()
        debrisBirthTimes[instance] = bornAt
        if not liveDebrisItems[instance] then
            liveDebrisItems[instance] = true
            debrisRevision = debrisRevision + 1
        end

        -- Item attributes can arrive a frame after ChildAdded. Bump the revision
        -- after replication settles so world scans retry the registry without
        -- repeatedly walking every tagged template in the game.
        if not debrisMetadataRefreshScheduled then
            debrisMetadataRefreshScheduled = true
            task.delay(0.12, function()
                debrisMetadataRefreshScheduled = false
                debrisRevision = debrisRevision + 1
                -- High-latency servers can replicate Ragdoll/Resource and body
                -- parts after the first frame-settle window. Force one late retry
                -- so a corpse is not postponed until an entire map sweep later.
                task.delay(0.55, function()
                    if scriptAlive then debrisRevision = debrisRevision + 1 end
                end)
            end)
        end

        local session = activeChestDropSession
        if session
            and (
                session.suppressEvents
                or os.clock() < (session.suppressEventsUntil or 0)
            )
        then
            session.ignored[instance] = true
        else
            appendChestDropEvent(session, instance, bornAt)
        end
    end

    local function registerDebrisContainer(instance)
        if not instance or debrisContainerSet[instance] then
            return
        end
        if debrisContainerNames[normalizeInstanceName(instance.Name)] then
            debrisContainerSet[instance] = true
            -- Subscribe first, then reconcile the baseline. This closes the tiny
            -- startup window where a newly spawned drop could otherwise appear
            -- between GetChildren() and ChildAdded:Connect().
            connect(instance.ChildAdded, trackDebrisBirth)
            connect(instance.ChildRemoved, function(child)
                if liveDebrisItems[child] then
                    liveDebrisItems[child] = nil
                    debrisBirthTimes[child] = nil
                    debrisRevision = debrisRevision + 1
                end
            end)
            -- Streaming may create the outer RagdollDummy first and its body parts
            -- later. The registry already knows the model, so wake scanners when a
            -- usable part appears inside that existing direct child.
            connect(instance.DescendantAdded, function(descendant)
                if not descendant:IsA("BasePart") or descendant.Parent == instance then
                    return
                end
                local directChild = descendant
                while directChild.Parent and directChild.Parent ~= instance do
                    directChild = directChild.Parent
                end
                if directChild.Parent == instance and liveDebrisItems[directChild] then
                    debrisRevision = debrisRevision + 1
                end
            end)

            -- Children present before a chest session are baseline world loot.
            -- Only ChildAdded records receive a real birth timestamp.
            local addedBaseline = false
            for _, child in ipairs(instance:GetChildren()) do
                if child.Parent == instance then
                    if debrisBirthTimes[child] == nil then
                        debrisBirthTimes[child] = 0
                    end
                    if not liveDebrisItems[child] then
                        liveDebrisItems[child] = true
                        addedBaseline = true
                    end
                end
            end
            if addedBaseline then debrisRevision = debrisRevision + 1 end
        end
    end

    -- The captured place stores every live world item as a direct child of
    -- Workspace.DebrisField. Do not register Workspace itself: doing so made
    -- every loot pass walk the entire map and was the main source of delay.
    connect(workspace.ChildAdded, registerDebrisContainer)
    for _, child in ipairs(workspace:GetChildren()) do
        registerDebrisContainer(child)
    end
    connect(CollectionService:GetInstanceAddedSignal("Interactable"), function(instance)
        if liveDebrisItems[instance] then
            debrisRevision = debrisRevision + 1
        end
    end)
    connect(CollectionService:GetInstanceRemovedSignal("Interactable"), function(instance)
        if liveDebrisItems[instance] then
            debrisRevision = debrisRevision + 1
        end
    end)

    local function ownExplicitName(instance)
        if not instance then
            return nil
        end

        for _, attributeName in ipairs(itemNameAttributes) do
            local attributeValue = instance:GetAttribute(attributeName)
            if type(attributeValue) == "string" and attributeValue ~= "" then
                return attributeValue
            end

            local valueObject = instance:FindFirstChild(attributeName)
            if valueObject
                and valueObject:IsA("StringValue")
                and valueObject.Value ~= ""
            then
                return valueObject.Value
            end
        end

        return nil
    end

    local function explicitName(instance)
        local current = instance

        for _ = 1, 8 do
            if not current then
                break
            end

            local currentName = ownExplicitName(current)
            if currentName then
                return currentName
            end

            if current == workspace then
                break
            end
            current = current.Parent
        end

        return nil
    end

    local function displayName(instance)
        local attributeName = explicitName(instance)
        if attributeName then
            return attributeName
        end

        local instanceName = instance and tostring(instance.Name) or ""
        local cleanedInstanceName = instanceName:gsub("_CLIENT$", "")
        local normalizedInstanceName = normalizeInstanceName(cleanedInstanceName)
        if cleanedInstanceName ~= ""
            and not tonumber(cleanedInstanceName)
            and not genericItemNames[normalizedInstanceName]
        then
            return cleanedInstanceName
        end

        local current = instance and instance.Parent
        for _ = 1, 6 do
            if not current or current == workspace then
                break
            end

            local parentName = tostring(current.Name or ""):gsub("_CLIENT$", "")
            local normalizedParentName = normalizeInstanceName(parentName)
            if parentName ~= ""
                and not tonumber(parentName)
                and not genericItemNames[normalizedParentName]
                and not debrisContainerNames[normalizedParentName]
            then
                return parentName
            end
            current = current.Parent
        end

        local targetPart = getTargetPart(instance)
        if targetPart
            and not tonumber(targetPart.Name)
            and targetPart.Name ~= "HumanoidRootPart"
            and not genericItemNames[normalizeInstanceName(targetPart.Name)]
        then
            return targetPart.Name
        end

        return cleanedInstanceName
    end

    -- DebrisField children are created with a numeric network id, then receive
    -- Item/Sack metadata a frame later. Treating that temporary id as a real
    -- name makes `All Items` queue the object as Sack material before a weapon
    -- or Sack upgrade can be identified. Wait for a stable item identity.
    local function resolvedLootName(instance)
        local value = displayName(instance)
        if type(value) ~= "string" then
            return nil, nil
        end

        value = value:match("^%s*(.-)%s*$") or ""
        local normalized = normalizeInstanceName(value)
        if value == ""
            or tonumber(value)
            or normalized == ""
            or genericItemNames[normalized]
            or debrisContainerNames[normalized]
        then
            return nil, nil
        end

        return value, normalized
    end

    local function instancePath(instance)
        local segments = {}
        local current = instance

        for _ = 1, 10 do
            if not current then
                break
            end
            table.insert(segments, 1, tostring(current.Name or current.ClassName or "?"))
            if current == workspace then
                break
            end
            current = current.Parent
        end

        return table.concat(segments, "/")
    end

    local function promptDescription(prompt)
        if not prompt then
            return "none"
        end

        local success, description = pcall(function()
            local keyName = prompt.KeyboardKeyCode and prompt.KeyboardKeyCode.Name or "?"
            return tostring(keyName)
                .. ":"
                .. tostring(prompt.ActionText or "")
                .. ":"
                .. tostring(prompt.ObjectText or "")
        end)
        return success and description or "unreadable"
    end

    local function recordDiagnostic(candidate, action, result, prompt)
        local className = candidate and candidate.ClassName or "nil"
        local distanceText = "n/a"
        local ownershipText = "unknown"
        local targetPart = candidate and getTargetPart(candidate)
        local rootPart = getHumanoidRootPart()
        if targetPart and rootPart then
            local success, distance = pcall(function()
                return (targetPart.Position - rootPart.Position).Magnitude
            end)
            if success then
                distanceText = string.format("%.1f", distance)
            end
        end
        if targetPart and typeof(isnetworkowner) == "function" then
            local success, owned = pcall(function()
                return isnetworkowner(targetPart)
            end)
            if success then
                ownershipText = owned and "client" or "server"
            end
        end

        local line = string.format(
            "[%0.2f] item=%s | class=%s | distance=%s | owner=%s | path=%s | action=%s | prompt=%s | result=%s",
            os.clock(),
            candidate and displayName(candidate) or "nil",
            tostring(className),
            distanceText,
            ownershipText,
            instancePath(candidate),
            tostring(action or "none"),
            promptDescription(prompt),
            tostring(result or "unknown")
        )

        diagnosticEntries[#diagnosticEntries + 1] = line
        if #diagnosticEntries > DIAGNOSTIC_LIMIT then
            table.remove(diagnosticEntries, 1)
        end
        if api.DiagnosticsEnabled then
            print("[SeaLoot] " .. line)
        end
    end

    local function matchesName(value, selectedItems)
        local normalizedName = normalizeInstanceName(value)

        for _, selectedName in ipairs(selectedItems) do
            local pattern = ITEM_PATTERNS[selectedName] or selectedName
            local normalizedSelectedName = normalizeInstanceName(selectedName)

            if normalizedSelectedName == "all" or normalizedSelectedName == "allitems" then
                return true
            end

            -- displayName() already resolves Item/ItemName attributes, so broad
            -- substring matching causes more false positives than it solves.
            if normalizedName == normalizedSelectedName then
                return true
            end
            if type(pattern) == "table" then
                for _, alias in ipairs(pattern) do
                    if normalizedName == normalizeInstanceName(alias) then
                        return true
                    end
                end
            elseif normalizedName == normalizeInstanceName(pattern) then
                return true
            end
        end

        return false
    end

    local function addCatalogName(value)
        if type(value) ~= "string" then
            return false
        end

        local trimmedName = value:match("^%s*(.-)%s*$") or ""
        if trimmedName == "" or tonumber(trimmedName) or #trimmedName > 80 then
            return false
        end

        local normalizedName = normalizeInstanceName(trimmedName)
        if normalizedName == ""
            or normalizedName == "interactable"
            or normalizedName == "humanoidrootpart"
            or catalogSet[normalizedName]
        then
            return false
        end

        catalogSet[normalizedName] = true
        api.Catalog[#api.Catalog + 1] = trimmedName
        return true
    end

    local function forEachDebrisItem(callback)
        -- ChildAdded/ChildRemoved maintain this live index. Iterating it avoids
        -- GetChildren allocations and a full CollectionService scan on every
        -- world-search poll.
        for child in pairs(liveDebrisItems) do
            local container = child.Parent
            if container
                and container.Parent == workspace
                and debrisContainerSet[container]
                and (child:IsA("Model") or child:IsA("Tool") or child:IsA("BasePart"))
            then
                callback(child)
            else
                liveDebrisItems[child] = nil
            end
        end
    end

    local function canonicalCandidate(instance)
        local current = instance
        local fallback = instance

        for _ = 1, 10 do
            if not current or current == workspace then
                break
            end

            if ownExplicitName(current) then
                return current
            end

            local cleanedName = tostring(current.Name or ""):gsub("_CLIENT$", "")
            local normalizedName = normalizeInstanceName(cleanedName)
            local meaningfulName = cleanedName ~= ""
                and not tonumber(cleanedName)
                and not genericItemNames[normalizedName]
                and not debrisContainerNames[normalizedName]

            if current:IsA("Tool") then
                return current
            elseif current:IsA("Model") and meaningfulName then
                return current
            elseif meaningfulName then
                fallback = current
            end

            local parent = current.Parent
            if parent
                and debrisContainerNames[normalizeInstanceName(parent.Name)]
            then
                break
            end
            current = current.Parent
        end

        return fallback
    end

    local function isGrindableEnemyCorpse(instance)
        local candidate = canonicalCandidate(instance)
        if not candidate or not candidate:IsA("Model") then
            return false
        end

        -- Enemy corpses are spawned as RagdollDummy_<network id>, while their
        -- readable NPC name usually arrives later in Item. Resource is the
        -- grinder's native compatibility contract (the supplied place uses Goo).
        local resource = candidate:GetAttribute("Resource")
        local isRagdoll = candidate:GetAttribute("Ragdoll") == true
            or string.find(
                normalizeInstanceName(candidate.Name),
                "ragdolldummy",
                1,
                true
            ) == 1
        return isRagdoll
            and type(resource) == "string"
            and resource ~= ""
    end

    local function nearbyCandidates(
        originPosition,
        radius,
        _includeContainerFallback
    )
        local candidates = {}
        local seen = setmetatable({}, { __mode = "k" })

        local function addCandidate(instance)
            if not instance or not instance.Parent then
                return
            end

            local candidate = canonicalCandidate(instance)
            if not candidate or seen[candidate] or not candidate.Parent then
                return
            end
            if not candidate:IsDescendantOf(workspace) then
                return
            end

            -- A saved Drop Here is a storage zone, not a fresh-loot source.
            -- This prevents World/Chest Auto Loot from immediately re-storing
            -- items that SackClient just dropped at the user's saved point.
            if DropManager
                and type(DropManager.ShouldIgnoreCandidate) == "function"
                and DropManager.ShouldIgnoreCandidate(candidate)
            then
                return
            end

            local targetPart = getTargetPart(candidate)
            if not targetPart then
                return
            end

            local distance = (targetPart.Position - originPosition).Magnitude
            if distance <= (radius or api.Radius) then
                seen[candidate] = true
                candidates[#candidates + 1] = candidate
            end
        end

        -- Live loot is stored as direct children of Workspace.DebrisField. Using
        -- this source-only registry prevents ReplicatedStorage templates from
        -- becoming unreachable false targets during a math.huge world scan.
        forEachDebrisItem(addCandidate)

        return candidates
    end

    local function findInteraction(instance)
        local current = instance
        local boundary = canonicalCandidate(instance) or instance

        for _ = 1, 5 do
            if not current or current == workspace or debrisContainerSet[current]
                or current == ReplicatedStorage
            then
                break
            end

            local prompt = current:IsA("ProximityPrompt") and current
                or current:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt then
                return prompt, nil
            end

            local clickDetector = current:IsA("ClickDetector") and current
                or current:FindFirstChildWhichIsA("ClickDetector", true)
            if clickDetector then
                return nil, clickDetector
            end

            -- Never search the whole DebrisField (or a sibling item's prompt).
            if current == boundary then break end
            current = current.Parent
        end

        return nil, nil
    end

    local sackNameTokens = { "sack", "bag", "pouch" }
    local function containsAnyToken(value, tokens)
        local normalized = normalizeInstanceName(value)
        for _, token in ipairs(tokens) do
            if string.find(normalized, token, 1, true) then
                return true
            end
        end
        return false
    end

    local function isSackTool(instance)
        if not instance or not instance:IsA("Tool") then
            return false
        end

        if containsAnyToken(instance.Name, sackNameTokens) then
            return true
        end

        for _, attributeName in ipairs({
            "Sack",
            "SackType",
            "Storage",
            "Capacity",
        }) do
            local success, value = pcall(function()
                return instance:GetAttribute(attributeName)
            end)
            if success and value ~= nil then
                return true
            end
        end

        return false
    end

    local function findSackTool()
        local character = getCharacter()
        local backpack = localPlayer:FindFirstChildOfClass("Backpack")
            or localPlayer:FindFirstChild("Backpack")

        for _, container in ipairs({ character, backpack }) do
            if container then
                for _, child in ipairs(container:GetChildren()) do
                    if isSackTool(child) then
                        return child
                    end
                end
            end
        end

        return nil
    end

    local function findEquippedTool()
        local character = getCharacter()
        if not character then
            return nil
        end

        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") then
                return child
            end
        end

        return nil
    end

    local function equipSackTool(sackTool)
        local character = getCharacter()
        if not sackTool or not character then
            return false
        end
        if sackTool.Parent == character then
            return true
        end

        local humanoid = getHumanoid()
        if not humanoid then
            return false
        end

        return pcall(function()
            humanoid:EquipTool(sackTool)
        end)
    end

    local function getSackCounterLabel(sackTool)
        if not sackTool then
            return nil
        end

        local handle = sackTool:FindFirstChild("Handle")
        local billboard = handle and handle:FindFirstChild("BillboardGui")
        local label = billboard and billboard:FindFirstChild("TextLabel")
        if label then
            return label
        end

        return sackTool:FindFirstChildWhichIsA("TextLabel", true)
    end

    local function readSackState(sackTool)
        local state = {
            count = nil,
            maximum = nil,
            full = false,
            counterText = "unknown",
        }
        if not sackTool then
            return state
        end

        local maxSuccess, maxAttribute = pcall(function()
            return sackTool:GetAttribute("Max")
        end)
        if maxSuccess then
            state.maximum = tonumber(maxAttribute)
        end

        local label = getSackCounterLabel(sackTool)
        if label then
            local textSuccess, labelText = pcall(function()
                return label.Text
            end)
            if textSuccess and type(labelText) == "string" then
                local countText, maximumText = string.match(
                    labelText,
                    "^%s*(%d+)%s*/%s*(%d+)"
                )
                state.count = tonumber(countText)
                state.maximum = state.maximum or tonumber(maximumText)
            end
        end

        -- Fallback for variants that replicate the counter as a ValueObject
        -- instead of the standard Sack billboard used by the captured place.
        if state.count == nil then
            for _, descendant in ipairs(sackTool:GetDescendants()) do
                if descendant:IsA("ValueBase")
                    and containsAnyToken(descendant.Name, {
                        "count",
                        "stored",
                    })
                then
                    local valueSuccess, value = pcall(function()
                        return descendant.Value
                    end)
                    if valueSuccess and type(value) == "number" then
                        state.count = value
                        break
                    end
                end
            end
        end

        if type(state.count) == "number"
            and type(state.maximum) == "number"
        then
            state.full = state.count >= state.maximum
            state.counterText = tostring(state.count)
                .. "/"
                .. tostring(state.maximum)
        elseif type(state.maximum) == "number" then
            state.counterText = "?/" .. tostring(state.maximum)
        end

        return state
    end

    local function storageSnapshot(sackTool)
        local sackState = readSackState(sackTool)
        return {
            count = sackState.count,
            maximum = sackState.maximum,
            counterText = sackState.counterText,
        }
    end

    local function sackCountIncreased(sackTool, before)
        if not sackTool
            or not before
            or type(before.count) ~= "number"
        then
            return false
        end

        local current = readSackState(sackTool)
        return type(current.count) == "number"
            and current.count > before.count
    end

    local function inventorySnapshot()
        local snapshot = setmetatable({}, { __mode = "k" })
        local character = getCharacter()
        local backpack = localPlayer:FindFirstChildOfClass("Backpack")
            or localPlayer:FindFirstChild("Backpack")

        for _, container in ipairs({ character, backpack }) do
            if container then
                for _, child in ipairs(container:GetChildren()) do
                    snapshot[child] = true
                end
            end
        end

        return snapshot
    end

    local function inventoryChanged(before)
        if not before then
            return false
        end

        local character = getCharacter()
        local backpack = localPlayer:FindFirstChildOfClass("Backpack")
            or localPlayer:FindFirstChild("Backpack")
        for _, container in ipairs({ character, backpack }) do
            if container then
                for _, child in ipairs(container:GetChildren()) do
                    if not before[child] then
                        return true
                    end
                end
            end
        end

        return false
    end

    local function candidateIsStoredByPlayer(candidate)
        local character = getCharacter()
        local backpack = localPlayer:FindFirstChildOfClass("Backpack")
            or localPlayer:FindFirstChild("Backpack")
        local current = candidate

        for _ = 1, 14 do
            if not current then
                break
            end
            if current == character or current == backpack or current == localPlayer then
                return true
            end
            current = current.Parent
        end

        return false
    end

    local function candidateHasStoredMarker(candidate)
        local current = candidate
        for _ = 1, 8 do
            if not current or current == workspace then
                break
            end

            for _, attributeName in ipairs({
                "Collected",
                "InSack",
                "PickedUp",
                "Stored",
            }) do
                local success, value = pcall(function()
                    return current:GetAttribute(attributeName)
                end)
                if success and value == true then
                    return true
                end
            end

            current = current.Parent
        end

        return false
    end

    local function candidateWasCollected(
        candidate,
        action,
        sackTool,
        beforeStorage,
        beforeInventory,
        itemOnly
    )
        if not candidate or not candidate.Parent then
            return true
        end
        if candidateHasStoredMarker(candidate) then
            return true
        end

        if action == "sack" then
            if not itemOnly and sackCountIncreased(sackTool, beforeStorage) then
                return true
            end
        elseif candidateIsStoredByPlayer(candidate) then
            return true
        end

        local success, stillInWorkspace = pcall(function()
            return candidate:IsDescendantOf(workspace)
        end)
        return success and not stillInWorkspace
    end

    local function waitForCollection(
        candidate,
        action,
        sackTool,
        beforeStorage,
        beforeInventory,
        checks,
        canContinue,
        itemOnly
    )
        for _ = 1, checks or 5 do
            if type(canContinue) == "function" and not canContinue() then return false end
            if candidateWasCollected(
                candidate,
                action,
                sackTool,
                beforeStorage,
                beforeInventory,
                itemOnly
            ) then
                return true
            end
            task.wait(0.12)
        end

        return candidateWasCollected(
            candidate,
            action,
            sackTool,
            beforeStorage,
            beforeInventory,
            itemOnly
        )
    end

    local cachedSackClient

    local function getSackClient()
        if cachedSackClient and cachedSackClient.Net then
            return cachedSackClient
        end

        local modules = ReplicatedStorage:FindFirstChild("Modules")
        local systems = modules and modules:FindFirstChild("Systems")
        local moduleScript = systems and systems:FindFirstChild("SackClient")
        if not moduleScript then
            return nil
        end

        local success, sackClient = pcall(function()
            return require(moduleScript)
        end)
        if success and type(sackClient) == "table" and sackClient.Net then
            cachedSackClient = sackClient
            return sackClient
        end

        return nil
    end

    local function getStoreTarget(candidate)
        if not candidate or not candidate.Parent then
            return nil
        end
        if candidate:IsA("BasePart") then
            return candidate
        end

        -- Native SackClient sends v14 directly, where v14 is the BasePart from
        -- DragSystem.getDragItem()/checkForTarget(). Pick the closest queryable
        -- part inside the same Interactable instead of sending the Model.
        local root = getHumanoidRootPart()
        local bestPart
        local bestDistance = math.huge
        for _, descendant in ipairs(candidate:GetDescendants()) do
            if descendant:IsA("BasePart") and descendant.Parent then
                local usable = true
                pcall(function()
                    if descendant.CanQuery == false then
                        usable = false
                    end
                end)
                if descendant.Transparency >= 1 and not candidate:GetAttribute("Ragdoll") then
                    usable = false
                end
                if usable then
                    local distance = root and (descendant.Position - root.Position).Magnitude or 0
                    if not bestPart or distance < bestDistance then
                        bestPart = descendant
                        bestDistance = distance
                    end
                end
            end
        end

        return bestPart
            or (candidate:IsA("Model") and candidate.PrimaryPart)
            or candidate:FindFirstChildWhichIsA("BasePart", true)
    end

    local function fireSilentStore(candidate)
        local sackClient = getSackClient()
        local storeTarget = getStoreTarget(candidate)
        if not sackClient or not storeTarget or not storeTarget:IsA("BasePart") then
            return false
        end

        return pcall(function()
            sackClient.Net:FireServer("StoreItem", storeTarget)
        end)
    end

    local cachedLootDragSystem
    local function getLootDragSystem()
        if cachedLootDragSystem and cachedLootDragSystem.Network then
            return cachedLootDragSystem
        end
        local modules = ReplicatedStorage:FindFirstChild("Modules")
        local systems = modules and modules:FindFirstChild("Systems")
        local moduleScript = systems and systems:FindFirstChild("DragSystem")
        if not moduleScript then return nil end
        local ok, result = pcall(require, moduleScript)
        if ok and type(result) == "table" and result.Network then
            cachedLootDragSystem = result
            return result
        end
        return nil
    end

    local function getNativeCollectInteractable(candidate)
        local current = candidate
        for _ = 1, 10 do
            if not current or current == workspace then break end
            -- This function is reached only after resolvePickupAction selected E.
            -- The live game sends the Interactable's unique Name to DragSystem's
            -- Collect remote; chest weapons/currency are often Models rather than
            -- Tools and must not be rejected merely because they lack Food flags.
            if CollectionService:HasTag(current, "Interactable") then
                return current
            end
            current = current.Parent
        end
        return nil
    end

    local function fireNativeCollect(candidate)
        local interactable = getNativeCollectInteractable(candidate)
        if not interactable then
            return false
        end

        -- World Sack models are not ordinary Consumables. The game's own
        -- SackClient handles E with UpgradeSack; sending DragSystem.Collect is
        -- rejected and was why Good/Giant/Ghost Sack drops stayed on the floor.
        local sackName = interactable:GetAttribute("Sack")
        if (type(sackName) == "string" and sackName ~= "")
            or CollectionService:HasTag(interactable, "Sack")
        then
            local sackClient = getSackClient()
            if not sackClient or not sackClient.Net then
                return false
            end
            local success = pcall(function()
                sackClient.Net:FireServer("UpgradeSack", interactable)
            end)
            return success, "UpgradeSack"
        end

        local dragSystem = getLootDragSystem()
        if not dragSystem or not dragSystem.Network then
            return false
        end
        return pcall(function()
            dragSystem.Network:FireServer("Collect", interactable.Name)
        end), "Collect"
    end

    local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
    local floatingItemTemplates = assetsFolder
        and assetsFolder:FindFirstChild("Floating_Item_Models")
    local toolTemplates = assetsFolder and assetsFolder:FindFirstChild("Tools")
    local toolModelTemplates = assetsFolder
        and assetsFolder:FindFirstChild("ToolModels")

    local smartPickupNames = {}
    for _, value in ipairs({
        "Potato",
        "Stew",
        "Sushi",
        "Cooked Bird",
        "Fish Fillet",
        "Fish Filet",
        "Meat",
        "Crab Sticks",
        "Orange",
        "Calamari",
        "Machete",
        "Medkit",
        "Bandage",
        "Ancient Tablet",
        "Quest Key",
    }) do
        smartPickupNames[normalizeInstanceName(value)] = true
    end

    -- Every Tool template is an E pickup. This covers weapons and consumables
    -- whose names do not contain obvious words such as "rifle" or "food".
    if toolTemplates then
        for _, template in ipairs(toolTemplates:GetChildren()) do
            if template:IsA("Tool") then
                smartPickupNames[normalizeInstanceName(template.Name)] = true
            end
        end
    end

    local smartPickupTokens = {
        "ammo",
        "bandage",
        "bullet",
        "consumable",
        "food",
        "gun",
        "harpoon",
        "key",
        "machete",
        "medkit",
        "pistol",
        "potion",
        "rifle",
        "sack",
        "shell",
        "spear",
        "sword",
        "tablet",
        "weapon",
    }

    local function pressInputKey(keyCode, keyName, virtualKey)
        if VirtualInputManager then
            local success = pcall(function()
                VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
                task.wait(0.07)
                VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
            end)
            if success then
                return true
            end
        end

        if typeof(keypress) == "function" and typeof(keyrelease) == "function" then
            local success = pcall(function()
                keypress(virtualKey)
                task.wait(0.07)
                keyrelease(virtualKey)
            end)
            if success then
                return true
            end
        end

        return pcall(function()
            VirtualUser:SetKeyDown(keyName)
            task.wait(0.07)
            VirtualUser:SetKeyUp(keyName)
        end)
    end

    local function candidateUsesPickupKey(candidate)
        local normalizedName = normalizeInstanceName(displayName(candidate))
        if smartPickupNames[normalizedName]
            or containsAnyToken(normalizedName, smartPickupTokens)
        then
            return true
        end

        local current = candidate
        for _ = 1, 8 do
            if not current or current == workspace then
                break
            end

            for _, attributeName in ipairs({
                "Category",
                "ItemType",
                "PickupType",
                "ToolType",
                "Type",
            }) do
                local success, value = pcall(function()
                    return current:GetAttribute(attributeName)
                end)
                if success
                    and type(value) == "string"
                    and containsAnyToken(value, smartPickupTokens)
                then
                    return true
                end
            end

            for _, attributeName in ipairs({
                "Ammo",
                "AmmoType",
                "Consumable",
                "Damage",
                "Doubloons",
                "EssenceType",
                "Food",
                "IsGun",
                "QuestKey",
                "Sack",
                "Weapon",
            }) do
                local success, value = pcall(function()
                    return current:GetAttribute(attributeName)
                end)
                if success and value ~= nil and value ~= false then
                    return true
                end
            end

            -- CantStore is used by world-tool representations that must be
            -- collected/equipped with E instead of sent to SackClient.StoreItem.
            if CollectionService:HasTag(current, "CantStore")
                or CollectionService:HasTag(current, "Sack")
            then
                return true
            end

            current = current.Parent
        end

        return false
    end

    local function actionFromPrompt(prompt)
        if not prompt then
            return nil
        end

        local success, action = pcall(function()
            local text = normalizeInstanceName(
                tostring(prompt.ActionText or "")
                    .. " "
                    .. tostring(prompt.ObjectText or "")
            )
            if containsAnyToken(text, {
                "bag",
                "sack",
                "stash",
                "store",
            }) then
                return "sack"
            elseif containsAnyToken(text, {
                "collect",
                "consume",
                "equip",
                "pickup",
                "take",
                "use",
            }) then
                return "pickup"
            end

            -- F is an unambiguous Sack action. A bare E prompt is not: the
            -- game can show E before the Sack is equipped even for storable
            -- materials, so unknown E items fall back to type/name detection.
            local keyCode = prompt.KeyboardKeyCode
            if keyCode == Enum.KeyCode.F or (keyCode and keyCode.Name == "F") then
                return "sack"
            end

            return nil
        end)

        return success and action or nil
    end

    local function resolvePickupAction(candidate, requestedMode, prompt)
        if requestedMode == "Pickup / Use (E)" then
            return "pickup"
        elseif requestedMode == "Store in Sack (F)" then
            return "sack"
        end

        local promptAction = actionFromPrompt(prompt)
        if promptAction then
            return promptAction
        end

        return candidateUsesPickupKey(candidate) and "pickup" or "sack"
    end

    local function requestLootSimulationRadius()
        if typeof(setsimulationradius) == "function" then
            pcall(function()
                setsimulationradius(10000)
            end)
            return
        end

        if typeof(sethiddenproperty) == "function" then
            pcall(function()
                sethiddenproperty(localPlayer, "SimulationRadius", 10000)
            end)
            pcall(function()
                sethiddenproperty(localPlayer, "MaximumSimulationRadius", 10000)
            end)
        end
    end

    local function captureCandidateTransform(candidate, targetPart)
        if candidate:IsA("Model") then
            local success, pivot = pcall(function()
                return candidate:GetPivot()
            end)
            if success then
                return pivot
            end
        end

        return targetPart and targetPart.CFrame or nil
    end

    local function candidateParts(candidate, targetPart)
        local parts = {}
        local seen = setmetatable({}, { __mode = "k" })

        local function add(part)
            if part and part:IsA("BasePart") and not seen[part] then
                seen[part] = true
                parts[#parts + 1] = part
            end
        end

        add(candidate)
        add(targetPart)
        for _, descendant in ipairs(candidate:GetDescendants()) do
            add(descendant)
        end
        return parts
    end

    local function prepareCandidatePhysics(candidate, targetPart)
        local states = {}
        for _, part in ipairs(candidateParts(candidate, targetPart)) do
            local success, canCollide = pcall(function()
                return part.CanCollide
            end)
            if success then
                states[#states + 1] = {
                    part = part,
                    canCollide = canCollide,
                }
                pcall(function()
                    part.CanCollide = false
                    part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    part.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
                end)
            end
        end
        return states
    end

    local function restoreCandidatePhysics(states)
        for _, state in ipairs(states or {}) do
            if state.part and state.part.Parent then
                pcall(function()
                    state.part.CanCollide = state.canCollide
                end)
            end
        end
    end

    local function moveCandidateToPlayer(candidate, targetPart, rootPart, pulses)
        requestLootSimulationRadius()
        local pulseCount = pulses or 3

        for pulse = 1, pulseCount do
            if not candidate.Parent or not targetPart.Parent or not rootPart.Parent then
                return false
            end

            -- Four studs in front matches the game's ordinary interaction
            -- layout better than placing the item inside the character rig.
            local destination = rootPart.CFrame + Vector3.new(0, 0.5, -4)
            local moved = pcall(function()
                if candidate:IsA("Model") then
                    candidate:PivotTo(destination)
                else
                    targetPart.CFrame = destination
                end

                for _, part in ipairs(candidateParts(candidate, targetPart)) do
                    part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    part.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
                end
            end)
            if not moved then
                return false
            end

            if pulse < pulseCount then
                task.wait(0.04)
            end
        end

        return true
    end

    local function restoreCandidateTransform(candidate, targetPart, originalTransform)
        if not candidate
            or not candidate.Parent
            or not targetPart
            or not targetPart.Parent
            or not originalTransform
        then
            return
        end

        pcall(function()
            if candidate:IsA("Model") then
                candidate:PivotTo(originalTransform)
            else
                targetPart.CFrame = originalTransform
            end
        end)
    end

    local function restorePreviousTool(previousTool, sackTool)
        if previousTool
            and previousTool.Parent
            and previousTool ~= sackTool
            and getHumanoid()
        then
            pcall(function()
                getHumanoid():EquipTool(previousTool)
            end)
        elseif not previousTool and sackTool and getHumanoid() then
            pcall(function()
                getHumanoid():UnequipTools()
            end)
        end
    end

    -- v47 live-target refresh -------------------------------------------------
    -- Full-map scanners can discover an Interactable model one frame before all of
    -- its BaseParts finish streaming. They can also hold a reference to a streamed
    -- clone that is replaced before InteractBatch reaches it. Auto Loot survives
    -- this better because it keeps rebuilding Candidates(); station farms now use
    -- the same idea at the final interaction boundary instead of failing immediately
    -- with `missing-target`.
    local function resolveLiveInteractionCandidate(candidate, rootPart, allowRefresh)
        local function livePart(instance)
            if not instance or not instance.Parent then return nil end
            local part = getTargetPart(instance)
            return part and part.Parent and part or nil
        end

        local targetPart = livePart(candidate)
        if targetPart or not allowRefresh or not rootPart then
            return candidate, targetPart
        end

        local wanted = normalizeInstanceName(displayName(candidate))
        local deadline = os.clock() + 0.85
        repeat
            targetPart = livePart(candidate)
            if targetPart then
                return candidate, targetPart
            end

            local bestCandidate
            local bestPart
            local bestDistance = math.huge
            for _, current in ipairs(nearbyCandidates(rootPart.Position, math.huge, true)) do
                if current and current.Parent
                    and normalizeInstanceName(displayName(current)) == wanted
                then
                    local part = livePart(current)
                    if part then
                        local distance = (part.Position - rootPart.Position).Magnitude
                        if distance < bestDistance then
                            bestDistance = distance
                            bestCandidate = current
                            bestPart = part
                        end
                    end
                end
            end
            if bestCandidate then
                return bestCandidate, bestPart
            end
            task.wait(0.05)
        until not scriptAlive or not rootPart.Parent or os.clock() >= deadline

        return candidate, nil
    end

    local function interact(candidate, requestedMode, batchSession, forcedAction)
        if batchSession and type(batchSession.canContinue) == "function" and not batchSession.canContinue() then
            return false, "batch-cancelled"
        end
        local rootPart = getHumanoidRootPart()
        local autonomousMovement = batchSession and batchSession.autonomousMovement == true
        local rapidChest = batchSession and batchSession.rapidChest == true
        local resolvedCandidate, targetPart = resolveLiveInteractionCandidate(
            candidate,
            rootPart,
            autonomousMovement
        )
        candidate = resolvedCandidate
        if not rootPart or not targetPart or not candidate or not candidate.Parent then
            recordDiagnostic(candidate, requestedMode, "missing-target", nil)
            return false, "missing-target"
        end
        if inFlight[candidate] then
            return false, "busy"
        end

        local reservation = { holder = coroutine.running() }
        inFlight[candidate] = reservation
        local prompt, clickDetector = findInteraction(candidate)
        local previousTool = batchSession
            and batchSession.previousTool
            or findEquippedTool()
        local beforeInventory = inventorySnapshot()
        local action = forcedAction or resolvePickupAction(
            candidate,
            requestedMode or api.Mode,
            prompt
        )
        local sackTool = action == "sack"
            and ((batchSession and batchSession.sackTool) or findSackTool())
            or nil

        local movementToken = batchSession
            and batchSession.movementToken
            or getMovementRevision()
        local originalCFrame = batchSession
            and batchSession.originCFrame
            or rootPart.CFrame
        local traveled = false
        local beforeStorage

        local function movementInterrupted()
            return not scriptAlive
                or not rootPart.Parent
                or getHumanoidRootPart() ~= rootPart
                or getMovementRevision() ~= movementToken
                or (batchSession and type(batchSession.canContinue) == "function" and not batchSession.canContinue())
        end

        local function waitForConfirmation(checks)
            return waitForCollection(candidate, action, sackTool, beforeStorage, beforeInventory,
                checks, function() return not movementInterrupted() end,
                batchSession and batchSession.nativeOnly)
        end

        local function restorePlayerIfNeeded()
            if batchSession or not traveled then
                return
            end
            local humanoid = getHumanoid()
            if not movementInterrupted()
                and rootPart.Parent
                and (not humanoid or humanoid.MoveDirection.Magnitude <= 0.05)
            then
                rootPart.AssemblyLinearVelocity = Vector3.zero
                rootPart.AssemblyAngularVelocity = Vector3.zero
                teleportPlayer(rootPart, originalCFrame, function() return not movementInterrupted() end,
                    rapidChest or (batchSession and batchSession.chestTeleport))
            end
        end

        local function finish(success, method, state)
            if not batchSession then
                restorePreviousTool(previousTool, sackTool)
            end
            restorePlayerIfNeeded()
            if inFlight[candidate] == reservation then inFlight[candidate] = nil end
            local diagnostic = method or (success and "native-travel" or "native-travel-unconfirmed")
            recordDiagnostic(candidate, action, diagnostic, prompt)
            return success == true, diagnostic, state
        end

        if action == "sack" and not sackTool then
            return finish(false, "sack-missing", nil)
        end

        local initialSackState = action == "sack"
            and readSackState(sackTool)
            or nil
        if initialSackState and initialSackState.full then
            return finish(false, "sack-full", initialSackState)
        end

        if not batchSession then
            if action == "sack" then
                if not equipSackTool(sackTool) then
                    return finish(false, "sack-equip-failed", initialSackState)
                end
                task.wait(0.16)
            elseif previousTool and isSackTool(previousTool) then
                local humanoid = getHumanoid()
                if humanoid then
                    pcall(function() humanoid:UnequipTools() end)
                    task.wait(0.06)
                end
            end
        end

        beforeStorage = storageSnapshot(sackTool)

        -- v37 pickup engine: move the PLAYER into the game's normal interaction
        -- range. Do not locally magnet/PivotTo the item. StoreItem and Collect are
        -- then sent from real proximity, matching SackClient/Food/Consumables more
        -- closely and avoiding client-only item snapback.
        local function travelIntoNativeRange()
            if movementInterrupted() or not candidate.Parent then
                return false
            end

            -- IMPORTANT: resolve the actual target + proximity BEFORE consulting
            -- MoveDirection. After a CFrame island visit Roblox can leave a transient
            -- non-zero MoveDirection for a few frames even when no key is held. v43
            -- therefore found a BonfireFuel item, stood beside it, then returned
            -- native-travel-failed before StoreItem was ever sent.
            targetPart = getTargetPart(candidate)
            if not targetPart or not targetPart.Parent then
                return false
            end

            local distance = (targetPart.Position - rootPart.Position).Magnitude
            if distance <= 10.5 then
                return true
            end

            local humanoid = getHumanoid()
            local autonomousMovement = batchSession and batchSession.autonomousMovement == true
            if not autonomousMovement
                and humanoid
                and humanoid.MoveDirection.Magnitude > 0.05
            then
                if batchSession then batchSession.userMoved = true end
                return false
            end

            local delta = rootPart.Position - targetPart.Position
            local flat = Vector3.new(delta.X, 0, delta.Z)
            if flat.Magnitude < 0.1 then
                flat = Vector3.new(0, 0, 1)
            else
                flat = flat.Unit
            end

            local standPosition = targetPart.Position
                + flat * 5
                + Vector3.new(0, 2.5, 0)
            local lookTarget = targetPart.Position + Vector3.new(0, 1, 0)

            local destinationCFrame = CFrame.lookAt(standPosition, lookTarget)
            if batchSession and type(batchSession.travelFunction) == "function" then
                local okTravel, traveledOk = pcall(
                    batchSession.travelFunction,
                    destinationCFrame,
                    candidate,
                    targetPart,
                    movementToken
                )
                if not okTravel or traveledOk ~= true then return false end
            else
                rootPart.AssemblyLinearVelocity = Vector3.zero
                rootPart.AssemblyAngularVelocity = Vector3.zero
                if not teleportPlayer(rootPart, destinationCFrame, function() return not movementInterrupted() end,
                    rapidChest or (batchSession and batchSession.chestTeleport)) then return false end
            end
            traveled = true
            if batchSession then batchSession.traveled = true end

            -- Let streaming/proximity replicate before using the native remote.
            task.wait(0.14)
            if movementInterrupted() then
                return false
            end

            targetPart = getTargetPart(candidate)
            return targetPart ~= nil
                and targetPart.Parent ~= nil
                and (targetPart.Position - rootPart.Position).Magnitude <= 13
        end

        if not travelIntoNativeRange() then
            local state = action == "sack" and readSackState(sackTool) or nil
            return finish(false, "native-travel-failed", state)
        end

        -- Interaction descriptors can appear only after an island/item finishes
        -- streaming, so refresh them after travel.
        prompt, clickDetector = findInteraction(candidate)

        local interactionMethod
        local keyCode = action == "sack" and Enum.KeyCode.F or Enum.KeyCode.E
        local keyName = action == "sack" and "f" or "e"
        local virtualKey = action == "sack" and 0x46 or 0x45

        local maximumAttempts = rapidChest and 1
            or math.clamp(tonumber(batchSession and batchSession.maximumAttempts) or 3, 1, 3)
        for attempt = 1, maximumAttempts do
            if movementInterrupted() then
                break
            end
            if candidateWasCollected(
                candidate,
                action,
                sackTool,
                beforeStorage,
                beforeInventory,
                batchSession and batchSession.nativeOnly
            ) then
                interactionMethod = "native-proximity-confirmed"
                break
            end

            if action == "sack" then
                if fireSilentStore(candidate)
                    and waitForConfirmation(rapidChest and 2 or 6)
                then
                    interactionMethod = "StoreItem-proximity"
                    break
                end
            else
                local fired, pickupMethod = fireNativeCollect(candidate)
                if fired
                    and waitForConfirmation(rapidChest and 2 or 5)
                then
                    interactionMethod = pickupMethod == "UpgradeSack"
                        and "UpgradeSack-proximity"
                        or "Collect-proximity"
                    break
                end
            end

            if movementInterrupted() then break end
            if batchSession and batchSession.nativeOnly then
                if attempt < maximumAttempts then task.wait(0.1) end
                continue
            end

            -- Input fallback is kept only after real proximity has been
            -- established. Unlike the previous engine, the item itself is never
            -- moved locally to fake range.
            if pressInputKey(keyCode, keyName, virtualKey)
                and waitForConfirmation(rapidChest and 1 or 4)
            then
                interactionMethod = action == "sack"
                    and "F-proximity-fallback"
                    or "E-proximity-fallback"
                break
            end

            if not interactionMethod and prompt and prompt.Parent and prompt.Enabled then
                pcall(function() prompt.HoldDuration = 0 end)
                local prompted = false
                if typeof(fireproximityprompt) == "function" then
                    prompted = pcall(function() fireproximityprompt(prompt) end)
                end
                if not prompted then
                    prompted = pcall(function()
                        prompt:InputHoldBegin()
                        task.wait(0.05)
                        prompt:InputHoldEnd()
                    end)
                end
                if prompted
                    and waitForConfirmation(rapidChest and 1 or 4)
                then
                    interactionMethod = "prompt-proximity"
                    break
                end
            end

            if not interactionMethod
                and clickDetector
                and typeof(fireclickdetector) == "function"
            then
                local clicked = pcall(function() fireclickdetector(clickDetector) end)
                if clicked
                    and waitForConfirmation(rapidChest and 1 or 4)
                then
                    interactionMethod = "click-proximity"
                    break
                end
            end

            if attempt < maximumAttempts then
                task.wait(0.1)
            end
        end

        local finalSackState = action == "sack"
            and readSackState(sackTool)
            or nil
        if interactionMethod then
            return finish(true, interactionMethod, finalSackState)
        end
        if movementInterrupted() then return finish(false, "batch-cancelled", finalSackState) end
        if finalSackState and finalSackState.full then
            return finish(false, "sack-full", finalSackState)
        end
        return finish(false, "native-proximity-unconfirmed", finalSackState)
    end

    local function restoreBatchTool(previousTool, activeBatchTool)
        local humanoid = getHumanoid()
        if not humanoid then
            return
        end

        if not previousTool and not activeBatchTool then
            return
        end

        -- Nothing changed when the batch ended with the same tool that was
        -- equipped before it started.
        if previousTool and previousTool == activeBatchTool then
            return
        end

        local character = getCharacter()
        if previousTool and previousTool.Parent == character then
            return
        end

        if previousTool and previousTool.Parent then
            pcall(function()
                humanoid:EquipTool(previousTool)
            end)
        else
            pcall(function()
                humanoid:UnequipTools()
            end)
        end
    end

    local function makeBatchFailureResults(candidates, maximumItems, method)
        local results = {}
        local limit = maximumItems or 12
        for _, candidate in ipairs(candidates or {}) do
            if #results >= limit then
                break
            end
            results[#results + 1] = {
                candidate = candidate,
                success = false,
                method = method,
                action = "unknown",
            }
        end
        return results
    end

    local function runRapidChestBatch(candidates, requestedMode, maximumItems, options)
        options = type(options) == "table" and options or {}
        local queues = { pickup = {}, sack = {} }
        local seen = setmetatable({}, { __mode = "k" })
        local limit = maximumItems or 12
        for _, candidate in ipairs(candidates or {}) do
            if #queues.pickup + #queues.sack >= limit then break end
            if candidate and candidate.Parent and not seen[candidate] and not inFlight[candidate] then
                seen[candidate] = true
                local prompt, clickDetector = findInteraction(candidate)
                local action = resolvePickupAction(candidate, requestedMode or api.Mode, prompt)
                queues[action][#queues[action] + 1] = {
                    candidate = candidate, prompt = prompt,
                    clickDetector = clickDetector, action = action,
                }
            end
        end

        local results = {}
        local root = getHumanoidRootPart()
        local movementToken = getMovementRevision()
        local origin = root and root.CFrame
        local previousTool = findEquippedTool()
        local sackTool
        local traveled = false
        local clustersLeft = 4
        local batchDeadline = os.clock() + 0.85
        local pacing = options.pacing or { lastSentAt = 0 }
        local function canRun()
            return scriptAlive and root and root.Parent and root == getHumanoidRootPart()
                and getMovementRevision() == movementToken
                and (type(options.canContinue) ~= "function" or options.canContinue())
        end
        local function confirmed(candidate)
            if not candidate or not candidate.Parent then return true end
            if candidateHasStoredMarker(candidate) or candidateIsStoredByPlayer(candidate) then
                return true
            end
            local ok, inWorkspace = pcall(function() return candidate:IsDescendantOf(workspace) end)
            return ok and not inWorkspace
        end
        local function report(entry, success, method, state)
            if entry.done then return end
            entry.done = true
            recordDiagnostic(entry.candidate, entry.action, method, entry.prompt)
            results[#results + 1] = {
                candidate = entry.candidate, success = success == true,
                method = method, action = entry.action, sentAt = entry.sentAt,
                sackCount = state and state.count, sackMax = state and state.maximum,
                sackText = state and state.counterText,
            }
        end
        local function failQueue(entries, method, state)
            for _, entry in ipairs(entries) do report(entry, false, method, state) end
        end

        local function processQueue(entries, action)
            if #entries == 0 then return end
            if not canRun() then failQueue(entries, "chest-cancelled"); return end
            local slots = math.huge
            if action == "sack" then
                -- Pickup may have just upgraded/replaced the Sack. Never reuse the
                -- Tool captured before UpgradeSack was sent.
                sackTool = findSackTool()
                if not sackTool then failQueue(entries, "sack-missing"); return end
                local state = readSackState(sackTool)
                if state.full then failQueue(entries, "sack-full", state); return end
                if state.count and state.maximum then
                    slots = math.max(0, state.maximum - state.count)
                    -- Reserve unconfirmed requests from the preceding batch, but
                    -- do not reserve the same slot twice for a scheduled retry.
                    for candidate, pending in pairs(options.pendingConfirmation or {}) do
                        if pending.action == "sack" and not seen[candidate] and not confirmed(candidate) then
                            slots = math.max(0, slots - 1)
                        end
                    end
                end
                if not equipSackTool(sackTool) then
                    failQueue(entries, "sack-equip-failed", state); return
                end
                if sackTool.Parent ~= getCharacter() then task.wait(0.04) end
                if not canRun() then failQueue(entries, "chest-cancelled"); return end
                if sackTool.Parent ~= getCharacter() then
                    failQueue(entries, "sack-equip-failed", state); return
                end
            else
                local equipped = findEquippedTool()
                if equipped and isSackTool(equipped) then
                    local humanoid = getHumanoid()
                    if humanoid then pcall(function() humanoid:UnequipTools() end); task.wait() end
                end
            end

            while canRun() and clustersLeft > 0 and os.clock() < batchDeadline and slots > 0 do
                local nearest, nearestPart, nearestDistance = nil, nil, math.huge
                for _, entry in ipairs(entries) do
                    if not entry.done then
                        if confirmed(entry.candidate) then
                            report(entry, true, "chest-burst")
                        else
                            local part = getTargetPart(entry.candidate)
                            if part and part.Parent then
                                local distance = (part.Position - root.Position).Magnitude
                                if distance < nearestDistance then
                                    nearest, nearestPart, nearestDistance = entry, part, distance
                                end
                            end
                        end
                    end
                end
                if not nearest then break end
                if nearestDistance > 11 then
                    local humanoid = getHumanoid()
                    if options.autonomousMovement ~= true and humanoid
                        and humanoid.MoveDirection.Magnitude > 0.05
                    then break end
                    local delta = root.Position - nearestPart.Position
                    local flat = Vector3.new(delta.X, 0, delta.Z)
                    flat = flat.Magnitude < 0.1 and Vector3.new(0, 0, 1) or flat.Unit
                    local stand = nearestPart.Position + flat * 4 + Vector3.new(0, 2.5, 0)
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                    root.CFrame = CFrame.lookAt(stand, nearestPart.Position)
                    traveled = true
                    -- One proximity replication window per CLUSTER, not per item.
                    task.wait(0.07)
                end
                if not canRun() then break end
                clustersLeft = clustersLeft - 1
                local issued = {}
                for _, entry in ipairs(entries) do
                    if not canRun() then break end
                    if not entry.done then
                        local part = getTargetPart(entry.candidate)
                        if confirmed(entry.candidate) then
                            report(entry, true, "chest-burst")
                        elseif part and part.Parent and slots > 0
                            and (part.Position - root.Position).Magnitude <= 12
                        then
                            if (options.attempts and options.attempts[entry.candidate] or 1) > 1 then
                                -- A partially accepted burst may be rate-limited.
                                -- Pace retries, but still confirm as a group: no
                                -- per-item keyboard/hold/confirmation timeout.
                                local delay = math.max(0, pacing.lastSentAt + 0.22 - os.clock())
                                if os.clock() + delay >= batchDeadline then break end
                                if delay > 0 then task.wait(delay) end
                            end
                            if not canRun() then break end
                            if confirmed(entry.candidate) then
                                report(entry, true, "chest-burst")
                                continue
                            end
                            part = getTargetPart(entry.candidate)
                            if not part or not part.Parent or (part.Position - root.Position).Magnitude > 12 then
                                report(entry, false, "chest-deferred")
                                continue
                            end
                            local fired
                            if action == "sack" then
                                fired = fireSilentStore(entry.candidate)
                            else
                                fired = fireNativeCollect(entry.candidate)
                            end
                            -- Native-less variants get a bounded local prompt/click
                            -- fallback. Never enter interact()'s serial key/hold waits.
                            if not fired and entry.prompt and typeof(fireproximityprompt) == "function" then
                                fired = pcall(fireproximityprompt, entry.prompt)
                            elseif not fired and entry.clickDetector and typeof(fireclickdetector) == "function" then
                                fired = pcall(fireclickdetector, entry.clickDetector)
                            end
                            if fired then
                                entry.sentAt = os.clock()
                                pacing.lastSentAt = entry.sentAt
                                issued[#issued + 1] = entry
                                if action == "sack" then slots = slots - 1 end
                            else
                                report(entry, false, "chest-native-unavailable")
                            end
                        end
                    end
                end

                -- Confirm only this item disappearing/storing. A global inventory
                -- or Sack counter change cannot confirm every member of a burst.
                local deadline = math.min(batchDeadline, os.clock() + 0.14)
                repeat
                    local waiting = false
                    for _, entry in ipairs(issued) do
                        if not entry.done then
                            if confirmed(entry.candidate) then
                                report(entry, true, "chest-burst")
                            else
                                waiting = true
                            end
                        end
                    end
                    if not waiting or not canRun() or os.clock() >= deadline then break end
                    SharedInteraction.Touch("loot")
                    interactionBatchTouchedAt = os.clock()
                    task.wait(0.025)
                until false
                for _, entry in ipairs(issued) do
                    report(entry, false, "chest-burst-pending")
                end
            end

            local state = action == "sack" and readSackState(sackTool) or nil
            for _, entry in ipairs(entries) do
                if not entry.done then
                    if confirmed(entry.candidate) then
                        report(entry, true, "chest-burst", state)
                    else
                        report(entry, false, not canRun() and "chest-cancelled"
                            or (state and state.full and "sack-full" or "chest-deferred"), state)
                    end
                end
            end
        end

        processQueue(queues.pickup, "pickup")
        processQueue(queues.sack, "sack")
        if canRun() then
            if options.keepSackEquipped ~= true then
                local equipped = findEquippedTool()
                restoreBatchTool(previousTool, equipped and isSackTool(equipped) and equipped or nil)
            end
            if traveled and origin and options.restorePosition ~= false then
                local humanoid = getHumanoid()
                if not humanoid or humanoid.MoveDirection.Magnitude <= 0.05 then
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                    root.CFrame = origin
                end
            end
        end
        return results, #queues.pickup, #queues.sack
    end

    local function runInteractionBatch(candidates, requestedMode, maximumItems, options)
        options = type(options) == "table" and options or {}
        if options.rapidChest then
            return runRapidChestBatch(candidates, requestedMode, maximumItems, options)
        end
        if options.autonomousMovement
            and os.clock() < (SharedInteraction.chestPriorityUntil or 0)
        then
            return makeBatchFailureResults(
                candidates,
                maximumItems,
                "chest-priority"
            ), 0, 0
        end
        local queues = {
            pickup = {},
            sack = {},
        }
        local seen = setmetatable({}, { __mode = "k" })
        local limit = maximumItems or 12

        for _, candidate in ipairs(candidates or {}) do
            if #queues.pickup + #queues.sack >= limit then
                break
            end
            if candidate
                and candidate.Parent
                and not seen[candidate]
                and not inFlight[candidate]
            then
                seen[candidate] = true
                local prompt = findInteraction(candidate)
                local action = resolvePickupAction(
                    candidate,
                    requestedMode or api.Mode,
                    prompt
                )
                queues[action][#queues[action] + 1] = {
                    candidate = candidate,
                    prompt = prompt,
                }
            end
        end

        local results = {}
        local batchRoot = getHumanoidRootPart()
        local session = {
            -- Auto Farm intentionally does not remember/restore Harpoon or another
            -- previously equipped tool. While keepSackEquipped is set, Sack owns
            -- the tool slot for the whole farming session.
            previousTool = if options.keepSackEquipped then nil else findEquippedTool(),
            sackTool = findSackTool(),
            originCFrame = batchRoot and batchRoot.CFrame or nil,
            movementToken = getMovementRevision(),
            traveled = false,
            userMoved = false,
            travelFunction = options.travelFunction,
            nativeOnly = options.nativeOnly == true,
            chestTeleport = options.chestTeleport == true,
            maximumAttempts = options.maximumAttempts,
            -- Station farms own character movement while enabled. This prevents a
            -- transient MoveDirection after an island teleport from cancelling the
            -- next StoreItem attempt. World/Chest loot keep the normal user-input guard.
            autonomousMovement = options.autonomousMovement == true,
        }
        local humanoid = getHumanoid()
        local deadline = os.clock() + (tonumber(options.timeBudget) or math.huge)
        local function canRun()
            return scriptAlive and batchRoot ~= nil and batchRoot.Parent ~= nil
                and getHumanoidRootPart() == batchRoot
                and getMovementRevision() == session.movementToken
                and os.clock() < deadline
                and (type(options.canContinue) ~= "function" or options.canContinue())
        end
        session.canContinue = canRun

        local function ensureSackEquipped()
            if not canRun() or not session.sackTool then
                return false
            end
            if not equipSackTool(session.sackTool) then
                return false
            end
            task.wait(0.05)
            return canRun() and session.sackTool.Parent == getCharacter()
        end

        -- In full-map Auto Farm mode the Sack is equipped immediately and kept
        -- equipped between targets. E-only items may temporarily need an empty
        -- hand, but the Sack is re-equipped immediately afterwards.
        if options.keepSackEquipped and session.sackTool then
            ensureSackEquipped()
        end

        local sackReady = #queues.sack == 0
        local sackFailure = "sack-missing"
        local sackEquipped = false
        local sackState = session.sackTool
            and readSackState(session.sackTool)
            or nil
        local stoppedForFullSack = false

        local function processSackQueue()
            if #queues.sack == 0 then
                return
            end

            if session.sackTool then
                if sackState and sackState.full then
                    sackReady = false
                    sackFailure = "sack-full"
                    stoppedForFullSack = true
                else
                    sackReady = ensureSackEquipped()
                    sackFailure = "sack-equip-failed"
                    sackEquipped = sackReady
                end
            end

            for _, entry in ipairs(queues.sack) do
                if not canRun() then break end
                SharedInteraction.Touch("loot")
                interactionBatchTouchedAt = os.clock()
                if type(options.onProgress) == "function" then
                    pcall(options.onProgress)
                end
                if sackReady then
                    sackState = readSackState(session.sackTool)
                    if sackState.full then
                        sackReady = false
                        sackFailure = "sack-full"
                        stoppedForFullSack = true
                    else
                        local success, method, resultState = interact(
                            entry.candidate,
                            requestedMode,
                            session,
                            "sack"
                        )
                        resultState = resultState
                            or readSackState(session.sackTool)
                            or {}
                        results[#results + 1] = {
                            candidate = entry.candidate,
                            success = success,
                            method = method,
                            action = "sack",
                            sackCount = resultState.count,
                            sackMax = resultState.maximum,
                            sackText = resultState.counterText,
                        }
                        if method == "sack-full" or resultState.full then
                            sackReady = false
                            sackFailure = "sack-full"
                            stoppedForFullSack = true
                            sackState = resultState
                        end
                    end
                end

                if not sackReady
                    and (
                        #results == 0
                        or results[#results].candidate ~= entry.candidate
                    )
                then
                    sackState = session.sackTool
                        and readSackState(session.sackTool)
                        or sackState
                    local diagnosticResult = sackFailure
                    if sackFailure == "sack-full" and sackState then
                        diagnosticResult = diagnosticResult
                            .. " "
                            .. sackState.counterText
                    end
                    recordDiagnostic(
                        entry.candidate,
                        "sack",
                        diagnosticResult,
                        entry.prompt
                    )
                    results[#results + 1] = {
                        candidate = entry.candidate,
                        success = false,
                        method = sackFailure,
                        action = "sack",
                        sackCount = sackState and sackState.count or nil,
                        sackMax = sackState and sackState.maximum or nil,
                        sackText = sackState and sackState.counterText or nil,
                    }
                end

                if stoppedForFullSack and options.stopWhenSackFull then
                    break
                end
            end
        end

        local function processPickupQueue()
            if not canRun() or #queues.pickup == 0 then
                return
            end
            if stoppedForFullSack and options.stopWhenSackFull then
                return
            end

            local equipped = findEquippedTool()
            if equipped and isSackTool(equipped) and humanoid then
                pcall(function()
                    humanoid:UnequipTools()
                end)
                task.wait(0.04)
            end

            for _, entry in ipairs(queues.pickup) do
                if not canRun() then break end
                SharedInteraction.Touch("loot")
                interactionBatchTouchedAt = os.clock()
                if type(options.onProgress) == "function" then
                    pcall(options.onProgress)
                end
                local success, method = interact(
                    entry.candidate,
                    requestedMode,
                    session,
                    "pickup"
                )
                results[#results + 1] = {
                    candidate = entry.candidate,
                    success = success,
                    method = method,
                    action = "pickup",
                }
            end

            if options.keepSackEquipped and session.sackTool then
                ensureSackEquipped()
            end
        end

        if options.sackFirst then
            processSackQueue()
            processPickupQueue()
        else
            processPickupQueue()
            processSackQueue()
        end

        local activeBatchTool = #queues.sack > 0
            and sackEquipped
            and session.sackTool
            or nil
        if canRun() then
            if options.keepSackEquipped and session.sackTool then
                ensureSackEquipped()
            else
                restoreBatchTool(session.previousTool, activeBatchTool)
            end
        end

        -- Normal chest-loot batches preserve the old one-batch restore behavior.
        -- Full-map Auto Farm sets restorePosition=false so it continues from the
        -- last collected item instead of teleporting back after every 10 items.
        if canRun() and options.restorePosition ~= false
            and session.traveled
            and not session.userMoved
            and session.originCFrame
        then
            local root = getHumanoidRootPart()
            local currentHumanoid = getHumanoid()
            if root
                and root.Parent
                and getMovementRevision() == session.movementToken
                and (not currentHumanoid or currentHumanoid.MoveDirection.Magnitude <= 0.05)
            then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                teleportPlayer(root, session.originCFrame, canRun, session.chestTeleport)
            end
        end

        return results, #queues.pickup, #queues.sack
    end

    local function interactBatch(candidates, requestedMode, maximumItems, options)
        if interactionBatchActive
            and interactionBatchTouchedAt > 0
            and os.clock() - interactionBatchTouchedAt >= SharedInteraction.staleAfter
        then
            warn("[SEA Loot Recovery] releasing stale interaction batch")
            interactionBatchActive = false
            interactionBatchEpoch = interactionBatchEpoch + 1
            interactionBatchTouchedAt = 0
            SharedInteraction.Release("loot", true)
        end
        if interactionBatchActive or not SharedInteraction.TryAcquire("loot") then
            return makeBatchFailureResults(
                candidates,
                maximumItems,
                "batch-busy"
            ), 0, 0
        end

        interactionBatchActive = true
        interactionBatchEpoch = interactionBatchEpoch + 1
        local epoch = interactionBatchEpoch
        local holder = coroutine.running()
        local batchOptions = table.clone(type(options) == "table" and options or {})
        local parentCanContinue = batchOptions.canContinue
        batchOptions.canContinue = function()
            return interactionBatchEpoch == epoch and SharedInteraction.holder == holder
                and (type(parentCanContinue) ~= "function" or parentCanContinue())
        end
        interactionBatchTouchedAt = os.clock()
        local success, results, pickupCount, sackCount = pcall(function()
            return runInteractionBatch(
                candidates,
                requestedMode,
                maximumItems,
                batchOptions
            )
        end)
        if interactionBatchEpoch == epoch then
            interactionBatchActive = false
            interactionBatchTouchedAt = 0
            SharedInteraction.Release("loot")
        end
        for candidate, reservation in pairs(inFlight) do
            if type(reservation) == "table" and reservation.holder == holder then inFlight[candidate] = nil end
        end

        if success then
            return results, pickupCount, sackCount
        end

        local failedResults = makeBatchFailureResults(
            candidates,
            maximumItems,
            "batch-error"
        )
        for _, result in ipairs(failedResults) do
            recordDiagnostic(
                result.candidate,
                "batch",
                "batch-error: " .. tostring(results),
                nil
            )
        end
        return failedResults, 0, 0
    end

    addCatalogName("All Items")
    -- Stable semantic entry for dynamically named RagdollDummy instances. It is
    -- usable by World Loot and is also shared with the Auto Grinder item filter.
    addCatalogName("Enemy Corpses")
    for _, itemName in ipairs(ITEM_NAMES) do
        addCatalogName(itemName)
    end
    -- The RBXL contains a complete item template catalog here. Loading it at
    -- startup makes all choices available even if an item has not spawned yet.
    if floatingItemTemplates then
        for _, template in ipairs(floatingItemTemplates:GetChildren()) do
            if template:IsA("Model") or template:IsA("Tool") then
                addCatalogName(template.Name)
            end
        end
    end
    -- Weapons live in Assets.Tools, not Floating_Item_Models. They were used
    -- for Smart E/F detection above but were accidentally omitted from the UI
    -- filter, leaving only Machete selectable. Include every replicated tool and
    -- the explicit Item names carried by the game's world-tool models.
    if toolTemplates then
        for _, template in ipairs(toolTemplates:GetChildren()) do
            if template:IsA("Tool") then
                addCatalogName(template.Name)
            end
        end
    end
    if toolModelTemplates then
        for _, template in ipairs(toolModelTemplates:GetChildren()) do
            local templateItemName = ownExplicitName(template)
            if templateItemName then
                addCatalogName(templateItemName)
            end
        end
    end
    table.sort(api.Catalog, function(left, right)
        return string.lower(left) < string.lower(right)
    end)
    for _, itemName in ipairs(api.Selected) do
        addCatalogName(itemName)
    end

    function api.DisplayName(instance)
        return displayName(instance)
    end

    function api.Matches(instance, selectedItems)
        if isGrindableEnemyCorpse(instance) then
            for _, selectedName in ipairs(selectedItems or {}) do
                if normalizeInstanceName(selectedName) == "enemycorpses" then
                    return true
                end
            end
        end
        return matchesName(displayName(instance), selectedItems)
    end

    function api.IsGrindableEnemyCorpse(instance)
        return isGrindableEnemyCorpse(instance)
    end

    function api.MatchesName(value, selectedItems)
        return matchesName(value, selectedItems)
    end

    function api.SetDropdown(control)
        if control then
            dropdowns[#dropdowns + 1] = control
        end
    end

    function api.SetSelected(options)
        api.Selected = options
        Config:Set("ChestLootItems", options)
    end

    function api.SetEnabled(enabled)
        api.Enabled = enabled == true
        collectGeneration = collectGeneration + 1
        if not api.Enabled then
            if activeChestDropSession then
                activeChestDropSession.closed = true
                activeChestDropSession = nil
            end
            -- Disabling chest loot must never leave World Auto Loot paused by a
            -- stale priority lease from an already-closed session.
            SharedInteraction.chestPriorityUntil = os.clock()
            SharedInteraction.chestPrioritySession = nil
        end
        Config:Set("AutoLootChestDrops", api.Enabled)
    end

    function api.SetRadius(value)
        api.Radius = value
        Config:Set("ChestLootRadius", value)
    end

    function api.SetMode(value)
        api.Mode = firstSelectedValue(value) or "Smart (E / F)"
        Config:Set("ChestLootMode", api.Mode)
    end

    function api.SetDiagnosticsEnabled(enabled)
        api.DiagnosticsEnabled = enabled == true
        Config:Set("LootDiagnostics", api.DiagnosticsEnabled)
    end

    function api.GetDiagnosticsReport()
        local lines = {
            "100 Days at Sea v48 - Loot Diagnostics",
            "mode=" .. tostring(api.Mode),
            "entries=" .. tostring(#diagnosticEntries),
        }
        for _, entry in ipairs(diagnosticEntries) do
            lines[#lines + 1] = entry
        end
        return table.concat(lines, "\n")
    end

    function api.CopyDiagnostics()
        local report = api.GetDiagnosticsReport()
        local copied = false
        if typeof(setclipboard) == "function" then
            copied = pcall(function()
                setclipboard(report)
            end)
        end

        if not copied then
            print(report)
        end
        notify(
            "Loot Report",
            copied and "Copied to clipboard" or "Printed to executor console",
            2
        )
        return report
    end

    function api.ClearDiagnostics()
        for index = #diagnosticEntries, 1, -1 do
            diagnosticEntries[index] = nil
        end
        notify("Loot Report", "Diagnostic history cleared", 1.5)
    end

    function api.AddCatalogName(value)
        return addCatalogName(value)
    end

    function api.Candidates(originPosition, radius, includeContainerFallback)
        return nearbyCandidates(originPosition, radius, includeContainerFallback)
    end

    function api.GetDebrisRevision()
        return debrisRevision
    end

    function api.Interact(candidate, requestedMode)
        return interact(candidate, requestedMode)
    end

    function api.InteractBatch(candidates, requestedMode, maximumItems, options)
        return interactBatch(candidates, requestedMode, maximumItems, options)
    end

    function api.RecoverInteraction(expectedHolder)
        for candidate, reservation in pairs(inFlight) do
            if not expectedHolder or (type(reservation) == "table" and reservation.holder == expectedHolder) then
                inFlight[candidate] = nil
            end
        end
        -- Abandoned reservations may outlive their old lock. Clear only those
        -- reservations, without resetting a newer coroutine's active batch.
        if expectedHolder and SharedInteraction.holder ~= expectedHolder then return false end
        interactionBatchActive = false
        interactionBatchEpoch = interactionBatchEpoch + 1
        interactionBatchTouchedAt = 0
        SharedInteraction.Release("loot", true)
        SharedInteraction.Release("loot-search", true)
        return true
    end

    function api.Refresh(showNotification)
        local discoveredNames = {}
        local discoveredSet = {}

        local function consider(instance)
            local readableName = explicitName(instance) or displayName(instance)
            if type(readableName) == "string" then
                local normalizedName = normalizeInstanceName(readableName)
                if normalizedName ~= ""
                    and not catalogSet[normalizedName]
                    and not discoveredSet[normalizedName]
                then
                    discoveredSet[normalizedName] = true
                    discoveredNames[#discoveredNames + 1] = readableName
                end
            end
        end

        forEachDebrisItem(consider)
        if floatingItemTemplates then
            for _, template in ipairs(floatingItemTemplates:GetChildren()) do
                consider(template)
            end
        end

        table.sort(discoveredNames, function(left, right)
            return string.lower(left) < string.lower(right)
        end)

        local addedCount = 0
        for _, itemName in ipairs(discoveredNames) do
            if addCatalogName(itemName) then
                addedCount = addedCount + 1
            end
        end

        for _, dropdown in ipairs(dropdowns) do
            dropdown:Refresh(api.Catalog)
        end

        if showNotification then
            if addedCount > 0 then
                notify("Loot List Updated", "Added " .. addedCount .. " new item types", 2)
            else
                notify("Loot List Updated", "No new item types are spawned", 2)
            end
        end

        return addedCount
    end

    function api.Snapshot(originPosition, chest)
        if activeChestDropSession then
            local previousSession = activeChestDropSession
            previousSession.closed = true
            if SharedInteraction.chestPrioritySession == previousSession then
                SharedInteraction.chestPriorityUntil = os.clock()
                SharedInteraction.chestPrioritySession = nil
            end
        end

        local session = {
            isChestDropSession = true,
            origin = originPosition,
            chest = chest,
            createdAt = os.clock(),
            armedAt = nil,
            events = {},
            queued = setmetatable({}, { __mode = "k" }),
            ignored = setmetatable({}, { __mode = "k" }),
            existing = setmetatable({}, { __mode = "k" }),
            closed = false,
        }

        -- Baseline the whole debris container once. Unlike the old nearby scan,
        -- an existing world item cannot become a "new chest drop" merely because
        -- it moved or streamed into the configured radius later.
        forEachDebrisItem(function(instance)
            session.existing[instance] = true
            local candidate = canonicalCandidate(instance)
            if candidate then
                session.existing[candidate] = true
            end
        end)

        activeChestDropSession = session
        return session
    end

    function api.Arm(session, replicationLead)
        if type(session) ~= "table"
            or session.isChestDropSession ~= true
            or session.closed
        then
            return false
        end

        session.armedAt = os.clock() - math.max(0, tonumber(replicationLead) or 0)
        activeChestDropSession = session
        session.priorityUntil = os.clock() + 6
        SharedInteraction.chestPriorityUntil = session.priorityUntil
        SharedInteraction.chestPrioritySession = session
        return true
    end

    function api.CancelSession(session)
        if type(session) == "table" then
            session.closed = true
        end
        if activeChestDropSession == session then
            activeChestDropSession = nil
        end
        if SharedInteraction.chestPrioritySession == session then
            SharedInteraction.chestPriorityUntil = os.clock() + 0.1
            SharedInteraction.chestPrioritySession = nil
        end
    end

    function api.SetStatus(message, title)
        api.LastStatus = tostring(message)
        if api.StatusControl then
            api.StatusControl:Set(api.LastStatus, title or "Chest route status")
        end
    end

    function api.Collect(originPosition, beforeSnapshot, expectedGeneration)
        if not api.Enabled or #api.Selected == 0 then
            api.CancelSession(beforeSnapshot)
            return 0
        end

        local generation = expectedGeneration
        if generation == nil then
            collectGeneration = collectGeneration + 1
            generation = collectGeneration
        end

        local session = beforeSnapshot
        if type(session) == "table"
            and session.isChestDropSession == true
            and session.closed
        then
            return 0
        end
        if type(session) ~= "table" or session.isChestDropSession ~= true then
            session = {
                isChestDropSession = true,
                origin = originPosition,
                createdAt = os.clock(),
                armedAt = os.clock() - 0.25,
                events = {},
                queued = setmetatable({}, { __mode = "k" }),
                ignored = setmetatable({}, { __mode = "k" }),
                existing = type(beforeSnapshot) == "table"
                    and beforeSnapshot
                    or setmetatable({}, { __mode = "k" }),
                closed = false,
            }
        elseif not session.armedAt then
            api.Arm(session, 0.25)
        end

        originPosition = originPosition or session.origin
        if not originPosition then
            api.CancelSession(session)
            return 0
        end

        session.closed = false
        activeChestDropSession = session

        -- Recover the tiny Snapshot -> ChildAdded scheduling race without ever
        -- consulting the global Interactable tag list.
        local function queueRecentDebris()
            forEachDebrisItem(function(instance)
                local bornAt = debrisBirthTimes[instance]
                local candidate = canonicalCandidate(instance)
                if candidate
                    and bornAt
                    and bornAt >= session.armedAt - 0.03
                    and not session.ignored[instance]
                    and not session.existing[instance]
                    and not session.existing[candidate]
                then
                    appendChestDropEvent(session, instance, bornAt)
                end
            end)
        end

        queueRecentDebris()
        local pickedUpCount = 0
        local detectedCount = 0
        local detected = setmetatable({}, { __mode = "k" })
        local attempts = setmetatable({}, { __mode = "k" })
        local nextAttemptAt = setmetatable({}, { __mode = "k" })
        local pendingConfirmation = setmetatable({}, { __mode = "k" })
        local pacing = { lastSentAt = 0 }
        local sackMissingCount = 0
        local sackFullCount = 0
        local sackFullText
        local sackAutoEmptied = false
        local emptyAttempted = false
        local emptyCycles = 0
        local sawChestDrop = false
        local startedAt = os.clock()
        local lastRelevantAt = startedAt
        local nextFallbackScanAt = startedAt + 0.12
        local absoluteDeadline = startedAt + 2.8
        local maximumBusyDeadline = startedAt + 6
        local movementToken = getMovementRevision()
        local originalRoot = getHumanoidRootPart()
        local originalCFrame = originalRoot and originalRoot.CFrame
        local previousTool = findEquippedTool()

        local function reportResult(title, message, duration)
            api.SetStatus(message .. string.format(" | %.2fs", os.clock() - startedAt), title)
            if not api.StatusControl then notify(title, message, duration) end
        end

        local function collectCanRun()
            return scriptAlive and api.Enabled and generation == collectGeneration
                and not session.closed and getMovementRevision() == movementToken
                and originalRoot and originalRoot.Parent and originalRoot == getHumanoidRootPart()
                and (type(session.canContinue) ~= "function" or session.canContinue())
        end

        local function settlePendingRemotes()
            for candidate in pairs(pendingConfirmation) do
                local confirmed = not candidate.Parent
                    or candidateHasStoredMarker(candidate)
                    or candidateIsStoredByPlayer(candidate)
                if not confirmed then
                    local success, inWorkspace = pcall(function()
                        return candidate:IsDescendantOf(workspace)
                    end)
                    confirmed = success and not inWorkspace
                end
                if confirmed then
                    pendingConfirmation[candidate] = nil
                    if not handled[candidate] then
                        handled[candidate] = true
                        pickedUpCount = pickedUpCount + 1
                    end
                end
            end
        end

        repeat
            if not collectCanRun() then
                break
            end

            if SharedInteraction.chestPrioritySession == session then
                SharedInteraction.chestPriorityUntil = math.max(
                    SharedInteraction.chestPriorityUntil or 0,
                    os.clock() + 0.75
                )
            end
            settlePendingRemotes()

            local now = os.clock()
            if now >= nextFallbackScanAt then
                nextFallbackScanAt = now + 0.15
                queueRecentDebris()
            end

            local batchCandidates = {}
            local batchSeen = setmetatable({}, { __mode = "k" })
            local unresolvedMetadataThisPass = false
            local retryableThisPass = false
            for _, event in ipairs(session.events) do
                local source = event.instance
                local candidate = canonicalCandidate(source)
                local sourceStillInDebris = source
                    and source.Parent
                    and debrisContainerSet[source.Parent]
                local ignoredByDropPoint = candidate
                    and DropManager
                    and type(DropManager.ShouldIgnoreCandidate) == "function"
                    and DropManager.ShouldIgnoreCandidate(candidate)

                if event.bornAt >= session.armedAt - 0.03
                    and sourceStillInDebris
                    and candidate
                    and candidate.Parent
                    and not ignoredByDropPoint
                    and not session.existing[source]
                    and not session.existing[candidate]
                then
                    local targetPart = getTargetPart(candidate)
                    if not targetPart then
                        -- Streaming can replicate the drop Model before any part.
                        -- Give this incomplete event the same bounded grace window
                        -- as late Item/Sack metadata instead of declaring it empty.
                        unresolvedMetadataThisPass = true
                    end
                    if targetPart and not event.spawnPosition then
                        event.spawnPosition = targetPart.Position
                    end
                    if targetPart
                        and (event.spawnPosition - originPosition).Magnitude <= api.Radius
                    then
                        sawChestDrop = true
                        lastRelevantAt = math.max(lastRelevantAt, event.bornAt)
                        local currentDisplayName, currentName = resolvedLootName(candidate)
                        if not currentName then
                            -- ChildAdded can precede Item/Sack/Consumable
                            -- replication. Do not classify a numeric network id
                            -- as material and do not close the chest session yet.
                            unresolvedMetadataThisPass = true
                        else
                            addCatalogName(currentDisplayName)
                            if not handled[candidate]
                                and matchesName(currentName, api.Selected)
                            then
                                if not detected[candidate] then
                                    detected[candidate] = true
                                    detectedCount = detectedCount + 1
                                end

                                local attemptCount = attempts[candidate] or 0
                                if attemptCount < 3 then retryableThisPass = true end
                                if attemptCount < 3
                                    and now >= (nextAttemptAt[candidate] or 0)
                                    and not batchSeen[candidate]
                                    and #batchCandidates < 12
                                then
                                    attempts[candidate] = attemptCount + 1
                                    nextAttemptAt[candidate] = now + 0.4
                                    batchSeen[candidate] = true
                                    batchCandidates[#batchCandidates + 1] = candidate
                                end
                            end
                        end
                    end
                end
            end

            local attemptedThisPass = #batchCandidates > 0
            local batchWasBusy = false
            if attemptedThisPass then
                lastRelevantAt = os.clock()
                if pickedUpCount > 0 then
                    for _, candidate in ipairs(batchCandidates) do
                        if (attempts[candidate] or 0) > 1 then
                            -- Healthy batches keep the short normal window. A
                            -- partially accepted burst gets bounded time for its
                            -- paced tail instead of abandoning selected drops.
                            absoluteDeadline = math.min(maximumBusyDeadline,
                                math.max(absoluteDeadline, os.clock() + 1 + #batchCandidates * 0.24))
                            break
                        end
                    end
                end
                local batchResults = interactBatch(
                    batchCandidates,
                    api.Mode,
                    12,
                    {
                        rapidChest = true,
                        pendingConfirmation = pendingConfirmation,
                        attempts = attempts,
                        pacing = pacing,
                        canContinue = collectCanRun,
                        autonomousMovement = session.chest ~= nil,
                        keepSackEquipped = true,
                        restorePosition = false,
                    }
                )
                for _, result in ipairs(batchResults) do
                    if result.success then
                        pendingConfirmation[result.candidate] = nil
                        if not handled[result.candidate] then
                            handled[result.candidate] = true
                            pickedUpCount = pickedUpCount + 1
                        end
                    elseif result.method == "chest-burst-pending" then
                        local sentAt = result.sentAt or os.clock()
                        pendingConfirmation[result.candidate] = {
                            action = result.action, sentAt = sentAt,
                        }
                        -- A delayed reply is not a failed pickup. Keep verifying
                        -- all pending items while other ready drops are processed.
                        nextAttemptAt[result.candidate] = sentAt
                            + math.min(0.65, 0.32 + (attempts[result.candidate] or 1) * 0.08)
                    elseif result.method == "sack-missing"
                        or result.method == "sack-equip-failed"
                    then
                        sackMissingCount = sackMissingCount + 1
                    elseif result.method == "sack-full" then
                        sackFullCount = sackFullCount + 1
                        sackFullText = result.sackText or sackFullText
                        attempts[result.candidate] = 3
                    elseif result.method == "batch-busy" or result.method == "chest-deferred" then
                        batchWasBusy = result.method == "batch-busy" or batchWasBusy
                        attempts[result.candidate] = math.max(
                            0,
                            (attempts[result.candidate] or 1) - 1
                        )
                        nextAttemptAt[result.candidate] = os.clock() + 0.05
                    end
                end
            end

            if batchWasBusy then
                -- World Auto Loot may be finishing one already-started batch.
                -- Preserve this chest's event queue long enough to take the next
                -- lock gap, without making the normal no-content path slower.
                absoluteDeadline = math.min(
                    maximumBusyDeadline,
                    math.max(absoluteDeadline, os.clock() + 0.65)
                )
            end

            local emptiedFullSack = false
            if sackFullCount > 0 and DropManager and not emptyAttempted
                and emptyCycles < 2 and collectCanRun()
            then
                -- Drop Here creates fresh DebrisField children too. Suppress that
                -- known non-chest burst at the source so it can never feed back
                -- into this chest session, even when protection is disabled.
                session.suppressEvents = true
                emptyAttempted = true
                local success, emptied = pcall(
                    DropManager.EmptyIfFull,
                    "Chest Loot"
                )
                session.suppressEvents = false
                session.suppressEventsUntil = os.clock() + 0.45
                emptiedFullSack = success and emptied == true
            end
            if emptiedFullSack then
                sackAutoEmptied = true
                emptyAttempted = false
                emptyCycles = emptyCycles + 1
                sackFullCount = 0
                sackFullText = nil
                for candidate in pairs(detected) do
                    if not handled[candidate] then
                        attempts[candidate] = 0
                        nextAttemptAt[candidate] = 0
                        pendingConfirmation[candidate] = nil
                    end
                end
                lastRelevantAt = os.clock()
                -- EmptyIfFull can consume the old deadline. Give the original
                -- chest drops a fresh bounded collection window after returning.
                absoluteDeadline = os.clock() + 2.8
                maximumBusyDeadline = os.clock() + 6
            end

            now = os.clock()
            local quietFor = now - lastRelevantAt
            if detectedCount > 0 then
                if not attemptedThisPass
                    and not unresolvedMetadataThisPass
                    and not retryableThisPass
                    and next(pendingConfirmation) == nil
                    and quietFor >= 0.24
                then
                    break
                end
            elseif sawChestDrop
                and not unresolvedMetadataThisPass
                and quietFor >= 0.3
            then
                break
            elseif not unresolvedMetadataThisPass and now - startedAt >= 1.25 and quietFor >= 0.38 then
                break
            end

            task.wait(batchWasBusy and 0.012 or 0.04)
        until os.clock() >= absoluteDeadline

        settlePendingRemotes()
        if collectCanRun() then
            local equipped = findEquippedTool()
            restoreBatchTool(previousTool, equipped and isSackTool(equipped) and equipped or nil)
            local humanoid = getHumanoid()
            if originalCFrame and (not humanoid or humanoid.MoveDirection.Magnitude <= 0.05) then
                originalRoot.AssemblyLinearVelocity = Vector3.zero
                originalRoot.AssemblyAngularVelocity = Vector3.zero
                originalRoot.CFrame = originalCFrame
            end
        end
        api.CancelSession(session)

        if scriptAlive and generation == collectGeneration and api.Enabled
            and getMovementRevision() == movementToken
        then
            if pickedUpCount > 0 then
                local message = "Collected " .. pickedUpCount .. " chest-only drops"
                if detectedCount > pickedUpCount then
                    message = message
                        .. "; "
                        .. (detectedCount - pickedUpCount)
                        .. " could not be confirmed"
                end
                if sackMissingCount > 0 then
                    message = message .. "; Sack required for materials"
                end
                if sackAutoEmptied then
                    message = message .. "; Sack auto-emptied at Drop Here"
                elseif sackFullCount > 0 then
                    message = message
                        .. "; Sack full"
                        .. (sackFullText and (" (" .. sackFullText .. ")") or "")
                        .. ", remaining items left in place"
                end
                reportResult("Chest Loot", message, 2.5)
            elseif detectedCount > 0 then
                if sackFullCount > 0 then
                    reportResult(
                        "Chest Loot",
                        "Sack full"
                            .. (sackFullText and (" (" .. sackFullText .. ")") or "")
                            .. "; chest materials were left in place",
                        2.5
                    )
                elseif sackMissingCount > 0 then
                    reportResult("Chest Loot", "A Sack is required for chest materials", 2.5)
                else
                    reportResult(
                        "Chest Loot Retry",
                        "Found "
                            .. detectedCount
                            .. " chest drops, but pickup was not confirmed",
                        2.5
                    )
                end
            else
                reportResult("Chest Loot", "No selected item was emitted by this chest", 1.5)
            end
        end

        return pickedUpCount
    end

    function api.Watch(originPosition, beforeSnapshot, replicationLead)
        if not api.Enabled or #api.Selected == 0 or not originPosition then
            api.CancelSession(beforeSnapshot)
            return false
        end

        if beforeSnapshot and not beforeSnapshot.armedAt then
            api.Arm(beforeSnapshot, replicationLead or 0)
        end
        collectGeneration = collectGeneration + 1
        local generation = collectGeneration
        task.spawn(function()
            api.Collect(originPosition, beforeSnapshot, generation)
        end)
        return true
    end

    -- Narrow exports for DropManager. They keep Sack parsing/equip logic in a
    -- single place instead of duplicating assumptions about the current game.
    function api.FindSackTool()
        return findSackTool()
    end

    function api.ReadSackState(sackTool)
        return readSackState(sackTool)
    end

    function api.EquipSackTool(sackTool)
        return equipSackTool(sackTool)
    end

    function api.GetSackClient()
        return getSackClient()
    end

    function api.FindEquippedTool()
        return findEquippedTool()
    end

    function api.CollectNearby()
        local rootPart = getHumanoidRootPart()
        if not rootPart then
            notify("Chest Loot", "HumanoidRootPart not found", 2)
            return false
        end
        if #api.Selected == 0 then
            notify("Chest Loot", "Choose at least one loot type first", 2)
            return false
        end

        local candidates = {}
        for _, candidate in ipairs(nearbyCandidates(rootPart.Position, api.Radius, true)) do
            if not handled[candidate]
                and matchesName(displayName(candidate), api.Selected)
            then
                candidates[#candidates + 1] = candidate
                if #candidates >= 12 then
                    break
                end
            end
        end

        if #candidates == 0 then
            notify("Chest Loot", "No selected nearby drops found", 1.5)
            return false
        end

        local results = interactBatch(
            candidates,
            api.Mode,
            12,
            { rapidChest = true }
        )
        local collected = 0
        for _, result in ipairs(results) do
            if result.success then
                handled[result.candidate] = true
                collected = collected + 1
            end
        end
        notify(
            "Chest Loot",
            "Collected " .. collected .. "/" .. #candidates .. " nearby drops",
            2
        )
        return collected > 0
    end

    return api
end)()

-- Drop Here / Sack emptying --------------------------------------------------
-- DropItem has no destination argument. Client position alone is not an
-- acknowledgement: settle once, confirm one probe, then use a bounded pipeline.
local DropSafety = (function()
    local api = {}
    local unconfirmed = setmetatable({}, { __mode = "k" })
    local lastPendingNoticeAt = 0
    api.Profiles = {
        Slow = { perFrame = 2, maxPending = 4, framePause = 0.05 },
        Normal = { perFrame = 3, maxPending = 12, framePause = 0 },
        Fast = { perFrame = 4, maxPending = 16, framePause = 0 },
    }

    function api.IsWaiting()
        local waiting = false
        for sack, batch in pairs(unconfirmed) do
            local state = sack.Parent and ChestLoot.ReadSackState(sack)
            if not sack.Parent then
                unconfirmed[sack] = nil
            else
                -- Partial progress cannot release a whole batch. A late response
                -- must reach the exact expected count, then finish its quiet hold.
                if state and type(state.count) == "number" and state.count <= batch.targetCount then
                    batch.acknowledgedAt = batch.acknowledgedAt or os.clock()
                else
                    batch.acknowledgedAt = nil
                end
                if not batch.active and batch.acknowledgedAt
                    and os.clock() - batch.acknowledgedAt >= 0.75
                then unconfirmed[sack] = nil else waiting = true end
            end
        end
        if waiting and os.clock() - lastPendingNoticeAt > 8 then
            lastPendingNoticeAt = os.clock()
            notify("Sack Drop", "Waiting for the full drop batch to be confirmed. Stay at the drop point while the Sack count updates.", 4)
        end
        return waiting
    end

    function api.IsNear(root, target, radius)
        return root and root.Parent and root == getHumanoidRootPart()
            and (root.Position - target.Position).Magnitude <= radius
            and root.AssemblyLinearVelocity.Magnitude <= 2
            and root.AssemblyAngularVelocity.Magnitude <= 1
            and root.CFrame.LookVector:Dot(target.LookVector) >= 0.99
    end

    function api.WaitForTool(sack, root, canContinue)
        local deadline, stableSince = os.clock() + 2, nil
        repeat
            if not scriptAlive or not canContinue() then return false end
            local handle = sack:FindFirstChild("Handle")
            if sack.Parent == getCharacter() and handle and handle:IsA("BasePart")
                and (handle.Position - root.Position).Magnitude <= 12
            then
                stableSince = stableSince or os.clock()
                if os.clock() - stableSince >= 0.08 then return true end
            else
                stableSince = nil
            end
            RunService.Heartbeat:Wait()
        until os.clock() >= deadline
        return false
    end

    function api.WaitStable(root, target, canContinue, radius, duration, timeout, emissionReady)
        local deadline, stableSince = os.clock() + timeout, nil
        repeat
            if not scriptAlive or not canContinue() then return false end
            if api.IsNear(root, target, radius) and (not emissionReady or emissionReady()) then
                stableSince = stableSince or os.clock()
                if os.clock() - stableSince >= duration then return true end
            else
                stableSince = nil
            end
            RunService.Heartbeat:Wait()
        until os.clock() >= deadline
        return false -- being alive at the deadline does NOT mean we arrived
    end

    function api.Empty(options)
        local sack, dropped = options.sack, 0
        if api.IsWaiting() then return false, dropped, "previous-drop-unconfirmed" end
        local profile = options.profile or api.Profiles.Fast
        local batch = { active = true, targetCount = 0 }
        local function canRun()
            return scriptAlive and options.canContinue() and options.hover:IsAlive()
                and sack.Parent == getCharacter() and options.root == getHumanoidRootPart()
        end
        local function touch()
            if options.onProgress then options.onProgress() end
        end
        local ok, success, reason = xpcall(function()
            if not canRun() then return false, "movement-interrupted" end
            local state = ChestLoot.ReadSackState(sack)
            if type(state.count) ~= "number" then return false, "sack-state-pending" end
            if state.count <= 0 then return true, "empty" end
            local target, emissionReady = options.prepare()
            if not target or not options.hover:SetTarget(target) then return false, "drop-hover-lost" end
            touch()
            if not api.WaitStable(options.root, target, canRun, 0.55, 0.35, 3, emissionReady) then
                return false, "drop-position-not-stable"
            end
            local initial = ChestLoot.ReadSackState(sack).count
            if type(initial) ~= "number" then return false, "sack-state-pending" end
            if initial < 0 or initial > 512 or initial % 1 ~= 0 then return false, "sack-state-pending" end
            local sent, confirmed, nextSendAt = 0, 0, 0
            local sentAt = {}
            local sendFailed = false
            local function aligned()
                return api.IsNear(options.root, target, 0.55) and (not emissionReady or emissionReady())
            end
            while confirmed < initial do
                if not canRun() then return false, "movement-interrupted" end
                touch()
                local after = ChestLoot.ReadSackState(sack).count
                if type(after) ~= "number" then return false, "sack-state-pending" end
                local acknowledged = initial - after
                if acknowledged < confirmed or acknowledged > sent then return false, "sack-state-changed" end
                confirmed, dropped = acknowledged, acknowledged
                local pending = sent - confirmed
                if pending == 0 and sent > 0 then batch.acknowledgedAt = batch.acknowledgedAt or os.clock() end
                if confirmed == initial then break end
                if sendFailed and pending == 0 then return false, "drop-remote-failed" end
                if pending > 0 and os.clock() - sentAt[confirmed + 1] >= 4 then
                    return false, sendFailed and "drop-remote-failed" or "drop-not-confirmed"
                end

                -- Freeze the emission target while packets are outstanding. A
                -- correction pauses new sends; re-align only after the queue drains.
                if not aligned() and pending == 0 then
                    target, emissionReady = options.prepare()
                    if not target or not options.hover:SetTarget(target) then return false, "drop-hover-lost" end
                    if not api.WaitStable(options.root, target, canRun, 0.55, 0.15, 3, emissionReady) then
                        return false, "drop-position-not-stable"
                    end
                end
                -- One acknowledged probe precedes the fast path. Grow the window
                -- with confirmed progress; never resend an unacknowledged packet.
                local window = confirmed == 0 and 1
                    or math.min(profile.maxPending, 4 + math.floor((confirmed - 1) / 4) * 4)
                local budget = math.min(profile.perFrame, window - pending, initial - sent)
                if not sendFailed and budget > 0 and os.clock() >= nextSendAt and aligned() then
                    for _ = 1, budget do
                        if not canRun() or not aligned() then break end
                        sent = sent + 1
                        sentAt[sent] = os.clock()
                        batch.targetCount = initial - sent
                        batch.acknowledgedAt = nil
                        unconfirmed[sack] = batch
                        local fireOk = pcall(function() options.network:FireServer("DropItem") end)
                        if not fireOk then sendFailed = true; break end
                    end
                    nextSendAt = os.clock() + (profile.framePause or 0)
                end
                RunService.Heartbeat:Wait() -- one bounded send slice per physics frame
            end
            -- One final hold for the WHOLE Sack, not one delay per item/batch.
            if dropped > 0 and not api.WaitStable(options.root, target, function()
                touch()
                return canRun()
            end, 0.65, 0.75, 3, emissionReady) then
                return false, "drop-position-not-stable"
            end
            local remaining = ChestLoot.ReadSackState(sack).count
            return remaining == 0, remaining == 0 and "empty" or "items-remain"
        end, function(message) return tostring(message) end)
        batch.active = false
        if ok and success then
            if unconfirmed[sack] == batch then unconfirmed[sack] = nil end
            return true, dropped, reason
        end
        -- Cancel/error/timeout leaves the aggregate count gate intact, including
        -- packets whose send threw after potentially reaching the server.
        return false, dropped, ok and reason or "drop-runtime-error: " .. tostring(success)
    end

    return api
end)()

-- Native SackClient drops exactly one stored item with Net:FireServer(
-- "DropItem") and supplies no destination argument. Therefore the reliable
-- destination is the player's replicated position at the time of each call.
DropManager = (function()
    local api: any = {}
    local DROP_PROFILES = DropSafety.Profiles
    local lastMissingPointNoticeAt = 0
    local lastBusyNoticeAt = 0

    local function getDropPoint()
        if Config:Get("DropHereSet") ~= true then
            return nil
        end
        return Vector3.new(
            tonumber(Config:Get("DropHereX")) or 0,
            tonumber(Config:Get("DropHereY")) or 0,
            tonumber(Config:Get("DropHereZ")) or 0
        )
    end

    local function restorePreviousTool(previousTool, sackTool)
        if not previousTool or previousTool == sackTool or not previousTool.Parent then
            return
        end
        local humanoid = getHumanoid()
        if humanoid then
            pcall(function() humanoid:EquipTool(previousTool) end)
        end
    end

    local function hasDropGround(point)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local excluded = { getCharacter() }
        if workspace.CurrentCamera then table.insert(excluded, workspace.CurrentCamera) end
        local debris = workspace:FindFirstChild("DebrisField")
        if debris then table.insert(excluded, debris) end
        params.FilterDescendantsInstances = excluded
        params.IgnoreWater = false
        params.RespectCanCollide = true
        for _, offset in ipairs({ Vector3.zero, Vector3.new(2, 0, 0), Vector3.new(-2, 0, 0),
            Vector3.new(0, 0, 2), Vector3.new(0, 0, -2) }) do
            local hit = workspace:Raycast(point + offset + Vector3.new(0, 6, 0), Vector3.new(0, -64, 0), params)
            if not hit or hit.Material == Enum.Material.Water or hit.Normal.Y < 0.65 then return false end
        end
        return true
    end

    function api.SetHere()
        local root = getHumanoidRootPart()
        if not root then
            notify("Drop Here", "HumanoidRootPart not found", 2)
            return false
        end
        local position = root.Position
        Config:Set("DropHereX", position.X)
        Config:Set("DropHereY", position.Y)
        Config:Set("DropHereZ", position.Z)
        Config:Set("DropHereSet", true, true)
        notify(
            "Drop Here",
            string.format("Saved at %.1f, %.1f, %.1f", position.X, position.Y, position.Z),
            2.5
        )
        return true
    end

    function api.Clear()
        Config:Set("DropHereSet", false, true)
        notify("Drop Here", "Custom drop point cleared", 2)
    end

    function api.SetAutoEnabled(enabled)
        Config:Set("AutoEmptySack", enabled == true)
    end

    function api.SetDropSpeed(value)
        Config:Set("DropSpeed", firstSelectedValue(value) or "Normal")
    end

    function api.GetStatusText()
        local point = getDropPoint()
        if not point then
            return "Not set"
        end
        return string.format("%.1f, %.1f, %.1f", point.X, point.Y, point.Z)
    end

    function api.GetPoint()
        return getDropPoint()
    end

    function api.SetProtectionEnabled(enabled)
        Config:Set("ProtectDropHere", enabled == true)
    end

    function api.SetProtectRadius(value)
        Config:Set("DropProtectRadius", tonumber(value) or 22)
    end

    function api.ShouldIgnoreCandidate(candidate)
        if Config:Get("ProtectDropHere") ~= true then
            return false
        end
        local point = getDropPoint()
        if not point or not candidate or not candidate.Parent then
            return false
        end
        local part = getTargetPart(candidate)
        if not part then
            return false
        end
        local radius = tonumber(Config:Get("DropProtectRadius")) or 22
        return (part.Position - point).Magnitude <= radius
    end

    -- v47 Drop Here hover -----------------------------------------------------
    -- Match the station-drop behavior: teleport once to the saved point, then keep
    -- the rig stable with BodyPosition/BodyGyro while every DropItem is sent. This
    -- removes the old per-item CFrame spam and keeps the Sack emission geometry tidy.
    local function startDropHereHover(initialCFrame, movementToken)
        if typeof(initialCFrame) ~= "CFrame" then return nil, "bad-target" end
        local root = getHumanoidRootPart()
        local humanoid = getHumanoid()
        local character = getCharacter()
        if not root or not humanoid or not character then
            return nil, "character-missing"
        end
        if Config:Get("FlyEnabled") == true then
            return nil, "manual-fly-active"
        end

        local token = movementToken or getMovementRevision()
        local oldAutoRotate = humanoid.AutoRotate
        local oldPlatformStand = humanoid.PlatformStand
        local oldSit = humanoid.Sit
        local collisions = {}
        local bodyPosition = Instance.new("BodyPosition")
        local bodyGyro = Instance.new("BodyGyro")
        local alive = true

        for _, descendant in ipairs(character:GetDescendants()) do
            if descendant:IsA("BasePart") then
                collisions[#collisions + 1] = { descendant, descendant.CanCollide }
                descendant.CanCollide = false
            end
        end

        humanoid.Sit = false
        humanoid.PlatformStand = true
        humanoid.AutoRotate = false
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero

        bodyPosition.Name = "SEA_DropHereHoverPosition"
        bodyPosition.MaxForce = Vector3.new(9e9, 9e9, 9e9)
        bodyPosition.P = 85000
        bodyPosition.D = 5000
        bodyPosition.Position = initialCFrame.Position
        bodyPosition.Parent = root

        bodyGyro.Name = "SEA_DropHereHoverGyro"
        bodyGyro.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
        bodyGyro.P = 110000
        bodyGyro.D = 1800
        bodyGyro.CFrame = initialCFrame
        bodyGyro.Parent = root

        local controller = {}
        function controller:IsAlive()
            return alive and scriptAlive and root.Parent ~= nil
                and root == getHumanoidRootPart() and humanoid.Health > 0
                and bodyPosition.Parent ~= nil and bodyGyro.Parent ~= nil
                and getMovementRevision() == token
        end
        function controller:SetTarget(targetCFrame)
            if not self:IsAlive() or typeof(targetCFrame) ~= "CFrame" then return false end
            bodyPosition.Position = targetCFrame.Position
            bodyGyro.CFrame = targetCFrame
            return true
        end
        function controller:WaitNear(targetCFrame, radius, timeout)
            return DropSafety.WaitStable(root, targetCFrame, function() return self:IsAlive() end,
                tonumber(radius) or 0.55, 0.12, math.max(0.2, tonumber(timeout) or 0.6))
        end
        function controller:Stop()
            if not alive then return end
            alive = false
            pcall(function() bodyPosition:Destroy() end)
            pcall(function() bodyGyro:Destroy() end)
            for _, entry in ipairs(collisions) do
                local part = entry[1]
                if part and part.Parent then part.CanCollide = entry[2] end
            end
            if root and root.Parent then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end
            if humanoid and humanoid.Parent then
                humanoid.AutoRotate = oldAutoRotate
                humanoid.PlatformStand = oldPlatformStand and Config:Get("FlyEnabled") == true or false
                humanoid.Sit = oldSit and Config:Get("FlyEnabled") == true or false
                if Config:Get("FlyEnabled") ~= true then
                    humanoid.PlatformStand = false
                    humanoid.Sit = false
                    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
                end
            end
        end
        controller:SetTarget(initialCFrame)
        return controller, nil
    end

    function api.EmptyNow(showNotification, keepSackEquipped, chestTeleport)
        if DropSafety.IsWaiting() then return false, "previous-drop-unconfirmed" end
        local dropPoint = getDropPoint()
        if not dropPoint then
            if showNotification ~= false then
                notify("Drop Here", "Set Drop Here first", 2)
            end
            return false, "drop-point-not-set"
        end

        local root = getHumanoidRootPart()
        local sackTool = ChestLoot.FindSackTool()
        local sackClient = ChestLoot.GetSackClient()
        if not root or not sackTool or not sackClient or not sackClient.Net then
            if showNotification ~= false then
                notify("Drop Here", "Sack or SackClient is not available", 2)
            end
            return false, "sack-unavailable"
        end
        if Config:Get("FlyEnabled") == true then
            return false, "manual-fly-active"
        end

        local initial = ChestLoot.ReadSackState(sackTool)
        if type(initial.count) == "number" and initial.count <= 0 then
            if showNotification ~= false then
                notify("Drop Here", "Sack is already empty", 1.5)
            end
            return true, "already-empty"
        end

        if not SharedInteraction.TryAcquire("drop") then
            if showNotification ~= false and os.clock() - lastBusyNoticeAt > 2 then
                lastBusyNoticeAt = os.clock()
                notify("Drop Here", "Another item automation is busy", 1.5)
            end
            return false, "interaction-busy"
        end

        local movementToken = getMovementRevision()
        local originalCFrame = root.CFrame
        local previousTool = ChestLoot.FindEquippedTool()
        local flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
        if flatLook.Magnitude < 0.05 then flatLook = Vector3.new(0, 0, -1) end
        flatLook = flatLook.Unit
        local basePosition = dropPoint + Vector3.new(0, 3.25, 0)
        local standCFrame = CFrame.lookAt(basePosition, basePosition + flatLook)
        local droppedCount = 0
        local hover
        local function canDrop()
            local humanoid = getHumanoid()
            return scriptAlive and root.Parent ~= nil and root == getHumanoidRootPart()
                and humanoid ~= nil and humanoid.Health > 0
                and getMovementRevision() == movementToken
        end

        local function stopHover()
            if hover then
                pcall(function() hover:Stop() end)
                hover = nil
            end
        end

        local ok, emptyResult, emptyReason = xpcall(function()
            -- One double hop (single for chest routes), then a physics hover.
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            if not teleportPlayer(root, standCFrame, function()
                return getMovementRevision() == movementToken
            end, chestTeleport) then return false, "movement-interrupted" end
            task.wait(0.025)

            if not ChestLoot.EquipSackTool(sackTool) then
                return false, "sack-equip-failed"
            end
            if not DropSafety.WaitForTool(sackTool, root, canDrop) then
                return false, "sack-equip-unconfirmed"
            end
            if not hasDropGround(dropPoint) then return false, "drop-point-has-no-dry-ground" end

            local hoverReason
            hover, hoverReason = startDropHereHover(standCFrame, movementToken)
            if not hover then
                return false, "drop-hover-failed:" .. tostring(hoverReason)
            end
            local profile = DROP_PROFILES[Config:Get("DropSpeed") or "Normal"]
                or DROP_PROFILES.Normal
            local function prepareDrop()
                local targetCFrame = standCFrame
                local handle = sackTool:FindFirstChild("Handle")
                if handle and handle:IsA("BasePart") then
                    local errorXZ = Vector3.new(
                        dropPoint.X - handle.Position.X,
                        0,
                        dropPoint.Z - handle.Position.Z
                    )
                    if errorXZ.Magnitude < 8 then
                        local correctedPosition = Vector3.new(root.Position.X + errorXZ.X,
                            standCFrame.Position.Y, root.Position.Z + errorXZ.Z)
                        targetCFrame = CFrame.lookAt(correctedPosition, correctedPosition + flatLook)
                    end
                end
                return targetCFrame, function()
                    if not handle or not handle.Parent then return false end
                    local error = handle.Position - dropPoint
                    return Vector3.new(error.X, 0, error.Z).Magnitude <= 1.5
                end
            end
            local success, count, reason = DropSafety.Empty({
                root = root, sack = sackTool, hover = hover, network = sackClient.Net,
                canContinue = canDrop, prepare = prepareDrop, profile = profile,
                onProgress = function() SharedInteraction.Touch("drop") end,
            })
            droppedCount = count
            return success, reason
        end, function(err)
            return tostring(err)
        end)

        stopHover()
        if canDrop() then
            if keepSackEquipped or Config:Get("AutoLootWorld") == true then
                ChestLoot.EquipSackTool(sackTool)
            else
                restorePreviousTool(previousTool, sackTool)
            end
        end
        if canDrop() and not DropSafety.IsWaiting() then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            teleportPlayer(root, originalCFrame, function()
                return getMovementRevision() == movementToken
            end, chestTeleport)
        end
        SharedInteraction.Release("drop")

        local success = ok and emptyResult == true
        local reason = ok and emptyReason or emptyResult
        if showNotification ~= false then
            if success then
                notify("Drop Here", "Dropped " .. droppedCount .. " Sack item(s)", 2.5)
            else
                notify("Drop Here", "Could not empty Sack: " .. tostring(reason), 2.5)
            end
        end
        return success, reason or (success and "empty" or "runtime-error")
    end

    function api.EmptyIfFull(source)
        if Config:Get("AutoEmptySack") ~= true then
            return false
        end
        if not getDropPoint() then
            if os.clock() - lastMissingPointNoticeAt > 8 then
                lastMissingPointNoticeAt = os.clock()
                notify(
                    source or "Auto Loot",
                    "Sack is full; set Drop Here to enable auto-empty",
                    2.5
                )
            end
            return false
        end

        local sackTool = ChestLoot.FindSackTool()
        local state = sackTool and ChestLoot.ReadSackState(sackTool) or nil
        if not state or state.full ~= true then
            return false
        end
        return api.EmptyNow(false, true, source == "Chest Loot") == true
    end

    return api
end)()

-- Shared base-item exclusion -----------------------------------------------
-- The game's Bonfire.LevelUp resizes SpawnIsland.Ring to
-- 100 + 220 * level / 7, with 320 studs at MAX. Ring.Size is the diameter,
-- so its live half-size is the actual expanding base radius. Use X/Z only:
-- height differences must not make an item at the base look like island loot.
-- Dropper/Rig plus the replicated Level attribute cover streaming gaps.
-- Keep its state inside this closure instead of consuming scarce chunk-level
-- registers for constants/cache/helper locals on executor Luau compilers.
DropManager.IsInsideBase = (function()
    local cachedCenter: any = nil
    local cachedRadius = 160

    local function radiusFromLevel(spawnIsland: any): any
        local level = spawnIsland and tonumber(spawnIsland:GetAttribute("Level"))
        if not level then return nil end
        level = math.clamp(math.floor(level + 0.5), 1, 7)
        return (100 + 220 * level / 7) * 0.5
    end

    local function getBoundary()
        local spawnIsland: any = workspace:FindFirstChild("SpawnIsland")
        local ring: any = spawnIsland and spawnIsland:FindFirstChild("Ring")
        local ringPart: any = getTargetPart(ring)
        if ringPart then
            local size: any = ringPart.Size
            local radius = size and math.max(size.X, size.Z) * 0.5 or nil
            cachedCenter = ringPart.Position
            if radius and radius > 0 then cachedRadius = radius end
            return cachedCenter, cachedRadius
        end

        local dropper: any = spawnIsland and spawnIsland:FindFirstChild("Dropper")
        local anchorPart: any = getTargetPart(dropper)
        if not anchorPart then
            local distantIslands: any = ReplicatedStorage:FindFirstChild("DistantIslands")
            local rigMarker: any = distantIslands and distantIslands:FindFirstChild("Rig")
            anchorPart = getTargetPart(rigMarker)
        end

        if anchorPart then
            cachedCenter = anchorPart.Position
        end
        local levelRadius = radiusFromLevel(spawnIsland)
        if levelRadius then cachedRadius = levelRadius end
        return cachedCenter, cachedRadius
    end

    return function(candidate: any): boolean
        if not candidate or not candidate.Parent then return false end
        local part: any = getTargetPart(candidate)
        local center: any, radius: number = getBoundary()
        if not part or not center then return false end

        local dx = part.Position.X - center.X
        local dz = part.Position.Z - center.Z
        return dx * dx + dz * dz < radius * radius
    end
end)()

-- Assigned after Automation is constructed. This lets World Loot and station
-- farms turn one another off instead of leaving two ON toggles fighting for the
-- same Sack/full-map route.
local stopStationFarmsForWorldLoot

local WorldLoot: any = (function()
    local api = {
        Selected = Config:Get("WorldLootItems") or {},
        Enabled = Config:Get("AutoLootWorld") == true,
        Mode = Config:Get("WorldLootMode") or "Smart (E / F)",
    }
    local generation = 0
    local loopRunning = false
    local workerLastPulseAt = 0
    local supervisorRunning = false
    local toggleControl
    local nextAttemptAt = setmetatable({}, { __mode = "k" })
    local worldSearchCursor = 0
    local lastSackNoticeAt = 0
    local lastNoTargetNoticeAt = 0

    -- Preserve existing exact-filter setups while teaching them about the new
    -- semantic corpse group. All Items already matches corpses; an empty setup
    -- remains empty so merely updating the script never enables World Loot.
    if Config:Get("WorldLootCorpseGroupInitialized") ~= true then
        local hasAllItems = false
        local hasCorpseGroup = false
        for _, itemName in ipairs(api.Selected) do
            local normalized = normalizeInstanceName(itemName)
            if normalized == "all" or normalized == "allitems" then
                hasAllItems = true
            elseif normalized == "enemycorpses" then
                hasCorpseGroup = true
            end
        end
        if #api.Selected > 0 and not hasAllItems and not hasCorpseGroup then
            api.Selected[#api.Selected + 1] = "Enemy Corpses"
        end
        Config:Set("WorldLootCorpseGroupInitialized", true)
        Config:Set("WorldLootItems", api.Selected, true)
    end

    for _, itemName in ipairs(api.Selected) do
        ChestLoot.AddCatalogName(itemName)
    end

    local function canRun(expectedGeneration)
        return scriptAlive
            and api.Enabled
            and #api.Selected > 0
            and (expectedGeneration == nil or expectedGeneration == generation)
    end

    local function pulseWorker()
        workerLastPulseAt = os.clock()
    end

    local function ensureFarmSack(showNotification)
        local sackTool = ChestLoot.FindSackTool()
        if not sackTool then
            if showNotification or os.clock() - lastSackNoticeAt > 6 then
                lastSackNoticeAt = os.clock()
                notify("World Loot", "A Sack is required for full-map Auto Farm", 2.5)
            end
            return nil, nil
        end
        if not ChestLoot.EquipSackTool(sackTool) then
            if showNotification or os.clock() - lastSackNoticeAt > 6 then
                lastSackNoticeAt = os.clock()
                notify("World Loot", "Could not equip Sack", 2)
            end
            return nil, nil
        end
        return sackTool, ChestLoot.ReadSackState(sackTool)
    end

    local function collectMapAnchors(originPosition)
        local anchors = {}
        local seenCells = {}

        local function addPosition(position, label)
            if typeof(position) ~= "Vector3" then return end
            local cell = string.format(
                "%d:%d",
                math.floor(position.X / 140 + 0.5),
                math.floor(position.Z / 140 + 0.5)
            )
            if seenCells[cell] then return end
            seenCells[cell] = true
            anchors[#anchors + 1] = {
                position = position,
                label = label or "Island",
            }
        end

        -- Map.Pop() does not stream world loot. It only draws icons from these
        -- DistantIslands proxies. Use the same authoritative island coordinates
        -- directly for farming instead of opening the visual Map UI.
        local distantIslands = ReplicatedStorage:FindFirstChild("DistantIslands")
        if distantIslands then
            for _, marker in ipairs(distantIslands:GetChildren()) do
                if marker.Name ~= "Rig" then
                    if marker:IsA("BasePart") then
                        addPosition(marker.Position, marker.Name)
                    elseif marker:IsA("Model") then
                        local ok, pivot = pcall(marker.GetPivot, marker)
                        if ok then addPosition(pivot.Position, marker.Name) end
                    end
                end
            end
        end

        local islandContainer = workspace:FindFirstChild("IslandContainer")
        if islandContainer then
            for _, island in ipairs(islandContainer:GetChildren()) do
                if island:IsA("BasePart") then
                    addPosition(island.Position, island.Name)
                elseif island:IsA("Model") then
                    local ok, pivot = pcall(island.GetPivot, island)
                    if ok then addPosition(pivot.Position, island.Name) end
                end
            end
        end

        -- Keep route order stable across teleports so worldSearchCursor really
        -- advances through the whole map instead of being reinterpreted after
        -- every change of player position.
        table.sort(anchors, function(left, right)
            if left.position.X ~= right.position.X then
                return left.position.X < right.position.X
            end
            if left.position.Z ~= right.position.Z then
                return left.position.Z < right.position.Z
            end
            return tostring(left.label) < tostring(right.label)
        end)
        return anchors
    end

    -- RequestStreamAroundAsync can occasionally outlive its nominal timeout on a
    -- saturated server. Keep it off the route coroutine so one streaming request
    -- can never freeze the continuous teleport scanner. Cap abandoned requests as
    -- well: after the cap, teleport probes continue to trigger normal proximity
    -- streaming without accumulating an unbounded number of suspended coroutines.
    local streamRequestsInFlight = 0
    local MAX_STREAM_REQUESTS_IN_FLIGHT = 2
    local function requestStreamAt(position, canContinue)
        if streamRequestsInFlight >= MAX_STREAM_REQUESTS_IN_FLIGHT then
            return false, "request-saturated"
        end

        local completed = false
        local succeeded = false
        streamRequestsInFlight = streamRequestsInFlight + 1
        task.spawn(function()
            succeeded = pcall(function()
                localPlayer:RequestStreamAroundAsync(position, 0.8)
            end)
            completed = true
            streamRequestsInFlight = math.max(0, streamRequestsInFlight - 1)
        end)

        local deadline = os.clock() + 1.05
        repeat
            if type(canContinue) == "function" then
                local ok, keepRunning = pcall(canContinue)
                if not ok or not keepRunning then
                    return false, "cancelled"
                end
            end
            RunService.Heartbeat:Wait()
        until completed or os.clock() >= deadline

        if not completed then
            return false, "timeout"
        end
        if succeeded then
            return true, nil
        end
        return false, "request-failed"
    end

    local function loadedMatchingCandidates(rootPart, maximum)
        if not rootPart then return {} end
        local candidates = ChestLoot.Candidates(rootPart.Position, math.huge, true)
        local now = os.clock()
        local filtered = {}

        for _, candidate in ipairs(candidates) do
            if candidate
                and candidate.Parent
                and candidate:IsDescendantOf(workspace)
                and not DropManager.IsInsideBase(candidate)
                and ChestLoot.Matches(candidate, api.Selected)
                and (nextAttemptAt[candidate] or 0) <= now
            then
                filtered[#filtered + 1] = candidate
            end
        end

        table.sort(filtered, function(left, right)
            local leftPart = getTargetPart(left)
            local rightPart = getTargetPart(right)
            local leftDistance = leftPart
                and (leftPart.Position - rootPart.Position).Magnitude
                or math.huge
            local rightDistance = rightPart
                and (rightPart.Position - rootPart.Position).Magnitude
                or math.huge
            return leftDistance < rightDistance
        end)

        if maximum and #filtered > maximum then
            for index = #filtered, maximum + 1, -1 do
                filtered[index] = nil
            end
        end
        return filtered
    end

    -- v46 persistent World Loot scanner ---------------------------------------
    -- v44 searched only five map markers per collectPass and then returned to the
    -- outer loop. A transient Humanoid MoveDirection/PlatformStand state after the
    -- last teleport could make the next call refuse to move, which looked like the
    -- farm had stopped permanently. Keep the scanner alive until a selected item is
    -- actually found (or the toggle/movement generation is cancelled), and rebuild
    -- the route after every full sweep so newly spawned/streamed items are discovered.
    -- v46 scanner probe --------------------------------------------------------
    -- DistantIslands entries are STREAMING markers, not guaranteed walkable spawn
    -- points. v45 treated them like landing points, unanchored the Humanoid, then
    -- waited ~1 second for replication. When geometry had not streamed yet, gravity
    -- could drop the player straight into the ocean before the next marker.
    --
    -- Probe from a safe airborne position instead. The root is temporarily Anchored
    -- only during the streaming/scan window (this is NOT the Fly feature), then its
    -- original Anchored/collision/Humanoid state is restored before pickup resumes.
    local WORLD_SCAN_SAFE_MIN_Y = 178
    local WORLD_SCAN_MARKER_LIFT = 24

    local function worldSearchProbeCFrame(anchorPosition)
        local safeY = math.max(anchorPosition.Y + WORLD_SCAN_MARKER_LIFT, WORLD_SCAN_SAFE_MIN_Y)
        return CFrame.new(anchorPosition.X, safeY, anchorPosition.Z)
    end

    local function recoverWorldSearchRoot(root, humanoid, chestTeleport)
        if not root or not root.Parent then return false end
        local swimming = false
        if humanoid and humanoid.Parent then
            local ok, state = pcall(function() return humanoid:GetState() end)
            swimming = ok and state == Enum.HumanoidStateType.Swimming
        end
        -- Oxygen.luau in the supplied place treats Head.Y < 147 as underwater.
        -- Root.Y below ~146 or an active Swimming state means a previous scan/physics
        -- correction already left us in the sea; recover without bumping movementRevision.
        if root.Position.Y < WORLD_SCAN_SAFE_MIN_Y - 12 or swimming then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            teleportPlayer(root, CFrame.new(root.Position.X, WORLD_SCAN_SAFE_MIN_Y, root.Position.Z), nil, chestTeleport)
            task.wait(0.04)
        end
        return root.Parent ~= nil
    end

    local function beginWorldSearchProbe(targetCFrame, chestTeleport, canContinue)
        local root = getHumanoidRootPart()
        local humanoid = getHumanoid()
        local character = getCharacter()
        if not root or not root.Parent or typeof(targetCFrame) ~= "CFrame" then
            return nil
        end
        if Config:Get("FlyEnabled") == true then
            return nil
        end

        local oldAnchored = root.Anchored
        local oldAutoRotate = humanoid and humanoid.AutoRotate
        local oldPlatformStand = humanoid and humanoid.PlatformStand
        local oldSit = humanoid and humanoid.Sit
        local collisionState = {}
        local alive = true
        local movementToken = getMovementRevision()
        local function probeCanRun()
            return alive and scriptAlive and root.Parent ~= nil and root == getHumanoidRootPart()
                and getMovementRevision() == movementToken
                and (not canContinue or canContinue())
        end

        if character then
            for _, descendant in ipairs(character:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    collisionState[#collisionState + 1] = { descendant, descendant.CanCollide }
                    descendant.CanCollide = false
                end
            end
        end

        if humanoid then
            humanoid.Sit = false
            humanoid.PlatformStand = false
            humanoid.AutoRotate = false
        end
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.Anchored = true
        local controller = {}
        function controller:Hold()
            if not probeCanRun() then return false end
            root.Anchored = true
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            -- Server correction / character scripts can occasionally shift the root.
            -- Never allow a probe to drift downward into the ocean or far from marker.
            if root.Position.Y < WORLD_SCAN_SAFE_MIN_Y - 8
                or (root.Position - targetCFrame.Position).Magnitude > 8
            then
                return teleportPlayer(root, targetCFrame, probeCanRun, chestTeleport)
            end
            return true
        end
        function controller:Stop()
            if not alive then return end
            alive = false
            if root and root.Parent then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                root.Anchored = oldAnchored
            end
            for _, entry in ipairs(collisionState) do
                local part = entry[1]
                if part and part.Parent then part.CanCollide = entry[2] end
            end
            if humanoid and humanoid.Parent then
                humanoid.AutoRotate = oldAutoRotate
                if Config:Get("FlyEnabled") ~= true then
                    humanoid.PlatformStand = false
                    humanoid.Sit = false
                    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
                else
                    humanoid.PlatformStand = oldPlatformStand
                    humanoid.Sit = oldSit
                end
            end
        end
        if not teleportPlayer(root, targetCFrame, probeCanRun, chestTeleport) then controller:Stop(); return nil end
        task.wait(0.045)
        if not controller:Hold() then controller:Stop(); return nil end
        return controller
    end

    local function searchNextWorldArea(expectedGeneration)
        local root = getHumanoidRootPart()
        if not root or Config:Get("FlyEnabled") == true then
            return false
        end

        recoverWorldSearchRoot(root, getHumanoid())
        local movementToken = getMovementRevision()
        local sweep = 0

        local function scannerCanRun()
            if not canRun(expectedGeneration)
                or not root.Parent
                or getMovementRevision() ~= movementToken
                or os.clock() < (SharedInteraction.chestPriorityUntil or 0)
            then
                return false
            end
            if Config:Get("FlyEnabled") == true then
                return false
            end
            local sack = ChestLoot.FindSackTool()
            local state = sack and ChestLoot.ReadSackState(sack)
            return not (state and state.full)
        end

        while scannerCanRun() do
            pulseWorker()
            local anchors = collectMapAnchors(root.Position)
            if #anchors == 0 then
                task.wait(0.25)
                continue
            end
            if worldSearchCursor > #anchors then worldSearchCursor = 0 end

            local visitedThisSweep = 0
            while scannerCanRun() and visitedThisSweep < #anchors do
                pulseWorker()
                recoverWorldSearchRoot(root, getHumanoid())
                -- Let other item automations run between island visits instead of
                -- holding the shared interaction lock for an entire empty-map sweep.
                if not SharedInteraction.TryAcquire("loot-search") then
                    task.wait(0.06)
                    continue
                end

                worldSearchCursor = worldSearchCursor + 1
                if worldSearchCursor > #anchors then worldSearchCursor = 1 end
                visitedThisSweep = visitedThisSweep + 1
                local anchor = anchors[worldSearchCursor]

                local found = false
                local probe
                local ok, err = xpcall(function()
                    local observedRevision = ChestLoot.GetDebrisRevision()
                    local streamReady = requestStreamAt(anchor.position, scannerCanRun)
                    if not scannerCanRun() then return end
                    task.wait(0.08)
                    if not scannerCanRun() then return end

                    -- An already-streamed item can become visible before we need to move.
                    if #loadedMatchingCandidates(root, 1) > 0 then
                        found = true
                        return
                    end
                    observedRevision = ChestLoot.GetDebrisRevision()

                    probe = beginWorldSearchProbe(worldSearchProbeCFrame(anchor.position), false, scannerCanRun)
                    if not probe then return end
                    local probeRevision = ChestLoot.GetDebrisRevision()
                    if probeRevision ~= observedRevision then
                        observedRevision = probeRevision
                        if #loadedMatchingCandidates(root, 1) > 0 then
                            found = true
                            return
                        end
                    end

                    -- The probe itself drives Roblox proximity streaming. Query the
                    -- loot registry only when ChildAdded/ChildRemoved changes it,
                    -- plus one final check, instead of scanning hundreds of objects
                    -- every 0.08 seconds. One RequestStream call per anchor also
                    -- avoids saturating the two-request safety cap.
                    local deadline = os.clock() + (streamReady and 0.75 or 1.15)
                    repeat
                        pulseWorker()
                        if not probe:Hold() then return end
                        local currentRevision = ChestLoot.GetDebrisRevision()
                        if currentRevision ~= observedRevision then
                            observedRevision = currentRevision
                            if #loadedMatchingCandidates(root, 1) > 0 then
                                found = true
                                return
                            end
                        end
                        task.wait(0.045)
                    until not scannerCanRun() or os.clock() >= deadline

                    if scannerCanRun() and #loadedMatchingCandidates(root, 1) > 0 then
                        found = true
                    end
                end, function(message)
                    return tostring(message)
                end)

                if probe then probe:Stop() end
                recoverWorldSearchRoot(root, getHumanoid())
                SharedInteraction.Release("loot-search")
                if not ok then
                    warn("[SEA World Loot Scanner] " .. tostring(err))
                end
                if found then
                    return true
                end
                task.wait(0.025)
            end

            -- One whole route was empty. Immediately rebuild DistantIslands / current
            -- streamed anchors and sweep again. This is the respawn/new-item scanner:
            -- it never depends on a later collectPass to restart movement.
            sweep = sweep + 1
            if sweep % 2 == 0 then
                for candidate, retryAt in pairs(nextAttemptAt) do
                    if retryAt <= os.clock() then nextAttemptAt[candidate] = 0 end
                end
            end
            task.wait(0.16)
        end
        return false
    end

    local function collectPass(showNotification, expectedGeneration)
        if DropSafety.IsWaiting() then return 0, 0, "previous-drop-unconfirmed" end
        if expectedGeneration ~= nil and expectedGeneration ~= generation then
            return 0, 0, "generation-changed"
        end
        pulseWorker()
        if os.clock() < (SharedInteraction.chestPriorityUntil or 0) then
            return 0, 0, "chest-priority"
        end
        local rootPart = getHumanoidRootPart()
        if not rootPart then
            if showNotification then
                notify("World Loot", "HumanoidRootPart not found", 2)
            end
            return 0, 0, "no-root"
        end
        if #api.Selected == 0 then
            if showNotification then
                notify("World Loot", "Choose at least one loot type first", 2)
            end
            return 0, 0, "no-selection"
        end

        local sackTool, sackState = ensureFarmSack(showNotification)
        if not sackTool then
            return 0, 0, "no-sack"
        end

        -- Exact requested cycle: keep searching until the Sack is full, then go
        -- to Drop Here, empty it, keep the Sack equipped, and continue searching.
        if sackState and sackState.full then
            if DropManager
                and type(DropManager.GetPoint) == "function"
                and DropManager.GetPoint()
                and DropManager.EmptyNow(false, true)
            then
                for candidate in pairs(nextAttemptAt) do
                    nextAttemptAt[candidate] = 0
                end
                return 0, 0, "dropped-full-sack"
            end
            if os.clock() - lastSackNoticeAt > 5 then
                lastSackNoticeAt = os.clock()
                notify("World Loot", "Sack is full; set Drop Here once so Auto Farm can empty and continue", 2.5)
            end
            return 0, 0, "full-sack"
        end

        local remainingCapacity = 12
        if sackState
            and type(sackState.count) == "number"
            and type(sackState.maximum) == "number"
        then
            remainingCapacity = math.max(1, sackState.maximum - sackState.count)
        end
        local batchLimit = math.min(remainingCapacity, 16)

        local batchCandidates = loadedMatchingCandidates(rootPart, batchLimit)
        if #batchCandidates == 0 then
            searchNextWorldArea(expectedGeneration)
            if os.clock() < (SharedInteraction.chestPriorityUntil or 0) then
                return 0, 0, "chest-priority"
            end
            rootPart = getHumanoidRootPart()
            batchCandidates = loadedMatchingCandidates(rootPart, batchLimit)
        end

        if #batchCandidates == 0 then
            if showNotification or os.clock() - lastNoTargetNoticeAt > 8 then
                lastNoTargetNoticeAt = os.clock()
                if showNotification then
                    notify("World Loot", "No selected item found on the current full-map search segment", 1.8)
                end
            end
            return 0, 0, "searching"
        end

        local results = ChestLoot.InteractBatch(
            batchCandidates,
            api.Mode,
            batchLimit,
            {
                keepSackEquipped = true,
                restorePosition = false,
                sackFirst = true,
                stopWhenSackFull = true,
                autonomousMovement = true,
                onProgress = pulseWorker,
            }
        )

        local collectedCount = 0
        local foundCount = #batchCandidates
        local sackFull = false
        local sackFullText
        local now = os.clock()

        for _, result in ipairs(results) do
            local retryDelay = result.success and 20 or 1.2
            if result.method == "sack-missing"
                or result.method == "sack-equip-failed"
            then
                retryDelay = 4
            elseif result.method == "sack-full" then
                retryDelay = 0
                sackFull = true
                sackFullText = result.sackText or sackFullText
            elseif result.method == "busy"
                or result.method == "batch-busy"
                or result.method == "chest-priority"
            then
                retryDelay = 0.25
            end
            nextAttemptAt[result.candidate] = now + retryDelay
            if result.success then
                collectedCount = collectedCount + 1
            end
        end

        local afterState = ChestLoot.ReadSackState(sackTool)
        if afterState and afterState.full then
            sackFull = true
            sackFullText = afterState.counterText or sackFullText
        end

        if sackFull then
            if DropManager
                and type(DropManager.GetPoint) == "function"
                and DropManager.GetPoint()
                and DropManager.EmptyNow(false, true)
            then
                for candidate in pairs(nextAttemptAt) do
                    nextAttemptAt[candidate] = 0
                end
                sackFull = false
            end
        end

        -- Reassert Sack after any E-only item temporarily needed an empty hand.
        ChestLoot.EquipSackTool(sackTool)

        if showNotification then
            local message = string.format(
                "Collected %d/%d candidate(s)",
                collectedCount,
                foundCount
            )
            if sackFull then
                message = message .. "; Sack full " .. tostring(sackFullText or "")
            end
            notify("World Loot", message, 2)
        end

        return collectedCount, foundCount, sackFull and "full-sack" or "collected"
    end

    local startLoop

    local function recoverAbandonedWorker()
        ChestLoot.RecoverInteraction()
        SharedInteraction.Release("drop", true)
        local root = getHumanoidRootPart()
        local humanoid = getHumanoid()
        if root and root.Parent and Config:Get("FlyEnabled") ~= true then
            for _, name in ipairs({
                "SEA_DropHereHoverPosition",
                "SEA_DropHereHoverGyro",
            }) do
                local mover = root:FindFirstChild(name)
                if mover then pcall(function() mover:Destroy() end) end
            end
            root.Anchored = false
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
        if humanoid and humanoid.Parent and Config:Get("FlyEnabled") ~= true then
            humanoid.PlatformStand = false
            humanoid.Sit = false
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
    end

    local function ensureSupervisor()
        if supervisorRunning then return end
        supervisorRunning = true
        task.spawn(function()
            while scriptAlive do
                if canRun() then
                    local stale = loopRunning
                        and workerLastPulseAt > 0
                        and os.clock() - workerLastPulseAt >= 15
                    if stale then
                        warn("[SEA World Loot Supervisor] stalled worker restarted")
                        generation = generation + 1
                        loopRunning = false
                        worldSearchCursor = 0
                        recoverAbandonedWorker()
                        -- The bounded scanner normally unwinds on the next heartbeat.
                        -- Give its controller cleanup one frame-window before a new
                        -- route can claim movement and interaction ownership.
                        task.wait(0.12)
                    end
                    if not loopRunning then
                        startLoop()
                    end
                end
                task.wait(1.5)
            end
            supervisorRunning = false
        end)
    end

    startLoop = function()
        if loopRunning or not canRun() then
            return
        end

        local currentGeneration = generation
        loopRunning = true
        pulseWorker()
        task.spawn(function()
            local lastWorkerErrorNoticeAt = 0
            local workerOk, workerError = xpcall(function()
                while canRun(currentGeneration) do
                    pulseWorker()
                    -- Every pass is isolated, while the outer xpcall guarantees that
                    -- even an error in the worker shell clears loopRunning and restarts.
                    local passOk, collectedCount, _, state = pcall(
                        collectPass,
                        false,
                        currentGeneration
                    )
                    pulseWorker()
                    if not passOk then
                        warn("[SEA World Loot Worker] " .. tostring(collectedCount))
                        if os.clock() - lastWorkerErrorNoticeAt >= 5 then
                            lastWorkerErrorNoticeAt = os.clock()
                            notify("World Loot Recovery", "Transient error; full-map scan is continuing", 2.5)
                        end
                        task.wait(0.20)
                    elseif state == "full-sack" or state == "no-sack" then
                        task.wait(0.30)
                    elseif collectedCount > 0 or state == "dropped-full-sack" then
                        task.wait(0.05)
                    else
                        task.wait(0.12)
                    end
                end
            end, function(message)
                return tostring(message)
            end)

            if not workerOk then
                warn("[SEA World Loot Worker Shell] " .. tostring(workerError))
            end
            if currentGeneration == generation then
                loopRunning = false
                if canRun(currentGeneration) then
                    task.defer(startLoop)
                end
            end
        end)
        ensureSupervisor()
    end

    function api.SetSelected(options)
        api.Selected = options
        for _, itemName in ipairs(options) do
            ChestLoot.AddCatalogName(itemName)
        end
        Config:Set("WorldLootItems", options)
        if api.Enabled then
            generation = generation + 1
            loopRunning = false
            startLoop()
        end
    end

    function api.SetEnabled(enabled)
        enabled = enabled == true
        if enabled and type(stopStationFarmsForWorldLoot) == "function" then
            if Travel then Travel.Stop("World Auto Loot started") end
            stopStationFarmsForWorldLoot()
        end
        api.Enabled = enabled
        Config:Set("AutoLootWorld", api.Enabled)
        generation = generation + 1
        loopRunning = false

        if api.Enabled then
            if #api.Selected == 0 then
                notify("World Loot", "Choose at least one loot type first", 2)
            else
                -- Match the older material-farm behavior: Auto Farm owns the Sack
                -- tool slot immediately instead of restoring Harpoon after a batch.
                task.spawn(function()
                    ensureFarmSack(true)
                end)
                startLoop()
            end
        end
    end

    function api.SetMode(value)
        api.Mode = firstSelectedValue(value) or "Smart (E / F)"
        Config:Set("WorldLootMode", api.Mode)
    end

    function api.CollectNow()
        return collectPass(true)
    end

    function api.SetToggleControl(control)
        toggleControl = control
    end

    function api.DisableForRoute(source, routeName, quiet)
        if not api.Enabled and Config:Get("AutoLootWorld") ~= true then return end
        api.SetEnabled(false)
        if toggleControl then
            pcall(function() toggleControl:Set(false, false) end)
        end
        if quiet ~= true then
            notify(
                source or "Exclusive Route",
                "World Auto Loot was disabled so the " .. tostring(routeName or "other route") .. " can run",
                2.2
            )
        end
        return true
    end

    function api.DisableForStation(source)
        return api.DisableForRoute(source or "Station Farm", "station route")
    end

    -- Auto Chest shares the proven DistantIslands discovery path without turning
    -- World Loot itself on. Keeping this as a narrow API also avoids a second,
    -- subtly different streaming implementation that could stall independently.
    function api.GetSearchAnchors(originPosition)
        return collectMapAnchors(originPosition)
    end

    function api.ProbeSearchArea(position, canContinue)
        if typeof(position) ~= "Vector3" or Config:Get("FlyEnabled") == true then
            return false
        end

        local function shouldContinue()
            if not scriptAlive or Config:Get("FlyEnabled") == true then
                return false
            end
            if type(canContinue) ~= "function" then
                return true
            end
            local ok, keepRunning = pcall(canContinue)
            return ok and keepRunning == true
        end

        if not shouldContinue() or not SharedInteraction.TryAcquire("chest-search") then
            return false
        end

        local probe
        local ok, result = xpcall(function()
            local root = getHumanoidRootPart()
            if not root or not root.Parent then return false end
            recoverWorldSearchRoot(root, getHumanoid(), true)

            local streamReady = requestStreamAt(position, shouldContinue)
            if not shouldContinue() then return false end
            task.wait(0.08)
            if not shouldContinue() then return false end

            probe = beginWorldSearchProbe(worldSearchProbeCFrame(position), true, shouldContinue)
            if not probe then return false end

            -- Proximity movement is the fallback when RequestStreamAroundAsync is
            -- unavailable or times out. Holding briefly lets DescendantAdded feed
            -- the live chest cache; no full Workspace rescan is needed here.
            local deadline = os.clock() + (streamReady and 0.75 or 1.15)
            repeat
                SharedInteraction.Touch("chest-search")
                if not probe:Hold() then return false end
                task.wait(0.045)
            until not shouldContinue() or os.clock() >= deadline
            return shouldContinue()
        end, function(message)
            return tostring(message)
        end)

        if probe then
            pcall(function() probe:Stop() end)
        end
        recoverWorldSearchRoot(getHumanoidRootPart(), getHumanoid(), true)
        SharedInteraction.Release("chest-search")

        if not ok then
            warn("[SEA Auto Chest Scanner] " .. tostring(result))
            return false
        end
        return result == true
    end

    function api.Refresh(showNotification)
        return ChestLoot.Refresh(showNotification)
    end

    function api.StartIfEnabled()
        if api.Enabled and #api.Selected > 0 then
            task.spawn(function()
                ensureFarmSack(false)
            end)
            startLoop()
            ensureSupervisor()
        end
    end

    function api.StopForUnload()
        api.Enabled = false
        generation = generation + 1
        loopRunning = false
    end

    connect(localPlayer.CharacterAdded, function()
        if not api.Enabled then return end
        generation = generation + 1
        loopRunning = false
        worldSearchCursor = 0
        task.delay(0.8, function()
            if canRun() then startLoop() end
        end)
    end)

    return api
end)()

ChestLoot.Refresh(false)


-- Teleport features ---------------------------------------------------------

local selectedCreature = Config:Get("SelectedCreature") or CREATURE_NAMES[1]
local selectedChest = Config:Get("SelectedChest") or "Any Chest"
local creatureDropdown
local chestDropdown

-- Weak tables prevent destroyed chest instances/prompts from being retained.
local chestStates = setmetatable({}, { __mode = "k" })
local monitoredChestPrompts = setmetatable({}, { __mode = "k" })
local manualChestLootConnections = setmetatable({}, { __mode = "k" })
local cachedChests = setmetatable({}, { __mode = "k" })
local chestRuntime: { [string]: any } = {
    retryAt = setmetatable({}, { __mode = "k" }),
    failures = setmetatable({}, { __mode = "k" }),
    pending = setmetatable({}, { __mode = "k" }),
    inFlight = 0,
}

-- v49 one-tap migration: any of the three legacy chest toggles enables the new
-- unified route. From this point they are kept in lockstep for old save files.
local autoOpenAfterTeleport = Config:Get("AutoChestAndLoot") == true
    or Config:Get("AutoOpenAfterTeleport") == true
    or Config:Get("AutoNextChest") == true
    or ChestLoot.Enabled
local continueChestRoute = autoOpenAfterTeleport
local o2GuardEnabled = Config:Get("O2Guard") == true
local chestRouteRunning = false
local chestRouteGeneration = 0
local baseCFrame

if autoOpenAfterTeleport and #ChestLoot.Selected == 0 then
    ChestLoot.SetSelected({ "All Items" })
end
ChestLoot.SetEnabled(autoOpenAfterTeleport)
Config:Set("AutoChestAndLoot", autoOpenAfterTeleport)
Config:Set("AutoOpenAfterTeleport", autoOpenAfterTeleport)
Config:Set("AutoNextChest", autoOpenAfterTeleport)

local cachedGameNetwork
local nextNetworkScanAt = 0

local CHEST_OPEN_STATE_NAMES = {
    "Opened",
    "IsOpened",
    "Open",
    "Claimed",
    "Collected",
}

local function chestNameMatchesSelection(instanceName, selection)
    local normalizedName = normalizeInstanceName(instanceName)

    if selection == "Any Chest" then
        -- cachedChests contains only the game's authoritative CollectionService
        -- "Chest" tag, so Any Chest also covers future variants automatically.
        return true
    end

    local aliases = CHEST_NORMALIZED_ALIASES[selection]
    return aliases and aliases[normalizedName] == true or false
end

local function setChestState(chest, state)
    chestStates[chest] = state
end

local function getPlayerChestOpenedAttribute()
    return "Opened" .. localPlayer.Name
end

local function chestHasOpenedState(chest)
    if chestStates[chest] == "opened" then
        return true
    end

    -- This is the exact state read by Modules.Systems.Chests.HandleChest().
    if chest:GetAttribute(getPlayerChestOpenedAttribute()) == true then
        setChestState(chest, "opened")
        return true
    end

    -- Keep generic fallbacks for alternate chest variants / future updates.
    for _, stateName in ipairs(CHEST_OPEN_STATE_NAMES) do
        if chest:GetAttribute(stateName) == true then
            setChestState(chest, "opened")
            return true
        end

        local stateValue = chest:FindFirstChild(stateName, true)
        if stateValue and stateValue:IsA("BoolValue") and stateValue.Value then
            setChestState(chest, "opened")
            return true
        end
    end

    local stateAttribute = chest:GetAttribute("State")
    if type(stateAttribute) == "string" then
        local normalizedState = string.lower(stateAttribute)
        if normalizedState == "opened"
            or normalizedState == "claimed"
            or normalizedState == "collected"
        then
            setChestState(chest, "opened")
            return true
        end
    end

    return false
end

local function getChestPromptState(chest)
    local foundDisabledPrompt = false

    for _, descendant in ipairs(chest:GetDescendants()) do
        if descendant:IsA("ProximityPrompt") then
            if descendant.Enabled then
                return descendant, false
            end
            foundDisabledPrompt = true
        end
    end

    -- Native Chests temporarily disables the prompt before _G.OpenChest and
    -- re-enables it on failure, so disabled alone must never mark the chest open.
    return nil, foundDisabledPrompt
end

local function monitorChestPrompt(chest, prompt)
    if monitoredChestPrompts[chest] then
        return
    end

    monitoredChestPrompts[chest] = true
    local attributeName = getPlayerChestOpenedAttribute()
    connect(chest:GetAttributeChangedSignal(attributeName), function()
        if chest:GetAttribute(attributeName) == true then
            setChestState(chest, "opened")
        end
    end)

    -- Triggered only means the native 2-second hold completed. The authoritative
    -- OpenChest result / Opened<PlayerName> attribute decides success.
    if prompt then
        connect(prompt.Triggered, function(triggeringPlayer)
            if triggeringPlayer == nil or triggeringPlayer == localPlayer then
                if chest:GetAttribute(attributeName) == true then
                    setChestState(chest, "opened")
                end
            end
        end)
    end
end

local function watchManualChestLoot(chest, originPosition, beforeSnapshot)
    if not chest or not originPosition or not beforeSnapshot then
        return false
    end

    local oldConnection = manualChestLootConnections[chest]
    if oldConnection then
        pcall(function() oldConnection:Disconnect() end)
        manualChestLootConnections[chest] = nil
    end

    local attributeName = getPlayerChestOpenedAttribute()
    local connection
    connection = chest:GetAttributeChangedSignal(attributeName):Connect(function()
        if chest.Parent and chest:GetAttribute(attributeName) == true then
            if connection then
                connection:Disconnect()
            end
            manualChestLootConnections[chest] = nil
            -- The server can replicate DebrisField children just before the
            -- Opened<Player> attribute reaches this client. Include only that
            -- short lead-in, not every item spawned since teleporting here.
            if ChestLoot.Arm(beforeSnapshot, 1.25) then
                task.spawn(function()
                    ChestLoot.Collect(originPosition, beforeSnapshot)
                end)
            end
        end
    end)
    manualChestLootConnections[chest] = connection
    return true
end

local function cacheChestCandidate(instance)
    if instance:IsA("Model")
        and instance:IsDescendantOf(workspace)
        and CollectionService:HasTag(instance, "Chest")
    then
        cachedChests[instance] = true
    end
end

local function rebuildChestCache()
    cachedChests = setmetatable({}, { __mode = "k" })
    for _, taggedChest in ipairs(CollectionService:GetTagged("Chest")) do
        cacheChestCandidate(taggedChest)
    end
end

rebuildChestCache()

connect(workspace.DescendantAdded, cacheChestCandidate)
connect(CollectionService:GetInstanceAddedSignal("Chest"), cacheChestCandidate)
connect(CollectionService:GetInstanceRemovedSignal("Chest"), function(instance)
    cachedChests[instance] = nil
    chestStates[instance] = nil
end)
connect(workspace.DescendantRemoving, function(instance)
    cachedChests[instance] = nil
    chestStates[instance] = nil
end)

local function getGameNetwork()
    if cachedGameNetwork
        and type(cachedGameNetwork.FireServer) == "function"
        and type(cachedGameNetwork.InvokeServer) == "function"
    then
        return cachedGameNetwork
    end

    -- Client.luau assigns the SAME initialized network to SackClient.Net and
    -- DragSystem.Network. Network itself is a callable wrapper, not the ready
    -- object: use the client-owned reference without calling that wrapper.
    local sackClient = ChestLoot.GetSackClient()
    local initializedNetwork = sackClient and sackClient.Net
    if type(initializedNetwork) == "table"
        and type(initializedNetwork.FireServer) == "function"
        and type(initializedNetwork.InvokeServer) == "function"
    then
        cachedGameNetwork = initializedNetwork
        return initializedNetwork
    end

    -- Compatibility for alternate builds which export the ready object directly.
    local directModule = ReplicatedStorage:FindFirstChild("Network")
    if directModule and directModule:IsA("ModuleScript") then
        local success, network = pcall(require, directModule)
        if success and type(network) == "table"
            and type(network.FireServer) == "function"
            and type(network.InvokeServer) == "function"
        then
            cachedGameNetwork = network
            return network
        end
    end

    local now = os.clock()
    if now < nextNetworkScanAt or typeof(getgc) ~= "function" then
        return nil
    end

    -- Executor fallback for builds where Network is relocated.
    nextNetworkScanAt = now + 10
    pcall(function()
        for _, candidate in pairs(getgc(true)) do
            if type(candidate) == "table"
                and rawget(candidate, "FireServer")
                and candidate.InvokeServer
            then
                cachedGameNetwork = candidate
                break
            end
        end
    end)

    return cachedGameNetwork
end

local function invokeOpenChest(chest, canContinue)
    local request = chestRuntime.pending[chest]
    if not request then
        -- A stalled RemoteFunction must not suspend the route forever or create
        -- an unbounded number of abandoned InvokeServer coroutines.
        if chestRuntime.inFlight >= 2 then return false, nil, "network-busy" end
        request = { done = false }
        chestRuntime.pending[chest] = request
        chestRuntime.inFlight = chestRuntime.inFlight + 1
        task.spawn(function()
            request.ok, request.response = pcall(function()
                local network = getGameNetwork()
                if not network then return nil end
                return network:InvokeServer("OpenChest", chest)
            end)
            request.done = true
            chestRuntime.inFlight = math.max(0, chestRuntime.inFlight - 1)
        end)
    end

    local deadline = os.clock() + 1.6
    repeat
        if not scriptAlive or (canContinue and not canContinue()) then
            return false, nil, "cancelled"
        end
        if request.done then
            chestRuntime.pending[chest] = nil
            return request.ok, request.response,
                request.response == nil and "network-unavailable" or "response"
        end
        if chest.Parent and chest:GetAttribute(getPlayerChestOpenedAttribute()) == true then
            return true, true, "attribute"
        end
        task.wait(0.025)
    until os.clock() >= deadline
    return false, nil, "timeout"
end

local function captureBasePosition()
    if baseCFrame then
        return
    end

    local rootPart = getHumanoidRootPart()
    if rootPart then
        baseCFrame = rootPart.CFrame
    end
end

local function returnToBase()
    local rootPart = getHumanoidRootPart()
    if not rootPart or not baseCFrame then
        notify("Base Teleport", "Base position is not available yet", 2)
        return
    end

    interruptAutomationMovement()
    rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    if not teleportPlayer(rootPart, baseCFrame) then return end
    notify("Base Teleport", "Returned to the saved starting position", 2)
end

local lastO2GuardNoticeAt = 0
local function applyO2Guard()
    if not o2GuardEnabled then
        return false
    end

    local oxygen = tonumber(localPlayer:GetAttribute("O2"))
    local character = getCharacter()
    local rootPart = getHumanoidRootPart()
    local head = character and character:FindFirstChild("Head")
    if not oxygen or not rootPart or not head then
        return false
    end

    -- Oxygen.luau treats the equipped Tank as a separate reserve and replaces
    -- it with 50 normal O2 when depleted. Guarding the tank value itself would
    -- pause the route forever because tank O2 does not refill at the surface.
    if character:FindFirstChild("Tank") then
        return false
    end
    if oxygen > 25 then
        return false
    end

    -- Oxygen.HandleOxygen() considers Head.Y < 147 underwater. Surface above
    -- that real threshold and cancel this route step instead of diving again.
    interruptAutomationMovement()
    local requiredRise = math.max(0, 148.5 - head.Position.Y)
    if requiredRise > 0 then
        rootPart.AssemblyLinearVelocity = Vector3.zero
        rootPart.CFrame = rootPart.CFrame + Vector3.new(0, requiredRise + 1.5, 0)
    end

    if os.clock() - lastO2GuardNoticeAt > 2.5 then
        lastO2GuardNoticeAt = os.clock()
        notify(
            "O2 Guard",
            "Low oxygen; surfacing and pausing this chest step until O2 recovers",
            2
        )
    end

    -- Without a tank the server resets O2 to 100 once the head is above water.
    local deadline = os.clock() + 1.8
    repeat
        task.wait(0.1)
        oxygen = tonumber(localPlayer:GetAttribute("O2")) or oxygen
    until not scriptAlive or oxygen >= 85 or os.clock() >= deadline

    -- If normal O2 recovered at the surface, continue this same chest step with
    -- fresh oxygen. Abort only when the server did not replenish it in time.
    return oxygen < 85
end

captureBasePosition()

local function findNearestUnopenedChest(selection, rootPart)
    local closestChest
    local closestPart
    local closestPrompt
    local closestDistance = math.huge
    local unopenedCount = 0

    for chest in pairs(cachedChests) do
        local state = chestStates[chest]
        if chest.Parent
            and chestNameMatchesSelection(chest.Name, selection)
            and state ~= "opening"
            and os.clock() >= (chestRuntime.retryAt[chest] or 0)
            and not chestHasOpenedState(chest)
        then
            local prompt, hasOnlyDisabledPrompts = getChestPromptState(chest)
            local chestPart = getTargetPart(chest)

            -- Manual mode requires a prompt. Optional network auto-open can
            -- also handle chest models whose prompt is not exposed.
            if chestPart and (prompt or autoOpenAfterTeleport) then
                unopenedCount = unopenedCount + 1

                local distance = (chestPart.Position - rootPart.Position).Magnitude
                if distance < closestDistance then
                    closestDistance = distance
                    closestChest = chest
                    closestPart = chestPart
                    closestPrompt = prompt
                end
            end
        end
    end

    return closestChest, closestPart, closestPrompt, unopenedCount
end







local function tryOpenChest(chest, prompt, quiet, routeCanContinue)
    if not scriptAlive or not chest or not chest.Parent then return false end
    if chestHasOpenedState(chest) then return true end

    local movementToken = getMovementRevision()
    local function canContinue()
        return scriptAlive and getMovementRevision() == movementToken
            and (type(routeCanContinue) ~= "function" or routeCanContinue())
    end
    setChestState(chest, "opening")
    ChestLoot.SetStatus("Opening " .. chest.Name .. "...", "Auto Chest + Loot")
    local chestPart = getTargetPart(chest)
    local lootOrigin = chestPart and chestPart.Position
    local beforeLootSnapshot
    if ChestLoot.Enabled and #ChestLoot.Selected > 0 and lootOrigin then
        beforeLootSnapshot = ChestLoot.Snapshot(lootOrigin, chest)
        beforeLootSnapshot.canContinue = canContinue
    end

    local function opened()
        setChestState(chest, "opened")
        chestRuntime.retryAt[chest] = nil
        chestRuntime.failures[chest] = nil
        if quiet ~= true then notify("Chest Confirmed", "Opened " .. chest.Name, 2) end
        if beforeLootSnapshot and canContinue() then
            local ok, message = pcall(ChestLoot.Collect, lootOrigin, beforeLootSnapshot)
            if not ok then warn("[SEA Chest Drops] " .. tostring(message)) end
        end
        if beforeLootSnapshot then ChestLoot.CancelSession(beforeLootSnapshot) end
        return true
    end

    -- No wait for the game's lid animation / 2-second prompt hold on the native
    -- OpenChest route. Only allow character proximity to reach the server first.
    task.wait(0.075)
    if beforeLootSnapshot then ChestLoot.Arm(beforeLootSnapshot, 0) end
    local lastReason = "cancelled"
    local allowPromptFallback = false
    for attempt = 1, 2 do
        if not canContinue() or not chest.Parent then break end
        local success, response, reason = invokeOpenChest(chest, canContinue)
        lastReason = reason
        if not canContinue() then break end
        if (success and response == true) or (chest.Parent and chestHasOpenedState(chest)) then
            return opened()
        end
        -- Client.Chests only treats truthy as success. Its supplied client code
        -- does NOT establish that false means "already looted". Keep it retryable.
        if success and response == false then lastReason = "server-rejected" end
        if reason == "timeout" or reason == "network-busy" or reason == "cancelled" then break end
        allowPromptFallback = reason == "network-unavailable" or not success
        if attempt < 2 then task.wait(0.12) end
    end

    if allowPromptFallback and prompt and prompt.Parent and canContinue()
        and typeof(fireproximityprompt) == "function"
    then
        pcall(fireproximityprompt, prompt)
        local deadline = os.clock() + 2.5
        repeat
            if not canContinue() or not chest.Parent then break end
            if chestHasOpenedState(chest) then return opened() end
            task.wait(0.05)
        until os.clock() >= deadline
    end

    if chestStates[chest] == "opening" then setChestState(chest, "retry") end
    local failures = math.min(4, (chestRuntime.failures[chest] or 0) + 1)
    chestRuntime.failures[chest] = failures
    chestRuntime.retryAt[chest] = os.clock() + math.min(12, 2 ^ failures)
    if beforeLootSnapshot then ChestLoot.CancelSession(beforeLootSnapshot) end
    if canContinue() then
        ChestLoot.SetStatus("Open not confirmed (" .. tostring(lastReason)
            .. "). Scanning other chests; this chest remains retryable.", "Chest retry")
        if quiet ~= true then notify("Chest Retry", "Not confirmed; will retry after a short cooldown", 2.5) end
    end
    return false
end

local function teleportToSelectedCreature()
    if not selectedCreature and creatureDropdown then
        selectedCreature = firstSelectedValue(creatureDropdown.Selected)
    end

    if not selectedCreature then
        notify("Error", "Please select a creature first", 2)
        return
    end

    local rootPart = getHumanoidRootPart()
    if not rootPart then
        notify("Error", "HumanoidRootPart not found", 2)
        return
    end

    local wanted = normalizeInstanceName(selectedCreature)
    local closestPart
    local closestDistance = math.huge
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("Model") then
            local baseName = tostring(descendant.Name):gsub("_CLIENT$", "")
            if normalizeInstanceName(baseName) == wanted then
                local part = getTargetPart(descendant, "HumanoidRootPart")
                    or getTargetPart(descendant, "Root")
                    or getTargetPart(descendant, "Center")
                    or getTargetPart(descendant)
                if part then
                    local distance = (part.Position - rootPart.Position).Magnitude
                    if distance < closestDistance then
                        closestDistance = distance
                        closestPart = part
                    end
                end
            end
        end
    end

    if not closestPart then
        notify("Error", "Creature '" .. tostring(selectedCreature) .. "' is not spawned", 2)
        return
    end

    interruptAutomationMovement()
    if not teleportPlayer(rootPart, closestPart.CFrame + Vector3.new(0, 3, 2)) then return end
    notify("Teleported", "Nearest " .. tostring(selectedCreature) .. " found", 2)
end

local function teleportToNextChest(quiet, canContinue)
    if DropSafety.IsWaiting() then return nil, nil end
    if not scriptAlive or Config:Get("FlyEnabled") == true
        or (canContinue and not canContinue())
    then return nil, nil end
    if not selectedChest and chestDropdown then
        selectedChest = firstSelectedValue(chestDropdown.Selected)
    end

    if not selectedChest
        or (selectedChest ~= "Any Chest" and not CHEST_NORMALIZED_ALIASES[selectedChest])
    then
        if quiet ~= true then notify("Error", "Chest pattern not found", 2) end
        return nil, nil
    end

    local rootPart = getHumanoidRootPart()
    if not rootPart then
        if quiet ~= true then notify("Error", "HumanoidRootPart not found", 2) end
        return nil, nil
    end

    if applyO2Guard() then
        return nil, nil
    end
    if not scriptAlive or (canContinue and not canContinue()) then return nil, nil end

    local chest, chestPart, prompt, unopenedCount = findNearestUnopenedChest(
        selectedChest,
        rootPart
    )

    if not chest or not chestPart then
        if quiet ~= true then
            notify(
                "No Unopened Chest",
                "No unopened '" .. tostring(selectedChest) .. "' chest found",
                2.5
            )
        end
        return nil, nil
    end

    if prompt then
        monitorChestPrompt(chest, prompt)
    end

    setChestState(chest, "teleported")
    interruptAutomationMovement()
    rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    rootPart.CFrame = chestPart.CFrame + Vector3.new(0, 3, 2)

    if ChestLoot.Enabled
        and #ChestLoot.Selected > 0
        and not autoOpenAfterTeleport
    then
        local manualLootSnapshot = ChestLoot.Snapshot(chestPart.Position, chest)
        watchManualChestLoot(chest, chestPart.Position, manualLootSnapshot)
    end

    if quiet ~= true then
        notify(
            "Teleported",
            "Teleported to " .. chest.Name .. " (" .. unopenedCount .. " unopened found)",
            2.5
        )
    end

    return chest, prompt
end

local function runChestRoute()
    if chestRouteRunning or not autoOpenAfterTeleport or not continueChestRoute then
        return
    end

    chestRouteRunning = true
    chestRouteGeneration = chestRouteGeneration + 1
    local generation = chestRouteGeneration

    task.spawn(function()
        local searchCursor = 0
        local function routeCanRun()
            return scriptAlive
                and continueChestRoute
                and autoOpenAfterTeleport
                and generation == chestRouteGeneration
        end

        local workerOk, workerError = xpcall(function()
            while routeCanRun() do
                local stepOk, chest, prompt = pcall(teleportToNextChest, true, routeCanRun)
                if not routeCanRun() then break end
                if not stepOk then
                    warn("[SEA Auto Chest Route] " .. tostring(chest))
                    task.wait(0.65)
                elseif chest then
                    local openOk, opened = pcall(tryOpenChest, chest, prompt, true, routeCanRun)
                    if not openOk then
                        warn("[SEA Auto Chest Open] " .. tostring(opened))
                        if chestStates[chest] == "opening" then setChestState(chest, "retry") end
                        chestRuntime.retryAt[chest] = os.clock() + 4
                    end
                    task.wait(openOk and opened and 0.06 or 0.2)
                else
                    -- An empty live cache is not an empty world under StreamingEnabled.
                    -- Walk the authoritative DistantIslands coordinates continuously;
                    -- each probe streams that area and DescendantAdded fills the cache.
                    local root = getHumanoidRootPart()
                    local anchors = Travel and Travel.GetSearchAnchors()
                        or WorldLoot.GetSearchAnchors(root and root.Position)
                    if root and #anchors > 0 and Config:Get("FlyEnabled") ~= true then
                        searchCursor = searchCursor + 1
                        if searchCursor > #anchors then searchCursor = 1 end
                        ChestLoot.SetStatus("Scanning island " .. searchCursor .. "/" .. #anchors
                            .. "; route remains ON.", "Auto Chest + Loot")
                        WorldLoot.ProbeSearchArea(anchors[searchCursor].position, routeCanRun)
                        task.wait(0.04)
                    else
                        -- Respawn, Fly, or a temporarily unavailable map never kills
                        -- the worker; it resumes automatically when conditions recover.
                        task.wait(0.45)
                    end
                end
            end
        end, function(message)
            return tostring(message)
        end)

        if not workerOk then
            warn("[SEA Auto Chest Worker] " .. tostring(workerError))
        end

        if generation == chestRouteGeneration then
            chestRouteRunning = false
            if scriptAlive and autoOpenAfterTeleport and continueChestRoute then
                task.delay(0.35, runChestRoute)
            end
        end
    end)
end

local function teleportToSelectedChest()
    if autoOpenAfterTeleport and continueChestRoute then
        runChestRoute()
        return
    end

    local chest, prompt = teleportToNextChest()
    if chest and autoOpenAfterTeleport then
        task.spawn(function()
            tryOpenChest(chest, prompt)
        end)
    end
end

local function teleportToBonfire()
    local rootPart = getHumanoidRootPart()
    local bonfire = findNamedTarget("Bonfire", true)
    local bonfirePart = getTargetPart(bonfire, "Part")

    if rootPart and bonfirePart then
        interruptAutomationMovement()
        if not teleportPlayer(rootPart, bonfirePart.CFrame + Vector3.new(0, 3, 2)) then return end
        notify("Teleported", "Teleported to Bonfire", 2)
    else
        notify("Error", "Bonfire not found", 2)
    end
end

local function teleportToMerchant()
    local rootPart = getHumanoidRootPart()
    local merchant = findNamedModel("Merchant")
    local merchantRootPart = merchant and merchant:FindFirstChild("HumanoidRootPart")

    if rootPart and merchantRootPart then
        interruptAutomationMovement()
        if not teleportPlayer(rootPart, merchantRootPart.CFrame + Vector3.new(0, 3, 2)) then return end
        notify("Teleported", "Teleported to Merchant", 2)
    else
        notify("Error", "Merchant is not spawned yet", 2)
    end
end

local function teleportToFisherman()
    local rootPart = getHumanoidRootPart()
    local islandContainer = workspace:FindFirstChild("IslandContainer")
    local tutorialIsland = islandContainer and islandContainer:FindFirstChild("TutorialIsland")
    local fisherman = tutorialIsland and tutorialIsland:FindFirstChild("Fisherman")
    local fishermanRootPart

    if fisherman and fisherman:IsA("Model") then
        fishermanRootPart = fisherman:FindFirstChild("HumanoidRootPart")
    end

    if rootPart and fishermanRootPart then
        interruptAutomationMovement()
        if not teleportPlayer(rootPart, fishermanRootPart.CFrame + Vector3.new(0, 3, 2)) then return end
        notify("Teleported", "Teleported to Fisherman", 2)
    else
        notify("Error", "Fisherman not found", 2)
    end
end


-- Bring-item feature --------------------------------------------------------

local selectedBringItems = Config:Get("BringItems")

local function forEachItemModel(callback)
    local debrisField = workspace:FindFirstChild("DebrisField")
    if not debrisField then
        return
    end

    for _, item in ipairs(debrisField:GetChildren()) do
        if item:IsA("Model") or item:IsA("Tool") or item:IsA("BasePart") then
            callback(item)
        end
    end
end

local function bringSelectedItems()
    local rootPart = getHumanoidRootPart()
    if not rootPart then
        notify("Error", "HumanoidRootPart not found", 2)
        return
    end
    if not SharedInteraction.TryAcquire("bring") then
        notify("Bring Items", "Another item automation is busy; try again in a moment", 2)
        return
    end

    local confirmedCount = 0
    local attemptedCount = 0
    local unownedCount = 0

    local scanOk, scanError = pcall(function()
        forEachItemModel(function(item)
        SharedInteraction.Touch("bring")
        if ChestLoot.Matches(item, selectedBringItems) then
            local part = item:IsA("BasePart") and item or getTargetPart(item)
            if not part or part.Anchored then
                return
            end

            attemptedCount = attemptedCount + 1
            local ownershipKnown = false
            local ownsPart = true
            if typeof(isnetworkowner) == "function" then
                local ok, result = pcall(isnetworkowner, part)
                if ok then
                    ownershipKnown = true
                    ownsPart = result == true
                end
            end

            if ownershipKnown and not ownsPart then
                unownedCount = unownedCount + 1
                return
            end

            local destination = rootPart.CFrame + Vector3.new(
                math.random(-4, 4),
                math.random(1, 4),
                math.random(-4, 4)
            )
            local moved = pcall(function()
                for _ = 1, 3 do
                    if not item.Parent or not part.Parent then break end
                    if item:IsA("Model") then
                        item:PivotTo(destination)
                    else
                        part.CFrame = destination
                    end
                    part.AssemblyLinearVelocity = Vector3.zero
                    part.AssemblyAngularVelocity = Vector3.zero
                    task.wait(0.05)
                end
            end)

            if moved then
                task.wait(0.18)
                if part.Parent and (part.Position - rootPart.Position).Magnitude <= 12 then
                    confirmedCount = confirmedCount + 1
                end
            end
        end
        end)
    end)

    SharedInteraction.Release("bring")
    if not scanOk then
        warn("[SEA Bring] " .. tostring(scanError))
        notify("Bring Items", "Bring scan stopped after an internal error", 2.5)
        return
    end

    if confirmedCount > 0 then
        local detail = "Confirmed " .. confirmedCount .. " items near you"
        if unownedCount > 0 then
            detail = detail .. "; " .. unownedCount .. " server-owned skipped"
        end
        notify("Bring Complete", detail, 3)
    elseif attemptedCount > 0 then
        notify(
            "Bring Unconfirmed",
            unownedCount > 0
                and "Selected items are server-owned / position did not persist"
                or "Position changes did not remain near the player",
            3
        )
    else
        notify("Error", "No matching movable items found", 2)
    end
end


-- v37 automation: native-travel loot, Bonfire acquisition, Grinder, crafting, world search --
-- Auto Loot no longer teleports/magnets items themselves; the player travels into native interaction range.
-- These routines use the actual client contracts recovered from The Sea(2):
--   * Bonfire fuel is physically delivered to SpawnIsland.Dropper.
--   * Grinder resources are physically delivered to Grinder.Collection.
--   * Item movement uses DragSystem's AttemptDrag/GiveUpOwnership pair.
--   * Crafting uses _G.Craft / Network:InvokeServer("Craft", itemName).
--   * Eating uses DragSystem.Network:FireServer("Eat", itemName).

local Automation: any = (function()
    local autoBonfireEnabled = false
    local autoGrinderEnabled = false
    local autoCraftEnabled = false
    local autoEatEnabled = false

    local bonfireGeneration = 0
    local grinderGeneration = 0
    local craftGeneration = 0
    local craftWorkerRunning = false
    local craftingCursor = 0
    local pendingCraft = {}
    local craftBackoff = {}
    local CRAFT_CONCURRENCY = 4
    local builderOwnsOutpost = false
    local craftStatus = "Off"
    local eatGeneration = 0
    local stationBusy = false
    local stationBusySince = 0
    local stationBusyHolder
    local stationBlockedUntil = setmetatable({}, { __mode = "k" })
    local stationNextSearchAt: { [string]: any } = { bonfire = 0, grinder = 0 }
    local stationWorkerRunning: { [string]: any } = { bonfire = false, grinder = false }
    local stationWorkerPulseAt: { [string]: any } = { bonfire = 0, grinder = 0 }
    local stationWorkerThreads: { [string]: any } = {}
    local stationRuntime: { [string]: any } = {
        bonfire = { phase = "off", message = "Off", progressAt = 0, cursor = 0, sweeps = 0 },
        grinder = { phase = "off", message = "Off", progressAt = 0, cursor = 0, sweeps = 0 },
    }
    local activeStationSearchProbe
    local activeStationDropHover
    local beginStationSearchProbe
    local stationSupervisorRunning = false

    local function setStationBusy(value, force)
        local holder = coroutine.running()
        if value ~= true and force ~= true and stationBusyHolder ~= holder then return end
        stationBusy = value == true
        stationBusySince = stationBusy and os.clock() or 0
        stationBusyHolder = stationBusy and holder or nil
    end

    local function stationCanRun(kind, generation, movementToken)
        if not scriptAlive or Config:Get("FlyEnabled") == true
            or Config:Get("AutoLootWorld") == true
            or (movementToken ~= nil and getMovementRevision() ~= movementToken)
        then
            return false
        end
        local root = getHumanoidRootPart()
        local humanoid = getHumanoid()
        if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then return false end
        if kind == "bonfire" then
            if not autoBonfireEnabled or (generation ~= nil and generation ~= bonfireGeneration) then
                return false
            end
            local island = workspace:FindFirstChild("SpawnIsland")
            return not island or (tonumber(island:GetAttribute("Level")) or 1) < 7
        end
        return autoGrinderEnabled and (generation == nil or generation == grinderGeneration)
    end

    local function stationStatus(kind, phase, message, progressed)
        local state = stationRuntime[kind]
        state.phase, state.message = phase, message
        stationWorkerPulseAt[kind] = os.clock()
        if progressed then state.progressAt = os.clock() end
    end

    local function recoverStaleStationBusy()
        if not stationBusy then return false end
        -- Step cannot overlap an earlier operation on the SAME coroutine. If it
        -- re-enters with busy still set, the earlier operation threw before cleanup.
        -- Do not use the loop pulse here: Step just refreshed it, hiding this leak.
        local sameWorker = stationBusyHolder == coroutine.running()
        local stale = os.clock() - stationBusySince >= 12
            and (SharedInteraction.holder ~= stationBusyHolder
                or os.clock() - SharedInteraction.touchedAt >= 12)
        if not sameWorker and not stale then return false end
        warn("[SEA Station Recovery] releasing stale busy state")
        local holder = stationBusyHolder
        setStationBusy(false, true)
        if holder and SharedInteraction.holder == holder then
            ChestLoot.RecoverInteraction(holder)
            SharedInteraction.Release("station", true)
            SharedInteraction.Release("station-search", true)
            SharedInteraction.Release("station-drop", true)
        end
        if activeStationSearchProbe then activeStationSearchProbe:Stop() end
        if activeStationDropHover then activeStationDropHover:Stop() end
        return true
    end

    local bonfireToggleControl
    local grinderToggleControl

    local cachedDragSystem
    local cachedCraftingItems
    local cachedRigCrafting
    local craftingByName = {}
    local craftingNames = { "All" }

    -- Conventional guns in this place keep their current magazine in the first
    -- upvalue shared by Fire/Restock/Reload. Reserve ammo and Sack contents remain
    -- server-owned; this feature only prevents the compatible client magazine from
    -- reaching zero. Everything is capability-checked so unsupported executors or
    -- special server-driven weapons keep their native behavior.
    local unlimitedAmmoEnabled = false
    local unlimitedAmmoGeneration = 0
    local unlimitedAmmoToggleControl
    local unlimitedAmmoPatches = setmetatable({}, { __mode = "k" })
    local UNLIMITED_MAGAZINE_VALUE = 999

    local function executorFunction(name)
        local value = type(globalEnvironment) == "table" and globalEnvironment[name] or nil
        if typeof(value) ~= "function" and typeof(getfenv) == "function" then
            local ok, currentEnvironment = pcall(getfenv)
            if ok and type(currentEnvironment) == "table" then
                value = currentEnvironment[name]
            end
        end
        return typeof(value) == "function" and value or nil
    end

    local function resolveUpvalueReader()
        if type(debug) == "table" and typeof(debug.getupvalue) == "function" then
            return debug.getupvalue, false
        end
        local singleReader = executorFunction("getupvalue")
        if singleReader then
            return singleReader, false
        end
        if type(debug) == "table" and typeof(debug.getupvalues) == "function" then
            return debug.getupvalues, true
        end
        local allReader = executorFunction("getupvalues")
        if allReader then
            return allReader, true
        end
        return nil, false
    end

    local function resolveUpvalueWriter()
        if type(debug) == "table" and typeof(debug.setupvalue) == "function" then
            return debug.setupvalue
        end
        return executorFunction("setupvalue")
    end

    local function readClosureUpvalue(closure, index)
        local reader, readsAll = resolveUpvalueReader()
        if not reader then return false, nil end
        local ok, first, second
        if readsAll then
            ok, first, second = pcall(reader, closure)
        else
            ok, first, second = pcall(reader, closure, index)
        end
        if not ok then return false, nil end
        if readsAll then
            if type(first) ~= "table" then return false, nil end
            return true, first[index]
        end
        -- Standard Lua returns name,value; common executors return value only.
        return true, second ~= nil and second or first
    end

    local function writeClosureUpvalue(closure, index, value)
        local writer = resolveUpvalueWriter()
        if not writer then return false end
        return pcall(writer, closure, index, value)
    end

    local function ammoPatchSupported()
        local reader = resolveUpvalueReader()
        return executorFunction("getsenv") ~= nil
            and reader ~= nil
            and resolveUpvalueWriter() ~= nil
    end

    local function patchAmmoLocalScript(localScript)
        local existing = unlimitedAmmoPatches[localScript]
        if existing then
            return writeClosureUpvalue(
                existing.closure,
                existing.index,
                UNLIMITED_MAGAZINE_VALUE
            )
        end

        local getScriptEnvironment = executorFunction("getsenv")
        if not getScriptEnvironment then return false end
        local envOk, environment = pcall(getScriptEnvironment, localScript)
        if not envOk or type(environment) ~= "table" then return false end

        local fire = rawget(environment, "Fire")
        local restock = rawget(environment, "Restock")
        local reload = rawget(environment, "Reload")
        local mouseDown = rawget(environment, "MouseDown")
        if type(fire) ~= "function"
            or type(restock) ~= "function"
            or type(reload) ~= "function"
            or type(mouseDown) ~= "function"
        then
            return false
        end

        local readOk, currentMagazine = readClosureUpvalue(fire, 1)
        if not readOk or type(currentMagazine) ~= "number" then return false end
        if not writeClosureUpvalue(fire, 1, UNLIMITED_MAGAZINE_VALUE) then return false end

        unlimitedAmmoPatches[localScript] = {
            closure = fire,
            index = 1,
            -- A LocalScript still in Backpack may not have run Init yet (-1).
            -- Restoring zero is safe: the native next shot invokes Reload.
            original = math.max(0, currentMagazine),
            updateUi = rawget(environment, "UpdateUI"),
        }
        local updateUi = unlimitedAmmoPatches[localScript].updateUi
        if type(updateUi) == "function" then pcall(updateUi) end
        return true
    end

    local function patchAvailableAmmoTools()
        local patched = 0
        local function scanContainer(container)
            if not container then return end
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool")
                    and (
                        type(tool:GetAttribute("AmmoType")) == "string"
                        or tool:GetAttribute("IsGun") == true
                    )
                then
                    for _, descendant in ipairs(tool:GetDescendants()) do
                        if descendant:IsA("LocalScript") and patchAmmoLocalScript(descendant) then
                            patched = patched + 1
                        end
                    end
                end
            end
        end

        scanContainer(localPlayer:FindFirstChildOfClass("Backpack"))
        scanContainer(getCharacter())
        return patched
    end

    local function restoreAmmoPatches()
        for localScript, patch in pairs(unlimitedAmmoPatches) do
            if patch.closure then
                writeClosureUpvalue(patch.closure, patch.index, patch.original)
            end
            if type(patch.updateUi) == "function" then pcall(patch.updateUi) end
            unlimitedAmmoPatches[localScript] = nil
        end
    end

    local function startUnlimitedAmmoWorker()
        local expectedGeneration = unlimitedAmmoGeneration
        task.spawn(function()
            local foundCompatibleWeapon = false
            local noticeDeadline = os.clock() + 1.2
            while scriptAlive
                and unlimitedAmmoEnabled
                and expectedGeneration == unlimitedAmmoGeneration
            do
                if patchAvailableAmmoTools() > 0 then
                    foundCompatibleWeapon = true
                elseif not foundCompatibleWeapon and os.clock() >= noticeDeadline then
                    foundCompatibleWeapon = true
                    notify(
                        "Unlimited Ammo",
                        "Enabled; equip a compatible magazine weapon to patch it",
                        2.5
                    )
                end
                task.wait(0.08)
            end
        end)
    end

    -- Raygun and the heat/cooldown weapons do not use the conventional numeric
    -- magazine above. Their LocalScripts gate input with CanFire or a debounce,
    -- but the actual shot still goes through the server ToolReplicator. Calling
    -- the equipped script's Fire closure directly is the least invasive client
    -- bypass: no global metamethod hook, no permanent attribute spoof, and all
    -- excess calls remain subject to whatever rate validation the server uses.
    local rapidFireState: any = {
        enabled = false,
        generation = 0,
        held = false,
        toggleControl = nil,
        laserTool = nil,
        cache = setmetatable({}, { __mode = "k" }),
        inFlight = setmetatable({}, { __mode = "k" }),
        nextShotAt = setmetatable({}, { __mode = "k" }),
        warned = setmetatable({}, { __mode = "k" }),
        profiles = {
            Raygun = { mode = "closure", interval = 0.06, maxInFlight = 4 },
            Minigun = { mode = "closure", interval = 0.055, maxInFlight = 3 },
            ["Corrupt Minigun"] = { mode = "closure", interval = 0.055, maxInFlight = 3 },
            ["Void Slicer"] = { mode = "closure", interval = 0.055, maxInFlight = 3 },
            ["Magma Staff"] = { mode = "closure", interval = 0.08, maxInFlight = 3 },
            ["Wizard Staff"] = { mode = "closure", interval = 0.08, maxInFlight = 3 },
            ["Squid Laser"] = { mode = "laser", interval = 0.03, maxInFlight = 3 },
        },
    }

    local function rapidFireTrigger(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.KeyCode == Enum.KeyCode.ButtonR2
        then
            return true
        end
        if input.UserInputType == Enum.UserInputType.Touch then
            local camera = workspace.CurrentCamera
            return camera ~= nil and input.Position.X > camera.ViewportSize.X / 3
        end
        return false
    end

    local function getEquippedRapidFireTool()
        local character = getCharacter()
        if not character then return nil end
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") and rapidFireState.profiles[child.Name] then
                return child
            end
        end
        return nil
    end

    local function getRapidFireClosure(tool)
        local cached = rapidFireState.cache[tool]
        if cached
            and cached.localScript
            and cached.localScript.Parent
            and type(cached.fire) == "function"
        then
            return cached.fire
        end

        local getScriptEnvironment = executorFunction("getsenv")
        if not getScriptEnvironment then return nil end
        for _, descendant in ipairs(tool:GetDescendants()) do
            if descendant:IsA("LocalScript") then
                local ok, environment = pcall(getScriptEnvironment, descendant)
                local fire = ok and type(environment) == "table"
                    and rawget(environment, "Fire")
                    or nil
                if type(fire) == "function" then
                    rapidFireState.cache[tool] = {
                        localScript = descendant,
                        fire = fire,
                    }
                    return fire
                end
            end
        end
        return nil
    end

    local function rapidFireAimPosition(tool, distance)
        local camera = workspace.CurrentCamera
        if not camera then return nil end
        local mousePosition = UserInputService:GetMouseLocation()
        local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { getCharacter(), tool }
        params.IgnoreWater = false
        local result = workspace:Raycast(ray.Origin, ray.Direction * distance, params)
        return result and result.Position or (ray.Origin + ray.Direction * distance)
    end

    local function endRapidFireLaser()
        if not rapidFireState.laserTool then return end
        rapidFireState.laserTool = nil
        task.spawn(function()
            if type(_G.ToolProcessor) == "function" then
                pcall(function() _G.ToolProcessor("Laser", "End") end)
            end
        end)
    end

    local function warnRapidFireFailure(tool, message)
        if rapidFireState.warned[tool] then return end
        rapidFireState.warned[tool] = true
        notify("Rapid Fire", message, 2.5)
    end

    local function fireRapidWeapon(tool)
        local profile = rapidFireState.profiles[tool.Name]
        if not profile then return end

        local now = os.clock()
        if now < (rapidFireState.nextShotAt[tool] or 0) then return end
        local inFlight = rapidFireState.inFlight[tool] or 0
        if inFlight >= profile.maxInFlight then return end

        local fire
        local payload
        if profile.mode == "closure" then
            fire = getRapidFireClosure(tool)
            if not fire then
                rapidFireState.nextShotAt[tool] = now + 0.5
                warnRapidFireFailure(tool, tool.Name .. " client Fire closure is not ready")
                return
            end
            payload = { Position = UserInputService:GetMouseLocation() }
        else
            payload = rapidFireAimPosition(tool, 200)
            if not payload then return end
            rapidFireState.laserTool = tool
        end

        rapidFireState.nextShotAt[tool] = now + profile.interval
        rapidFireState.inFlight[tool] = inFlight + 1
        task.spawn(function()
            local ok, err
            if profile.mode == "closure" then
                ok, err = pcall(fire, payload)
            else
                ok, err = pcall(function()
                    tool:Activate()
                    if type(_G.ToolProcessor) ~= "function" then
                        error("ToolProcessor is unavailable")
                    end
                    _G.ToolProcessor("Laser", "Shoot", payload)
                end)
            end
            rapidFireState.inFlight[tool] = math.max(
                0,
                (rapidFireState.inFlight[tool] or 1) - 1
            )
            if not ok then
                warnRapidFireFailure(tool, tool.Name .. " direct fire failed: " .. tostring(err))
            end
        end)
    end

    local function startRapidFireWorker()
        local expectedGeneration = rapidFireState.generation
        task.spawn(function()
            while scriptAlive
                and rapidFireState.enabled
                and expectedGeneration == rapidFireState.generation
            do
                local tool = getEquippedRapidFireTool()
                if rapidFireState.laserTool and rapidFireState.laserTool ~= tool then
                    endRapidFireLaser()
                end
                if rapidFireState.held
                    and not UserInputService:GetFocusedTextBox()
                    and tool
                then
                    fireRapidWeapon(tool)
                elseif rapidFireState.laserTool then
                    endRapidFireLaser()
                end
                task.wait(0.015)
            end
            endRapidFireLaser()
        end)
    end

    connect(UserInputService.InputBegan, function(input, processed)
        if rapidFireState.enabled and not processed and rapidFireTrigger(input) then
            rapidFireState.held = true
        end
    end)

    connect(UserInputService.InputEnded, function(input)
        if rapidFireTrigger(input) then
            rapidFireState.held = false
            endRapidFireLaser()
        end
    end)

    local function getDragSystem()
        if cachedDragSystem and cachedDragSystem.Network then
            return cachedDragSystem
        end

        local modules = ReplicatedStorage:FindFirstChild("Modules")
        local systems = modules and modules:FindFirstChild("Systems")
        local moduleScript = systems and systems:FindFirstChild("DragSystem")
        if not moduleScript then
            return nil
        end

        local success, result = pcall(require, moduleScript)
        if success and type(result) == "table" then
            cachedDragSystem = result
            return result
        end
        return nil
    end

    local function loadCraftingItems()
        if cachedCraftingItems then
            return cachedCraftingItems
        end

        local modules = ReplicatedStorage:FindFirstChild("Modules")
        local dataFolder = modules and modules:FindFirstChild("Data")
        local moduleScript = dataFolder and dataFolder:FindFirstChild("CraftingItems")
        if not moduleScript then
            return {}
        end

        local success, definitions = pcall(require, moduleScript)
        if not success or type(definitions) ~= "table" then
            return {}
        end

        cachedCraftingItems = definitions
        craftingByName = {}
        craftingNames = { "All" }
        for _, definition in ipairs(definitions) do
            if type(definition) == "table"
                and type(definition.ItemName) == "string"
                and definition.ItemName ~= ""
                and not definition.hidden
            then
                craftingByName[definition.ItemName] = definition
                craftingNames[#craftingNames + 1] = definition.ItemName
            end
        end
        table.sort(craftingNames, function(left, right)
            if left == "All" then return true end
            if right == "All" then return false end
            return string.lower(left) < string.lower(right)
        end)
        return cachedCraftingItems
    end

    loadCraftingItems()

    local function getRigCrafting()
        if cachedRigCrafting then
            return cachedRigCrafting
        end
        local modules = ReplicatedStorage:FindFirstChild("Modules")
        local systems = modules and modules:FindFirstChild("Systems")
        local moduleScript = systems and systems:FindFirstChild("RigCrafting")
        if not moduleScript then
            return nil
        end
        local success, result = pcall(require, moduleScript)
        if success and type(result) == "table" then
            cachedRigCrafting = result
            return result
        end
        return nil
    end

    local function getCraftStockValue(itemName)
        local modules = ReplicatedStorage:FindFirstChild("Modules")
        local dataFolder = modules and modules:FindFirstChild("Data")
        local craftingModule = dataFolder and dataFolder:FindFirstChild("CraftingItems")
        local stockValue = craftingModule and craftingModule:FindFirstChild(itemName)
        if stockValue and stockValue:IsA("ValueBase") then
            local success, value = pcall(function() return stockValue.Value end)
            if success and type(value) == "number" then
                return value
            end
        end
        return nil
    end

    local function pruneCraftRequests()
        local count = 0
        for request in pairs(pendingCraft) do
            if request.done and os.clock() >= request.releaseAt then
                pendingCraft[request] = nil
            else
                count = count + 1
            end
        end
        return count
    end

    local function canAffordCraft(definition)
        pruneCraftRequests()
        if type(definition) ~= "table" then
            return false, "Recipe has not replicated yet"
        end

        local spawnIsland = workspace:FindFirstChild("SpawnIsland")
        local level = spawnIsland and tonumber(spawnIsland:GetAttribute("Level")) or 1
        if tonumber(definition.RigLevel) and level < tonumber(definition.RigLevel) then
            return false, "Requires bonfire level " .. tostring(definition.RigLevel)
        end

        if definition.classOnly ~= nil
            and localPlayer:GetAttribute("Class") ~= definition.classOnly
        then
            return false, "Requires class " .. tostring(definition.classOnly)
        end

        -- Mirror RigCrafting's client visibility/eligibility checks so Auto Craft
        -- does not hammer recipes that the normal crafting UI considers locked.
        if definition.requiresUnlock then
            local rigCrafting = getRigCrafting()
            if not rigCrafting
                or type(rigCrafting.unlocked) ~= "table"
                or rigCrafting.unlocked[definition.ItemName] ~= true
            then
                return false, "Recipe is locked; find the unlock first"
            end
        end
        if (workspace:GetAttribute("ChallengeTier") or 0) >= 5
            and definition.ItemName == "Map Radar"
        then
            return false, "Map Radar is disabled in this challenge tier"
        end

        local stock = getCraftStockValue(definition.ItemName)
        local reservedStock = 0
        for request in pairs(pendingCraft) do
            if request.itemName == definition.ItemName then reservedStock = reservedStock + 1 end
        end
        if stock ~= nil and stock - reservedStock <= 0 then
            return false, "Waiting for crafting stock"
        end

        local discount = math.clamp(tonumber(localPlayer:GetAttribute("CraftDiscount")) or 0, 0, 0.9)
        for resourceName, required in pairs(definition.Recipe or {}) do
            if type(required) == "number" and required > 0 then
                required = math.floor(required * (1 - discount))
                local owned = tonumber(workspace:GetAttribute(resourceName)) or 0
                for request in pairs(pendingCraft) do
                    owned = owned - (request.cost[resourceName] or 0)
                end
                if owned < required then
                    return false, "Need " .. resourceName .. " " .. tostring(owned) .. "/" .. tostring(required)
                end
            end
        end
        return true
    end

    local function queueCraft(definition, canContinue, builderRequest)
        if not definition then return nil, "Recipe has not replicated yet" end
        local itemName = definition.ItemName
        if not scriptAlive or (canContinue and not canContinue()) then return nil, "Cancelled" end
        local laneLimit = builderOwnsOutpost and not builderRequest and CRAFT_CONCURRENCY - 1 or CRAFT_CONCURRENCY
        if pruneCraftRequests() >= laneLimit then return nil, "Craft pipeline is full" end
        local backoff = craftBackoff[itemName]
        if backoff and os.clock() < backoff.untilAt then return nil, "Waiting after server craft rejection" end
        -- Outpost is unique and is consumed by a dependent placement step.
        -- Other recipes can fill up to four lanes, bounded by reserved materials.
        if itemName == "Outpost" then
            for request in pairs(pendingCraft) do
                if request.itemName == itemName then return nil, "Waiting for Outpost craft response" end
            end
        end
        local affordable, reason = canAffordCraft(definition)
        if not affordable then return nil, reason end
        local nativeCraft = type(_G.Craft) == "function" and _G.Craft or nil
        local network = not nativeCraft and getGameNetwork() or nil
        if not nativeCraft and not network then return nil, "Craft network is not ready" end
        local cost = {}
        local discount = math.clamp(tonumber(localPlayer:GetAttribute("CraftDiscount")) or 0, 0, 0.9)
        for resourceName, amount in pairs(definition.Recipe or {}) do
            if type(amount) == "number" and amount > 0 then cost[resourceName] = math.floor(amount * (1 - discount)) end
        end
        local request = { done = false, success = false, itemName = itemName, cost = cost, releaseAt = math.huge }
        pendingCraft[request] = true
        task.spawn(function()
            local ok, result = pcall(function()
                if not scriptAlive or (canContinue and not canContinue()) then return false end
                if nativeCraft then return nativeCraft(itemName) end
                return network:InvokeServer("Craft", itemName)
            end)
            request.success = ok and result == true
            request.done = true
            -- Briefly retain reservations so replicated resource/stock changes can
            -- catch up with the reply. Never release a timed-out, unresolved call.
            request.releaseAt = os.clock() + 0.05
            if request.success then
                craftBackoff[itemName] = nil
                if canContinue == nil or canContinue() then craftStatus = "Crafted " .. itemName end
            else
                local failures = math.min(5, (craftBackoff[itemName] and craftBackoff[itemName].failures or 0) + 1)
                craftBackoff[itemName] = { failures = failures, untilAt = os.clock() + math.min(2, 0.1 * 2^(failures - 1)) }
            end
        end)
        return request, "Crafting " .. itemName
    end

    local function invokeCraft(itemName, canContinue)
        loadCraftingItems()
        local request, reason = queueCraft(craftingByName[itemName], canContinue, true)
        if not request then return false, reason end
        local deadline = os.clock() + 6
        while not request.done do
            if not scriptAlive or (canContinue and not canContinue()) then return false, "Cancelled" end
            if os.clock() >= deadline then return false, "Waiting for previous craft response" end
            RunService.Heartbeat:Wait()
        end
        return request.success, request.success and "Crafted " .. itemName or "Server declined craft"
    end

    local function craftStep(generation)
        local selected = firstSelectedValue(Config:Get("AutoCraftItem")) or "All"
        local function canRun()
            return scriptAlive and autoCraftEnabled and generation == craftGeneration
                and selected == (firstSelectedValue(Config:Get("AutoCraftItem")) or "All")
        end
        local crafted = 0
        if pruneCraftRequests() >= CRAFT_CONCURRENCY then
            craftStatus = "Crafting: 4 requests in flight"
            return 0
        end
        craftStatus = "Waiting for eligible recipes / resources"
        local definitions = loadCraftingItems()
        for offset = 1, #definitions do
            if not canRun() then break end
            local index = selected == "All" and (craftingCursor % #definitions + 1) or offset
            if selected == "All" then craftingCursor = index end
            local definition = definitions[index]
            if type(definition) == "table"
                and not definition.hidden
                and type(definition.ItemName) == "string"
                and (selected == "All" or selected == definition.ItemName)
                and not (builderOwnsOutpost and definition.ItemName == "Outpost")
            then
                repeat
                    local request, result = queueCraft(definition, canRun)
                    craftStatus = result
                    if not request then break end
                    crafted = crafted + 1
                until selected == "All" or crafted >= CRAFT_CONCURRENCY or not canRun()
                if selected ~= "All" then
                    break
                end
                if crafted >= CRAFT_CONCURRENCY then
                    break
                end
            end
        end

        return crafted
    end

    local foodBlockedUntil = setmetatable({}, { __mode = "k" })

    local function findFoodInteractable(rawItem)
        local current = rawItem
        for _ = 1, 12 do
            if not current or current == workspace then
                break
            end
            if CollectionService:HasTag(current, "Interactable")
                and tonumber(current:GetAttribute("Food")) ~= nil
            then
                return current
            end
            current = current.Parent
        end
        return nil
    end

    local function findNearestFoodInteractable()
        local root = getHumanoidRootPart()
        if not root then return nil end

        local nearest
        local nearestDistance = math.huge
        local seen = setmetatable({}, { __mode = "k" })
        local function consider(rawItem)
            local item = findFoodInteractable(rawItem)
            if not item or seen[item] or not item.Parent then return end
            if not item:IsDescendantOf(workspace) then return end
            seen[item] = true
            if foodBlockedUntil[item] and os.clock() < foodBlockedUntil[item] then return end
            if DropManager
                and type(DropManager.ShouldIgnoreCandidate) == "function"
                and DropManager.ShouldIgnoreCandidate(item)
            then
                return
            end

            local part = item:IsA("BasePart") and item
                or (item:IsA("Model") and item.PrimaryPart)
                or item:FindFirstChildWhichIsA("BasePart", true)
            if not part then return end

            local distance = (part.Position - root.Position).Magnitude
            -- DragSystem.checkForTarget() is a close-range interaction. Do not
            -- consume arbitrary food from across the whole map.
            if distance <= 24 and distance < nearestDistance then
                nearest = item
                nearestDistance = distance
            end
        end

        for _, tagged in ipairs(CollectionService:GetTagged("Interactable")) do
            consider(tagged)
        end
        forEachItemModel(consider)
        return nearest
    end

    local function eatOne()
        local foodLevel = tonumber(localPlayer:GetAttribute("Food")) or 100
        local threshold = tonumber(Config:Get("EatThreshold")) or 60
        if foodLevel >= threshold then
            return false, "not-needed"
        end

        local foodItem = findNearestFoodInteractable()
        if not foodItem then
            return false, "no-nearby-food"
        end
        if not SharedInteraction.TryAcquire("eat") then
            return false, "interaction-busy"
        end
        local function finishEat(success, reason)
            SharedInteraction.Release("eat")
            return success, reason
        end

        local dragSystem = getDragSystem()
        local network = dragSystem and dragSystem.Network
        if not network or type(network.FireServer) ~= "function" then
            return finishEat(false, "network-unavailable")
        end

        local before = foodLevel
        -- This mirrors Food.luau exactly: DragSystem.Network:FireServer("Eat",
        -- v23.Name), where v23 is the Interactable ancestor carrying Food.
        local success = pcall(function()
            network:FireServer("Eat", foodItem.Name)
        end)
        if not success then
            foodBlockedUntil[foodItem] = os.clock() + 4
            return finishEat(false, "eat-remote-failed")
        end

        local deadline = os.clock() + 1.4
        repeat
            task.wait(0.1)
            local current = tonumber(localPlayer:GetAttribute("Food")) or before
            if current > before then
                foodBlockedUntil[foodItem] = nil
                return finishEat(true, foodItem:GetAttribute("Item") or foodItem.Name)
            end
        until not scriptAlive or not foodItem.Parent or os.clock() >= deadline

        foodBlockedUntil[foodItem] = os.clock() + 4
        return finishEat(false, "not-confirmed")
    end

    local function hasActiveGrabber(item)
        local current = item
        for _ = 1, 8 do
            if not current or current == workspace then break end
            local success, value = pcall(function() return current:GetAttribute("Grabber") end)
            if success and value ~= nil and value ~= false then
                return true
            end
            current = current.Parent
        end
        if item and (item:IsA("Model") or item:IsA("Folder") or item:IsA("Tool")) then
            for _, descendant in ipairs(item:GetDescendants()) do
                local success, value = pcall(function() return descendant:GetAttribute("Grabber") end)
                if success and value ~= nil and value ~= false then
                    return true
                end
            end
        end
        return false
    end

    local function getDraggablePart(item)
        if not item then return nil end
        if item:IsA("BasePart") then return item end
        if item:IsA("Model") and item.PrimaryPart then return item.PrimaryPart end
        return item:FindFirstChildWhichIsA("BasePart", true)
    end

    local function getTopInteractable(item)
        local current = item
        for _ = 1, 12 do
            if not current or current == workspace then break end
            if CollectionService:HasTag(current, "Interactable") then
                return current
            end
            current = current.Parent
        end
        return item
    end

    local function itemPosition(item)
        local part = getDraggablePart(item)
        if part then return part.Position end
        if item and item:IsA("Model") then
            local success, pivot = pcall(item.GetPivot, item)
            if success then return pivot.Position end
        end
        return nil
    end

    local function findNearestStationItem(predicate)
        local root = getHumanoidRootPart()
        if not root then return nil end

        local nearest
        local nearestDistance = math.huge
        local seen = setmetatable({}, { __mode = "k" })

        local function consider(rawItem)
            local item = getTopInteractable(rawItem)
            if not item or seen[item] or not item.Parent then return end
            if not item:IsDescendantOf(workspace) then return end
            seen[item] = true
            if DropManager.IsInsideBase(item) then return end
            if stationBlockedUntil[item] and os.clock() < stationBlockedUntil[item] then return end
            if DropManager
                and type(DropManager.ShouldIgnoreCandidate) == "function"
                and DropManager.ShouldIgnoreCandidate(item)
            then
                return
            end
            if hasActiveGrabber(item) or not predicate(item) then return end

            local position = itemPosition(item)
            if not position then return end
            local distance = (position - root.Position).Magnitude
            if distance < nearestDistance then
                nearest = item
                nearestDistance = distance
            end
        end

        -- Use the shared DebrisField registry so ReplicatedStorage templates can
        -- never become a station target and each pass stays bounded.
        for _, candidate in ipairs(ChestLoot.Candidates(root.Position, math.huge, true)) do
            consider(candidate)
        end
        return nearest
    end

    local function collectStationSearchAnchors(originPosition)
        local anchors = {}
        local seenCells = {}

        local function addPosition(position, label, stableKey, secondary)
            if typeof(position) ~= "Vector3" then return end
            if secondary then
                for _, anchor in ipairs(anchors) do
                    if (anchor.position - position).Magnitude < 100 then return end
                end
            end
            -- A 140-stud grid used to collapse distinct nearby islands. Preserve
            -- the shared catalog's IDs; only coalesce secondary debris/POI hints.
            local cell = stableKey or string.format("%d:%d",
                math.floor(position.X + 0.5), math.floor(position.Z + 0.5))
            if seenCells[cell] then return end
            seenCells[cell] = true
            anchors[#anchors + 1] = {
                position = position,
                label = label or "Area",
                key = cell,
            }
        end

        -- Map.luau renders islands from ReplicatedStorage.DistantIslands.
        -- Those proxy Parts contain CFrames for the whole generated map even
        -- when the physical island is currently outside StreamingTargetRadius.
        -- They are therefore the authoritative full-map search route.
        local hasCatalog = Travel and type(Travel.GetSearchAnchors) == "function"
        if hasCatalog then
            for _, anchor in ipairs(Travel.GetSearchAnchors()) do
                addPosition(anchor.position, anchor.id, anchor.id)
            end
        end
        local distantIslands = ReplicatedStorage:FindFirstChild("DistantIslands")
        if not hasCatalog and distantIslands then
            for _, marker in ipairs(distantIslands:GetChildren()) do
                if marker.Name ~= "Rig" then
                    if marker:IsA("BasePart") then
                        addPosition(marker.Position, "Map: " .. marker.Name)
                    elseif marker:IsA("Model") then
                        local success, pivot = pcall(marker.GetPivot, marker)
                        if success then
                            addPosition(pivot.Position, "Map: " .. marker.Name)
                        end
                    end
                end
            end
        end

        local islandContainer = workspace:FindFirstChild("IslandContainer")
        if not hasCatalog and islandContainer then
            for _, island in ipairs(islandContainer:GetChildren()) do
                if island:IsA("Model") then
                    local success, pivot = pcall(island.GetPivot, island)
                    if success then
                        addPosition(pivot.Position, island.Name)
                    end
                elseif island:IsA("BasePart") then
                    addPosition(island.Position, island.Name)
                end
            end
        end

        -- Chests and already-replicated debris are useful secondary streaming
        -- anchors for POIs whose island wrapper is currently streamed out. Cells
        -- are deduplicated above, so dense loot fields do not flood the route.
        for _, chest in ipairs(CollectionService:GetTagged("Chest")) do
            local part = getTargetPart(chest)
            if part then
                addPosition(part.Position, "Chest POI", nil, true)
            end
        end
        forEachItemModel(function(item)
            local position = itemPosition(item)
            if position then
                addPosition(position, "Debris", nil, true)
            end
        end)

        -- Keep route order deterministic so the teleport search cursor does not
        -- skip or repeat map cells when the player position changes.
        table.sort(anchors, function(left, right)
            if left.position.X ~= right.position.X then
                return left.position.X < right.position.X
            end
            if left.position.Z ~= right.position.Z then
                return left.position.Z < right.position.Z
            end
            return tostring(left.label) < tostring(right.label)
        end)
        return anchors
    end

    local stationStreamRequestsInFlight = 0
    local MAX_STATION_STREAM_REQUESTS_IN_FLIGHT = 2
    local function requestStreamAt(position, canContinue)
        if not localPlayer or typeof(position) ~= "Vector3" then return false end
        if stationStreamRequestsInFlight >= MAX_STATION_STREAM_REQUESTS_IN_FLIGHT then
            return false, "request-saturated"
        end

        local completed = false
        local succeeded = false
        stationStreamRequestsInFlight = stationStreamRequestsInFlight + 1
        task.spawn(function()
            succeeded = pcall(function()
                localPlayer:RequestStreamAroundAsync(position, 0.8)
            end)
            completed = true
            stationStreamRequestsInFlight = math.max(0, stationStreamRequestsInFlight - 1)
        end)

        local deadline = os.clock() + 1.05
        repeat
            if type(canContinue) == "function" then
                local ok, keepRunning = pcall(canContinue)
                if not ok or not keepRunning then
                    return false, "cancelled"
                end
            end
            RunService.Heartbeat:Wait()
        until completed or os.clock() >= deadline

        if not completed then
            return false, "timeout"
        end
        if succeeded then
            return true, nil
        end
        return false, "request-failed"
    end

    -- v43 critical restore: v42 switched search/drop back to the v39 teleport
    -- path but accidentally removed this local helper while leaving all calls to it.
    -- Because the station loops wrap Step() in pcall, that nil-global call was
    -- swallowed every tick and made Bonfire/Grinder look completely dead.
    -- Keep this helper lexically before searchStationWorld/dropAtStation.
    local function safeAutomationTeleport(targetCFrame, settleSeconds, canContinue)
        local root = getHumanoidRootPart()
        if not root or not root.Parent or typeof(targetCFrame) ~= "CFrame" then
            return false
        end
        if Config:Get("FlyEnabled") == true then
            return false
        end
        if type(canContinue) == "function" and not canContinue() then return false end

        -- Share the ownership-aware hold with search. Its synchronous Stop() also
        -- lets OFF/respawn clean up a teleport that is still settling, so an old
        -- cleanup cannot restore CanCollide over a newer worker's captured state.
        local probe = beginStationSearchProbe(targetCFrame, canContinue)
        if not probe then return false end
        local deadline = os.clock() + math.max(0.06, tonumber(settleSeconds) or 0.10)
        repeat
            RunService.Heartbeat:Wait()
            if not probe:Hold() then break end
        until os.clock() >= deadline
        probe:Stop()

        return root.Parent ~= nil
            and getHumanoidRootPart() == root
            and (type(canContinue) ~= "function" or canContinue())
            and (root.Position - targetCFrame.Position).Magnitude <= 8
    end

    -- v42 station DROP hover --------------------------------------------------
    -- Search and pickup no longer use flight. This controller exists only while a
    -- Sack is actively being emptied into Bonfire/Grinder. It replaces repeated
    -- CFrame corrections with a physics hold (BodyPosition + BodyGyro), so the rig
    -- and Sack emission point stay stable without teleport-spamming every DropItem.
    local stationDropHover = (function()
        local api = {}

        function api.Start(initialCFrame, movementToken)
            if typeof(initialCFrame) ~= "CFrame" then return nil, "bad-target" end
            local root = getHumanoidRootPart()
            local humanoid = getHumanoid()
            local character = getCharacter()
            if not root or not humanoid or not character then
                return nil, "character-missing"
            end
            if Config:Get("FlyEnabled") == true then
                return nil, "manual-fly-active"
            end
            if activeStationDropHover then activeStationDropHover:Stop() end

            local token = movementToken
            if token == nil then token = getMovementRevision() end
            local oldAutoRotate = humanoid.AutoRotate
            local oldPlatformStand = humanoid.PlatformStand
            local oldSit = humanoid.Sit
            local collisions = {}
            local position = Instance.new("BodyPosition")
            local gyro = Instance.new("BodyGyro")
            local alive = true

            for _, descendant in ipairs(character:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    collisions[#collisions + 1] = { descendant, descendant.CanCollide }
                    descendant.CanCollide = false
                end
            end

            humanoid.Sit = false
            humanoid.PlatformStand = true
            humanoid.AutoRotate = false
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero

            position.Name = "SEA_StationDropHoverPosition"
            position.MaxForce = Vector3.new(9e9, 9e9, 9e9)
            position.P = 85000
            position.D = 5000
            position.Position = initialCFrame.Position
            position.Parent = root

            gyro.Name = "SEA_StationDropHoverGyro"
            gyro.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
            gyro.P = 110000
            gyro.D = 1800
            gyro.CFrame = initialCFrame
            gyro.Parent = root

            local controller = {}

            function controller:IsAlive()
                return alive
                    and activeStationDropHover == self
                    and scriptAlive
                    and root.Parent ~= nil
                    and root == getHumanoidRootPart() and humanoid.Health > 0
                    and position.Parent ~= nil
                    and gyro.Parent ~= nil
                    and getMovementRevision() == token
            end

            function controller:SetTarget(targetCFrame)
                if not self:IsAlive() or typeof(targetCFrame) ~= "CFrame" then return false end
                position.Position = targetCFrame.Position
                gyro.CFrame = targetCFrame
                return true
            end

            function controller:WaitNear(targetCFrame, radius, timeout)
                return DropSafety.WaitStable(root, targetCFrame, function() return self:IsAlive() end,
                    tonumber(radius) or 0.45, 0.12, math.max(0.2, tonumber(timeout) or 0.6))
            end

            function controller:Nudge(delta)
                if not self:IsAlive() or typeof(delta) ~= "Vector3" then return false end
                position.Position = position.Position + delta
                return true
            end

            function controller:Stop()
                if not alive then return end
                alive = false
                pcall(function() position:Destroy() end)
                pcall(function() gyro:Destroy() end)
                if activeStationDropHover ~= self then return end
                activeStationDropHover = nil
                for _, entry in ipairs(collisions) do
                    local part = entry[1]
                    if part and part.Parent then
                        part.CanCollide = entry[2]
                    end
                end
                if root and root.Parent then
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end
                if humanoid and humanoid.Parent then
                    humanoid.AutoRotate = oldAutoRotate
                    humanoid.PlatformStand = oldPlatformStand and Config:Get("FlyEnabled") == true or false
                    humanoid.Sit = oldSit and Config:Get("FlyEnabled") == true or false
                    if Config:Get("FlyEnabled") ~= true then
                        humanoid.PlatformStand = false
                        humanoid.Sit = false
                        pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
                    end
                end
            end

            activeStationDropHover = controller
            controller:SetTarget(initialCFrame)
            return controller, nil
        end

        return api
    end)()

    -- v46 safe airborne station probe -----------------------------------------
    -- Same rule as World Loot: DistantIslands/Chest/Debris anchors are streaming
    -- coordinates, not guaranteed solid landing surfaces. Keep the rig anchored in
    -- safe air only while each area streams, then release before normal Sack pickup.
    local STATION_SCAN_SAFE_MIN_Y = 178
    local STATION_SCAN_MARKER_LIFT = 24

    local function stationSearchProbeCFrame(anchorPosition)
        local safeY = math.max(anchorPosition.Y + STATION_SCAN_MARKER_LIFT, STATION_SCAN_SAFE_MIN_Y)
        local position = Vector3.new(anchorPosition.X, safeY, anchorPosition.Z)
        return CFrame.lookAt(position, position + Vector3.new(0, 0, -1))
    end

    beginStationSearchProbe = function(targetCFrame, canContinue)
        local root = getHumanoidRootPart()
        local humanoid = getHumanoid()
        local character = getCharacter()
        if not root or not root.Parent or typeof(targetCFrame) ~= "CFrame" then return nil end
        if Config:Get("FlyEnabled") == true then return nil end
        if type(canContinue) == "function" and not canContinue() then return nil end
        if activeStationSearchProbe then activeStationSearchProbe:Stop() end

        local oldAnchored = root.Anchored
        local oldAutoRotate = humanoid and humanoid.AutoRotate
        local oldPlatformStand = humanoid and humanoid.PlatformStand
        local oldSit = humanoid and humanoid.Sit
        local collisions = {}
        local alive = true

        if character then
            for _, descendant in ipairs(character:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    collisions[#collisions + 1] = { descendant, descendant.CanCollide }
                    descendant.CanCollide = false
                end
            end
        end
        if humanoid then
            humanoid.Sit = false
            humanoid.PlatformStand = false
            humanoid.AutoRotate = false
        end
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.Anchored = true
        local controller = {}
        function controller:Hold()
            if not alive or activeStationSearchProbe ~= self or not root.Parent
                or getHumanoidRootPart() ~= root
                or (type(canContinue) == "function" and not canContinue())
            then return false end
            root.Anchored = true
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            if root.Position.Y < STATION_SCAN_SAFE_MIN_Y - 8
                or (root.Position - targetCFrame.Position).Magnitude > 8
            then
                return teleportPlayer(root, targetCFrame, function()
                    return alive and activeStationSearchProbe == self
                        and (type(canContinue) ~= "function" or canContinue())
                end)
            end
            return true
        end
        function controller:Stop()
            if not alive then return end
            alive = false
            -- Recovery stops this exact controller BEFORE another worker starts.
            -- A late old worker must never unanchor or restore a newer probe.
            if activeStationSearchProbe ~= self then return end
            activeStationSearchProbe = nil
            if root and root.Parent then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                root.Anchored = oldAnchored
            end
            for _, entry in ipairs(collisions) do
                local part = entry[1]
                if part and part.Parent then part.CanCollide = entry[2] end
            end
            if humanoid and humanoid.Parent then
                humanoid.AutoRotate = oldAutoRotate
                if Config:Get("FlyEnabled") ~= true then
                    humanoid.PlatformStand = false
                    humanoid.Sit = false
                    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
                else
                    humanoid.PlatformStand = oldPlatformStand
                    humanoid.Sit = oldSit
                end
            end
        end
        activeStationSearchProbe = controller
        if not teleportPlayer(root, targetCFrame, function()
            return alive and activeStationSearchProbe == controller
                and (type(canContinue) ~= "function" or canContinue())
        end) then controller:Stop(); return nil end
        if not controller:Hold() then controller:Stop(); return nil end
        task.wait(0.045)
        if not controller:Hold() then controller:Stop(); return nil end
        return controller
    end

    -- v51 bounded, persistent scanner. Each worker tick scans a short segment of
    -- one stable route snapshot. Returning after an empty segment is essential:
    -- the farm must be able to re-check Sack fullness, respawn and partial delivery.
    -- The worker, not an infinite nested search, repeats the route until OFF/MAX.
    local function searchStationWorld(predicate, kind, expectedGeneration, hasSelection)
        if Config:Get("StationWorldSearch") ~= true then
            return nil, "local-only", false
        end

        local root = getHumanoidRootPart()
        local movementToken = getMovementRevision()
        local function stationScannerCanRun()
            return stationCanRun(kind, expectedGeneration, movementToken)
                and getHumanoidRootPart() == root
                and Config:Get("StationWorldSearch") == true
                and (type(hasSelection) ~= "function" or hasSelection())
        end
        if not stationScannerCanRun() then return nil, "cancelled", false end
        local route = stationRuntime[kind]
        local mapSeed = tostring(localPlayer:GetAttribute("DisplaySeed") or "")
        local islandContainer = workspace:FindFirstChild("IslandContainer")
        if route.mapSeed ~= mapSeed
            or (route.container and islandContainer and route.container ~= islandContainer)
        then
            route.anchors, route.cursor, route.sweeps = nil, 0, 0
        end
        route.mapSeed, route.container = mapSeed, islandContainer
        if not route.anchors then
            local anchors = collectStationSearchAnchors(root.Position)
            if #anchors == 0 then
                stationStatus(kind, "waiting-map", "Waiting for island markers; retrying")
                return nil, "no-anchors", false
            end
            route.anchors, route.cursor = anchors, 0
        end

        local segmentDeadline = os.clock() + 6
        for _ = 1, 3 do
            if not stationScannerCanRun() then return nil, "cancelled", false end
            if not SharedInteraction.TryAcquire("station-search") then
                stationStatus(kind, "interaction-busy", "Waiting for another interaction; route retained")
                return nil, "interaction-busy", false
            end

            local anchors = route.anchors
            local nextIndex = route.cursor + 1
            local anchor = anchors[nextIndex]
            local foundItem, probe
            stationStatus(kind, "searching", string.format("Searching %d/%d | %s",
                nextIndex, #anchors, tostring(anchor.label or anchor.key)))
            local ok, err = xpcall(function()
                -- Travel first: even if two stream requests time out, proximity
                -- still lets Roblox stream the next island instead of freezing.
                probe = beginStationSearchProbe(stationSearchProbeCFrame(anchor.position), stationScannerCanRun)
                if not probe then return end
                local streamReady = requestStreamAt(anchor.position, stationScannerCanRun)
                local deadline = os.clock() + (streamReady and 0.75 or 1.15)
                local observedRevision, nextCheckAt = nil, 0
                repeat
                    if not stationScannerCanRun() or not probe:Hold() then return end
                    stationWorkerPulseAt[kind] = os.clock()
                    SharedInteraction.Touch("station-search")
                    -- Re-check on a bounded timer too: late tags/attributes and
                    -- expired item cooldowns need not increment DebrisRevision.
                    local revision = ChestLoot.GetDebrisRevision()
                    if revision ~= observedRevision or os.clock() >= nextCheckAt then
                        observedRevision, nextCheckAt = revision, os.clock() + 0.2
                        foundItem = findNearestStationItem(predicate)
                        if foundItem then return end
                    end
                    task.wait(0.06)
                until os.clock() >= deadline
            end, function(message) return tostring(message) end)

            if probe then probe:Stop() end
            SharedInteraction.Release("station-search")
            if not stationScannerCanRun() then return nil, "cancelled", false end
            -- Commit only after a live visit, never from a cancelled old worker.
            route.cursor = nextIndex
            stationNextSearchAt[kind .. "Serial"] = (stationNextSearchAt[kind .. "Serial"] or 0) + 1
            route.progressAt = os.clock()
            local complete = nextIndex >= #anchors
            if complete then
                route.sweeps = route.sweeps + 1
                route.anchors, route.cursor = nil, 0
            end
            if not ok then warn("[SEA Station Scanner] " .. tostring(err)) end
            if foundItem and foundItem.Parent and predicate(foundItem) then
                return foundItem, "found", complete
            end
            if complete then return nil, "sweep-empty", true end
            if os.clock() >= segmentDeadline then break end
        end
        return nil, "segment-empty", false
    end

    local function moveOwnedItem(item, targetCFrame)
        if item:IsA("Model") then
            item:PivotTo(targetCFrame)
            for _, descendant in ipairs(item:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    descendant.AssemblyLinearVelocity = Vector3.zero
                    descendant.AssemblyAngularVelocity = Vector3.zero
                end
            end
            return true
        end

        local part = getDraggablePart(item)
        if not part then return false end
        part.CFrame = targetCFrame
        part.AssemblyLinearVelocity = Vector3.zero
        part.AssemblyAngularVelocity = Vector3.zero
        return true
    end

    local readGrinderResource

    local function transferToStation(item, stationPart, kind, returnCFrameOverride, movementTokenOverride)
        if stationBusy or not item or not stationPart then
            return false, "busy-or-missing"
        end

        local root = getHumanoidRootPart()
        local humanoid = getHumanoid()
        local dragPart = getDraggablePart(item)
        local dragSystem = getDragSystem()
        local network = dragSystem and dragSystem.Network
        if not root or not dragPart or not network then
            return false, "drag-system-unavailable"
        end
        if humanoid and (humanoid.PlatformStand or humanoid.MoveDirection.Magnitude > 0.05) then
            return false, "player-movement-active"
        end
        if dragSystem.dragging then
            return false, "manual-drag-active"
        end
        if not SharedInteraction.TryAcquire("station") then
            return false, "interaction-busy"
        end

        setStationBusy(true)
        local movementToken = movementTokenOverride or getMovementRevision()
        local returnCFrame = returnCFrameOverride or root.CFrame
        local ownershipGranted = false
        local released = false

        local function movementInterrupted()
            return not scriptAlive
                or getMovementRevision() ~= movementToken
                or not root.Parent
        end

        local function releaseOwnership()
            if ownershipGranted and not released and dragPart and dragPart.Parent then
                released = true
                pcall(function()
                    network:FireServer("GiveUpOwnership", dragPart, dragPart.AssemblyLinearVelocity)
                end)
            end
        end

        local function restorePlayer()
            if not movementInterrupted()
                and root.Parent
                and (not humanoid or humanoid.MoveDirection.Magnitude <= 0.05)
            then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                teleportPlayer(root, returnCFrame, function() return not movementInterrupted() end)
            end
        end

        local ok, confirmed, reason = xpcall(function()
            local spawnIslandBefore = workspace:FindFirstChild("SpawnIsland")
            local beforeLevel = spawnIslandBefore and spawnIslandBefore:GetAttribute("Level")
            local beforeProgress = spawnIslandBefore and spawnIslandBefore:GetAttribute("Progress")

            local grinderResource
            local grinderResourceBefore
            if kind == "grinder" then
                grinderResource = readGrinderResource(item)
                if grinderResource then
                    grinderResourceBefore = tonumber(workspace:GetAttribute(grinderResource)) or 0
                end
            end

            local position = itemPosition(item)
            if position then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                teleportPlayer(root, CFrame.new(position + Vector3.new(0, 3, 2)),
                    function() return not movementInterrupted() end)
                task.wait(0.14)
            end
            if movementInterrupted() then
                return false, "movement-interrupted"
            end

            -- Native DragSystem does not pre-check Anchored. It asks AttemptDrag
            -- with the actual BasePart and trusts the server response. Mirror that
            -- contract so client streaming state cannot incorrectly reject targets.
            local attemptSuccess, granted = pcall(function()
                return network:InvokeServer("AttemptDrag", dragPart)
            end)
            if not attemptSuccess or granted ~= true then
                stationBlockedUntil[item] = os.clock() + 8
                return false, "drag-denied"
            end
            ownershipGranted = true

            -- Give replication a short window to reflect the server ownership/
            -- unanchor transition. Do not mutate Anchored client-side.
            local movableDeadline = os.clock() + 0.85
            while dragPart.Parent and dragPart.Anchored and os.clock() < movableDeadline do
                if movementInterrupted() then
                    return false, "movement-interrupted"
                end
                task.wait(0.05)
            end
            if dragPart.Parent and dragPart.Anchored then
                stationBlockedUntil[item] = os.clock() + 12
                return false, "drag-granted-but-anchored"
            end

            if movementInterrupted() then
                return false, "movement-interrupted"
            end

            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            teleportPlayer(root, stationPart.CFrame + Vector3.new(0, 3, 2),
                function() return not movementInterrupted() end)
            task.wait(0.10)
            if movementInterrupted() then
                return false, "movement-interrupted"
            end

            local moveOk, moveResult = pcall(function()
                return moveOwnedItem(item, stationPart.CFrame)
            end)
            if not moveOk or moveResult ~= true then
                stationBlockedUntil[item] = os.clock() + 12
                return false, "move-failed"
            end

            if kind == "grinder" then
                -- Grinder.InteractablesCache refreshes only every 5 seconds. Keep
                -- ownership while the item is inside Collection long enough to be
                -- admitted to that cache; releasing immediately can let it settle
                -- anchored before the next refresh. Native acceptance is confirmed
                -- by parent -> Grinding, destruction, or the resource counter.
                local grinderAcceptDeadline = os.clock() + 6.4
                local nextCenterAt = 0
                repeat
                    if movementInterrupted() then
                        return false, "movement-interrupted"
                    end
                    if not item.Parent or not item:IsDescendantOf(workspace) then
                        return true, "consumed"
                    end

                    local spawnIsland = workspace:FindFirstChild("SpawnIsland")
                    local grinder = spawnIsland and spawnIsland:FindFirstChild("Grinder")
                    local grinding = grinder and grinder:FindFirstChild("Grinding")
                    if grinding and item:IsDescendantOf(grinding) then
                        return true, "grinding-confirmed"
                    end

                    if grinderResource and grinderResourceBefore ~= nil then
                        local current = tonumber(workspace:GetAttribute(grinderResource)) or 0
                        -- Grinder removes the Interactable tag before awarding the
                        -- resource. Require both signals so another player's grind
                        -- cannot falsely confirm our target.
                        if current > grinderResourceBefore
                            and not CollectionService:HasTag(item, "Interactable")
                        then
                            return true, "resource-confirmed"
                        end
                    end

                    -- Keep the owned model centered in Collection while waiting for
                    -- the native 5-second cache refresh. This mirrors a player
                    -- continuing to hold the object over the grinder volume.
                    if os.clock() >= nextCenterAt and dragPart.Parent and not dragPart.Anchored then
                        nextCenterAt = os.clock() + 0.22
                        pcall(function()
                            moveOwnedItem(item, stationPart.CFrame)
                        end)
                    end
                    task.wait(0.08)
                until not scriptAlive or os.clock() >= grinderAcceptDeadline

                -- Native manual play eventually releases the held object. Give the
                -- server one final post-release window before declaring failure.
                releaseOwnership()
                local postReleaseDeadline = os.clock() + 1.35
                repeat
                    if not item.Parent or not item:IsDescendantOf(workspace) then
                        return true, "consumed-after-release"
                    end
                    local spawnIsland = workspace:FindFirstChild("SpawnIsland")
                    local grinder = spawnIsland and spawnIsland:FindFirstChild("Grinder")
                    local grinding = grinder and grinder:FindFirstChild("Grinding")
                    if grinding and item:IsDescendantOf(grinding) then
                        return true, "grinding-confirmed-after-release"
                    end
                    if grinderResource and grinderResourceBefore ~= nil then
                        local current = tonumber(workspace:GetAttribute(grinderResource)) or 0
                        if current > grinderResourceBefore
                            and not CollectionService:HasTag(item, "Interactable")
                        then
                            return true, "resource-confirmed-after-release"
                        end
                    end
                    task.wait(0.08)
                until not scriptAlive or os.clock() >= postReleaseDeadline

                return false, "grinder-not-confirmed"
            end

            -- Bonfire does not use Grinder's 5-second interactable cache. Release
            -- normally after placing the fuel, then verify replicated progress.
            releaseOwnership()
            task.wait(0.18)
            local deadline = os.clock() + 1.8
            repeat
                if not item.Parent or not item:IsDescendantOf(workspace) then
                    return true, "consumed"
                end
                local spawnIsland = workspace:FindFirstChild("SpawnIsland")
                local currentLevel = spawnIsland and spawnIsland:GetAttribute("Level")
                local currentProgress = spawnIsland and spawnIsland:GetAttribute("Progress")
                if currentLevel ~= beforeLevel or currentProgress ~= beforeProgress then
                    return true, "progress-confirmed"
                end
                task.wait(0.08)
            until not scriptAlive or os.clock() >= deadline

            return false, "not-confirmed"
        end, function(err)
            return tostring(err)
        end)

        releaseOwnership()
        restorePlayer()
        setStationBusy(false)
        SharedInteraction.Release("station")

        if not ok then
            stationBlockedUntil[item] = os.clock() + 10
            warn("[SEA Station] " .. tostring(confirmed))
            return false, "runtime-error"
        end

        stationBlockedUntil[item] = os.clock() + (confirmed and 3 or 10)
        return confirmed == true, reason
    end

    local function bonfireIsMax()
        local spawnIsland = workspace:FindFirstChild("SpawnIsland")
        if not spawnIsland then return false end
        local level = tonumber(spawnIsland:GetAttribute("Level")) or 1
        return level >= 7
    end

    local function bonfireNeedsFuel()
        -- v48 persistent rule: Auto Bonfire keeps searching until the game's actual
        -- maximum level is reached. TargetLevel/Keep no longer terminate the scanner
        -- early; max level is the one automatic stop requested by the user.
        return not bonfireIsMax()
    end

    local function isBonfireFuel(item)
        -- DragSystem highlights SpawnIsland.Dropper whenever the Interactable has
        -- a BonfireFuel attribute. Do not require the client snapshot to already
        -- be unanchored: AttemptDrag(BasePart) is the authoritative server check,
        -- just like the Grinder fix. This was the reason v35 could visit islands
        -- repeatedly without ever selecting a fuel item.
        if not item or not item.Parent then
            return false
        end

        local fuel = item:GetAttribute("BonfireFuel")
        if fuel == nil then
            local itemName = item:GetAttribute("Item") or item.Name
            local assets = ReplicatedStorage:FindFirstChild("Assets")
            local floating = assets and assets:FindFirstChild("Floating_Item_Models")
            local template = floating and floating:FindFirstChild(tostring(itemName))
            fuel = template and template:GetAttribute("BonfireFuel") or nil
        end

        local hasFuel = fuel ~= nil and fuel ~= false
        if type(fuel) == "number" then
            hasFuel = fuel > 0
        end
        return hasFuel and getDraggablePart(item) ~= nil
    end

    local grinderResourceDropdown

    readGrinderResource = function(item)
        if not item then return nil end

        local resource = item:GetAttribute("Resource")
        if type(resource) == "string" and resource ~= "" then
            return resource
        end

        -- A partially-streamed runtime model can temporarily be missing attributes
        -- that are present on its Floating_Item_Models template. This fallback is
        -- discovery-only; AttemptDrag and Grinder.Grinding remain the authority.
        local itemName = item:GetAttribute("Item") or item.Name
        local assets = ReplicatedStorage:FindFirstChild("Assets")
        local floating = assets and assets:FindFirstChild("Floating_Item_Models")
        local template = floating and floating:FindFirstChild(tostring(itemName))
        local templateResource = template and template:GetAttribute("Resource")
        if type(templateResource) == "string" and templateResource ~= "" then
            return templateResource
        end

        return nil
    end

    local function collectGrinderResourceNames()
        local found = { All = true }

        local function addResource(value)
            if type(value) == "string" and value ~= "" then
                found[value] = true
            end
        end

        local assets = ReplicatedStorage:FindFirstChild("Assets")
        local floating = assets and assets:FindFirstChild("Floating_Item_Models")
        if floating then
            for _, template in ipairs(floating:GetChildren()) do
                if template:IsA("Model") then
                    addResource(template:GetAttribute("Resource"))
                end
            end
        end

        for _, tagged in ipairs(CollectionService:GetTagged("Interactable")) do
            local model = getTopInteractable(tagged)
            if model and model:IsA("Model") then
                addResource(model:GetAttribute("Resource"))
            end
        end

        -- Preserve a saved/future value even if that resource is not spawned in
        -- this particular server yet. All always remains the future-proof mode.
        addResource(Config:Get("GrinderResource"))

        local values = { "All" }
        for value in pairs(found) do
            if value ~= "All" then
                values[#values + 1] = value
            end
        end
        table.sort(values, function(left, right)
            if left == "All" then return true end
            if right == "All" then return false end
            return string.lower(left) < string.lower(right)
        end)
        return values
    end

    local function matchesGrinderResource(item)
        -- Do not reject an item from the client-side PrimaryPart/Anchored snapshot.
        -- The real DragSystem asks the server AttemptDrag(BasePart) first; the
        -- server's boolean response is the authoritative permission to move it.
        -- This matters because streamed DebrisField clones frequently expose nil
        -- PrimaryPart or an anchored part until ownership is granted.
        if not item:IsA("Model") or not item.Parent then
            return false
        end
        if not CollectionService:HasTag(item, "Interactable") then
            return false
        end
        if not getDraggablePart(item) then
            return false
        end

        local resource = readGrinderResource(item)
        if not resource then
            return false
        end

        return true
    end

    -- v38 station Sack farm -------------------------------------------------
    -- Bonfire and Grinder now use the exact same transport family as World
    -- Auto Loot: equip Sack -> travel to a real item -> StoreItem(BasePart) ->
    -- fill the Sack -> travel to the station -> DropItem until empty.
    --
    -- Compatibility remains native-data-driven:
    --   Bonfire: Floating/runtime BonfireFuel > 0
    --   Grinder : Floating/runtime Resource is a non-empty string
    -- Only compatible names are exposed in the two UI multi-select lists.
    local StationSackFarm = (function()
        local farm = {}
        local catalogs = { bonfire = {}, grinder = {} }
        local selected = { bonfire = {}, grinder = {} }
        local dropdowns = { bonfire = nil, grinder = nil }
        local ownsSack = { bonfire = false, grinder = false }
        local lastNoticeAt = { bonfire = 0, grinder = 0 }
        local partialSince = { bonfire = 0, grinder = 0 }
        local lastPickupAt = { bonfire = 0, grinder = 0 }
        local forceSearch = { bonfire = false, grinder = false }
        local pickupFailures = setmetatable({}, { __mode = "k" })
        local stationCache: { [string]: any } = { bonfire = {}, grinder = {} }
        local stationMapSeed

        -- v41 Grinder drop calibration. DropItem is emitted from the equipped
        -- Sack/rig side, not from HumanoidRootPart's exact center. Keep a small
        -- horizontal correction learned from the actual replicated landing point.
        local grinderDropCorrection = Vector3.zero
        local grinderDropCalibrationCount = 0
        -- Sack count replication can lead the corresponding world models. Keep
        -- the player at Collection only until every confirmed counter decrement
        -- has a matching drop (or Grinding child), followed by a quiet window.
        -- Do not wait for those models to finish grinding; the station can process
        -- its physical queue after the route has already resumed.
        -- DropSafety already held the complete acknowledged Sack for 0.75s.
        -- Keep only a final observer tick here, plus the actual model-count gate.
        local GRINDER_DROP_REPLICATION_HOLD = 0.10
        local GRINDER_DROP_REPLICATION_QUIET = 0.35
        local GRINDER_DROP_REPLICATION_TIMEOUT = 12

        local CONFIG_KEYS = {
            bonfire = { items = "BonfireItems", initialized = "BonfireItemsInitialized" },
            grinder = { items = "GrinderItems", initialized = "GrinderItemsInitialized" },
        }

        local function copyList(values)
            local result = {}
            for _, value in ipairs(values or {}) do
                result[#result + 1] = value
            end
            return result
        end

        local function addUnique(list, seen, value)
            if type(value) ~= "string" or value == "" or seen[value] then
                return
            end
            seen[value] = true
            list[#list + 1] = value
            ChestLoot.AddCatalogName(value)
        end

        local function positiveFuel(value)
            if type(value) == "number" then
                return value > 0
            end
            return value ~= nil and value ~= false
        end

        local function rebuildCatalogs()
            local bonfire = {}
            local grinder = {}
            local bonfireSeen = {}
            local grinderSeen = {}

            -- Corpse display names are NPC-dependent and only exist after a kill.
            -- Keep one permanent selector so future/streamed corpses cannot fall
            -- out of the saved exact-name list.
            addUnique(grinder, grinderSeen, "Enemy Corpses")

            local assets = ReplicatedStorage:FindFirstChild("Assets")
            local floating = assets and assets:FindFirstChild("Floating_Item_Models")
            if floating then
                for _, template in ipairs(floating:GetChildren()) do
                    if template:IsA("Model") then
                        if positiveFuel(template:GetAttribute("BonfireFuel")) then
                            addUnique(bonfire, bonfireSeen, template.Name)
                        end
                        local resource = template:GetAttribute("Resource")
                        if type(resource) == "string" and resource ~= "" then
                            addUnique(grinder, grinderSeen, template.Name)
                        end
                    end
                end
            end

            -- Runtime discovery catches update-added items whose current server
            -- already knows the attributes before this script is updated.
            for _, tagged in ipairs(CollectionService:GetTagged("Interactable")) do
                local item = getTopInteractable(tagged)
                if item and item.Parent then
                    local display = ChestLoot.DisplayName(item)
                    local fuel = item:GetAttribute("BonfireFuel")
                    if fuel == nil and floating and display then
                        local template = floating:FindFirstChild(display)
                        fuel = template and template:GetAttribute("BonfireFuel") or nil
                    end
                    if positiveFuel(fuel) then
                        addUnique(bonfire, bonfireSeen, display)
                    end

                    local resource = readGrinderResource(item)
                    if resource then
                        addUnique(grinder, grinderSeen, display)
                    end
                end
            end

            table.sort(bonfire, function(a, b) return string.lower(a) < string.lower(b) end)
            table.sort(grinder, function(a, b) return string.lower(a) < string.lower(b) end)
            catalogs.bonfire = bonfire
            catalogs.grinder = grinder
        end

        local function filterSelection(kind, values)
            local allowed = {}
            for _, name in ipairs(catalogs[kind]) do allowed[name] = true end
            local result = {}
            local seen = {}
            for _, name in ipairs(values or {}) do
                if allowed[name] and not seen[name] then
                    seen[name] = true
                    result[#result + 1] = name
                end
            end
            return result
        end

        local function initializeSelection(kind)
            local keys = CONFIG_KEYS[kind]
            if Config:Get(keys.initialized) ~= true then
                selected[kind] = copyList(catalogs[kind])
                Config:Set(keys.items, selected[kind])
                Config:Set(keys.initialized, true, true)
            else
                selected[kind] = filterSelection(kind, Config:Get(keys.items) or {})
                Config:Set(keys.items, selected[kind])
            end

            -- Existing saves were initialized before the stable corpse group was
            -- available. Add it exactly once; after migration, an explicit user
            -- deselection remains respected on every later reload/refresh.
            if kind == "grinder"
                and Config:Get("GrinderCorpseGroupInitialized") ~= true
            then
                if not table.find(selected.grinder, "Enemy Corpses") then
                    selected.grinder[#selected.grinder + 1] = "Enemy Corpses"
                end
                Config:Set("GrinderCorpseGroupInitialized", true)
                Config:Set(keys.items, selected.grinder, true)
            end
        end

        local function stationPart(kind)
            local seed = tostring(localPlayer:GetAttribute("DisplaySeed") or "")
            if seed ~= stationMapSeed then
                stationMapSeed = seed
                stationCache = { bonfire = {}, grinder = {} }
            end
            local spawnIsland = workspace:FindFirstChild("SpawnIsland")
            if not spawnIsland then return nil end
            local part
            if kind == "bonfire" then
                part = spawnIsland:FindFirstChild("Dropper")
            else
                local grinder = spawnIsland:FindFirstChild("Grinder")
                part = grinder and grinder:FindFirstChild("Collection")
            end
            if part and part:IsA("BasePart") and part:IsDescendantOf(workspace) then
                -- Keep coordinates/geometry, never a stale streamed Instance.
                stationCache[kind] = { CFrame = part.CFrame, Size = part.Size, Name = part.Name }
                return part
            end
            return nil
        end

        local function resolveStation(kind, canContinue)
            local part = stationPart(kind)
            if part then return part end
            local cached = stationCache[kind].CFrame
            local markers = ReplicatedStorage:FindFirstChild("DistantIslands")
            local rig = markers and markers:FindFirstChild("Rig")
            local position = cached and cached.Position or (rig and itemPosition(rig))
            if not position then
                local other = stationCache[kind == "bonfire" and "grinder" or "bonfire"].CFrame
                position = other and other.Position
            end
            if not position then return nil, "Waiting for the Rig marker / station coordinates" end
            if not canContinue() then return nil, "Cancelled" end
            if not SharedInteraction.TryAcquire("station-search") then
                return nil, "Waiting for another interaction before returning to the station"
            end
            stationStatus(kind, "streaming-station", "Returning to the Rig; loading the station")
            local probe
            local ok, err = xpcall(function()
                probe = beginStationSearchProbe(stationSearchProbeCFrame(position), canContinue)
                if not probe then return end
                requestStreamAt(position, canContinue)
                local deadline = os.clock() + 2
                repeat
                    if not canContinue() or not probe:Hold() then return end
                    stationWorkerPulseAt[kind] = os.clock()
                    SharedInteraction.Touch("station-search")
                    part = stationPart(kind)
                    if part then return end
                    task.wait(0.1)
                until os.clock() >= deadline
            end, function(message) return tostring(message) end)
            if probe then probe:Stop() end
            SharedInteraction.Release("station-search")
            if not canContinue() then return nil, "Cancelled" end
            if not ok then warn("[SEA Station Streaming] " .. tostring(err)) end
            return part, part and nil or "Station not streamed yet; retrying automatically"
        end

        local function insideStationZone(item, part)
            if not item or not part or not part.CFrame or not part.Size then return false end
            local position = itemPosition(item)
            if not position then return false end
            local localPosition = part.CFrame:PointToObjectSpace(position)
            -- Grinder drops can sit just outside Collection until its 5-second
            -- cache accepts them. Keep a generous exclusion halo so the next
            -- Sack-fill pass cannot immediately pick its own station drops back up.
            local padding = part.Name == "Collection" and 5 or 3
            local half = part.Size * 0.5 + Vector3.new(padding, padding, padding)
            return math.abs(localPosition.X) <= half.X
                and math.abs(localPosition.Y) <= half.Y
                and math.abs(localPosition.Z) <= half.Z
        end

        local function compatibleAndSelected(kind, item)
            if not item or not item.Parent or not item:IsDescendantOf(workspace) then
                return false
            end
            if DropManager.IsInsideBase(item) then
                return false
            end
            if not CollectionService:HasTag(item, "Interactable") then
                return false
            end
            if #selected[kind] == 0 or not ChestLoot.Matches(item, selected[kind]) then
                return false
            end
            local part = stationPart(kind) or stationCache[kind]
            if part and insideStationZone(item, part) then
                return false
            end
            if kind == "bonfire" then
                return isBonfireFuel(item)
            end
            return matchesGrinderResource(item)
        end

        local function loadedCandidates(kind, maximum)
            local root = getHumanoidRootPart()
            if not root then return {} end
            local candidates = ChestLoot.Candidates(root.Position, math.huge, true)
            local result = {}
            local seen = setmetatable({}, { __mode = "k" })
            for _, raw in ipairs(candidates) do
                local item = getTopInteractable(raw)
                if item and not seen[item] then
                    seen[item] = true
                    if (not stationBlockedUntil[item] or os.clock() >= stationBlockedUntil[item])
                        and not hasActiveGrabber(item)
                        and compatibleAndSelected(kind, item)
                    then
                        result[#result + 1] = item
                    end
                end
            end
            table.sort(result, function(left, right)
                local lp = itemPosition(left)
                local rp = itemPosition(right)
                local ld = lp and (lp - root.Position).Magnitude or math.huge
                local rd = rp and (rp - root.Position).Magnitude or math.huge
                return ld < rd
            end)
            if maximum and #result > maximum then
                for index = #result, maximum + 1, -1 do result[index] = nil end
            end
            return result
        end

        local function ensureOwnedSack(kind, canContinue)
            local sack = ChestLoot.FindSackTool()
            if not sack then
                return nil, nil, "sack-missing"
            end
            if not ChestLoot.EquipSackTool(sack) then
                return nil, nil, "sack-equip-failed"
            end
            local state = ChestLoot.ReadSackState(sack)
            if type(canContinue) == "function" and not canContinue() then
                return sack, state, "cancelled"
            end

            -- We cannot inspect individual Sack contents. On a fresh station
            -- session, refuse to dump unknown pre-existing items into a Bonfire or
            -- Grinder. Once the session starts from empty, every added item passed
            -- the station's compatibility + user-selection predicate.
            if not ownsSack[kind] then
                if not state or type(state.count) ~= "number" then
                    return sack, state, "sack-state-pending"
                end
                if state.count > 0 then
                    return sack, state, "sack-not-empty"
                end
                ownsSack[kind] = true
            end
            return sack, state, nil
        end

        local function grinderDesiredHandlePosition(part)
            -- v44: keep the Sack emission point horizontally centered but higher in
            -- Collection. v43 used only ~0.30 stud above the Collection center, which
            -- made the character sit unnecessarily low. Collection is ~3.5 studs tall
            -- in the supplied place, so ~1.1 studs remains inside its upper half while
            -- raising the whole rig noticeably.
            local yOffset = math.min(1.20, math.max(0.85, part.Size.Y * 0.32))
            return part.Position + Vector3.new(0, yOffset, 0) + grinderDropCorrection
        end

        local function stationStandCFrame(kind, part, sack)
            if kind == "grinder" then
                -- Align the SACK HANDLE with Grinder.Collection, not HRP.
                -- The user's live observation is the important signal here:
                -- HRP can be centered while DropItem still exits from the side
                -- where the equipped Sack is held.
                local root = getHumanoidRootPart()
                local handle = sack and sack:FindFirstChild("Handle")

                local rawForward = part.CFrame.LookVector
                local forward = Vector3.new(rawForward.X, 0, rawForward.Z)
                if forward.Magnitude < 0.05 then
                    local rawRight = part.CFrame.RightVector
                    forward = Vector3.new(rawRight.X, 0, rawRight.Z)
                end
                forward = forward.Magnitude > 0.05 and forward.Unit or Vector3.new(0, 0, -1)

                -- Put the native Sack emission point inside the exact center band
                -- of Collection. The learned horizontal correction compensates for
                -- any extra server-side drop offset that is not explained by Handle.
                local desiredHandle = grinderDesiredHandlePosition(part)

                local rootPosition
                if root and handle and handle:IsA("BasePart") then
                    -- Measure the equipped Handle offset in HRP-local coordinates,
                    -- then solve the HRP position that places that Handle at center
                    -- for the chosen facing direction.
                    local localHandleOffset = root.CFrame:PointToObjectSpace(handle.Position)
                    local orientation = CFrame.lookAt(Vector3.zero, forward)
                    local worldHandleOffset = orientation:VectorToWorldSpace(localHandleOffset)
                    rootPosition = desiredHandle - worldHandleOffset
                else
                    -- Safe fallback for unusual Sack skins with no Handle.
                    rootPosition = part.Position
                        - forward * ((part.Size.Z * 0.5) + 2.7)
                        + Vector3.new(0, (part.Size.Y * 0.5) + 3.10, 0)
                        + grinderDropCorrection
                end

                return CFrame.lookAt(rootPosition, rootPosition + forward)
            end

            local forward = Vector3.new(part.CFrame.LookVector.X, 0, part.CFrame.LookVector.Z)
            forward = forward.Magnitude > 0.05 and forward.Unit or Vector3.new(0, 0, -1)
            local orientation = CFrame.lookAt(Vector3.zero, forward)
            local root, handle = getHumanoidRootPart(), sack and sack:FindFirstChild("Handle")
            local position = part.Position + Vector3.new(0, part.Size.Y * 0.5 + 3.15, 0)
            if root and handle and handle:IsA("BasePart") then
                local offset = root.CFrame:PointToObjectSpace(handle.Position)
                position = part.Position + Vector3.new(0, part.Size.Y * 0.5 + 1.1, 0)
                    - orientation:VectorToWorldSpace(offset)
            end
            return CFrame.lookAt(position, position + forward)
        end

        local function snapshotStationInteractables()
            local snapshot = setmetatable({}, { __mode = "k" })
            local function add(raw)
                local item = getTopInteractable(raw)
                if item and item.Parent and item:IsDescendantOf(workspace) then snapshot[item] = true end
            end
            for _, tagged in ipairs(CollectionService:GetTagged("Interactable")) do add(tagged) end
            forEachItemModel(add)
            return snapshot
        end

        local function collectNewGrinderDrops(beforeSnapshot, part, pending, pendingSeen)
            if not beforeSnapshot or not part then return 0, nil end
            local added = 0
            local observedSum = Vector3.zero
            local observedCount = 0
            local scanned = setmetatable({}, { __mode = "k" })

            local function consider(raw)
                local item = getTopInteractable(raw)
                if not item or scanned[item] or beforeSnapshot[item] or pendingSeen[item]
                    or not item.Parent or not item:IsDescendantOf(workspace)
                then
                    return
                end
                scanned[item] = true
                -- Count every compatible local Grinder drop, not only the current
                -- filter. A Sack may legitimately contain items collected before
                -- the user changed its selection; ignoring those made the departure
                -- barrier time out and allowed their delayed spawn at the next island.
                if not matchesGrinderResource(item) then
                    return
                end
                local holder = item:GetAttribute("LastHolder")
                if holder ~= nil and holder ~= localPlayer.Name then return end
                local position = itemPosition(item)
                if not position or (position - part.Position).Magnitude > 24 then return end

                pendingSeen[item] = true
                pending[#pending + 1] = item
                stationBlockedUntil[item] = os.clock() + 10
                observedSum = observedSum + position
                observedCount = observedCount + 1
                added = added + 1
            end

            for _, tagged in ipairs(CollectionService:GetTagged("Interactable")) do consider(tagged) end
            forEachItemModel(consider)
            return added, observedCount > 0 and (observedSum / observedCount) or nil
        end

        local function keepGrinderDropCentered(item, part)
            if not item or not item.Parent or not CollectionService:HasTag(item, "Interactable") then
                return false
            end
            local desired = part.CFrame * CFrame.new(0, math.min(0.35, part.Size.Y * 0.10), 0)
            pcall(function()
                if item:IsA("Model") then
                    item:PivotTo(desired)
                    for _, descendant in ipairs(item:GetDescendants()) do
                        if descendant:IsA("BasePart") then
                            descendant.AssemblyLinearVelocity = Vector3.zero
                            descendant.AssemblyAngularVelocity = Vector3.zero
                        end
                    end
                else
                    local target = getDraggablePart(item)
                    if target then
                        target.CFrame = desired
                        target.AssemblyLinearVelocity = Vector3.zero
                        target.AssemblyAngularVelocity = Vector3.zero
                    end
                end
            end)
            return true
        end

        local function dropAtStation(kind, sack, part, expectedGeneration)
            if not sack or not part or not part.Parent or stationBusy then
                return false, "busy-or-missing"
            end
            local token = getMovementRevision()
            if not stationCanRun(kind, expectedGeneration, token) then return false, "cancelled" end
            if not SharedInteraction.TryAcquire("station-drop") then
                return false, "interaction-busy"
            end

            setStationBusy(true)
            local root = getHumanoidRootPart()
            local sackClient = ChestLoot.GetSackClient()
            local origin = root and root.CFrame or nil
            local dropped = 0
            local pendingGrinderDrops = {}
            local pendingGrinderSeen = setmetatable({}, { __mode = "k" })
            local hover
            local grinderChildConnection: any
            local originRestored = false
            local function canContinue()
                return stationCanRun(kind, expectedGeneration, token) and getHumanoidRootPart() == root
            end
            stationStatus(kind, "dropping", "Delivering Sack contents to the station")

            local spawnIsland = workspace:FindFirstChild("SpawnIsland")
            local beforeLevel = spawnIsland and spawnIsland:GetAttribute("Level")
            local beforeProgress = spawnIsland and spawnIsland:GetAttribute("Progress")
            local grinder = spawnIsland and spawnIsland:FindFirstChild("Grinder")
            local grinding = grinder and grinder:FindFirstChild("Grinding")
            local beforeGrinding = setmetatable({}, { __mode = "k" })
            if grinding then
                for _, child in ipairs(grinding:GetChildren()) do beforeGrinding[child] = true end
            end

            local function stopHover()
                if hover then
                    pcall(function() hover:Stop() end)
                    hover = nil
                end
            end

            local function restoreOriginOnce()
                if originRestored then return end
                if origin and root and root.Parent and canContinue() and not DropSafety.IsWaiting() then
                    originRestored = true
                    safeAutomationTeleport(origin, 0.07, canContinue)
                end
            end

            local ok, reason = xpcall(function()
                if not canContinue() then return "movement-interrupted" end
                if not root or not root.Parent or not sackClient or not sackClient.Net then
                    return "station-unavailable"
                end
                if Config:Get("FlyEnabled") == true then
                    return "manual-fly-active"
                end
                if not ChestLoot.EquipSackTool(sack) then
                    return "sack-equip-failed"
                end
                if not DropSafety.WaitForTool(sack, root, canContinue) then return "sack-equip-unconfirmed" end

                -- ONE teleport to the station. From here until the Sack is empty,
                -- BodyPosition/BodyGyro do all positional correction.
                local stand = stationStandCFrame(kind, part, sack)
                if not safeAutomationTeleport(stand, 0.08, canContinue) then
                    return "station-teleport-failed"
                end
                task.wait(0.035)
                if not canContinue() then return "movement-interrupted" end
                part = stationPart(kind)
                if not part then return "station-unavailable" end

                local hoverReason
                hover, hoverReason = stationDropHover.Start(stand, token)
                if not hover then
                    return "drop-hover-failed:" .. tostring(hoverReason)
                end
                local grinderWorldBeforeDrops = kind == "grinder"
                    and snapshotStationInteractables()
                    or nil
                local observedGrinderDrops = 0
                local lastGrinderDropObservedAt = os.clock()
                local acceptedAny = false

                -- Polling can miss a model that enters Grinding and is consumed
                -- between two frames. Observe ChildAdded as an acknowledgement too,
                -- while deduplicating models already seen in DebrisField.
                local function observeGrindingChild(child)
                    if not child or beforeGrinding[child] then return end
                    acceptedAny = true
                    if not pendingGrinderSeen[child] then
                        pendingGrinderSeen[child] = true
                        observedGrinderDrops = observedGrinderDrops + 1
                        lastGrinderDropObservedAt = os.clock()
                    end
                end
                if kind == "grinder" and grinding and grinding.ChildAdded then
                    grinderChildConnection = grinding.ChildAdded:Connect(observeGrindingChild)
                end

                local function registerGrinderDrops()
                    if kind ~= "grinder" or not grinderWorldBeforeDrops then return 0 end
                    local added, observedPosition = collectNewGrinderDrops(
                        grinderWorldBeforeDrops,
                        part,
                        pendingGrinderDrops,
                        pendingGrinderSeen
                    )
                    if added > 0 then
                        observedGrinderDrops = observedGrinderDrops + added
                        lastGrinderDropObservedAt = os.clock()
                    end
                    if observedPosition then
                        local errorVector = Vector3.new(
                            observedPosition.X - part.Position.X,
                            0,
                            observedPosition.Z - part.Position.Z
                        )
                        if errorVector.Magnitude > 0.12 and errorVector.Magnitude < 8 then
                            local learningRate = grinderDropCalibrationCount == 0 and 0.95 or 0.55
                            grinderDropCorrection = grinderDropCorrection - errorVector * learningRate
                            local magnitude = grinderDropCorrection.Magnitude
                            if magnitude > 4.5 then
                                grinderDropCorrection = grinderDropCorrection.Unit * 4.5
                            end
                            grinderDropCalibrationCount = math.min(grinderDropCalibrationCount + 1, 20)
                        end
                    end
                    for _, releasedItem in ipairs(pendingGrinderDrops) do
                        keepGrinderDropCentered(releasedItem, part)
                    end
                    return added
                end

                local function prepareDrop()
                    stand = stationStandCFrame(kind, part, sack)
                    return stand, function()
                        if not part or not part.Parent then return false end
                        local handle = sack:FindFirstChild("Handle")
                        if not handle or not handle:IsA("BasePart") then return false end
                        if kind == "grinder" then
                            return (handle.Position - grinderDesiredHandlePosition(part)).Magnitude <= 0.65
                        end
                        local relative = handle.Position - part.Position
                        return Vector3.new(relative.X, 0, relative.Z).Magnitude
                            <= math.max(2, math.min(part.Size.X, part.Size.Z) * 0.5)
                            and handle.Position.Y >= part.Position.Y
                    end
                end
                local nextObserveAt = 0
                local empty, count, dropReason = DropSafety.Empty({
                    root = root, sack = sack, hover = hover, network = sackClient.Net,
                    canContinue = canContinue, prepare = prepareDrop, profile = DropSafety.Profiles.Fast,
                    onProgress = function()
                        stationWorkerPulseAt[kind] = os.clock()
                        SharedInteraction.Touch("station-drop")
                        if os.clock() >= nextObserveAt then
                            nextObserveAt = os.clock() + 0.10
                            registerGrinderDrops()
                        end
                    end,
                })
                dropped = count
                if not empty then return dropReason end

                if kind == "bonfire" then
                    -- Keep the rig at the fire until the last drop's settling
                    -- window AND fuel acknowledgement have passed.
                    local acceptDeadline = os.clock() + 2.2
                    repeat
                        if not canContinue() then return "movement-interrupted" end
                        stationWorkerPulseAt[kind] = os.clock()
                        SharedInteraction.Touch("station-drop")
                        local currentIsland = workspace:FindFirstChild("SpawnIsland")
                        local level = currentIsland and currentIsland:GetAttribute("Level")
                        local progress = currentIsland and currentIsland:GetAttribute("Progress")
                        if level ~= beforeLevel or progress ~= beforeProgress then
                            return "bonfire-confirmed"
                        end
                        task.wait(0.08)
                    until not scriptAlive or os.clock() >= acceptDeadline
                    return dropped > 0 and "dropped-awaiting-bonfire" or "nothing-dropped"
                end

                -- The Sack counter can read zero before the last world models arrive.
                -- Hold only for the DropItem replication queue: once all models have
                -- appeared at Collection, leave immediately even if they are still
                -- waiting for the native Grinder's 5-second processing refresh.
                local emptyConfirmedAt = os.clock()
                local acceptDeadline = emptyConfirmedAt + GRINDER_DROP_REPLICATION_TIMEOUT
                local acceptedGrinderSeen = setmetatable({}, { __mode = "k" })
                stationStatus(kind, "draining-drops",
                    "Sack empty; confirming every drop at Grinder (not waiting for processing)", true)
                repeat
                    if not canContinue() then return "movement-interrupted" end
                    if not hover or not hover:IsAlive() then return "drop-hover-lost" end
                    stationWorkerPulseAt[kind] = os.clock()
                    SharedInteraction.Touch("station-drop")
                    registerGrinderDrops()
                    local pending = false
                    for _, releasedItem in ipairs(pendingGrinderDrops) do
                        if releasedItem and releasedItem.Parent
                            and CollectionService:HasTag(releasedItem, "Interactable")
                        then
                            pending = true
                            keepGrinderDropCentered(releasedItem, part)
                        elseif releasedItem then
                            acceptedAny = true
                        end
                    end

                    local currentIsland = workspace:FindFirstChild("SpawnIsland")
                    local currentGrinder = currentIsland and currentIsland:FindFirstChild("Grinder")
                    local currentGrinding = currentGrinder and currentGrinder:FindFirstChild("Grinding")
                    if currentGrinding then
                        for _, child in ipairs(currentGrinding:GetChildren()) do
                            if not beforeGrinding[child] and not acceptedGrinderSeen[child] then
                                acceptedGrinderSeen[child] = true
                                observeGrindingChild(child)
                            end
                        end
                    end
                    local now = os.clock()
                    local allDropsReplicated = observedGrinderDrops >= dropped
                    local replicationSettled = now - emptyConfirmedAt
                            >= GRINDER_DROP_REPLICATION_HOLD
                        and now - lastGrinderDropObservedAt
                            >= GRINDER_DROP_REPLICATION_QUIET
                    if dropped > 0 and allDropsReplicated and replicationSettled then
                        return pending and "grinder-drops-queued"
                            or (acceptedAny and "grinder-drops-processing" or "grinder-drops-replicated")
                    end
                    task.wait(0.10)
                until not scriptAlive or os.clock() >= acceptDeadline
                if observedGrinderDrops < dropped then
                    return "grinder-replication-timeout"
                end
                return dropped > 0 and "grinder-drops-replicated"
                    or "nothing-dropped"
            end, function(message)
                return tostring(message)
            end)

            if grinderChildConnection then
                pcall(function() grinderChildConnection:Disconnect() end)
                grinderChildConnection = nil
            end
            stopHover()
            -- Grinder stays at Collection until the replication-only barrier passes.
            -- Its next scanner segment may then teleport while the machine continues
            -- processing the already-released physical queue independently.
            -- Bonfire retains its single pre-drop-position restore.
            if kind ~= "grinder" then restoreOriginOnce() end
            if canContinue() then ChestLoot.EquipSackTool(sack) end
            setStationBusy(false)
            SharedInteraction.Release("station-drop")

            if not ok then
                warn("[SEA Station Sack] " .. tostring(reason))
                return false, "runtime-error"
            end
            local success = dropped > 0 and (reason == "bonfire-confirmed"
                or reason == "dropped-awaiting-bonfire" or reason == "grinder-drops-queued"
                or reason == "grinder-drops-processing" or reason == "grinder-drops-replicated")
            return success, reason
        end

        function farm.Step(kind, expectedGeneration)
            stationWorkerPulseAt[kind] = os.clock()
            if DropSafety.IsWaiting() then
                stationStatus(kind, "waiting-drop", "Waiting for the last Sack drop acknowledgement")
                return false
            end
            recoverStaleStationBusy()
            local token = getMovementRevision()
            local function canContinue()
                return stationCanRun(kind, expectedGeneration, token)
            end
            if not canContinue() then
                local humanoid = getHumanoid()
                if not getHumanoidRootPart() or not humanoid or humanoid.Health <= 0 then
                    stationStatus(kind, "waiting-character", "Waiting for respawn; farm remains enabled")
                elseif Config:Get("FlyEnabled") == true or Config:Get("AutoLootWorld") == true then
                    stationStatus(kind, "paused", "Paused while Fly / World Loot owns movement")
                end
                return false
            end
            if stationBusy then
                stationStatus(kind, "interaction-busy", "Waiting for the active station operation")
                return false
            end
            if #selected[kind] == 0 then
                stationStatus(kind, "waiting-selection", "Choose at least one compatible item")
                if os.clock() - lastNoticeAt[kind] > 6 then
                    lastNoticeAt[kind] = os.clock()
                    notify(kind == "bonfire" and "Auto Bonfire" or "Auto Grinder",
                        "Choose at least one compatible item first", 2.2)
                end
                return false
            end

            local sack, state, sackReason = ensureOwnedSack(kind, canContinue)
            if not canContinue() then return false, "cancelled" end
            if not sack then
                stationStatus(kind, "waiting-sack", "Waiting for a Sack; retrying automatically")
                if os.clock() - lastNoticeAt[kind] > 6 then
                    lastNoticeAt[kind] = os.clock()
                    notify(kind == "bonfire" and "Auto Bonfire" or "Auto Grinder",
                        "A Sack is required for station farming", 2.2)
                end
                return false
            end
            if sackReason == "sack-not-empty" then
                stationStatus(kind, "waiting-empty-sack", "Empty the Sack once; pre-existing contents are unknown")
                if os.clock() - lastNoticeAt[kind] > 6 then
                    lastNoticeAt[kind] = os.clock()
                    notify(kind == "bonfire" and "Auto Bonfire" or "Auto Grinder",
                        "Empty the Sack once before starting; existing contents are unknown", 2.8)
                end
                return false
            end
            if sackReason or not state or type(state.count) ~= "number" then
                stationStatus(kind, "waiting-sack", "Waiting for Sack equip/counter: " .. tostring(sackReason or "counter-loading"))
                return false
            end

            local used = state.count
            if used <= 0 then
                partialSince[kind] = 0
            elseif partialSince[kind] == 0 then
                partialSince[kind] = os.clock()
            end
            -- Cache station geometry when available, but DO NOT require the
            -- station's BasePart to be streamed in while searching remote islands.
            stationPart(kind)
            local function deliver()
                local part, reason = resolveStation(kind, canContinue)
                if not canContinue() then return false, "cancelled" end
                if not part then
                    stationStatus(kind, "waiting-station", reason or "Loading station; retrying")
                    return false, "station-unavailable"
                end
                local success, dropReason = dropAtStation(kind, sack, part, expectedGeneration)
                if not canContinue() then return success, dropReason end
                local after = ChestLoot.ReadSackState(sack)
                if type(after.count) == "number" and after.count <= 0 then
                    partialSince[kind], lastPickupAt[kind] = 0, 0
                end
                stationStatus(kind, success and "searching" or "retrying-drop",
                    success and "Delivery complete; continuing the route"
                        or ("Delivery retry: " .. tostring(dropReason)), success)
                return success, dropReason
            end
            local function partialDeliveryDue()
                return used > 0 and (Config:Get("StationWorldSearch") ~= true
                    or os.clock() - math.max(partialSince[kind], lastPickupAt[kind]) >= (kind == "bonfire" and 20 or 30))
            end
            if state.full or partialDeliveryDue() then return deliver() end

            local remaining = 12
            if state and type(state.count) == "number" and type(state.maximum) == "number" then
                remaining = math.max(1, state.maximum - state.count)
            end
            local batchLimit = math.min(remaining, 16)
            local candidates = loadedCandidates(kind, batchLimit)
            local completedSweep = false

            if #candidates == 0 or forceSearch[kind] then
                forceSearch[kind] = false
                local searchedItem, _, sweepDone = searchStationWorld(function(item)
                    return compatibleAndSelected(kind, item)
                end, kind, expectedGeneration, function()
                    return #selected[kind] > 0
                end)
                completedSweep = sweepDone
                if not canContinue() then return false, "cancelled" end

                -- v47: scanner hits are only AREA signals. Do not forward that exact
                -- Instance into InteractBatch because StreamingEnabled may replace or
                -- temporarily strip its BaseParts between scan and pickup. Rebuild the
                -- live candidate list exactly like World Auto Loot, and briefly wait for
                -- the streamed BasePart to become interactable.
                local refreshDeadline = os.clock() + (searchedItem and 0.85 or 0)
                repeat
                    candidates = loadedCandidates(kind, batchLimit)
                    if #candidates > 0 or os.clock() >= refreshDeadline then break end
                    task.wait(0.05)
                until not canContinue()
            end

            if not canContinue() then return false, "cancelled" end
            if partialDeliveryDue() then return deliver() end
            if #candidates == 0 then
                if used > 0 and completedSweep then return deliver() end
                if Config:Get("StationWorldSearch") ~= true then
                    stationStatus(kind, "local-only", "No loaded targets; enable Continuous Full-Map Scan to visit islands")
                end
                ChestLoot.EquipSackTool(sack)
                return false
            end

            stationStatus(kind, "picking-up", "Collecting selected materials into the Sack")
            local results = ChestLoot.InteractBatch(
                candidates,
                "Store in Sack (F)",
                batchLimit,
                {
                    keepSackEquipped = true,
                    restorePosition = false,
                    sackFirst = true,
                    stopWhenSackFull = true,
                    autonomousMovement = true,
                    -- A rejected item must not monopolize the route with repeated
                    -- keyboard fallbacks (F can DROP instead when the target vanishes).
                    nativeOnly = true,
                    maximumAttempts = 2,
                    timeBudget = 4.5,
                    canContinue = canContinue,
                    onProgress = function()
                        if canContinue() then stationWorkerPulseAt[kind] = os.clock() end
                    end,
                }
            )
            if not canContinue() then return false, "cancelled" end

            local collected = 0
            local firstFailureMethod
            local firstFailureCandidate
            for _, result in ipairs(results) do
                if result.success then
                    collected = collected + 1
                    pickupFailures[result.candidate] = nil
                    stationBlockedUntil[result.candidate] = os.clock() + 20
                elseif result.method == "chest-priority"
                    or result.method == "batch-busy"
                    or result.method == "busy"
                    or result.method == "batch-cancelled"
                    or result.method == "movement-interrupted"
                then
                    -- This item did not fail; another automation owns the short
                    -- interaction window. Leave it immediately eligible so the
                    -- continuous farm resumes on the next worker tick.
                elseif result.method ~= "sack-full" then
                    local failures = math.min(5, (pickupFailures[result.candidate] or 0) + 1)
                    pickupFailures[result.candidate] = failures
                    stationBlockedUntil[result.candidate] = os.clock() + math.min(45, 4 * 2 ^ (failures - 1))
                    if not firstFailureMethod then
                        firstFailureMethod = result.method
                        firstFailureCandidate = result.candidate
                    end
                end
            end

            if collected == 0 and firstFailureMethod then
                local key = kind .. "PickupFailureNotice"
                local now = os.clock()
                if now - (stationNextSearchAt[key] or 0) >= 3 then
                    stationNextSearchAt[key] = now
                    local itemLabel = firstFailureCandidate
                        and ChestLoot.DisplayName(firstFailureCandidate)
                        or "item"
                    warn(string.format("[SEA %s Pickup] %s -> %s",
                        kind, tostring(itemLabel), tostring(firstFailureMethod)))
                    notify(kind == "bonfire" and "Auto Bonfire Pickup" or "Auto Grinder Pickup",
                        tostring(itemLabel) .. " -> " .. tostring(firstFailureMethod), 2.2)
                end
            end

            local after = ChestLoot.ReadSackState(sack)
            ChestLoot.EquipSackTool(sack)
            if collected > 0 or (type(after.count) == "number" and after.count > used) then
                lastPickupAt[kind] = os.clock()
                if partialSince[kind] == 0 then partialSince[kind] = os.clock() end
                stationStatus(kind, "picking-up", "Collected materials; continuing", true)
            elseif firstFailureMethod then
                forceSearch[kind] = true
                stationStatus(kind, "retrying-pickup", "Item not accepted; moving to another area")
            elseif #results == 0 then
                -- E.g. old in-flight instances: advance instead of selecting the
                -- same empty batch on every 0.1-second tick.
                forceSearch[kind] = true
            end
            if after and after.full then
                return deliver()
            end
            return collected > 0
        end

        function farm.Reset(kind, preserveOwnedSack)
            -- A watchdog/respawn restart is still the same trusted farm session.
            -- Preserve ownership so a partially filled Sack resumes at DROP instead
            -- of becoming permanently blocked as "unknown existing contents".
            if preserveOwnedSack ~= true then
                ownsSack[kind] = false
                partialSince[kind], lastPickupAt[kind] = 0, 0
                local route = stationRuntime[kind]
                route.anchors, route.cursor, route.sweeps = nil, 0, 0
            end
            forceSearch[kind] = false
            lastNoticeAt[kind] = 0
            stationNextSearchAt[kind] = 0
            if kind == "grinder" then
                grinderDropCorrection = Vector3.zero
                grinderDropCalibrationCount = 0
            end
        end

        function farm.GetCatalog(kind)
            return copyList(catalogs[kind])
        end

        function farm.GetSelected(kind)
            return copyList(selected[kind])
        end

        function farm.SetSelected(kind, values)
            selected[kind] = filterSelection(kind, values)
            Config:Set(CONFIG_KEYS[kind].items, selected[kind])
            -- Previously collected contents are still compatible with this station,
            -- even if the user changes which names should be collected next.
            farm.Reset(kind, true)
        end

        function farm.SetDropdown(kind, control)
            dropdowns[kind] = control
        end

        function farm.Refresh(showNotification)
            rebuildCatalogs()
            for _, kind in ipairs({ "bonfire", "grinder" }) do
                selected[kind] = filterSelection(kind, selected[kind])
                Config:Set(CONFIG_KEYS[kind].items, selected[kind])
                local control = dropdowns[kind]
                if control then
                    pcall(function()
                        control:Refresh(catalogs[kind])
                        control:Select(selected[kind])
                    end)
                end
            end
            if showNotification then
                notify("Station Items", string.format(
                    "Compatible: %d Bonfire fuel item(s), %d Grinder item(s)",
                    #catalogs.bonfire, #catalogs.grinder
                ), 2.5)
            end
        end

        stationPart("bonfire")
        stationPart("grinder")
        rebuildCatalogs()
        initializeSelection("bonfire")
        initializeSelection("grinder")
        return farm
    end)()

    local function bonfireStep(expectedGeneration)
        return StationSackFarm.Step("bonfire", expectedGeneration)
    end

    local function grinderStep(expectedGeneration)
        return StationSackFarm.Step("grinder", expectedGeneration)
    end

    local function setToggleControl(control, enabled)
        if control then
            pcall(function() control:Set(enabled, false) end)
        end
    end

    local api = {}
    local startStationWorker

    local function stationEnabled(kind)
        if kind == "bonfire" then return autoBonfireEnabled end
        return autoGrinderEnabled
    end

    local function stationGeneration(kind)
        return kind == "bonfire" and bonfireGeneration or grinderGeneration
    end

    local function recoverAbandonedStationWorker(kind)
        local holder = stationWorkerThreads[kind]
        if holder then
            ChestLoot.RecoverInteraction(holder)
            if SharedInteraction.holder == holder then
                SharedInteraction.Release("station", true)
                SharedInteraction.Release("station-search", true)
                SharedInteraction.Release("station-drop", true)
            end
            if stationBusyHolder == holder then setStationBusy(false, true) end
        end
        if activeStationSearchProbe then activeStationSearchProbe:Stop() end
        if activeStationDropHover then activeStationDropHover:Stop() end
        StationSackFarm.Reset(kind, true)
    end

    local function stopBonfireAtMaximum()
        autoBonfireEnabled = false
        bonfireGeneration = bonfireGeneration + 1
        stationWorkerRunning.bonfire = false
        interruptAutomationMovement()
        recoverAbandonedStationWorker("bonfire")
        Config:Set("AutoBonfire", false)
        setToggleControl(bonfireToggleControl, false)
        StationSackFarm.Reset("bonfire")
        stationStatus("bonfire", "off", "MAX level 7 reached; stopped")
        notify("Auto Bonfire", "Bonfire reached max level; automation stopped", 2.5)
    end

    local function ensureStationSupervisor()
        if stationSupervisorRunning then return end
        stationSupervisorRunning = true
        task.spawn(function()
            while scriptAlive do
                for _, kind in ipairs({ "bonfire", "grinder" }) do
                    if stationEnabled(kind) then
                        if kind == "bonfire" and bonfireIsMax() then
                            stopBonfireAtMaximum()
                            continue
                        end
                        local state = stationRuntime[kind]
                        local stale = stationWorkerRunning[kind]
                            and stationWorkerPulseAt[kind] > 0
                            and os.clock() - stationWorkerPulseAt[kind] >= 18
                        local noProgress = stationWorkerRunning[kind]
                            and state.progressAt > 0 and os.clock() - state.progressAt >= 30
                            and (state.phase == "searching" or state.phase == "picking-up"
                                or state.phase == "retrying-pickup" or state.phase == "retrying-drop"
                                or state.phase == "streaming-station")
                        if stale or noProgress then
                            warn("[SEA Station Supervisor] stalled " .. kind .. " worker restarted")
                            if kind == "bonfire" then
                                bonfireGeneration = bonfireGeneration + 1
                            else
                                grinderGeneration = grinderGeneration + 1
                            end
                            interruptAutomationMovement()
                            stationWorkerRunning[kind] = false
                            recoverAbandonedStationWorker(kind)
                            stationStatus(kind, "recovering", "Restarting stalled worker; Sack and route preserved", true)
                            task.wait(0.12)
                        end
                        if not stationWorkerRunning[kind] then
                            startStationWorker(kind)
                        end
                    end
                end
                task.wait(1.5)
            end
            stationSupervisorRunning = false
        end)
    end

    startStationWorker = function(kind)
        if stationWorkerRunning[kind] or not stationEnabled(kind) then return end
        local generation = stationGeneration(kind)
        stationWorkerRunning[kind] = true
        stationWorkerPulseAt[kind] = os.clock()
        stationRuntime[kind].progressAt = os.clock()

        task.spawn(function()
            if generation ~= stationGeneration(kind) then return end
            stationWorkerThreads[kind] = coroutine.running()
            local workerOk, workerError = xpcall(function()
                while scriptAlive
                    and stationEnabled(kind)
                    and generation == stationGeneration(kind)
                do
                    stationWorkerPulseAt[kind] = os.clock()
                    if kind == "bonfire" and bonfireIsMax() then
                        -- Level 7 remains Auto Bonfire's only automatic stop.
                        stopBonfireAtMaximum()
                        return
                    end

                    local stepOk, stepError = pcall(
                        kind == "bonfire" and bonfireStep or grinderStep,
                        generation
                    )
                    if generation ~= stationGeneration(kind) then break end
                    stationWorkerPulseAt[kind] = os.clock()
                    if not stepOk then
                        stationStatus(kind, "retrying-pickup", "Recovering from error: " .. tostring(stepError))
                        warn("[SEA Auto " .. kind .. "] " .. tostring(stepError))
                        local now = os.clock()
                        local key = kind .. "ErrorNotice"
                        if now - (stationNextSearchAt[key] or 0) >= 5 then
                            stationNextSearchAt[key] = now
                            notify(
                                kind == "bonfire" and "Auto Bonfire Recovery" or "Auto Grinder Recovery",
                                "Transient error; continuous full-map scan is still active",
                                2.5
                            )
                        end
                    end
                    task.wait(0.10)
                end
            end, function(message)
                return tostring(message)
            end)

            if not workerOk then
                warn("[SEA Station Worker Shell] " .. kind .. ": " .. tostring(workerError))
            end
            if generation == stationGeneration(kind) then
                stationWorkerRunning[kind] = false
                if stationEnabled(kind) then
                    task.defer(function() startStationWorker(kind) end)
                end
            end
        end)
        ensureStationSupervisor()
    end

    function api.GetCraftNames()
        loadCraftingItems()
        local copy = {}
        for _, name in ipairs(craftingNames) do copy[#copy + 1] = name end
        return copy
    end

    function api.GetCraftStatus()
        return autoCraftEnabled and craftStatus or "Off"
    end

    function api.SetBuilderCraftOwner(enabled)
        builderOwnsOutpost = enabled == true
    end

    function api.CraftOutpost(canContinue)
        loadCraftingItems()
        local affordable, reason = canAffordCraft(craftingByName["Outpost"])
        if not affordable then return false, reason end
        return invokeCraft("Outpost", canContinue)
    end

    function api.GetBonfireItems()
        return StationSackFarm.GetCatalog("bonfire")
    end

    function api.GetStationStatusText()
        return "Bonfire: " .. stationRuntime.bonfire.message
            .. "\nGrinder: " .. stationRuntime.grinder.message
    end

    function api.GetSelectedBonfireItems()
        return StationSackFarm.GetSelected("bonfire")
    end

    function api.SetBonfireItems(values)
        StationSackFarm.SetSelected("bonfire", values)
    end

    function api.SetBonfireItemsDropdown(control)
        StationSackFarm.SetDropdown("bonfire", control)
    end

    function api.GetGrinderItems()
        return StationSackFarm.GetCatalog("grinder")
    end

    function api.GetSelectedGrinderItems()
        return StationSackFarm.GetSelected("grinder")
    end

    function api.SetGrinderItems(values)
        StationSackFarm.SetSelected("grinder", values)
    end

    function api.SetGrinderItemsDropdown(control)
        StationSackFarm.SetDropdown("grinder", control)
    end

    function api.RefreshStationItems(showNotification)
        return StationSackFarm.Refresh(showNotification)
    end

    function api.GetGrinderResources()
        return collectGrinderResourceNames()
    end

    function api.SetGrinderResourceDropdown(control)
        grinderResourceDropdown = control
    end

    function api.RefreshGrinderResources(showNotification)
        local values = collectGrinderResourceNames()
        if grinderResourceDropdown then
            pcall(function() grinderResourceDropdown:Refresh(values) end)
        end
        if showNotification then
            notify(
                "Grinder Types",
                "Detected " .. tostring(math.max(0, #values - 1))
                    .. " Resource types; All accepts any future Resource value",
                2.5
            )
        end
        return values
    end

    function api.SetBonfireToggle(control) bonfireToggleControl = control end
    function api.SetGrinderToggle(control) grinderToggleControl = control end

    function api.SetUnlimitedAmmoToggle(control)
        unlimitedAmmoToggleControl = control
    end

    function api.SetUnlimitedAmmo(enabled, shouldSave)
        enabled = enabled == true
        unlimitedAmmoGeneration = unlimitedAmmoGeneration + 1

        if enabled and not ammoPatchSupported() then
            unlimitedAmmoEnabled = false
            Config:Set("UnlimitedAmmo", false)
            if unlimitedAmmoToggleControl then
                task.defer(function()
                    pcall(function() unlimitedAmmoToggleControl:Set(false, false) end)
                end)
            end
            notify(
                "Unlimited Ammo",
                "Executor needs getsenv plus debug get/setupvalue support",
                3
            )
            return false
        end

        unlimitedAmmoEnabled = enabled
        if shouldSave ~= false then Config:Set("UnlimitedAmmo", enabled) end
        if enabled then
            startUnlimitedAmmoWorker()
        else
            restoreAmmoPatches()
        end
        return true
    end

    function api.SetRapidFireToggle(control)
        rapidFireState.toggleControl = control
    end

    function api.SetExperimentalRapidFire(enabled, shouldSave)
        enabled = enabled == true
        rapidFireState.generation = rapidFireState.generation + 1

        if enabled and not executorFunction("getsenv") then
            rapidFireState.enabled = false
            Config:Set("ExperimentalRapidFire", false)
            if rapidFireState.toggleControl then
                task.defer(function()
                    pcall(function() rapidFireState.toggleControl:Set(false, false) end)
                end)
            end
            notify("Rapid Fire", "Executor needs getsenv support", 3)
            return false
        end

        rapidFireState.enabled = enabled
        rapidFireState.held = false
        if shouldSave ~= false then Config:Set("ExperimentalRapidFire", enabled) end
        if enabled then
            startRapidFireWorker()
            notify(
                "Rapid Fire",
                "Experimental client bypass enabled; hold attack with a supported weapon",
                3
            )
        else
            endRapidFireLaser()
        end
        return true
    end

    function api.SetAutoBonfire(enabled, shouldSave)
        enabled = enabled == true
        if enabled == autoBonfireEnabled then
            if shouldSave ~= false then Config:Set("AutoBonfire", enabled) end
            if enabled then startStationWorker("bonfire") end
            return enabled
        end
        if enabled and Travel then Travel.Stop("Auto Bonfire started") end
        if enabled and autoGrinderEnabled then
            api.SetAutoGrinder(false)
            setToggleControl(grinderToggleControl, false)
        end
        if enabled and WorldLoot.Enabled then
            WorldLoot.DisableForStation("Auto Bonfire")
        end
        autoBonfireEnabled = enabled
        bonfireGeneration = bonfireGeneration + 1
        interruptAutomationMovement()
        recoverAbandonedStationWorker("bonfire")
        StationSackFarm.Reset("bonfire")
        stationWorkerRunning.bonfire = false
        stationWorkerPulseAt.bonfire = os.clock()
        stationStatus("bonfire", enabled and "searching" or "off", enabled and "Starting continuous search" or "Off", true)
        if shouldSave ~= false then Config:Set("AutoBonfire", enabled) end

        if enabled then
            startStationWorker("bonfire")
            ensureStationSupervisor()
        end
        return enabled
    end

    function api.SetAutoGrinder(enabled, shouldSave)
        enabled = enabled == true
        if enabled == autoGrinderEnabled then
            if shouldSave ~= false then Config:Set("AutoGrinder", enabled) end
            if enabled then startStationWorker("grinder") end
            return enabled
        end
        if enabled and Travel then Travel.Stop("Auto Grinder started") end
        if enabled and autoBonfireEnabled then
            api.SetAutoBonfire(false)
            setToggleControl(bonfireToggleControl, false)
        end
        if enabled and WorldLoot.Enabled then
            WorldLoot.DisableForStation("Auto Grinder")
        end
        autoGrinderEnabled = enabled
        grinderGeneration = grinderGeneration + 1
        interruptAutomationMovement()
        recoverAbandonedStationWorker("grinder")
        StationSackFarm.Reset("grinder")
        stationWorkerRunning.grinder = false
        stationWorkerPulseAt.grinder = os.clock()
        stationStatus("grinder", enabled and "searching" or "off", enabled and "Starting continuous search" or "Off", true)
        if shouldSave ~= false then Config:Set("AutoGrinder", enabled) end

        if enabled then
            startStationWorker("grinder")
            ensureStationSupervisor()
        end
        return enabled
    end

    function api.StopStationFarmsForWorldLoot()
        local stopped = false
        if autoBonfireEnabled then
            stopped = true
            api.SetAutoBonfire(false)
            setToggleControl(bonfireToggleControl, false)
        end
        if autoGrinderEnabled then
            stopped = true
            api.SetAutoGrinder(false)
            setToggleControl(grinderToggleControl, false)
        end
        return stopped
    end

    function api.SetAutoCraft(enabled, shouldSave)
        autoCraftEnabled = enabled == true
        craftGeneration = craftGeneration + 1
        if shouldSave ~= false then Config:Set("AutoCraft", autoCraftEnabled) end
        if autoCraftEnabled and not craftWorkerRunning then
            craftWorkerRunning = true
            task.spawn(function()
                while scriptAlive and autoCraftEnabled do
                    local ok, crafted = pcall(craftStep, craftGeneration)
                    if not ok then
                        craftStatus = "Craft error: " .. tostring(crafted)
                    end
                    -- Refill free lanes every frame. Idle recipes back off; replies
                    -- complete independently, so one network RTT no longer blocks all crafting.
                    task.wait(ok and (crafted > 0 or next(pendingCraft) ~= nil) and 0 or 0.10)
                end
                craftWorkerRunning = false
            end)
        end
    end

    function api.SetAutoEat(enabled, shouldSave)
        autoEatEnabled = enabled == true
        eatGeneration = eatGeneration + 1
        local generation = eatGeneration
        if shouldSave ~= false then Config:Set("AutoEat", autoEatEnabled) end
        if autoEatEnabled then
            task.spawn(function()
                while scriptAlive and autoEatEnabled and generation == eatGeneration do
                    local ok, reason = pcall(eatOne)
                    if not ok then
                        warn("[SEA Auto Eat] " .. tostring(reason))
                    end
                    task.wait(1.0)
                end
            end)
        end
    end

    connect(localPlayer.CharacterAdded, function()
        local activeKind = autoBonfireEnabled and "bonfire"
            or (autoGrinderEnabled and "grinder" or nil)
        if not activeKind then return end

        if activeKind == "bonfire" then
            bonfireGeneration = bonfireGeneration + 1
        else
            grinderGeneration = grinderGeneration + 1
        end
        stationWorkerRunning[activeKind] = false
        interruptAutomationMovement()
        recoverAbandonedStationWorker(activeKind)
        task.delay(0.8, function()
            if scriptAlive and stationEnabled(activeKind) then
                startStationWorker(activeKind)
            end
        end)
    end)

    function api.StopForUnload()
        autoBonfireEnabled = false
        autoGrinderEnabled = false
        autoCraftEnabled = false
        autoEatEnabled = false
        unlimitedAmmoEnabled = false
        rapidFireState.enabled = false
        rapidFireState.held = false
        bonfireGeneration = bonfireGeneration + 1
        grinderGeneration = grinderGeneration + 1
        craftGeneration = craftGeneration + 1
        eatGeneration = eatGeneration + 1
        unlimitedAmmoGeneration = unlimitedAmmoGeneration + 1
        rapidFireState.generation = rapidFireState.generation + 1
        restoreAmmoPatches()
        endRapidFireLaser()
        interruptAutomationMovement()
        recoverAbandonedStationWorker("bonfire")
        recoverAbandonedStationWorker("grinder")
        setStationBusy(false, true)
        stationWorkerRunning.bonfire = false
        stationWorkerRunning.grinder = false
        SharedInteraction.Release("station", true)
        SharedInteraction.Release("station-search", true)
        SharedInteraction.Release("station-drop", true)
    end

    return api
end)()

-- Builderman: the supplied place uses Crafted.Item for recipe identity,
-- BuildableItem/BuildableCount on placement tools, and a camera-owned green
-- ghost for validated grid placement. Teardown takes the model's unique Name.
local Builder: any = (function()
    local api = {}
    local removeEnabled, placeEnabled = false, false
    local running, generation = false, 0
    local pending = {} -- one remove and one place response at most
    local placement
    local removeNotBefore, craftNotBefore, placeNotBefore = 0, 0, 0
    local message = "Ready. Enable a Builder action."
    local removedCount, placedCount = 0, 0
    local removeToggle, placeToggle
    local wrenchScripts = {}

    local function restoreWrenchScripts()
        for client, saved in pairs(wrenchScripts) do
            local ok = pcall(function()
                if client.Parent then
                    -- Restore in Backpack so the native script can start cleanly
                    -- on the next manual equip, including after Stop / respawn.
                    if saved.tool.Parent == getCharacter() then
                        local humanoid = getHumanoid()
                        if humanoid then humanoid:UnequipTools() end
                    end
                    client.Disabled = saved.disabled
                end
            end)
            if ok then wrenchScripts[client] = nil end
        end
    end

    local function prepareWrench(tool, canRun)
        local client = tool:FindFirstChild("WrenchClient")
        if not client or not client:IsA("LocalScript") then return true end
        if wrenchScripts[client] then return client.Disabled == true end
        -- WrenchClient's Heartbeat highlight calls tool.Parent:GetPivot() even
        -- during a tool switch, when Parent is Backpack. Builder already supplies
        -- the exact teardown target; its native aiming UI is not needed here.
        if tool.Parent == getCharacter() then
            getHumanoid():UnequipTools()
            RunService.Heartbeat:Wait() -- let native Unequipped clean its UI first
        end
        if not canRun() then return false end
        local ok = pcall(function()
            local saved = { tool = tool, disabled = client.Disabled }
            wrenchScripts[client] = saved
            client.Disabled = true
        end)
        return ok and client.Disabled == true
    end

    local function nativeFunction(name)
        -- Farm Pearl resolves the game's runtime globals before executor _G.
        if type(getrenv) == "function" then
            local ok, runtime = pcall(getrenv)
            local candidate = ok and type(runtime) == "table"
                and type(runtime._G) == "table" and runtime._G[name]
            if type(candidate) == "function" then return candidate end
        end
        return type(_G) == "table" and _G[name] or nil
    end

    local function craftedFolder()
        local island = workspace:FindFirstChild("SpawnIsland")
        return island and island:FindFirstChild("Crafted")
    end

    local function isOutpost(model)
        return model and model:IsA("Model")
            and (model:GetAttribute("Item") == "Outpost" or model.Name == "Outpost")
    end

    local function nearestOutpost()
        local folder, root = craftedFolder(), getHumanoidRootPart()
        local nearest, distance = nil, math.huge
        if folder and root then
            for _, model in ipairs(folder:GetChildren()) do
                if isOutpost(model) then
                    local candidateDistance = (model:GetPivot().Position - root.Position).Magnitude
                    if candidateDistance < distance then nearest, distance = model, candidateDistance end
                end
            end
        end
        return nearest, distance
    end

    local function findTool(itemName)
        local function scan(container)
            if not container then return nil end
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") and (itemName == "Wrench" and tool.Name == "Wrench"
                    or itemName == "Outpost" and tool:GetAttribute("BuildableItem") == "Outpost")
                    and (tonumber(tool:GetAttribute("BuildableCount")) or 1) > 0
                then return tool end
            end
            return nil
        end
        return scan(getCharacter()) or scan(localPlayer:FindFirstChildOfClass("Backpack"))
    end

    local function equip(tool, canRun)
        local character, humanoid = getCharacter(), getHumanoid()
        if not canRun() or not tool or not tool.Parent or not humanoid then return false end
        if tool.Parent ~= character then
            humanoid:EquipTool(tool)
            RunService.Heartbeat:Wait()
        end
        return canRun() and tool.Parent == character and tool.Enabled ~= false
    end

    local function greenPreview(tool)
        if not tool or tool.Parent ~= getCharacter() then return nil end
        local camera = workspace.CurrentCamera
        local assets = ReplicatedStorage:FindFirstChild("Assets")
        local templates = assets and assets:FindFirstChild("Buildables")
        local template = templates and templates:FindFirstChild("Outpost")
        local ghost = camera and camera:FindFirstChild(template and template.Name or "Outpost")
        local highlight = ghost and ghost:FindFirstChildOfClass("Highlight")
        -- The native client publishes green only after checking the grid cell,
        -- supporting foundation and height. Its pivot is the PlaceBuildable CFrame.
        if ghost and ghost:IsA("Model") and highlight
            and highlight.FillColor == Color3.fromRGB(72, 220, 110)
        then return ghost:GetPivot() end
        return nil
    end

    local function observe(ticket)
        if ticket.observed then return true end
        local result = ticket.confirm()
        if not result then return false end
        ticket.observed = true
        if ticket.kind == "remove" then
            removedCount = removedCount + 1
        else
            placedCount = placedCount + 1
            placement = result:GetPivot()
        end
        return true
    end

    local function request(kind, target, canRun, confirm)
        if pending[kind] then return false, "Waiting for previous " .. kind .. " response" end
        if not canRun() then return false, "Cancelled" end
        local native = nativeFunction(kind == "remove" and "ToolProcessor" or "PlaceBuildable")
        local network = type(native) ~= "function" and getGameNetwork() or nil
        if type(native) ~= "function" and not network then return false, "Builder network is not ready" end
        local ticket = { done = false, kind = kind, confirm = confirm }
        pending[kind] = ticket
        task.spawn(function()
            if not canRun() then ticket.rejected = true; ticket.done = true; return end
            local ok, result = pcall(function()
                if kind == "remove" then
                    if type(native) == "function" then return native("Wrench", "Teardown", target) end
                    return network:InvokeServer("ToolReplicator", "Wrench", "Teardown", target)
                end
                if type(native) == "function" then return native("Outpost", target, nil) end
                return network:InvokeServer("PlaceBuildable", "Outpost", target, nil)
            end)
            -- A thrown request may already have reached the server. Retain that
            -- ticket until replication confirms it; only explicit false rejects.
            ticket.rejected = ok and result == false
            ticket.done = true
        end)
        local deadline = os.clock() + 6
        repeat
            if not canRun() then return false, "Cancelled" end
            if observe(ticket) then
                if ticket.done then pending[kind] = nil end
                return true, "Confirmed " .. kind
            end
            if ticket.done and ticket.rejected then
                pending[kind] = nil
                return false, "Server declined " .. kind
            end
            if SharedInteraction.Touch then SharedInteraction.Touch("builder") end
            RunService.Heartbeat:Wait()
        until os.clock() >= deadline
        return false, "Waiting for " .. kind .. " replication / response"
    end

    local function step(canRun)
        if localPlayer:GetAttribute("Class") ~= "Builderman" then
            restoreWrenchScripts()
            message = "Requires Builderman class"
            return
        end
        local root, humanoid = getHumanoidRootPart(), getHumanoid()
        if not root or not humanoid or humanoid.Health <= 0 or humanoid.SeatPart then
            restoreWrenchScripts()
            message = "Waiting for a living, unseated character"
            return
        end
        if not craftedFolder() then restoreWrenchScripts(); message = "Waiting for SpawnIsland.Crafted"; return end
        -- Let existing Sack/route workers own their tools; resume when they stop.
        if Config:Get("AutoLootWorld") == true or Config:Get("AutoBonfire") == true
            or Config:Get("AutoGrinder") == true or Config:Get("AutoChestAndLoot") == true
            or Config:Get("FlyEnabled") == true or (Travel and Travel.Busy)
        then restoreWrenchScripts(); message = "Paused while travel / Sack automation is active"; return end

        for kind, ticket in pairs(pending) do
            local confirmed = observe(ticket)
            if ticket.done and (confirmed or ticket.rejected) then
                pending[kind] = nil
            elseif not confirmed then
                message = "Waiting for " .. kind .. " replication / response"
                return
            end
        end

        local existing, distance = nearestOutpost()
        if existing then
            if not removeEnabled then message = "Outpost is already placed"; return end
            if pending.remove then message = "Waiting for previous remove response"; return end
            if distance > Config:Get("BuilderRemoveRadius") then
                message = "Move within " .. tostring(Config:Get("BuilderRemoveRadius")) .. " studs of the Outpost"
                return
            end
            if existing:GetAttribute("Active") == true then message = "Outpost is active; waiting to remove"; return end
            if os.clock() < removeNotBefore then return end
            local wrench = findTool("Wrench")
            if not wrench then message = "Wrench is required in your Backpack"; return end
            if not prepareWrench(wrench, canRun) then message = "Waiting for Wrench callback cleanup"; return end
            if not equip(wrench, canRun) then message = "Waiting to equip Wrench"; return end
            if not canRun() or existing.Parent ~= craftedFolder() or existing:GetAttribute("Active") == true then return end
            placement = existing:GetPivot()
            -- The Wrench UI's one-second debounce is not a server acknowledgement.
            -- Confirm this model disappeared; successful new cycles need no fixed pause.
            removeNotBefore = os.clock() + 0.08
            message = "Removing Outpost with Wrench..."
            local folder = craftedFolder()
            local accepted, reason = request("remove", existing.Name, canRun, function()
                return existing.Parent ~= folder
            end)
            if not canRun() then return end
            if not accepted then message = reason; removeNotBefore = os.clock() + 0.20; return end
            removeNotBefore = 0
            message = "Outpost removed; position remembered"
            return true
        end

        if not placeEnabled then message = "Waiting for an Outpost in Wrench range"; return end
        if pending.place then message = "Waiting for previous place response"; return end
        local tool = findTool("Outpost")
        if not tool then
            if os.clock() < craftNotBefore then return end
            message = "Crafting Outpost..."
            local crafted, reason = Automation.CraftOutpost(canRun)
            if not canRun() then return end
            message = reason
            if not crafted then craftNotBefore = os.clock() + 0.08; return end
            -- Craft returns before the placement Tool always finishes replicating.
            -- Do not buy another Outpost while the first tool is still arriving.
            craftNotBefore = os.clock() + 2
            local deadline = os.clock() + 2
            repeat
                tool = findTool("Outpost")
                if tool then break end
                RunService.Heartbeat:Wait()
            until not canRun() or os.clock() >= deadline
            if not tool then message = "Waiting for crafted Outpost tool"; return end
        end
        craftNotBefore = 0 -- tool arrived: do not carry its two-second timeout into the next cycle
        if not equip(tool, canRun) then message = "Waiting to equip Outpost"; return end
        local target = placement or greenPreview(tool)
        if not target then
            message = "Face a free supported grid cell until the Outpost preview turns green"
            return
        end
        if (target.Position - root.Position).Magnitude > 200 then
            message = "Move closer to the saved Outpost position or clear it"
            return
        end
        if os.clock() < placeNotBefore then return end
        if not canRun() or nearestOutpost() then return end
        message = "Placing Outpost..."
        local folder = craftedFolder()
        local accepted, reason = request("place", target, canRun, function()
            if craftedFolder() ~= folder then return nil end
            for _, model in ipairs(folder:GetChildren()) do
                if isOutpost(model) and (model:GetPivot().Position - target.Position).Magnitude <= 8 then
                    return model
                end
            end
            return nil
        end)
        if not canRun() then return end
        if not accepted then message = reason; placeNotBefore = os.clock() + 0.5; return end
        message = "Outpost placed"
        placeNotBefore = 0
        return true
    end

    local function startWorker()
        if running then return end
        running = true
        task.spawn(function()
            while scriptAlive and (removeEnabled or placeEnabled) do
                local run, token, character = generation, getMovementRevision(), getCharacter()
                local function canRun()
                    local humanoid = getHumanoid()
                    return scriptAlive and run == generation and (removeEnabled or placeEnabled)
                        and token == getMovementRevision() and character == getCharacter()
                        and character ~= nil and humanoid ~= nil and humanoid.Health > 0
                end
                if SharedInteraction.TryAcquire("builder") then
                    local ok, reason = pcall(function()
                        -- Chain confirmed remove -> craft/place immediately. Bound
                        -- the chain to two stages so other workers still get time.
                        for _ = 1, 2 do
                            if not canRun() or not step(canRun) then break end
                        end
                    end)
                    SharedInteraction.Release("builder")
                    if not ok then restoreWrenchScripts(); message = "Builder error: " .. tostring(reason) end
                else
                    message = "Waiting for current interaction"
                end
                RunService.Heartbeat:Wait()
            end
            restoreWrenchScripts()
            running = false
        end)
    end

    function api.SetRemove(enabled)
        removeEnabled = enabled == true
        generation = generation + 1
        if removeEnabled then startWorker() end
        if not removeEnabled then restoreWrenchScripts() end
    end

    function api.SetPlace(enabled)
        placeEnabled = enabled == true
        generation = generation + 1
        Automation.SetBuilderCraftOwner(placeEnabled)
        if placeEnabled then startWorker() end
    end

    function api.Stop()
        api.SetRemove(false)
        api.SetPlace(false)
        if removeToggle then removeToggle:Set(false, false) end
        if placeToggle then placeToggle:Set(false, false) end
        message = "Stopped"
    end

    function api.GetStatus()
        return (removeEnabled or placeEnabled) and message
            .. string.format(" | Removed: %d | Placed: %d", removedCount, placedCount) or "Off"
    end

    function api.BuildUI(tab)
        local section = tab:Section({ Title = "Builderman - Outpost" })
        section:Paragraph({
            Title = "Remove + Craft + Place",
            Desc = "Enable both actions to repeat the Outpost cycle. Remove uses Wrench within 25 studs. Place uses the green building preview or the last removed Outpost position. Outpost needs unlock, bonfire level 4, stock and resources.",
        })
        local statusControl = section:Paragraph({ Title = "Builder status", Desc = api.GetStatus() })
        removeToggle = section:Toggle({
            Title = "Auto Remove Outpost (Wrench)",
            Desc = "Equips Wrench and removes the nearest inactive Outpost in range",
            Value = false,
            Callback = api.SetRemove,
        })
        placeToggle = section:Toggle({
            Title = "Auto Craft + Place Outpost (Super Fast)",
            Desc = "Crafts when needed, equips the Outpost tool and confirms placement",
            Value = false,
            Callback = api.SetPlace,
        })
        section:Slider({
            Title = "Wrench Remove Radius", Step = 1,
            Value = { Min = 5, Max = 25, Default = Config:Get("BuilderRemoveRadius") },
            Callback = function(value) Config:Set("BuilderRemoveRadius", value) end,
        })
        section:Button({
            Title = "Clear Saved Outpost Position",
            Desc = "Use a new green preview for the next placement",
            Callback = function() generation = generation + 1; placement = nil; message = "Position cleared" end,
        })
        section:Button({ Title = "Stop Builder", Callback = api.Stop })
        task.spawn(function()
            local previous
            while scriptAlive do
                local current = api.GetStatus()
                if current ~= previous then
                    previous = current
                    statusControl:Set(current, "Builder status")
                end
                task.wait(0.25)
            end
        end)
    end

    return api
end)()

stopStationFarmsForWorldLoot = function()
    local stopped = Automation.StopStationFarmsForWorldLoot()
    if stopped then
        notify("World Loot", "Bonfire/Grinder was disabled so World Auto Loot can own the Sack route", 2.2)
    end
end


-- Safe legacy click-to-void logic -------------------------------------------

local clickKillConnection

local LEGACY_KNOWN_HOSTILE_NAMES = {}
for _, creatureName in ipairs(CREATURE_NAMES) do
    LEGACY_KNOWN_HOSTILE_NAMES[normalizeInstanceName(creatureName)] = true
end

local LEGACY_ENEMY_CONTAINER_NAMES = {
    creaturecontainer = true,
    creatures = true,
    enemycontainer = true,
    enemies = true,
    hostilecontainer = true,
    hostiles = true,
    monsters = true,
    mobs = true,
}

local LEGACY_PROTECTED_CONTAINER_NAMES = {
    friendlynpc = true,
    friendlynpcs = true,
    questnpc = true,
    questnpcs = true,
    questgiver = true,
    questgivers = true,
    merchant = true,
    merchants = true,
    vendor = true,
    vendors = true,
    allies = true,
    companions = true,
    teammates = true,
    crew = true,
    crewmates = true,
    followers = true,
    pets = true,
    neutralnpc = true,
    neutralnpcs = true,
    tutorialnpc = true,
    tutorialnpcs = true,
}

local LEGACY_PROTECTED_NAME_HINTS = {
    "merchant",
    "fisherman",
    "quest",
    "questgiver",
    "questnpc",
    "vendor",
    "trader",
    "shopkeeper",
    "friendly",
    "teammate",
    "companion",
    "crewmate",
    "follower",
    "ally",
    "civilian",
    "villager",
    "recruit",
    "survivor",
    "tutorialnpc",
}

local LEGACY_PROTECTED_TAGS = {
    "Friendly",
    "FriendlyNPC",
    "Ally",
    "Companion",
    "Follower",
    "Pet",
    "Summon",
    "Teammate",
    "Crew",
    "CrewMember",
    "QuestNPC",
    "QuestGiver",
    "DialogueNPC",
    "StoryNPC",
    "Talkable",
    "Merchant",
    "Vendor",
    "Neutral",
    "ProtectedNPC",
    "Tamed",
    "Recruited",
}

local LEGACY_HOSTILE_TAGS = {
    "Enemy",
    "Hostile",
    "Monster",
}

local LEGACY_HOSTILE_NAME_HINTS = {
    "rival",
    "enemy",
    "hostile",
    "raider",
    "bandit",
    "marauder",
    "pirate",
    "aggressive",
    "predator",
}

local LEGACY_PROTECTED_BOOL_ATTRIBUTES = {
    "Friendly",
    "IsFriendly",
    "Ally",
    "IsAlly",
    "Companion",
    "IsCompanion",
    "Follower",
    "IsFollower",
    "Pet",
    "IsPet",
    "Summoned",
    "IsSummoned",
    "Teammate",
    "IsTeammate",
    "CrewMember",
    "IsCrewMember",
    "QuestNPC",
    "IsQuestNPC",
    "QuestGiver",
    "IsQuestGiver",
    "Neutral",
    "IsNeutral",
    "Protected",
    "IsProtected",
    "Tamed",
    "IsTamed",
    "Recruited",
    "IsRecruited",
}

local LEGACY_HOSTILE_BOOL_ATTRIBUTES = {
    "Enemy",
    "IsEnemy",
    "Hostile",
    "IsHostile",
    "Monster",
    "IsMonster",
}

local LEGACY_OWNER_ATTRIBUTE_NAMES = {
    "Owner",
    "OwnerPlayer",
    "OwnerName",
    "OwnerUserId",
    "OwnerId",
    "Player",
    "PlayerName",
    "PlayerUserId",
    "Creator",
    "CreatorUserId",
    "Summoner",
    "SummonerUserId",
}

local LEGACY_RELATION_ATTRIBUTE_NAMES = {
    "Faction",
    "Alignment",
    "Disposition",
    "Team",
    "TeamName",
    "NPCType",
    "Role",
}

local LEGACY_PROTECTED_RELATION_VALUES = {
    friendly = true,
    ally = true,
    allied = true,
    neutral = true,
    player = true,
    players = true,
    crew = true,
    teammate = true,
    companion = true,
    quest = true,
    questnpc = true,
    merchant = true,
    vendor = true,
    survivor = true,
    tamed = true,
    recruited = true,
}

local LEGACY_HOSTILE_RELATION_VALUES = {
    enemy = true,
    hostile = true,
    monster = true,
}

local function belongsToPlayerCharacter(model)
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        if character and (
            model:IsDescendantOf(character)
            or character:IsDescendantOf(model)
        ) then
            return true
        end
    end

    return false
end

local function legacyMarkerIsEnabled(value)
    if value == true then
        return true
    end

    if type(value) == "number" then
        return value ~= 0
    end

    if type(value) == "string" then
        local normalizedValue = normalizeInstanceName(value)
        return normalizedValue == "true"
            or normalizedValue == "yes"
            or normalizedValue == "enabled"
            or normalizedValue == "active"
            or normalizedValue == "1"
    end

    return false
end

local function legacyInstanceHasTag(instance, tagName)
    local success, tagged = pcall(function()
        return CollectionService:HasTag(instance, tagName)
    end)

    return success and tagged == true
end

local function legacyHasAnyTag(instance, tagNames)
    if not instance then
        return false
    end

    for _, tagName in ipairs(tagNames) do
        if legacyInstanceHasTag(instance, tagName) then
            return true
        end
    end

    return false
end

local function legacyGetAttribute(instance, attributeName)
    if not instance then
        return nil
    end

    local success, value = pcall(function()
        return instance:GetAttribute(attributeName)
    end)

    if success then
        return value
    end

    return nil
end

local function legacyHasEnabledAttribute(instance, attributeNames)
    for _, attributeName in ipairs(attributeNames) do
        if legacyMarkerIsEnabled(legacyGetAttribute(instance, attributeName)) then
            return true
        end
    end

    return false
end

local function legacyValueReferencesPlayer(value)
    local valueType = type(value)
    local numericValue

    if valueType == "number" or valueType == "string" then
        numericValue = tonumber(value)
    end

    for _, player in ipairs(Players:GetPlayers()) do
        local playerObject: any = player
        if value == playerObject or value == playerObject.Character then
            return true
        end

        if numericValue ~= nil and numericValue == playerObject.UserId then
            return true
        end

        if valueType == "string" then
            local normalizedValue = normalizeInstanceName(value)
            if normalizedValue == normalizeInstanceName(playerObject.Name)
                or normalizedValue == normalizeInstanceName(playerObject.DisplayName)
            then
                return true
            end
        end
    end

    return false
end

local function legacyHasPlayerOwnerAttribute(instance)
    for _, attributeName in ipairs(LEGACY_OWNER_ATTRIBUTE_NAMES) do
        if legacyValueReferencesPlayer(legacyGetAttribute(instance, attributeName)) then
            return true
        end
    end

    return false
end

local function legacyGetRelation(instance)
    for _, attributeName in ipairs(LEGACY_RELATION_ATTRIBUTE_NAMES) do
        local value = legacyGetAttribute(instance, attributeName)
        if type(value) == "string" and value ~= "" then
            return normalizeInstanceName(value)
        end
    end

    return nil
end

local function legacyRelationMatchesLocalTeam(relation)
    local team = localPlayer.Team
    return team ~= nil
        and relation ~= nil
        and relation == normalizeInstanceName(team.Name)
end

local function legacyHasHostileName(model)
    local normalizedName = normalizeInstanceName(model.Name)

    for _, hostileHint in ipairs(LEGACY_HOSTILE_NAME_HINTS) do
        if string.find(normalizedName, hostileHint, 1, true) then
            return true
        end
    end

    return false
end

local function legacyHasProtectedName(model, hostileName)
    local normalizedName = normalizeInstanceName(model.Name)

    for _, protectedHint in ipairs(LEGACY_PROTECTED_NAME_HINTS) do
        if string.find(normalizedName, protectedHint, 1, true) then
            -- "Rival Survivor" is hostile; only the generic Survivor label is
            -- overridden. Quest, merchant, companion, and other safe labels win.
            if protectedHint ~= "survivor" or not hostileName then
                return true
            end
        end
    end

    return false
end

local function legacyIsInProtectedContainer(model)
    local current = model.Parent

    for _ = 1, 16 do
        if not current or current == workspace then
            break
        end

        if LEGACY_PROTECTED_CONTAINER_NAMES[normalizeInstanceName(current.Name)] then
            return true
        end

        current = current.Parent
    end

    return false
end

local function legacyHasProtectedInteraction(model)
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("ProximityPrompt")
            or descendant:IsA("ClickDetector")
            or descendant:IsA("Dialog")
        then
            return true
        end
    end

    return false
end

local function legacyRelationIsProtected(relation, hostileName)
    if relation == "survivor" and hostileName then
        return false
    end

    return LEGACY_PROTECTED_RELATION_VALUES[relation] == true
end

local function legacyHasProtectedValue(model, hostileName)
    for _, descendant in ipairs(model:GetDescendants()) do
        local normalizedName = normalizeInstanceName(descendant.Name)

        if descendant:IsA("ObjectValue")
            and (
                string.find(normalizedName, "owner", 1, true)
                or string.find(normalizedName, "creator", 1, true)
                or string.find(normalizedName, "summoner", 1, true)
            )
            and legacyValueReferencesPlayer(descendant.Value)
        then
            return true
        end

        if (descendant:IsA("IntValue") or descendant:IsA("NumberValue"))
            and (
                string.find(normalizedName, "owneruserid", 1, true)
                or string.find(normalizedName, "ownerid", 1, true)
                or string.find(normalizedName, "playeruserid", 1, true)
            )
            and legacyValueReferencesPlayer(descendant.Value)
        then
            return true
        end

        if descendant:IsA("BoolValue") and legacyMarkerIsEnabled(descendant.Value) then
            for _, protectedName in ipairs(LEGACY_PROTECTED_BOOL_ATTRIBUTES) do
                if normalizedName == normalizeInstanceName(protectedName) then
                    return true
                end
            end
        end

        if descendant:IsA("StringValue") then
            local relation = normalizeInstanceName(descendant.Value)
            if legacyRelationIsProtected(relation, hostileName)
                or legacyRelationMatchesLocalTeam(relation)
            then
                return true
            end
        end
    end

    return false
end

-- User-selected legacy click effect ----------------------------------------
-- The verified combat catalog is always available, even when a creature has not
-- spawned. Refresh may append only live unknown rigs that expose a real supported
-- CreatureID/Humanoid kill path; quest NPCs and client-only render rigs stay out.

local NpcKill: any = (function()
local NPC_KILL_CATALOG = {
    -- Boss / boss-like encounters. The display name is readable; aliases are
    -- exact template/runtime names found in The Sea(2).rbxl.
    { category = "Boss", name = "Ancient Squid", aliases = { "SquidBoss", "Squid Boss", "AncientSquidBoss" } },
    { category = "Boss", name = "Ghost Pirate Captain", aliases = { "GhostPirateCaptain" } },
    { category = "Boss", name = "Greenbeard" },
    { category = "Boss", name = "Kraken Tentacle", aliases = { "KrakenTentacle", "Kraken" } },
    { category = "Boss", name = "Lord of Lava", aliases = { "GolemBoss", "Golem Boss", "Magma Boss", "MagmaBossNPC" } },
    { category = "Boss", name = "The Corrupt", aliases = { "CorruptBoss", "Corrupt Boss", "The Corruptor", "Corruptor" } },
    { category = "Boss", name = "Yeti Boss", aliases = { "YetiBoss", "Yeti", "Ice Boss" } },
    { category = "Boss", name = "Snorflord" },

    -- Humanoid combat creatures.
    { category = "Enemy", name = "Buku Boku" },
    { category = "Enemy", name = "Buku Buku" },
    { category = "Enemy", name = "Buku Poku" },
    { category = "Enemy", name = "Buku Toku" },
    { category = "Enemy", name = "Corrupt Crewman", aliases = { "CorruptCrewman", "Corrupt Crewmate" } },
    { category = "Enemy", name = "Corrupt Minigunner", aliases = { "CorruptMinigunner" } },
    { category = "Enemy", name = "Corrupt Officer", aliases = { "CorruptOfficer" } },
    { category = "Enemy", name = "Corrupt Scientist" },
    { category = "Enemy", name = "Ghost Bombardier", aliases = { "GhostBombardier", "Ghost Pirate Bombardier" } },
    { category = "Enemy", name = "Ghost Pirate", aliases = { "GhostPirate" } },
    { category = "Enemy", name = "Ghost Pirate Gunner", aliases = { "GhostPirateGunner" } },
    { category = "Enemy", name = "Magma Golem", aliases = { "MagmaGolem", "Fire Golem" } },
    { category = "Enemy", name = "Melee Alien", aliases = { "MeleeAlien", "Alien" } },
    { category = "Enemy", name = "Raygun Alien", aliases = { "RaygunAlien", "Alien Overlord" } },
    { category = "Enemy", name = "Small Alien", aliases = { "SmallAlien", "Alien Warrior" } },
    { category = "Enemy", name = "Skelly" },
    { category = "Enemy", name = "Pirate Skelly", aliases = { "PirateSkelly" } },

    -- Non-Humanoid combat creatures. These are NOT sent through the legacy
    -- HipHeight/root-void path. Smart Kill uses the game's CreatureID +
    -- Harpoon/Riptide ToolReplicator path instead.
    { category = "Creature", name = "Battle Crab", aliases = { "BattleCrab" } },
    { category = "Creature", name = "Corrupt Jellyfish" },
    { category = "Creature", name = "Crab" },
    { category = "Creature", name = "Ice Crab", aliases = { "IceCrab" } },
    { category = "Creature", name = "Ice Wolf", aliases = { "IceWolf" } },
    { category = "Creature", name = "Jellyfish" },
    { category = "Creature", name = "Killer Whale", aliases = { "KillerWhale" } },
    { category = "Creature", name = "Mimic", aliases = { "Chest Mimic" } },
    { category = "Creature", name = "Penguin" },
    { category = "Creature", name = "Polar Bear", aliases = { "PolarBear" } },
    { category = "Creature", name = "Salamander" },
    { category = "Creature", name = "Seagull" },
    { category = "Creature", name = "Shark" },
    { category = "Creature", name = "Snail", aliases = { "Magma Snail", "Lava Snail" } },
    { category = "Creature", name = "Sniffler" },
    { category = "Creature", name = "Snorfler" },
    { category = "Creature", name = "Squid Arm", aliases = { "SquidArm" } },
    { category = "Creature", name = "Wraith" },
    { category = "Creature", name = "Arctic Tern" },
    { category = "Creature", name = "Crow" },

}

local NPC_KILL_GENERIC_NAMES = {
    animationcontroller = true,
    animal = true,
    character = true,
    client = true,
    creature = true,
    enemy = true,
    health = true,
    hitbox = true,
    humanoid = true,
    mob = true,
    model = true,
    npc = true,
    rig = true,
    root = true,
    stats = true,
}

local selectedNpcKillKeys = {}
local npcKillOptionByLabel = {}
local npcKillOptionByKey = {}
local npcKillDropdown
local activeLegacyVoidBursts = setmetatable({}, { __mode = "k" })
-- This set stores Humanoids, numeric Health values, and models whose health is
-- exposed as an attribute. Client render rigs are tracked too, but a matching
-- server-facing model is always preferred before applying the effect.
local trackedNpcControllers = setmetatable({}, { __mode = "k" })
local rememberedNpcKillOptions = {}
local rememberedNpcKillOptionsLoaded = false

local LEGACY_VOID_BURST_ATTEMPTS = 14
local LEGACY_VOID_BURST_INTERVAL = 0.1
local NPC_CLICK_RESOLVE_RADIUS = 32
local NPC_CLIENT_PAIR_RADIUS = 90

local HEALTH_VALUE_NAMES = {
    health = true,
    hp = true,
    currenthealth = true,
}

local HEALTH_ATTRIBUTE_NAMES = {
    "Health",
    "HP",
    "CurrentHealth",
}

local function normalizeNpcKillName(value)
    local cleanedValue = tostring(value or ""):gsub("_CLIENT$", "")
    local normalized = normalizeInstanceName(cleanedValue)

    -- Strip wrappers used for runtime/client clones while leaving meaningful
    -- words intact. This keeps Ghost Pirate separate from its Gunner variant.
    for _ = 1, 4 do
        local previous = normalized

        for _, prefix in ipairs({ "npc", "enemy", "mob", "creature", "animal" }) do
            if #normalized > #prefix
                and string.sub(normalized, 1, #prefix) == prefix
            then
                normalized = string.sub(normalized, #prefix + 1)
                break
            end
        end

        local withoutDigits = normalized:gsub("%d+$", "")
        if withoutDigits ~= "" then
            normalized = withoutDigits
        end

        local withoutClone = normalized:gsub("clone%d*$", "")
        if withoutClone ~= "" then
            normalized = withoutClone
        end

        for _, suffix in ipairs({
            "client",
            "rig",
            "model",
            "npc",
            "enemy",
            "mob",
            "creature",
            "animal",
        }) do
            if #normalized > #suffix
                and string.sub(normalized, -#suffix) == suffix
            then
                normalized = string.sub(normalized, 1, #normalized - #suffix)
                break
            end
        end

        if normalized == previous then
            break
        end
    end

    return normalized
end

-- Canonical identity groups solve client/server naming differences such as
-- CorruptJellyfish_CLIENT -> Corrupt Jellyfish and CorruptBoss -> The Corrupt.
local NPC_CANONICAL_ALIAS_GROUPS = {
    { "Corrupt Jellyfish", "CorruptJellyfish", "JellyCorrupt", "Jelly Corrupt", "Corrupted Jellyfish", "CorruptedJellyfish" },
    { "The Corrupt", "CorruptBoss", "Corrupt Boss", "The Corruptor", "Corruptor" },
    { "Ancient Squid", "SquidBoss", "Squid Boss", "AncientSquidBoss" },
    { "Lord of Lava", "GolemBoss", "Golem Boss", "Magma Boss", "MagmaBossNPC" },
    { "Yeti Boss", "YetiBoss", "Yeti", "Ice Boss" },
    { "Magma Golem", "MagmaGolem", "Fire Golem" },
    { "Ghost Pirate Captain", "GhostPirateCaptain" },
    { "Ghost Pirate Gunner", "GhostPirateGunner" },
    { "Ghost Bombardier", "GhostBombardier", "Ghost Pirate Bombardier" },
    { "Corrupt Crewman", "CorruptCrewman", "Corrupt Crewmate" },
    { "Corrupt Officer", "CorruptOfficer" },
    { "Corrupt Minigunner", "CorruptMinigunner" },
    { "Battle Crab", "BattleCrab" },
    { "Killer Whale", "KillerWhale" },
    { "Polar Bear", "PolarBear" },
    { "Ice Wolf", "IceWolf" },
    { "Ice Crab", "IceCrab" },
    { "Pirate Skelly", "PirateSkelly" },
    { "Melee Alien", "MeleeAlien", "Alien" },
    { "Raygun Alien", "RaygunAlien", "Alien Overlord" },
    { "Small Alien", "SmallAlien", "Alien Warrior" },
}

local npcCanonicalAlias = {}
for _, group in ipairs(NPC_CANONICAL_ALIAS_GROUPS) do
    local canonical = normalizeNpcKillName(group[1])
    for _, alias in ipairs(group) do
        npcCanonicalAlias[normalizeNpcKillName(alias)] = canonical
    end
end

local function canonicalNpcKillName(value)
    local normalized = normalizeNpcKillName(value)
    return npcCanonicalAlias[normalized] or normalized
end

-- Every curated entry above maps to one of the 45 combat creature templates in
-- ReplicatedStorage.Assets.Creatures. This identity set is also used to accept a
-- legacy Humanoid rig without accidentally accepting merchants, quest NPCs,
-- companions, ragdolls, or player-shaped scenery.
local npcKillCatalogIdentity = {}
for _, entry in ipairs(NPC_KILL_CATALOG) do
    npcKillCatalogIdentity[canonicalNpcKillName(entry.name)] = true
    for _, alias in ipairs(entry.aliases or {}) do
        npcKillCatalogIdentity[canonicalNpcKillName(alias)] = true
    end
end

local function isClientCreatureModel(model)
    if not model or not model:IsA("Model") then
        return false
    end
    return string.sub(string.upper(tostring(model.Name)), -7) == "_CLIENT"
end

local function isNumericHealthValue(instance)
    if not instance then
        return false
    end

    if not (instance:IsA("NumberValue") or instance:IsA("IntValue")) then
        return false
    end

    return HEALTH_VALUE_NAMES[string.lower(tostring(instance.Name))] == true
end

local function getModelHealthAttribute(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    for _, attributeName in ipairs(HEALTH_ATTRIBUTE_NAMES) do
        local success, value = pcall(function()
            return model:GetAttribute(attributeName)
        end)
        if success and type(value) == "number" then
            return value
        end
    end

    return nil
end

local function getNpcEntityRootPart(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    for _, partName in ipairs({
        "Root",
        "HumanoidRootPart",
        "Center", -- CorruptBoss uses Center instead of a normal Root BasePart.
        "Torso",
        "UpperTorso",
    }) do
        local part = model:FindFirstChild(partName, true)
        if part and part:IsA("BasePart") then
            return part
        end
    end

    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
        return model.PrimaryPart
    end

    return getTargetPart(model)
end

local function modelHasCreatureID(model)
    if not model or not model:IsA("Model") then
        return false
    end

    local creatureId = model:FindFirstChild("CreatureID")
    return creatureId ~= nil
end

local function getCreatureEntityModel(model)
    local current = model
    for _ = 1, 10 do
        if not current or current == workspace then
            break
        end
        if current:IsA("Model") and modelHasCreatureID(current) then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function creatureEntityHealth(entity)
    if not entity or not entity.Parent then
        return 0
    end

    local humanoid = entity:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        return humanoid.Health
    end

    for _, descendant in ipairs(entity:GetDescendants()) do
        if isNumericHealthValue(descendant) then
            return descendant.Value
        end
    end

    return getModelHealthAttribute(entity) or 0
end

local function creatureEntityIsAlive(entity)
    local success, health = pcall(function()
        return creatureEntityHealth(entity)
    end)
    return success and type(health) == "number" and health > 0
end

local function getNpcControllerForModel(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    -- Prefer a Humanoid when a rig has both Humanoid and mirrored Health value.
    local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        return humanoid
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        if isNumericHealthValue(descendant) then
            return descendant
        end
    end

    -- A few runtime rigs expose only a numeric Health/HP attribute. The model
    -- itself becomes the controller in that case.
    if getModelHealthAttribute(model) ~= nil then
        return model
    end

    return nil
end

local function getNpcModelForController(controller)
    if not controller then
        return nil
    end

    if controller:IsA("Model") then
        return getCreatureEntityModel(controller) or controller
    end

    local current = controller.Parent
    local fallback

    -- CreatureID is the authoritative entity boundary for combat creatures.
    -- Search it before accepting a nested Humanoid/visual wrapper model.
    for _ = 1, 14 do
        if not current or current == workspace then
            break
        end
        if current:IsA("Model") then
            fallback = fallback or current
            if modelHasCreatureID(current) then
                return current
            end
        end
        current = current.Parent
    end

    current = controller.Parent
    for _ = 1, 12 do
        if not current or current == workspace then
            break
        end
        if current:IsA("Model") then
            fallback = fallback or current
            if getNpcEntityRootPart(current) and getNpcControllerForModel(current) then
                return current
            end
        end
        current = current.Parent
    end

    return fallback
end

local function npcControllerHealth(controller)
    if not controller or not controller.Parent then
        return 0
    end

    if controller:IsA("Humanoid") then
        return controller.Health
    elseif isNumericHealthValue(controller) then
        return controller.Value
    elseif controller:IsA("Model") then
        return getModelHealthAttribute(controller) or 0
    end

    return 0
end

local function npcControllerIsAlive(controller)
    local success, health = pcall(function()
        return npcControllerHealth(controller)
    end)
    return success and type(health) == "number" and health > 0
end

local NPC_IDENTITY_ATTRIBUTE_NAMES = {
    "Animal",
    "Creature",
    "CreatureID",
    "CreatureName",
    "DisplayName",
    "Enemy",
    "EnemyName",
    "EntityName",
    "Mob",
    "MobName",
    "NPC",
    "NPCName",
    "NPCType",
    "Type",
}

local function collectNpcKillCandidateNames(model, controller)
    local names = {}
    local seen = {}
    local current = model

    local function addName(value)
        if type(value) ~= "string" then
            return
        end

        local normalized = canonicalNpcKillName(value)
        if normalized ~= ""
            and not NPC_KILL_GENERIC_NAMES[normalized]
            and not seen[normalized]
        then
            seen[normalized] = true
            names[#names + 1] = normalized
        end
    end

    if controller and controller:IsA("Humanoid") then
        local success, displayName = pcall(function()
            return controller.DisplayName
        end)
        if success then
            addName(displayName)
        end
    end

    -- Prefer identity from the entity model itself. Only climb when that model
    -- is a generic wrapper. This avoids shared container/island names becoming
    -- false creature identities.
    for _ = 1, 6 do
        if not current or current == workspace then
            break
        end

        local beforeCount = #names
        if current:IsA("Model") then
            addName(current.Name)
        end

        if current:IsA("Model") or current:IsA("Folder") then
            for _, attributeName in ipairs(NPC_IDENTITY_ATTRIBUTE_NAMES) do
                local success, value = pcall(function()
                    return current:GetAttribute(attributeName)
                end)
                if success then
                    addName(value)
                end

                local valueObject = current:FindFirstChild(attributeName)
                if valueObject and valueObject:IsA("StringValue") then
                    addName(valueObject.Value)
                end
            end
        end

        if current:IsA("Model") and #names > beforeCount then
            break
        end

        current = current.Parent
    end

    return names
end

local function buildNpcIdentitySet(model, controller)
    local result = {}
    for _, name in ipairs(collectNpcKillCandidateNames(model, controller)) do
        result[name] = true
    end
    return result
end

local function npcModelsShareIdentity(leftModel, leftController, rightModel, rightController)
    local left = buildNpcIdentitySet(leftModel, leftController)
    local right = buildNpcIdentitySet(rightModel, rightController)

    for name in pairs(left) do
        if right[name] then
            return true
        end
    end

    return false
end

local NPC_KILL_EXCLUDED_ANCESTORS = {
    companionfolder = true,
    companionmodels = true,
    debrisfield = true,
    effects = true,
    merchantboat = true,
    npcs = true,
}

local function isInsideCreatureContainer(model)
    local creatureContainer = workspace:FindFirstChild("CreatureContainer")
    return creatureContainer ~= nil
        and model ~= creatureContainer
        and model:IsDescendantOf(creatureContainer)
end

local function hasExcludedNpcKillAncestor(model)
    local current = model and model.Parent
    for _ = 1, 12 do
        if not current or current == workspace then
            break
        end
        if NPC_KILL_EXCLUDED_ANCESTORS[normalizeInstanceName(current.Name)] then
            return true
        end
        current = current.Parent
    end
    return false
end

local function npcKillTargetHasSupportedPath(model, controller)
    if not model
        or not controller
        or not model.Parent
        or not controller.Parent
        or belongsToPlayerCharacter(model)
        or isClientCreatureModel(model)
    then
        return false
    end

    -- CreatureID is the server-recognized HitEnemy route used by the real
    -- weapon scripts. Numeric Health without CreatureID is only a display value
    -- and must not make an arbitrary NPC appear killable.
    if getCreatureEntityModel(model) then
        return true
    end

    if not controller:IsA("Humanoid") or hasExcludedNpcKillAncestor(model) then
        return false
    end

    -- The live game normally keeps combat rigs in CreatureContainer. Retain the
    -- legacy Humanoid path for a known creature identity if a server update
    -- temporarily places that rig directly below an island instead.
    if isInsideCreatureContainer(model) then
        return true
    end
    for _, candidateName in ipairs(collectNpcKillCandidateNames(model, controller)) do
        if npcKillCatalogIdentity[candidateName] then
            return true
        end
    end
    return false
end

local function trackNpcController(instance)
    if not instance then
        return false
    end

    local controller
    if instance:IsA("Humanoid") or isNumericHealthValue(instance) then
        controller = instance
    elseif instance:IsA("Model") and getModelHealthAttribute(instance) ~= nil then
        controller = instance
    else
        return false
    end

    local model = getNpcModelForController(controller)
    if not model or not npcKillTargetHasSupportedPath(model, controller) then
        return false
    end

    trackedNpcControllers[controller] = true
    return true
end

for _, descendant in ipairs(workspace:GetDescendants()) do
    trackNpcController(descendant)
end

local function findServerFacingEquivalent(clientModel, clientController)
    if not clientModel then
        return nil, nil
    end

    local clickedPart = getNpcEntityRootPart(clientModel)
    local closestModel
    local closestController
    local closestDistance = math.huge
    local closestIdentityMatch = false

    for candidateController in pairs(trackedNpcControllers) do
        local candidateModel = getNpcModelForController(candidateController)
        if candidateModel
            and candidateModel.Parent
            and candidateModel ~= clientModel
            and not isClientCreatureModel(candidateModel)
            and npcControllerIsAlive(candidateController)
            and not belongsToPlayerCharacter(candidateModel)
        then
            local identityMatch = npcModelsShareIdentity(
                clientModel,
                clientController,
                candidateModel,
                candidateController
            )

            local candidatePart = getNpcEntityRootPart(candidateModel)
            local distance = math.huge
            if clickedPart and candidatePart then
                local success, result = pcall(function()
                    return (candidatePart.Position - clickedPart.Position).Magnitude
                end)
                if success then
                    distance = result
                end
            elseif candidateModel.Parent == clientModel.Parent then
                distance = 0
            end

            -- Prefer identity matches. If runtime names differ in a new update,
            -- a very close sibling server rig is still a safe pairing fallback.
            local proximityFallback = candidateModel.Parent == clientModel.Parent
                and distance <= NPC_CLIENT_PAIR_RADIUS

            if identityMatch or proximityFallback then
                local better = false
                if identityMatch and not closestIdentityMatch then
                    better = true
                elseif identityMatch == closestIdentityMatch and distance < closestDistance then
                    better = true
                end

                if better then
                    closestIdentityMatch = identityMatch
                    closestDistance = distance
                    closestModel = candidateModel
                    closestController = candidateController
                end
            end
        elseif not candidateController.Parent then
            trackedNpcControllers[candidateController] = nil
        end
    end

    return closestModel, closestController
end

local function findNpcModelFromTarget(target)
    local current = target

    for _ = 1, 24 do
        if not current or current == workspace then
            break
        end

        if current:IsA("Model") then
            local controller = getNpcControllerForModel(current)

            if isClientCreatureModel(current) then
                local serverModel, serverController = findServerFacingEquivalent(
                    current,
                    controller
                )
                if serverModel and serverController then
                    return serverModel, serverController, current
                end

                -- Never apply the legacy effect to a _CLIENT visual clone. It
                -- can look displaced locally while the authoritative creature
                -- remains alive, which was the main false-success path.
                return nil, nil, current
            elseif controller
                and npcControllerIsAlive(controller)
                and npcKillTargetHasSupportedPath(current, controller)
            then
                return current, controller, nil
            end
        end

        current = current.Parent
    end

    return nil, nil, nil
end

local function makeNpcKillOption(category, name, aliases, keyPrefix)
    local names = {}

    local function addName(value)
        local normalized = canonicalNpcKillName(value)
        if normalized ~= "" then
            names[normalized] = true
        end
    end

    addName(name)
    for _, alias in ipairs(aliases or {}) do
        addName(alias)
    end

    local key = (keyPrefix or "catalog:") .. normalizeInstanceName(name)
    return {
        key = key,
        label = string.format("[%s] %s", category, name),
        name = name,
        names = names,
    }
end

local function loadRememberedNpcKillOptions()
    if rememberedNpcKillOptionsLoaded then
        return
    end
    rememberedNpcKillOptionsLoaded = true

    for _, name in ipairs(Config:Get("NpcKillDiscovered") or {}) do
        local normalizedName = canonicalNpcKillName(name)
        if normalizedName ~= "" and not rememberedNpcKillOptions[normalizedName] then
            rememberedNpcKillOptions[normalizedName] = makeNpcKillOption(
                "Found",
                name,
                nil,
                "found:"
            )
        end
    end
end

local function saveRememberedNpcKillOptions()
    local names = {}
    for _, option in pairs(rememberedNpcKillOptions) do
        names[#names + 1] = option.name
    end
    table.sort(names, function(left, right)
        return string.lower(left) < string.lower(right)
    end)
    Config:Set("NpcKillDiscovered", names)
end

local function addNpcKillOption(labels, optionByLabel, optionByKey, option)
    if optionByKey[option.key] then
        return
    end

    optionByKey[option.key] = option
    optionByLabel[option.label] = option
    labels[#labels + 1] = option.label
end

local function npcKillTargetMatchesOption(model, option, controller)
    if not option then
        return false
    end

    for _, candidateName in ipairs(collectNpcKillCandidateNames(model, controller)) do
        if option.names[candidateName] then
            return true
        end
    end

    return false
end

local function npcKillTargetMatchesSelection(model, controller)
    for key in pairs(selectedNpcKillKeys) do
        if npcKillTargetMatchesOption(model, npcKillOptionByKey[key], controller) then
            return true
        end
    end

    return false
end

local function findNearestSelectedNpc(position)
    if not position then
        return nil, nil
    end

    local closestModel
    local closestController
    local closestDistance = NPC_CLICK_RESOLVE_RADIUS
    local closestWasClient = true

    for controller in pairs(trackedNpcControllers) do
        local model = getNpcModelForController(controller)
        if controller.Parent
            and model
            and model.Parent
            and npcControllerIsAlive(controller)
            and not belongsToPlayerCharacter(model)
            and npcKillTargetMatchesSelection(model, controller)
        then
            local targetPart = getNpcEntityRootPart(model)
            if targetPart then
                local success, distance = pcall(function()
                    return (targetPart.Position - position).Magnitude
                end)
                if success and distance <= closestDistance then
                    local isClient = isClientCreatureModel(model)
                    if distance < closestDistance
                        or (distance == closestDistance and closestWasClient and not isClient)
                    then
                        closestDistance = distance
                        closestModel = model
                        closestController = controller
                        closestWasClient = isClient
                    end
                end
            end
        elseif not controller.Parent then
            trackedNpcControllers[controller] = nil
        end
    end

    if closestModel and isClientCreatureModel(closestModel) then
        local serverModel, serverController = findServerFacingEquivalent(
            closestModel,
            closestController
        )
        if serverModel and serverController then
            return serverModel, serverController
        end
    end

    return closestModel, closestController
end

local function requestNpcSimulationRadius()
    if typeof(setsimulationradius) == "function" then
        pcall(function()
            setsimulationradius(10000)
        end)
        return
    end

    if typeof(sethiddenproperty) == "function" then
        pcall(function()
            sethiddenproperty(localPlayer, "SimulationRadius", 10000)
        end)
        pcall(function()
            sethiddenproperty(localPlayer, "MaximumSimulationRadius", 10000)
        end)
    end
end

local function getNpcKillDiscoveryName(model, controller)
    local candidateNames = collectNpcKillCandidateNames(model, controller)
    if #candidateNames > 0 then
        local normalized = candidateNames[1]
        local displayName = tostring(model.Name):gsub("_CLIENT$", "")
        return displayName, normalized
    end

    local fallback = tostring(model.Name):gsub("_CLIENT$", "")
    return fallback, canonicalNpcKillName(fallback)
end

local function scanNpcKillGroups()
    loadRememberedNpcKillOptions()

    local labels = {}
    local optionByLabel = {}
    local optionByKey = {}
    local knownNameToKey = {}
    local discoveredOptions = {}
    local instanceCount = 0

    for _, entry in ipairs(NPC_KILL_CATALOG) do
        local option = makeNpcKillOption(
            entry.category,
            entry.name,
            entry.aliases,
            "catalog:"
        )
        addNpcKillOption(labels, optionByLabel, optionByKey, option)

        for normalizedName in pairs(option.names) do
            knownNameToKey[normalizedName] = option.key
        end
    end

    -- Populate the selector from the complete creature template folder found
    -- in the supplied RBXL. Existing curated entries keep aliases/categories.
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local creatureTemplates = assets and assets:FindFirstChild("Creatures")
    if creatureTemplates then
        local templates = creatureTemplates:GetChildren()
        table.sort(templates, function(left, right)
            return string.lower(left.Name) < string.lower(right.Name)
        end)

        for _, template in ipairs(templates) do
            if template:IsA("Model") then
                local normalizedName = canonicalNpcKillName(template.Name)
                if normalizedName ~= "" and not knownNameToKey[normalizedName] then
                    local option = makeNpcKillOption(
                        "Creature",
                        template.Name,
                        nil,
                        "template:"
                    )
                    addNpcKillOption(labels, optionByLabel, optionByKey, option)
                    for optionName in pairs(option.names) do
                        knownNameToKey[optionName] = option.key
                    end
                end
            end
        end
    end

    -- A remembered [Found] label is retained only while a matching supported
    -- server-facing rig is actually present. This automatically purges stale
    -- merchants, quest NPCs, ragdolls, and old client-only discoveries.
    local liveCompatibleNames = {}
    for controller in pairs(trackedNpcControllers) do
        local model = getNpcModelForController(controller)
        if controller.Parent
            and model
            and model.Parent
            and npcControllerIsAlive(controller)
            and npcKillTargetHasSupportedPath(model, controller)
        then
            for _, candidateName in ipairs(collectNpcKillCandidateNames(
                model,
                controller
            )) do
                liveCompatibleNames[candidateName] = true
            end
        end
    end

    -- Migrate persistent [Found] entries from older versions. If their canonical
    -- identity is covered by the catalog or no longer maps to a live supported
    -- rig, remove it instead of displaying a duplicate/invalid target.
    local rememberedChanged = false
    local cleanedRemembered = {}
    for normalizedName, option in pairs(rememberedNpcKillOptions) do
        local canonical = canonicalNpcKillName(option.name)
        local hasLiveSupportedMatch = liveCompatibleNames[canonical] == true
        if not hasLiveSupportedMatch then
            for optionName in pairs(option.names) do
                if liveCompatibleNames[optionName] then
                    hasLiveSupportedMatch = true
                    break
                end
            end
        end

        if canonical == ""
            or knownNameToKey[canonical]
            or not hasLiveSupportedMatch
        then
            rememberedChanged = true
        elseif not discoveredOptions[canonical] then
            discoveredOptions[canonical] = option
            cleanedRemembered[canonical] = option
            if normalizedName ~= canonical then
                rememberedChanged = true
            end
            for optionName in pairs(option.names) do
                knownNameToKey[optionName] = option.key
            end
            knownNameToKey[canonical] = option.key
        else
            rememberedChanged = true
        end
    end
    rememberedNpcKillOptions = cleanedRemembered
    if rememberedChanged then
        saveRememberedNpcKillOptions()
    end

    local countedModels = setmetatable({}, { __mode = "k" })
    for controller in pairs(trackedNpcControllers) do
        local model = getNpcModelForController(controller)

        if controller.Parent
            and model
            and model.Parent
            and npcControllerIsAlive(controller)
            and npcKillTargetHasSupportedPath(model, controller)
        then
            if not countedModels[model] then
                countedModels[model] = true
                instanceCount = instanceCount + 1
            end

            local isKnown = false
            for _, candidateName in ipairs(collectNpcKillCandidateNames(
                model,
                controller
            )) do
                if knownNameToKey[candidateName] then
                    isKnown = true
                    break
                end
            end

            if not isKnown then
                local displayName, normalizedName = getNpcKillDiscoveryName(model, controller)
                if normalizedName ~= "" and not discoveredOptions[normalizedName] then
                    local option = makeNpcKillOption(
                        "Found",
                        displayName,
                        nil,
                        "found:"
                    )
                    discoveredOptions[normalizedName] = option
                    rememberedNpcKillOptions[normalizedName] = option
                    saveRememberedNpcKillOptions()
                end
            end
        elseif not controller.Parent then
            trackedNpcControllers[controller] = nil
        end
    end

    local discoveredLabels = {}
    for _, option in pairs(discoveredOptions) do
        discoveredLabels[#discoveredLabels + 1] = option.label
        optionByLabel[option.label] = option
        optionByKey[option.key] = option
    end
    table.sort(discoveredLabels, function(left, right)
        return string.lower(left) < string.lower(right)
    end)
    for _, label in ipairs(discoveredLabels) do
        labels[#labels + 1] = label
    end

    return labels, optionByLabel, optionByKey, #labels, instanceCount,
        #discoveredLabels
end

local function collectSelectedNpcLabels(value)
    local labels = {}
    local seen = {}

    local function addLabel(label)
        if type(label) ~= "string" then return end

        local resolvedLabel = label
        if not npcKillOptionByLabel[resolvedLabel] then
            local rawName = string.match(label, "^%[[^%]]+%]%s*(.+)$") or label
            local canonical = canonicalNpcKillName(rawName)
            for candidateLabel, option in pairs(npcKillOptionByLabel) do
                if option.names[canonical] then
                    resolvedLabel = candidateLabel
                    break
                end
            end
        end

        if npcKillOptionByLabel[resolvedLabel] and not seen[resolvedLabel] then
            seen[resolvedLabel] = true
            labels[#labels + 1] = resolvedLabel
        end
    end

    if type(value) == "string" then
        addLabel(value)
    elseif type(value) == "table" then
        for key, option in pairs(value) do
            if type(option) == "string" then
                addLabel(option)
            elseif type(option) == "table" then
                addLabel(option.Title or option.Value)
            elseif option == true and type(key) == "string" then
                addLabel(key)
            end
        end
    end

    return labels
end

local function setSelectedNpcKillOptions(value, shouldSave)
    selectedNpcKillKeys = {}

    local selectedLabels = collectSelectedNpcLabels(value)
    for _, label in ipairs(selectedLabels) do
        local option = npcKillOptionByLabel[label]
        if option then
            selectedNpcKillKeys[option.key] = true
        end
    end

    if shouldSave ~= false then
        Config:Set("NpcKillSelections", selectedLabels)
    end

    return #selectedLabels
end

local function getSelectedNpcKillCount()
    local count = 0
    for _ in pairs(selectedNpcKillKeys) do
        count = count + 1
    end
    return count
end

local function refreshNpcKillOptions(showNotification)
    local previousSelection = {}
    for key in pairs(selectedNpcKillKeys) do
        previousSelection[key] = true
    end

    local labels, optionByLabel, optionByKey, groupCount, instanceCount,
        discoveredCount = scanNpcKillGroups()
    npcKillOptionByLabel = optionByLabel
    npcKillOptionByKey = optionByKey

    local preservedLabels = {}
    for label, option in pairs(optionByLabel) do
        if previousSelection[option.key] then
            preservedLabels[#preservedLabels + 1] = label
        end
    end
    table.sort(preservedLabels)

    if npcKillDropdown then
        pcall(function()
            npcKillDropdown:Refresh(labels)
            npcKillDropdown:Select(preservedLabels)
        end)
    end

    setSelectedNpcKillOptions(preservedLabels)

    if showNotification then
        notify(
            "NPC List Refreshed",
            string.format(
                "%d verified types + %d live new; %d compatible rigs; %d selected",
                #NPC_KILL_CATALOG,
                discoveredCount,
                instanceCount,
                #preservedLabels
            ),
            2.5
        )
    end

    return labels, groupCount, instanceCount
end

local initialNpcKillOptions, initialNpcKillGroupCount,
    initialNpcKillInstanceCount, initialNpcKillDiscoveredCount,
    initialNpcKillSelection
do
    local options, optionByLabel, optionByKey, groupCount, instanceCount,
        discoveredCount = scanNpcKillGroups()
    initialNpcKillOptions = options
    npcKillOptionByLabel = optionByLabel
    npcKillOptionByKey = optionByKey
    initialNpcKillGroupCount = groupCount
    initialNpcKillInstanceCount = instanceCount
    initialNpcKillDiscoveredCount = discoveredCount
    initialNpcKillSelection = collectSelectedNpcLabels(
        Config:Get("NpcKillSelections")
    )
    setSelectedNpcKillOptions(initialNpcKillSelection, false)
    -- Persist migrated labels so old [Found] selections do not reappear on the
    -- next run after canonical dedupe.
    Config:Set("NpcKillSelections", initialNpcKillSelection)
end

local npcKillRefreshScheduled = false
local function scheduleNpcKillRefresh()
    if npcKillRefreshScheduled then
        return
    end

    npcKillRefreshScheduled = true
    task.delay(0.75, function()
        npcKillRefreshScheduled = false
        if scriptAlive then
            refreshNpcKillOptions(false)
        end
    end)
end

connect(workspace.DescendantAdded, function(descendant)
    if trackNpcController(descendant) then
        scheduleNpcKillRefresh()
    elseif descendant:IsA("Model") then
        -- A model can arrive before its Health/Humanoid child. Recheck once the
        -- spawn hierarchy has had time to finish replicating.
        task.delay(0.15, function()
            if descendant.Parent then
                local controller = getNpcControllerForModel(descendant)
                if controller and trackNpcController(controller) then
                    scheduleNpcKillRefresh()
                end
            end
        end)
    end
end)

connect(workspace.DescendantRemoving, function(descendant)
    if trackedNpcControllers[descendant] then
        trackedNpcControllers[descendant] = nil
        scheduleNpcKillRefresh()
    end
end)

local SMART_SERVER_HIT_ATTEMPTS = 12
local SMART_SERVER_HIT_INTERVAL = 0.14
local SMART_HIT_TOOL_NAMES = {
    Harpoon = true,
    Riptide = true,
}

local function findSmartHitTool()
    local character = localPlayer.Character
    if character then
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") and SMART_HIT_TOOL_NAMES[child.Name] then
                return child, true
            end
        end
    end

    local backpack = localPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") and SMART_HIT_TOOL_NAMES[child.Name] then
                return child, false
            end
        end
    end

    return nil, false
end

local function ensureSmartHitToolEquipped(tool, alreadyEquipped)
    if not tool then
        return false
    end
    if alreadyEquipped or tool.Parent == localPlayer.Character then
        return true
    end

    local character = localPlayer.Character
    local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
    if not humanoid then
        return false
    end

    local success = pcall(function()
        humanoid:EquipTool(tool)
    end)
    if success then
        task.wait(0.05)
    end
    return success and tool.Parent == character
end

local function applyLegacyHumanoidStep(controller)
    if not controller or not controller:IsA("Humanoid") then
        return false
    end

    return pcall(function()
        controller.HipHeight = math.huge
    end)
end

local function applyLegacyHumanoidBurst(targetModel, controller)
    if not controller or not controller:IsA("Humanoid") then
        return false, "not-humanoid"
    end

    if activeLegacyVoidBursts[controller] then
        return true, "legacy-running"
    end

    local success = applyLegacyHumanoidStep(controller)
    if not success then
        return false, "legacy-failed"
    end

    activeLegacyVoidBursts[controller] = true
    task.spawn(function()
        for _ = 2, LEGACY_VOID_BURST_ATTEMPTS do
            task.wait(LEGACY_VOID_BURST_INTERVAL)
            if not scriptAlive
                or not targetModel.Parent
                or not controller.Parent
                or not npcControllerIsAlive(controller)
            then
                break
            end
            applyLegacyHumanoidStep(controller)
        end
        activeLegacyVoidBursts[controller] = nil
    end)

    return true, "legacy-effect-applied"
end

local function readNpcControllerHealth(controller, model)
    if controller and controller:IsA("Humanoid") then
        return controller.Health
    end
    if controller and controller:IsA("ValueBase") then
        local value = tonumber(controller.Value)
        if value then return value end
    end
    if model then
        for _, attributeName in ipairs(HEALTH_ATTRIBUTE_NAMES) do
            local value = tonumber(model:GetAttribute(attributeName))
            if value then return value end
        end
    end
    return nil
end

local function invokeCreatureServerHit(entity, tool)
    if type(_G.ToolProcessor) ~= "function" then
        return false, "toolprocessor-unavailable", nil
    end
    if not entity or not entity.Parent or not modelHasCreatureID(entity) then
        return false, "no-creatureid", nil
    end

    local targetPart = getNpcEntityRootPart(entity)
    if not targetPart then
        return false, "no-target-part", nil
    end

    local sourcePart = tool and tool:FindFirstChild("Harpoon1", true)
        or getHumanoidRootPart()
    if not sourcePart or not sourcePart:IsA("BasePart") then
        sourcePart = getHumanoidRootPart()
    end
    if not sourcePart then
        return false, "no-source-part", nil
    end

    pcall(function()
        _G.ToolProcessor(tool.Name, "Fire", sourcePart.Position, targetPart.Position)
    end)
    task.wait(0.035)

    local success, response = pcall(function()
        return _G.ToolProcessor(tool.Name, "HitEnemy", entity)
    end)
    return success, success and "server-hit-sent" or "server-hit-failed", response
end

local function applyCreatureServerHitBurst(entity)
    if not entity or not modelHasCreatureID(entity) then
        return false, "no-creatureid"
    end
    -- Full-map Auto Farm intentionally owns the tool slot so it can keep Sack
    -- equipped. Do not silently swap to Harpoon/Riptide while farming materials.
    if Config:Get("AutoLootWorld") == true then
        return false, "loot-sack-tool-lock"
    end

    local character = localPlayer.Character
    local previousTool = character and character:FindFirstChildOfClass("Tool") or nil
    local tool, equipped = findSmartHitTool()
    if not tool then
        return false, "need-harpoon-or-riptide"
    end
    if previousTool == tool then
        previousTool = nil
    end
    if not ensureSmartHitToolEquipped(tool, equipped) then
        return false, "cannot-equip-hit-tool"
    end

    local function restorePreviousTool()
        if previousTool and previousTool.Parent then
            local humanoid = getHumanoid()
            if humanoid then
                pcall(function()
                    humanoid:UnequipTools()
                    humanoid:EquipTool(previousTool)
                end)
            end
        end
    end

    local controller = getNpcControllerForModel(entity)
    local beforeHealth = readNpcControllerHealth(controller, entity)
    local anyRequestSent = false
    local damageConfirmed = false

    for _ = 1, SMART_SERVER_HIT_ATTEMPTS do
        if not scriptAlive or not entity.Parent or not creatureEntityIsAlive(entity) then
            restorePreviousTool()
            return true, "server-death-confirmed"
        end

        local sent = invokeCreatureServerHit(entity, tool)
        anyRequestSent = anyRequestSent or sent == true
        task.wait(SMART_SERVER_HIT_INTERVAL)

        if not entity.Parent or not creatureEntityIsAlive(entity) then
            restorePreviousTool()
            return true, "server-death-confirmed"
        end

        local currentController = getNpcControllerForModel(entity) or controller
        local currentHealth = readNpcControllerHealth(currentController, entity)
        if beforeHealth ~= nil and currentHealth ~= nil and currentHealth < beforeHealth then
            damageConfirmed = true
        end
    end

    restorePreviousTool()
    if damageConfirmed then
        return true, "server-damage-confirmed:" .. tool.Name
    end
    return false, anyRequestSent and "server-hit-unconfirmed" or "server-hit-failed"
end

local function applySmartNpcKill(targetModel, controller)
    if not npcKillTargetHasSupportedPath(targetModel, controller) then
        return false, "unsupported-controller"
    end

    -- Priority 1: CreatureID defines combat entities. If the creature also has
    -- a Humanoid, preserve the old HipHeight method because it is the method
    -- already proven to work on those targets in this place.
    local creatureEntity = getCreatureEntityModel(targetModel)
    if creatureEntity then
        local creatureHumanoid = creatureEntity:FindFirstChildWhichIsA("Humanoid", true)
        if creatureHumanoid then
            return applyLegacyHumanoidBurst(creatureEntity, creatureHumanoid)
        end

        -- Non-Humanoid CreatureID entities must never be root-voided; their
        -- visual clone is server-driven. Use the game's own HitEnemy request.
        return applyCreatureServerHitBurst(creatureEntity)
    end

    -- Priority 2: standalone Humanoid NPCs (quest/friendly/legacy rigs).
    if controller and controller:IsA("Humanoid") then
        return applyLegacyHumanoidBurst(targetModel, controller)
    end

    return false, "unsupported-controller"
end

local function setLegacyClickKillEnabled(enabled, shouldSave)
    enabled = enabled == true
    if shouldSave ~= false then
        Config:Set("SmartNpcKill", enabled)
    end

    if clickKillConnection then
        clickKillConnection:Disconnect()
        clickKillConnection = nil
    end

    if not enabled then
        notify("Smart NPC Kill", "Disabled", 1.5)
        return
    end

    local selectedCount = getSelectedNpcKillCount()
    local mouse = localPlayer:GetMouse()
    requestNpcSimulationRadius()

    clickKillConnection = connect(mouse.Button1Down, function()
        local target = mouse.Target
        if not target or not target:IsA("BasePart") then
            return
        end

        local clickedModel = target:FindFirstAncestorOfClass("Model")
        if clickedModel and belongsToPlayerCharacter(clickedModel) then
            notify("Target Protected", "Player characters cannot be selected", 2)
            return
        end

        local targetModel, controller, clickedClientModel = findNpcModelFromTarget(target)
        if not targetModel
            or not controller
            or not npcControllerIsAlive(controller)
            or not npcKillTargetMatchesSelection(targetModel, controller)
        then
            targetModel, controller = findNearestSelectedNpc(target.Position)
            clickedClientModel = nil
        end

        if not targetModel or not controller or not npcControllerIsAlive(controller) then
            notify(
                "NPC Not Detected",
                "No living selected NPC/controller was found at this click",
                2
            )
            return
        end

        if not npcKillTargetMatchesSelection(targetModel, controller) then
            notify(
                "NPC Not Selected",
                tostring(targetModel.Name) .. " is not selected",
                2
            )
            return
        end

        local success, method = applySmartNpcKill(targetModel, controller)

        if success then
            local detail = method or "smart-kill"
            if clickedClientModel and clickedClientModel ~= targetModel then
                detail = detail .. "; resolved " .. clickedClientModel.Name
                    .. " -> " .. targetModel.Name
            end
            notify(
                "Smart NPC Kill",
                "Processed " .. targetModel.Name .. " (" .. detail .. ")",
                2
            )
        else
            local messages = {
                ["need-harpoon-or-riptide"] = "This CreatureID target has no Humanoid. Equip/own Harpoon or Riptide for the server HitEnemy path.",
                ["toolprocessor-unavailable"] = "The game's ToolProcessor is not ready; try again after the client finishes loading.",
                ["no-creatureid"] = "This target is not a CreatureID combat entity.",
                ["unsupported-controller"] = "This target has no supported legacy Humanoid or CreatureID kill path.",
                ["cannot-equip-hit-tool"] = "Harpoon/Riptide was found but could not be equipped.",
                ["loot-sack-tool-lock"] = "World Auto Loot is active and keeping the Sack equipped; disable it before using the Harpoon/Riptide combat path.",
                ["server-hit-unconfirmed"] = "Hit requests were sent, but no replicated damage/death was confirmed.",
                ["server-hit-failed"] = "The server hit request failed before damage could be confirmed.",
            }
            notify(
                "Smart NPC Kill",
                messages[method] or ("Kill path failed: " .. tostring(method)),
                3
            )
        end
    end)

    notify(
        "Smart NPC Kill",
        string.format("Enabled for %d selected NPC groups", selectedCount),
        2
    )
end

return {
    CatalogCount = #NPC_KILL_CATALOG,
    InitialOptions = initialNpcKillOptions,
    InitialGroupCount = initialNpcKillGroupCount,
    InitialInstanceCount = initialNpcKillInstanceCount,
    InitialDiscoveredCount = initialNpcKillDiscoveredCount,
    InitialSelection = initialNpcKillSelection,
    SetDropdown = function(control)
        npcKillDropdown = control
    end,
    SetSelected = setSelectedNpcKillOptions,
    Refresh = refreshNpcKillOptions,
    SetEnabled = setLegacyClickKillEnabled,
}
end)()


-- ESP feature ---------------------------------------------------------------

local selectedEspItems = Config:Get("EspItems")
local espEnabled = false
local espShowChests = Config:Get("EspShowChests") ~= false
local espShowCreatures = Config:Get("EspShowCreatures") ~= false
local espShowPlayers = Config:Get("EspShowPlayers") == true
local espShowResources = Config:Get("EspShowResources") == true
local espRefreshGeneration = 0
local espObjectsByInstance = {}
local espFolder

local ESP_RANGE = 900
local ESP_MAX_TARGETS = 130
local ESP_REFRESH_SECONDS = 1

local ESP_COLORS = {
    loot = Color3.fromRGB(120, 200, 255),
    chest = Color3.fromRGB(255, 205, 90),
    creature = Color3.fromRGB(255, 105, 105),
    player = Color3.fromRGB(120, 180, 255),
    resource = Color3.fromRGB(115, 235, 150),
}

local function ensureEspFolder()
    if espFolder and espFolder.Parent then
        return espFolder
    end

    espFolder = Instance.new("Folder")
    espFolder.Name = "SeaScriptESP"
    local parent = CoreGui
    if typeof(gethui) == "function" then
        local ok, hiddenUi = pcall(gethui)
        if ok and hiddenUi then
            parent = hiddenUi
        end
    end
    espFolder.Parent = parent
    return espFolder
end

local function getItemDisplayName(instance)
    return ChestLoot.DisplayName(instance)
end

local function itemMatchesEspSelection(instance)
    return ChestLoot.Matches(instance, selectedEspItems)
end

local function removeAllEspObjects()
    for instance, objects in pairs(espObjectsByInstance) do
        pcall(function()
            objects.highlight:Destroy()
        end)
        pcall(function()
            objects.billboard:Destroy()
        end)
        espObjectsByInstance[instance] = nil
    end
end

local function addOrUpdateEsp(instance, kind, distance)
    local targetPart = kind == "player"
        and getTargetPart(instance, "HumanoidRootPart")
        or getTargetPart(instance)
    if not targetPart then
        return
    end

    local objects = espObjectsByInstance[instance]
    local color = ESP_COLORS[kind]

    if not objects then
        local parent = ensureEspFolder()
        local highlight = Instance.new("Highlight")
        highlight.Adornee = instance
        highlight.FillColor = color
        highlight.FillTransparency = 0.65
        highlight.OutlineColor = color
        highlight.OutlineTransparency = 0
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Parent = parent

        local billboard = Instance.new("BillboardGui")
        billboard.Adornee = targetPart
        billboard.Size = UDim2.new(0, 150, 0, 20)
        billboard.StudsOffset = Vector3.new(0, 2.5, 0)
        billboard.AlwaysOnTop = true
        billboard.MaxDistance = ESP_RANGE
        billboard.Parent = parent

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 11
        label.TextColor3 = color
        label.TextStrokeTransparency = 0.4
        label.Parent = billboard

        objects = {
            highlight = highlight,
            billboard = billboard,
            label = label,
        }
        espObjectsByInstance[instance] = objects
    else
        objects.billboard.Adornee = targetPart
    end

    local displayName
    if kind == "loot" then
        displayName = getItemDisplayName(instance)
    elseif kind == "resource" then
        local resource = tostring(instance:GetAttribute("Resource") or "Resource")
        local value = tonumber(instance:GetAttribute("Value"))
        local itemName = getItemDisplayName(instance) or instance.Name
        displayName = value and string.format("%s • %s x%s", resource, itemName, tostring(value))
            or string.format("%s • %s", resource, itemName)
    elseif kind == "player" then
        local player = Players:GetPlayerFromCharacter(instance)
        displayName = player and (player.DisplayName .. " (@" .. player.Name .. ")") or instance.Name
    else
        displayName = instance.Name
    end
    objects.label.Text = string.format("%s  %dm", displayName, math.floor(distance))
    objects.seen = true
end

local function collectEspCandidates()
    local rootPart = getHumanoidRootPart()
    if not rootPart then
        return {}
    end

    local candidates = {}
    local addedInstances = setmetatable({}, { __mode = "k" })

    local function addCandidate(instance, kind)
        if not instance or addedInstances[instance] or not instance.Parent then
            return
        end
        if kind == "loot" and not itemMatchesEspSelection(instance) then
            return
        end

        local targetPart = kind == "player"
            and getTargetPart(instance, "HumanoidRootPart")
            or getTargetPart(instance)
        if not targetPart then return end

        local distance = (targetPart.Position - rootPart.Position).Magnitude
        if distance <= ESP_RANGE then
            addedInstances[instance] = true
            candidates[#candidates + 1] = {
                instance = instance,
                kind = kind,
                distance = distance,
            }
        end
    end

    if espShowPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= localPlayer and player.Character then
                addCandidate(player.Character, "player")
            end
        end
    end

    local interactables = CollectionService:GetTagged("Interactable")
    local itemModels = {}
    forEachItemModel(function(item)
        itemModels[#itemModels + 1] = item
    end)

    -- Resources win over ordinary loot when the same item belongs to both.
    if espShowResources then
        for _, interactable in ipairs(interactables) do
            if interactable:GetAttribute("Resource") ~= nil then
                addCandidate(interactable, "resource")
            end
        end
        for _, item in ipairs(itemModels) do
            if item:GetAttribute("Resource") ~= nil then
                addCandidate(item, "resource")
            end
        end
    end

    if #selectedEspItems > 0 then
        for _, interactable in ipairs(interactables) do
            addCandidate(interactable, "loot")
        end
        for _, item in ipairs(itemModels) do
            addCandidate(item, "loot")
        end
    end

    if espShowChests then
        for chest in pairs(cachedChests) do
            if not chestHasOpenedState(chest) then
                addCandidate(chest, "chest")
            end
        end
    end

    if espShowCreatures then
        local creatureContainer = workspace:FindFirstChild("CreatureContainer")
            or workspace:FindFirstChild("Creatures")

        if creatureContainer then
            for _, creature in ipairs(creatureContainer:GetChildren()) do
                if creature:IsA("Model") then
                    local isClient = creature.Name:match("_CLIENT$") ~= nil
                    local visualSibling = not isClient
                        and creatureContainer:FindFirstChild(creature.Name .. "_CLIENT")
                        or nil
                    -- The server proxy is frequently invisible. Prefer the visual
                    -- _CLIENT model when that pair exists so one creature = one ESP.
                    if isClient or not visualSibling then
                        local humanoid = creature:FindFirstChildOfClass("Humanoid")
                        local health = creature:FindFirstChild("Health", true)
                        local alive = not humanoid or humanoid.Health > 0
                        if alive and health and health:IsA("ValueBase") then
                            alive = tonumber(health.Value) == nil or tonumber(health.Value) > 0
                        end
                        if alive then
                            addCandidate(creature, "creature")
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(left, right)
        return left.distance < right.distance
    end)
    return candidates
end

local function refreshEsp()
    if not espEnabled then
        return 0
    end

    for _, objects in pairs(espObjectsByInstance) do
        objects.seen = false
    end

    local candidates = collectEspCandidates()
    local visibleCount = math.min(#candidates, ESP_MAX_TARGETS)

    for index = 1, visibleCount do
        local candidate = candidates[index]
        addOrUpdateEsp(candidate.instance, candidate.kind, candidate.distance)
    end

    for instance, objects in pairs(espObjectsByInstance) do
        if not objects.seen or not instance.Parent then
            objects.highlight:Destroy()
            objects.billboard:Destroy()
            espObjectsByInstance[instance] = nil
        end
    end

    return visibleCount
end

local function setEspEnabled(enabled, shouldSave)
    enabled = enabled == true
    if shouldSave ~= false then
        Config:Set("EspEnabled", enabled)
    end

    espEnabled = enabled
    espRefreshGeneration = espRefreshGeneration + 1
    local generation = espRefreshGeneration

    if enabled then
        local highlightedCount = refreshEsp()
        task.spawn(function()
            while scriptAlive and espEnabled and generation == espRefreshGeneration do
                task.wait(ESP_REFRESH_SECONDS)
                if scriptAlive and espEnabled and generation == espRefreshGeneration then
                    refreshEsp()
                end
            end
        end)

        notify("ESP Enabled", "Tracking " .. highlightedCount .. " nearby targets", 2)
    else
        removeAllEspObjects()
        notify("ESP Disabled", "ESP turned off", 1.5)
    end
end

local function updateEspFromButton()
    if espEnabled then
        local highlightedCount = refreshEsp()
        notify("ESP Updated", "Tracking " .. highlightedCount .. " nearby targets", 2)
    else
        notify("ESP Disabled", "Enable ESP first", 2)
    end
end


-- Walkspeed and prompt features --------------------------------------------

local desiredWalkSpeed = Config:Get("WalkSpeed") or 16
local walkSpeedConnection
local walkSpeedLocked = false
local originalWalkSpeedByHumanoid = setmetatable({}, { __mode = "k" })
local walkSpeedInternalWrite = false
local instantInteractEnabled = false
local instantInteractAddedConnection
local originalPromptDurations = setmetatable({}, { __mode = "k" })
local instantPromptConnections = setmetatable({}, { __mode = "k" })

local function applyWalkSpeed()
    local humanoid = getHumanoid()
    if humanoid and walkSpeedLocked and humanoid.WalkSpeed ~= desiredWalkSpeed then
        walkSpeedInternalWrite = true
        humanoid.WalkSpeed = desiredWalkSpeed
        walkSpeedInternalWrite = false
    end
end

local function bindWalkSpeedWatcher()
    if walkSpeedConnection then
        walkSpeedConnection:Disconnect()
        walkSpeedConnection = nil
    end

    local humanoid = getHumanoid()
    if not walkSpeedLocked or not humanoid then
        return
    end

    if originalWalkSpeedByHumanoid[humanoid] == nil then
        originalWalkSpeedByHumanoid[humanoid] = humanoid.WalkSpeed
    end
    applyWalkSpeed()
    walkSpeedConnection = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
        if not walkSpeedLocked or walkSpeedInternalWrite then
            return
        end
        if humanoid.WalkSpeed ~= desiredWalkSpeed then
            -- Remember the latest game/class/buff speed before enforcing the
            -- user's lock, so OFF restores current native behavior, not 16.
            originalWalkSpeedByHumanoid[humanoid] = humanoid.WalkSpeed
            applyWalkSpeed()
        end
    end)
end

local function setWalkSpeedLocked(enabled, shouldSave)
    enabled = enabled == true
    if shouldSave ~= false then
        Config:Set("WalkSpeedLocked", enabled)
    end

    walkSpeedLocked = enabled

    if enabled then
        bindWalkSpeedWatcher()
        notify("Walkspeed Locked", "Walkspeed set to " .. desiredWalkSpeed, 1.5)
    else
        if walkSpeedConnection then
            walkSpeedConnection:Disconnect()
            walkSpeedConnection = nil
        end

        local humanoid = getHumanoid()
        if humanoid then
            local original = originalWalkSpeedByHumanoid[humanoid]
            if original ~= nil then
                humanoid.WalkSpeed = original
                originalWalkSpeedByHumanoid[humanoid] = nil
            end
        end

        notify("Walkspeed Unlocked", "Original walkspeed restored", 1.5)
    end
end

local function makePromptInstant(instance)
    if not instance:IsA("ProximityPrompt") then
        return false
    end

    if originalPromptDurations[instance] == nil then
        originalPromptDurations[instance] = instance.HoldDuration
    end

    if not instantPromptConnections[instance] then
        instantPromptConnections[instance] = instance:GetPropertyChangedSignal("HoldDuration"):Connect(function()
            if instantInteractEnabled and instance.Parent and instance.HoldDuration ~= 0 then
                -- Preserve a later game-side duration change as the value to restore.
                originalPromptDurations[instance] = instance.HoldDuration
                instance.HoldDuration = 0
            end
        end)
    end

    instance.HoldDuration = 0
    return true
end

local function setInstantInteractEnabled(enabled, shouldSave)
    enabled = enabled == true
    if shouldSave ~= false then
        Config:Set("InstantInteract", enabled)
    end

    instantInteractEnabled = enabled

    if instantInteractAddedConnection then
        instantInteractAddedConnection:Disconnect()
        instantInteractAddedConnection = nil
    end

    if enabled then
        -- Scan once, then process only newly-added prompts. This replaces the
        -- old full workspace scan that ran on every rendered frame.
        for _, descendant in ipairs(workspace:GetDescendants()) do
            makePromptInstant(descendant)
        end

        instantInteractAddedConnection = workspace.DescendantAdded:Connect(function(descendant)
            if instantInteractEnabled then
                makePromptInstant(descendant)
            end
        end)

        notify("Instant Interact", "Enabled", 1.5)
    else
        -- Restore each prompt's real original duration instead of forcing 1.
        for prompt, originalDuration in pairs(originalPromptDurations) do
            if prompt.Parent then
                prompt.HoldDuration = originalDuration
            end
        end

        for prompt, connection in pairs(instantPromptConnections) do
            pcall(function() connection:Disconnect() end)
            instantPromptConnections[prompt] = nil
        end
        originalPromptDurations = setmetatable({}, { __mode = "k" })
        notify("Instant Interact", "Disabled", 1.5)
    end
end


-- Local player extras: Noclip + Fullbright --------------------------------

local setNoclipEnabled
local cleanupNoclip
do
    local noclipEnabled = false
    local savedCollision: any = setmetatable({}, { __mode = "k" })

    local function applyNoclip()
        local character = getCharacter()
        if not character then return end
        for _, descendant in ipairs(character:GetDescendants()) do
            local part: any = descendant
            if part:IsA("BasePart") then
                if savedCollision[part] == nil then
                    savedCollision[part] = part.CanCollide
                end
                part.CanCollide = false
            end
        end
    end

    local function restoreNoclipCollision()
        for part, canCollide in pairs(savedCollision) do
            if part and part.Parent then
                pcall(function() part.CanCollide = canCollide end)
            end
            savedCollision[part] = nil
        end
    end

    setNoclipEnabled = function(enabled, shouldSave)
        noclipEnabled = enabled == true
        if shouldSave ~= false then Config:Set("Noclip", noclipEnabled) end
        if noclipEnabled then
            applyNoclip()
            notify("Noclip", "Enabled", 1.5)
        else
            restoreNoclipCollision()
            notify("Noclip", "Disabled and collisions restored", 1.5)
        end
    end

    cleanupNoclip = function()
        noclipEnabled = false
        restoreNoclipCollision()
    end

    connect(RunService.Stepped, function()
        if scriptAlive and noclipEnabled then
            applyNoclip()
        end
    end)
end

local setFullbrightEnabled
local cleanupFullbright
do
    local fullbrightEnabled = false
    local fullbrightGeneration = 0
    local originalLighting
    local originalAtmosphereDensity: any = setmetatable({}, { __mode = "k" })

    local function captureLightingState()
        if originalLighting then return end
        originalLighting = {
            Ambient = Lighting.Ambient,
            Brightness = Lighting.Brightness,
            FogEnd = Lighting.FogEnd,
            GlobalShadows = Lighting.GlobalShadows,
        }
        for _, child in ipairs(Lighting:GetChildren()) do
            local atmosphere: any = child
            if atmosphere:IsA("Atmosphere") then
                originalAtmosphereDensity[atmosphere] = atmosphere.Density
            end
        end
    end

    local function applyFullbright()
        captureLightingState()
        Lighting.Ambient = Color3.new(1, 1, 1)
        Lighting.Brightness = 2
        Lighting.FogEnd = 1000000
        Lighting.GlobalShadows = false
        for _, child in ipairs(Lighting:GetChildren()) do
            local atmosphere: any = child
            if atmosphere:IsA("Atmosphere") then
                if originalAtmosphereDensity[atmosphere] == nil then
                    originalAtmosphereDensity[atmosphere] = atmosphere.Density
                end
                atmosphere.Density = 0
            end
        end
    end

    local function restoreFullbright()
        if originalLighting then
            pcall(function()
                Lighting.Ambient = originalLighting.Ambient
                Lighting.Brightness = originalLighting.Brightness
                Lighting.FogEnd = originalLighting.FogEnd
                Lighting.GlobalShadows = originalLighting.GlobalShadows
            end)
        end
        for atmosphere, density in pairs(originalAtmosphereDensity) do
            if atmosphere and atmosphere.Parent then
                pcall(function() atmosphere.Density = density end)
            end
            originalAtmosphereDensity[atmosphere] = nil
        end
        originalLighting = nil
    end

    setFullbrightEnabled = function(enabled, shouldSave)
        fullbrightEnabled = enabled == true
        fullbrightGeneration = fullbrightGeneration + 1
        local generation = fullbrightGeneration
        if shouldSave ~= false then Config:Set("Fullbright", fullbrightEnabled) end

        if fullbrightEnabled then
            applyFullbright()
            task.spawn(function()
                while scriptAlive and fullbrightEnabled and generation == fullbrightGeneration do
                    task.wait(0.8)
                    if scriptAlive and fullbrightEnabled and generation == fullbrightGeneration then
                        pcall(applyFullbright)
                    end
                end
            end)
            notify("Fullbright", "Enabled", 1.5)
        else
            restoreFullbright()
            notify("Fullbright", "Disabled and lighting restored", 1.5)
        end
    end

    cleanupFullbright = function()
        fullbrightEnabled = false
        fullbrightGeneration = fullbrightGeneration + 1
        restoreFullbright()
    end
end


-- Fly feature ---------------------------------------------------------------

local flying = false
local flyRequested = Config:Get("FlyEnabled") == true
local flySpeed = Config:Get("FlySpeed") or 50
local flyToggle
local suppressFlyToggleCallback = false
local flyInputBeganConnection
local flyInputEndedConnection
local flyRenderConnection
local activeFlyBodyGyro
local activeFlyBodyVelocity

local flyControl = {
    forward = false,
    backward = false,
    left = false,
    right = false,
    down = false,
    up = false,
}

local function clearFlyControl()
    flyControl.forward = false
    flyControl.backward = false
    flyControl.left = false
    flyControl.right = false
    flyControl.down = false
    flyControl.up = false
end

local function disconnectFlyInput()
    if flyInputBeganConnection then
        flyInputBeganConnection:Disconnect()
        flyInputBeganConnection = nil
    end

    if flyInputEndedConnection then
        flyInputEndedConnection:Disconnect()
        flyInputEndedConnection = nil
    end
end

local function stopFly(preserveRequest)
    flying = false
    if not preserveRequest then
        flyRequested = false
    end
    disconnectFlyInput()
    clearFlyControl()

    if flyRenderConnection then
        flyRenderConnection:Disconnect()
        flyRenderConnection = nil
    end

    if activeFlyBodyGyro then
        activeFlyBodyGyro:Destroy()
        activeFlyBodyGyro = nil
    end

    if activeFlyBodyVelocity then
        activeFlyBodyVelocity:Destroy()
        activeFlyBodyVelocity = nil
    end

    local humanoid = getHumanoid()
    if humanoid then
        humanoid.PlatformStand = false
    end

end

local function setControlForKey(keyCode, isPressed)
    if keyCode == Enum.KeyCode.W then
        flyControl.forward = isPressed
    elseif keyCode == Enum.KeyCode.S then
        flyControl.backward = isPressed
    elseif keyCode == Enum.KeyCode.A then
        flyControl.left = isPressed
    elseif keyCode == Enum.KeyCode.D then
        flyControl.right = isPressed
    elseif keyCode == Enum.KeyCode.LeftControl or keyCode == Enum.KeyCode.C then
        flyControl.down = isPressed
    elseif keyCode == Enum.KeyCode.Space then
        flyControl.up = isPressed
    end
end

local function startFly()
    local humanoid = getHumanoid()
    local rootPart = getHumanoidRootPart()
    if not humanoid or not rootPart then
        return false
    end

    flying = true
    clearFlyControl()
    humanoid.PlatformStand = true

    flyInputBeganConnection = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
            return
        end

        setControlForKey(input.KeyCode, true)
    end)

    flyInputEndedConnection = UserInputService.InputEnded:Connect(function(input)
        setControlForKey(input.KeyCode, false)
    end)

    activeFlyBodyGyro = Instance.new("BodyGyro")
    activeFlyBodyVelocity = Instance.new("BodyVelocity")

    activeFlyBodyGyro.P = 90000
    activeFlyBodyGyro.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
    activeFlyBodyGyro.CFrame = rootPart.CFrame
    activeFlyBodyGyro.Parent = rootPart

    activeFlyBodyVelocity.Velocity = Vector3.new(0, 0, 0)
    activeFlyBodyVelocity.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    activeFlyBodyVelocity.Parent = rootPart

    flyRenderConnection = RunService.RenderStepped:Connect(function()
        if not rootPart.Parent or not humanoid.Parent then
            stopFly(true)
            return
        end

        local cameraCFrame = workspace.CurrentCamera.CFrame
        local direction = Vector3.new(0, 0, 0)

        if flyControl.forward then
            direction = direction + cameraCFrame.LookVector
        end
        if flyControl.backward then
            direction = direction - cameraCFrame.LookVector
        end
        if flyControl.right then
            direction = direction + cameraCFrame.RightVector
        end
        if flyControl.left then
            direction = direction - cameraCFrame.RightVector
        end
        if flyControl.up then
            direction = direction + Vector3.new(0, 1, 0)
        end
        if flyControl.down then
            direction = direction - Vector3.new(0, 1, 0)
        end

        if direction.Magnitude > 0 then
            activeFlyBodyVelocity.Velocity = direction.Unit * flySpeed
        else
            activeFlyBodyVelocity.Velocity = Vector3.new(0, 0, 0)
        end

        activeFlyBodyGyro.CFrame = cameraCFrame
    end)

    return true
end

local function setFlyToggleVisual(enabled)
    if not flyToggle then
        return
    end

    suppressFlyToggleCallback = true
    pcall(function()
        flyToggle:Set(enabled)
    end)
    suppressFlyToggleCallback = false
end

local function setFlyEnabled(enabled, shouldSave)
    enabled = enabled == true
    if enabled then
        if Travel then Travel.Stop("Fly started") end
        interruptAutomationMovement()
    end
    if shouldSave ~= false then
        Config:Set("FlyEnabled", enabled)
    end

    flyRequested = enabled
    stopFly(enabled)

    if enabled then
        if startFly() then
            notify("Fly", "Fly enabled (T to disable)", 1.5)
        else
            if shouldSave ~= false then
                flyRequested = false
                Config:Set("FlyEnabled", false)
                setFlyToggleVisual(false)
            else
                -- Startup restore: keep the saved request so CharacterAdded can retry.
                flyRequested = true
            end
            notify("Fly", "Character is not ready; saved state will retry on spawn", 1.5)
        end
    else
        notify("Fly", "Fly disabled", 1.5)
    end
end

local function setFlySpeed(value)
    local numericValue = tonumber(value)
    if not numericValue then
        notify("Fly Speed", "Enter a valid number", 1.5)
        return
    end

    flySpeed = math.max(1, math.min(500, numericValue))
    Config:Set("FlySpeed", flySpeed)
end


-- Lightweight lifecycle helpers -------------------------------------------

local antiAfkEnabled = Config:Get("AntiAfk") == true

connect(localPlayer.Idled, function()
    if antiAfkEnabled then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

connect(localPlayer.CharacterAdded, function()
    task.wait(1)
    if not scriptAlive then
        return
    end

    captureBasePosition()

    if walkSpeedLocked then
        bindWalkSpeedWatcher()
    end

    if flyRequested and not flying then
        if startFly() and flyToggle then
            setFlyToggleVisual(true)
        end
    end
end)


-- Island travel -------------------------------------------------------------
-- Scoped separately to stay below Luau's per-function register limit.
Travel = (function()
    local api: any = { Enabled = false, Busy = false }
    local controls: { [string]: any } = {}
    local islands, islandById, islandByLabel = {}, {}, {}
    local discoveredIslands = {}
    local catalogContainer, catalogSeed
    local savedByLabel = {}
    local selectedIsland = Config:Get("SelectedIsland")
    local selectedPoint = Config:Get("SelectedTeleport")
    local generation = 0
    local activeHold
    local streamRequests = 0
    local refreshQueued = false
    local watchedContainers = setmetatable({}, { __mode = "k" })
    local confirmation
    local lastStatus = "Ready. Choose an island, start a tour, or save a coordinate."
    local offsets = { Vector3.zero }
    for _, radius in ipairs({ 16, 40, 80 }) do
        for _, pair in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {-1,1}, {1,-1}, {-1,-1} }) do
            offsets[#offsets + 1] = Vector3.new(pair[1] * radius, 0, pair[2] * radius)
        end
    end

    local function status(message)
        lastStatus = tostring(message)
        if controls.status then controls.status:Set(lastStatus, "Travel status") end
    end
    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) <= 1000000
    end
    local function validPosition(position)
        return typeof(position) == "Vector3"
            and finite(position.X) and finite(position.Y) and finite(position.Z)
    end
    local function coordinates(position)
        return string.format("%.1f, %.1f, %.1f", position.X, position.Y, position.Z)
    end
    local function positionOf(instance)
        if not instance then return nil end
        local ok, position = pcall(function()
            if instance:IsA("BasePart") then return instance.Position end
            if instance:IsA("Model") then return instance:GetPivot().Position end
            local part = getTargetPart(instance)
            return part and part.Position
        end)
        return ok and validPosition(position) and position or nil
    end
    local function islandKey(name, position)
        -- Marker Y is a map-icon height, NOT island ground height. Match the
        -- loaded model by name + X/Z, retaining distinct same-name islands.
        return name .. ":" .. math.round(position.X) .. ":" .. math.round(position.Z)
    end
    local function prettyName(name)
        return (name:gsub("(%l)(%u)", "%1 %2"):gsub("_", " "))
    end
    local function setTourVisual(enabled)
        if controls.tour then controls.tour:Set(enabled, false) end
    end

    function api.Refresh(showNotification)
        local records, byId = {}, {}
        local container = workspace:FindFirstChild("IslandContainer")
        local seed = tostring(localPlayer:GetAttribute("DisplaySeed") or "")
        if catalogContainer ~= container or catalogSeed ~= seed then
            discoveredIslands = {}
            catalogContainer, catalogSeed = container, seed
        end
        local function add(name, position, marker, model)
            if not validPosition(position) then return end
            local id = islandKey(name, position)
            local existing = byId[id]
            if existing then
                if model then existing.model = model end
                return
            end
            local record = {
                id = id, name = name, position = position, marker = marker, model = model,
                label = prettyName(name) .. string.format("  [%.0f, %.0f]", position.X, position.Z),
            }
            records[#records + 1] = record
            byId[id] = record
        end
        local markers = ReplicatedStorage:FindFirstChild("DistantIslands")
        if markers then
            for _, marker in ipairs(markers:GetChildren()) do
                add(marker.Name, positionOf(marker), marker, nil)
            end
        end
        -- Some loaded locations (including the supplied SmallIsland2 models and
        -- CorruptDungeon) have no map marker. Remember their coordinates for this
        -- map even after the Model streams out; never retain its dead Instance.
        for _, known in pairs(discoveredIslands) do
            add(known.name, known.position, nil, nil)
        end
        if container then
            for _, model in ipairs(container:GetChildren()) do
                if model:IsA("Model") then
                    local position = positionOf(model)
                    if position and position.Magnitude == 0 and not getTargetPart(model) then
                        position = nil
                    end
                    local matching
                    if position then
                        for _, record in ipairs(records) do
                            if record.name == model.Name
                                and Vector3.new(record.position.X - position.X, 0, record.position.Z - position.Z).Magnitude < 24
                            then matching = record; break end
                        end
                    end
                    if matching then matching.model = model
                    else
                        add(model.Name, position, nil, model)
                        if position then
                            discoveredIslands[islandKey(model.Name, position)] = {
                                name = model.Name, position = position,
                            }
                        end
                    end
                end
            end
        end
        local hasRig = false
        for _, record in ipairs(records) do
            if record.name == "Rig" then hasRig = true; break end
        end
        if not hasRig then
            local spawnIsland = workspace:FindFirstChild("SpawnIsland")
            local anchor = spawnIsland and (spawnIsland:FindFirstChild("Grinder") or spawnIsland)
            add("Rig", positionOf(anchor), nil, spawnIsland)
        end
        table.sort(records, function(a, b) return a.id < b.id end)
        islands, islandById, islandByLabel = records, byId, {}
        local labels = {}
        for _, record in ipairs(records) do
            labels[#labels + 1] = record.label
            islandByLabel[record.label] = record.id
        end
        if not byId[selectedIsland] then selectedIsland = records[1] and records[1].id or "" end
        if controls.islands then
            controls.islands:Refresh(labels)
            controls.islands:Select(byId[selectedIsland] and byId[selectedIsland].label or nil, false)
        end
        if controls.catalog then
            local loaded = 0
            for _, record in ipairs(records) do
                if record.model and record.model.Parent then loaded = loaded + 1 end
            end
            controls.catalog:Set(string.format(
                "%d destinations | %d loaded models. Map markers include islands not streamed yet. Same-name islands keep separate coordinates.",
                #records, loaded), "Island catalog")
        end
        if showNotification then status("Island list refreshed: " .. #records .. " destinations.") end
        return records
    end

    -- Stable order: sorting by the moving player's distance on EVERY chest scan
    -- causes an index-based scanner to revisit a subset and miss other islands.
    function api.GetSearchAnchors()
        local anchors = {}
        for _, record in ipairs(api.Refresh(false)) do
            anchors[#anchors + 1] = { position = record.position, id = record.id }
        end
        return anchors
    end

    local function refreshSoon()
        if refreshQueued or not scriptAlive then return end
        refreshQueued = true
        task.delay(0.2, function()
            refreshQueued = false
            if scriptAlive then api.Refresh(false) end
        end)
    end
    local function watchContainer(container)
        if not container or watchedContainers[container] then return end
        watchedContainers[container] = true
        connect(container.ChildAdded, refreshSoon)
        connect(container.ChildRemoved, refreshSoon)
    end
    watchContainer(ReplicatedStorage:FindFirstChild("DistantIslands"))
    watchContainer(workspace:FindFirstChild("IslandContainer"))
    connect(ReplicatedStorage.ChildAdded, function(child)
        if child.Name == "DistantIslands" then watchContainer(child); refreshSoon() end
    end)
    connect(workspace.ChildAdded, function(child)
        if child.Name == "IslandContainer" then watchContainer(child); refreshSoon()
        elseif child.Name == "SpawnIsland" then refreshSoon() end
    end)
    connect(localPlayer:GetAttributeChangedSignal("DisplaySeed"), refreshSoon)

    local function requestStream(position)
        if streamRequests >= 2 then return end
        streamRequests = streamRequests + 1
        task.spawn(function()
            pcall(function() localPlayer:RequestStreamAroundAsync(position, 2.5) end)
            streamRequests = math.max(0, streamRequests - 1)
        end)
    end

    local function modelFor(record)
        if record.name == "Rig" then return workspace:FindFirstChild("SpawnIsland") end
        if record.model and record.model.Parent then return record.model end
        local container = workspace:FindFirstChild("IslandContainer")
        if container then
            for _, model in ipairs(container:GetChildren()) do
                if model:IsA("Model") and model.Name == record.name then
                    local position = positionOf(model)
                    if position and Vector3.new(position.X - record.position.X, 0, position.Z - record.position.Z).Magnitude < 24 then
                        record.model = model
                        return model
                    end
                end
            end
        end
        return nil
    end
    local function safeSurface(hit, minimumY)
        if not hit or hit.Position.Y < minimumY or hit.Normal.Y < 0.65
            or hit.Material == Enum.Material.Water or hit.Material == Enum.Material.CrackedLava
        then return false end
        local instance = hit.Instance
        if not instance then return false end
        if instance:IsA("BasePart") and not instance.CanCollide then return false end
        local current = instance
        for _ = 1, 4 do
            if not current or current == workspace then break end
            local name = string.lower(current.Name)
            for _, hazard in ipairs({ "lava", "water", "killbrick", "damage", "spike", "leaves", "foliage" }) do
                if string.find(name, hazard, 1, true) then return false end
            end
            current = current.Parent
        end
        return true
    end
    local function landingFor(record)
        local include = {}
        local model = modelFor(record)
        if model then include[#include + 1] = model end
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if terrain then include[#include + 1] = terrain end
        if #include == 0 then return nil end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = include
        params.IgnoreWater = true
        params.RespectCanCollide = true
        local minimumY = math.max(147.5, record.position.Y - 400)
        local castY = math.max(400, record.position.Y + 256)
        if model and model:IsA("Model") then
            local ok, bounds, size = pcall(function() return model:GetBoundingBox() end)
            if ok and typeof(bounds) == "CFrame" and typeof(size) == "Vector3" then
                castY = math.max(castY, bounds.Position.Y + size.Y / 2 + 16)
            end
        end
        for _, offset in ipairs(offsets) do
            local origin = Vector3.new(record.position.X + offset.X, castY, record.position.Z + offset.Z)
            local hit = workspace:Raycast(origin, Vector3.new(0, minimumY - castY - 1, 0), params)
            if safeSurface(hit, minimumY) then
                local supported = true
                -- A broad standing patch, not a thin branch or marker. Also
                -- reject low ceilings before unanchoring the character.
                for _, side in ipairs({ Vector3.new(1.5,0,0), Vector3.new(-1.5,0,0), Vector3.new(0,0,1.5), Vector3.new(0,0,-1.5) }) do
                    local ground = workspace:Raycast(hit.Position + side + Vector3.new(0, 3, 0), Vector3.new(0, -5, 0), params)
                    if not safeSurface(ground, minimumY) or math.abs(ground.Position.Y - hit.Position.Y) > 1.5 then
                        supported = false
                        break
                    end
                end
                if supported and not workspace:Raycast(hit.Position + Vector3.new(0, 0.3, 0), Vector3.new(0, 6, 0), params) then
                    return hit.Position
                end
            end
        end
        return nil
    end

    local function releaseHold(hold, arrived)
        if not hold or hold.closed then return end
        hold.closed = true
        if activeHold == hold then activeHold = nil end
        pcall(function()
            if hold.root.Parent then
                if not arrived and getMovementRevision() == hold.token and hold.root == getHumanoidRootPart() then
                    hold.restorePosition = true
                end
                hold.root.Anchored = hold.anchored
            end
            if hold.humanoid and hold.humanoid.Parent then
                hold.humanoid.AutoRotate = hold.autoRotate
                hold.humanoid.PlatformStand = hold.platformStand
                hold.humanoid.Sit = not arrived and hold.sit or false
            end
        end)
        if hold.restorePosition then
            teleportPlayer(hold.root, hold.origin, function() return getMovementRevision() == hold.token end)
        end
    end

    function api.Stop(reason)
        if not api.Busy and not api.Enabled and not activeHold then return end
        local hold, previousToken = activeHold, getMovementRevision()
        generation = generation + 1
        api.Busy, api.Enabled = false, false
        local token = interruptAutomationMovement()
        if hold and hold.token == previousToken then hold.token = token end
        setTourVisual(false)
        if reason then status(reason .. ". Travel stopped.") end
        -- Cancel the hop before the return teleport yields its physics frame.
        releaseHold(hold, false)
    end

    function api.PrepareManual()
        api.Stop("Manual travel selected")
        Builder.Stop()
        if autoOpenAfterTeleport or continueChestRoute or ChestLoot.Enabled then
            autoOpenAfterTeleport, continueChestRoute = false, false
            chestRouteGeneration = chestRouteGeneration + 1
            chestRouteRunning = false
            ChestLoot.SetEnabled(false)
            Config:Set("AutoChestAndLoot", false)
            Config:Set("AutoOpenAfterTeleport", false)
            Config:Set("AutoNextChest", false)
            if chestRuntime.toggle then chestRuntime.toggle:Set(false, false) end
            ChestLoot.SetStatus("Stopped for manual / island travel.")
        end
        WorldLoot.DisableForRoute("Teleport", "island travel", true)
        Automation.StopStationFarmsForWorldLoot()
        if flyRequested or flying or Config:Get("FlyEnabled") == true then
            setFlyEnabled(false)
            setFlyToggleVisual(false)
        end
        return interruptAutomationMovement()
    end

    local function canRun(run, token)
        return scriptAlive and api.Busy and generation == run and getMovementRevision() == token
    end
    local function hop(position, island, run, token)
        local lockDeadline = os.clock() + 1.8
        while canRun(run, token) and not SharedInteraction.TryAcquire("island-travel") do
            if os.clock() >= lockDeadline then return false, "interaction-busy" end
            task.wait(0.04)
        end
        if not canRun(run, token) then return false, "cancelled" end
        local hold
        local ok, success, reason = xpcall(function()
            local root, humanoid = getHumanoidRootPart(), getHumanoid()
            if not root or not humanoid or humanoid.Health <= 0 or root.Anchored then
                return false, "character-not-ready"
            end
            hold = {
                root = root, humanoid = humanoid, origin = root.CFrame, token = token,
                anchored = root.Anchored, autoRotate = humanoid.AutoRotate,
                platformStand = humanoid.PlatformStand, sit = humanoid.Sit,
            }
            activeHold = hold
            local rotation = root.CFrame - root.CFrame.Position
            local probe = island and CFrame.new(position.X, math.max(200, position.Y + 64), position.Z) * rotation
                or CFrame.new(position) * rotation
            humanoid.Sit = false
            humanoid.AutoRotate = false
            root.Anchored = true
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            requestStream(position)
            if not teleportPlayer(root, probe, function() return canRun(run, token) and not hold.closed end) then
                return false, "cancelled"
            end
            local deadline = os.clock() + (island and 3.2 or 0.35)
            local nextGroundCheck = os.clock() + 0.12
            repeat
                if not canRun(run, token) or hold.closed then return false, "cancelled" end
                if root ~= getHumanoidRootPart() or not root.Parent or humanoid.Health <= 0 then
                    return false, "character-not-ready"
                end
                SharedInteraction.Touch("island-travel")
                if (root.Position - probe.Position).Magnitude > 1 then
                    if not teleportPlayer(root, probe, function() return canRun(run, token) and not hold.closed end) then
                        return false, "cancelled"
                    end
                end
                if island and os.clock() >= nextGroundCheck then
                    nextGroundCheck = os.clock() + 0.16
                    local ground = landingFor(island)
                    if ground then
                        local height = math.max(3, humanoid.HipHeight + root.Size.Y / 2 + 0.5)
                        local arrived = teleportPlayer(root, CFrame.new(ground + Vector3.new(0, height, 0)) * rotation,
                            function() return canRun(run, token) and not hold.closed end)
                        return arrived, arrived and "landed" or "cancelled"
                    end
                end
                task.wait(0.04)
            until os.clock() >= deadline
            return not island, island and "ground-not-ready" or "coordinate"
        end, function(message) return tostring(message) end)
        releaseHold(hold, ok and success == true)
        SharedInteraction.Release("island-travel")
        if not ok then
            warn("[SEA Island Travel] " .. tostring(success))
            return false, "travel-error"
        end
        return success == true, reason
    end

    local function begin(tour)
        local token = api.PrepareManual()
        generation = generation + 1
        api.Busy, api.Enabled = true, tour == true
        setTourVisual(api.Enabled)
        return generation, token
    end
    local function travelOnce(position, island, label)
        if not validPosition(position) then status("Invalid coordinates."); return false end
        if not getHumanoidRootPart() then status("Character is not ready. Try again after spawning."); return false end
        local run, token = begin(false)
        status("Traveling to " .. label .. "...")
        task.spawn(function()
            local success, reason = hop(position, island, run, token)
            if generation ~= run then return end
            api.Busy = false
            status(success and ("Arrived: " .. label .. ". Other travel automations are OFF.")
                or ("Travel not completed: " .. tostring(reason) .. ". Returned when possible."))
        end)
        return true
    end

    function api.GoIsland()
        api.Refresh(false)
        local record = islandById[selectedIsland]
        if not record then status("No island selected. Wait for the map or refresh the list."); return false end
        return travelOnce(record.position, record, record.label)
    end

    function api.SetTour(enabled)
        if enabled ~= true then api.Stop("Stopped by you"); return end
        api.Refresh(false)
        local run, token = begin(true)
        status("Tour started. All destinations, including unstreamed islands, will be visited.")
        task.spawn(function()
            local visited = {}
            local visitedCount, skippedCount, pass = 0, 0, 1
            while canRun(run, token) and api.Enabled do
                local ok, reason = pcall(function()
                    local root, humanoid = getHumanoidRootPart(), getHumanoid()
                    if not root or not humanoid or humanoid.Health <= 0 or root.Anchored then
                        status("Tour waiting for the character to respawn / become ready.")
                        task.wait(0.4)
                        return
                    end
                    api.Refresh(false)
                    local nextIsland, distance = nil, math.huge
                    for _, record in ipairs(islands) do
                        if not visited[record.id] then
                            local d = (record.position - root.Position).Magnitude
                            if d < distance then nextIsland, distance = record, d end
                        end
                    end
                    if not nextIsland then
                        if #islands == 0 then
                            status("Waiting for the island catalog; tour remains ON.")
                            task.wait(0.5)
                        elseif Config:Get("IslandTourRepeat") ~= true then
                            api.Enabled, api.Busy = false, false
                            setTourVisual(false)
                            status(string.format("Tour complete: %d visited, %d skipped.", visitedCount, skippedCount))
                        else
                            status(string.format("Pass %d complete: %d visited, %d skipped. Starting another scan.", pass, visitedCount, skippedCount))
                            visited, visitedCount, skippedCount, pass = {}, 0, 0, pass + 1
                            task.wait(0.35)
                        end
                        return
                    end
                    status(string.format("Pass %d | %d/%d processed | %s", pass, visitedCount + skippedCount + 1, #islands, nextIsland.label))
                    local success, result = hop(nextIsland.position, nextIsland, run, token)
                    if not canRun(run, token) then return end
                    if result == "character-not-ready" or result == "interaction-busy" then
                        status("Tour waiting: " .. result .. ". The same destination will be retried.")
                        task.wait(0.35)
                        return
                    end
                    visited[nextIsland.id] = true
                    if success then visitedCount = visitedCount + 1 else skippedCount = skippedCount + 1 end
                    status(string.format("Pass %d | %d/%d processed | %s%s", pass, visitedCount + skippedCount, #islands,
                        success and "At " or ("Skipped (" .. tostring(result) .. "): "), nextIsland.label))
                    local deadline = os.clock() + (success and Config:Get("IslandTourDelay") or 0.3)
                    repeat task.wait(0.05) until not canRun(run, token) or os.clock() >= deadline
                end)
                if not ok and canRun(run, token) then
                    warn("[SEA Island Tour] " .. tostring(reason))
                    status("Tour recovered from a step error; scanning continues.")
                    task.wait(0.4)
                end
            end
            if generation == run then
                releaseHold(activeHold, false)
                api.Busy, api.Enabled = false, false
                setTourVisual(false)
            end
        end)
    end

    function api.ParseCoordinates(text)
        local values = {}
        for token in tostring(text or ""):gmatch("[^,%s]+") do
            local value = tonumber(token)
            if not finite(value) or #values >= 3 then return nil end
            values[#values + 1] = value
        end
        if #values ~= 3 then return nil end
        return Vector3.new(values[1], values[2], values[3])
    end
    function api.RefreshSaved()
        local labels, points = {}, Config:Get("SavedTeleports")
        savedByLabel = {}
        local chosen
        for index, point in ipairs(points) do
            local label = string.format("%s  [%.1f, %.1f, %.1f] #%d", point.name, point.x, point.y, point.z, index)
            labels[#labels + 1] = label
            savedByLabel[label] = point
            if point.id == selectedPoint then chosen = label end
        end
        if not chosen and points[1] then selectedPoint, chosen = points[1].id, labels[1] end
        if not chosen then selectedPoint = "" end
        if controls.saved then controls.saved:Refresh(labels); controls.saved:Select(chosen, false) end
        return points
    end
    function api.SavePoint(name, text)
        if api.Busy then status("Stop travel before saving a point."); return false end
        name = tostring(name or ""):gsub("%c", " "):match("^%s*(.-)%s*$")
        local points = api.RefreshSaved()
        if #points >= 40 then status("40 points saved. Delete an unused point first."); return false end
        local position
        if tostring(text or ""):find("%S") then position = api.ParseCoordinates(text)
        else
            local root = getHumanoidRootPart()
            position = root and root.Position
        end
        if not validPosition(position) then status("Use three numbers: X, Y, Z; or leave XYZ empty for your current position."); return false end
        if name == "" then name = "Point " .. (#points + 1) end
        name = string.sub(name, 1, 40)
        local point = {
            id = game:GetService("HttpService"):GenerateGUID(false), name = name,
            x = position.X, y = position.Y, z = position.Z,
            placeId = tostring(game.PlaceId), jobId = tostring(game.JobId),
            mapSeed = tostring(localPlayer:GetAttribute("DisplaySeed") or ""),
        }
        points[#points + 1] = point
        selectedPoint = point.id
        Config:Set("SavedTeleports", points, true)
        Config:Set("SelectedTeleport", selectedPoint)
        api.RefreshSaved()
        status("Saved " .. name .. " at " .. coordinates(position) .. ". Separate from Sack Drop Here.")
        return true
    end
    local function getSelectedPoint()
        for _, point in ipairs(Config:Get("SavedTeleports")) do
            if point.id == selectedPoint then return point end
        end
        return nil
    end
    function api.GoSaved()
        local point = getSelectedPoint()
        if not point then status("Choose a saved point first."); return false end
        if point.placeId ~= "" and point.placeId ~= tostring(game.PlaceId) then
            status("This point belongs to a different place; teleport was not started."); return false
        end
        local seed = tostring(localPlayer:GetAttribute("DisplaySeed") or "")
        local differentMap = point.mapSeed ~= "" and seed ~= "" and point.mapSeed ~= seed
        local unknownMap = (point.mapSeed == "" or seed == "") and point.jobId ~= tostring(game.JobId)
        if differentMap or unknownMap then
            if not confirmation or confirmation.action ~= "travel" or confirmation.id ~= point.id or confirmation.untilAt < os.clock() then
                confirmation = { action = "travel", id = point.id, untilAt = os.clock() + 6 }
                status("Saved in another map/server. Coordinates may be unsafe; press Go Saved again within 6s to confirm.")
                return false
            end
        end
        confirmation = nil
        return travelOnce(Vector3.new(point.x, point.y, point.z), nil, point.name)
    end
    function api.GoCoordinates(text)
        local position = api.ParseCoordinates(text)
        if not position then status("Invalid XYZ. Example: 250, 160, -300."); return false end
        return travelOnce(position, nil, coordinates(position))
    end
    function api.DeleteSaved()
        local point = getSelectedPoint()
        if not point then status("Choose a saved point first."); return false end
        if not confirmation or confirmation.action ~= "delete" or confirmation.id ~= point.id or confirmation.untilAt < os.clock() then
            confirmation = { action = "delete", id = point.id, untilAt = os.clock() + 6 }
            status("Delete " .. point.name .. "? Press Delete again within 6s to confirm.")
            return false
        end
        local points = {}
        for _, saved in ipairs(Config:Get("SavedTeleports")) do
            if saved.id ~= point.id then points[#points + 1] = saved end
        end
        confirmation, selectedPoint = nil, ""
        Config:Set("SavedTeleports", points, true)
        Config:Set("SelectedTeleport", "")
        api.RefreshSaved()
        status("Deleted saved point: " .. point.name)
        return true
    end

    function api.BuildUI(tab)
        local islandSection = tab:Section({ Title = "Islands" })
        controls.status = islandSection:Paragraph({ Title = "Travel status", Desc = lastStatus })
        controls.islands = islandSection:Dropdown({
            Title = "Island Destination", Desc = "Search by name; X/Z distinguishes duplicate islands",
            Values = {}, Multi = false, AllowNone = false, SearchBarEnabled = true,
            Callback = function(label)
                selectedIsland = islandByLabel[firstSelectedValue(label)] or ""
                Config:Set("SelectedIsland", selectedIsland)
            end,
        })
        islandSection:Button({ Title = "Teleport to Selected Island", Desc = "Streams the area and finds a standing surface",
            Action = "Go", Callback = api.GoIsland })
        islandSection:Button({ Title = "Refresh Islands", Desc = "Also updates automatically when island models appear",
            Action = "Scan", Callback = function() api.Refresh(true) end })
        controls.catalog = islandSection:Paragraph({ Title = "Island catalog", Desc = "Loading map markers..." })

        local tourSection = tab:Section({ Title = "All-Island Tour" })
        tourSection:Paragraph({ Title = "One movement route at a time",
            Desc = "Travel stops Auto Chest, World Loot, Bonfire, Grinder, and Fly. The tour visits every map marker, skips unavailable ground, and resumes after respawn. It starts OFF on each script run." })
        controls.tour = tourSection:Toggle({
            Title = "Auto Teleport All Islands", Desc = "Continuous tour until OFF when Repeat Tour is enabled",
            Value = false, Callback = api.SetTour,
        })
        tourSection:Toggle({ Title = "Repeat Tour", Desc = "OFF = one pass; ON = rescan and repeat",
            Value = Config:Get("IslandTourRepeat"), Callback = function(value) Config:Set("IslandTourRepeat", value) end })
        tourSection:Slider({ Title = "Stay on Each Island", Desc = "Seconds after landing; streaming has its own timeout",
            Value = { Min = 1, Max = 20, Default = Config:Get("IslandTourDelay") }, Step = 1,
            Callback = function(value) Config:Set("IslandTourDelay", value) end })
        tourSection:Button({ Title = "Stop Travel Now", Desc = "Stops island or coordinate travel, including an active load",
            Action = "Stop", Callback = function() api.Stop("Stopped by you") end })

        local savedSection = tab:Section({ Title = "Saved Coordinates" })
        savedSection:Paragraph({ Title = "Named points",
            Desc = "Enter a name and save. Empty XYZ uses your current position; typed XYZ is saved exactly. Saved points use the existing config file, or session storage if file access is unavailable. Another map seed requires confirmation." })
        controls.name = savedSection:Input({ Title = "Point Name", Desc = "Optional; duplicate names never overwrite older points",
            Placeholder = "My fishing spot", MaxLength = 40 })
        controls.xyz = savedSection:Input({ Title = "X, Y, Z", Desc = "Empty = current position when saving; typed coordinates are exact",
            Placeholder = "250, 160, -300", MaxLength = 100 })
        savedSection:Button({ Title = "Save Point", Desc = "Stores this position with its place and map seed",
            Action = "Save", Callback = function() api.SavePoint(controls.name:Get(), controls.xyz:Get()) end })
        savedSection:Button({ Title = "Teleport to Entered XYZ", Desc = "Uses the coordinates above without saving",
            Action = "Go XYZ", Callback = function() api.GoCoordinates(controls.xyz:Get()) end })
        controls.saved = savedSection:Dropdown({
            Title = "Saved Points", Desc = "Up to 40 points; independent of Sack Drop Here",
            Values = {}, Multi = false, AllowNone = false, SearchBarEnabled = true,
            Callback = function(label)
                local point = savedByLabel[firstSelectedValue(label)]
                selectedPoint = point and point.id or ""
                confirmation = nil
                Config:Set("SelectedTeleport", selectedPoint)
            end,
        })
        savedSection:Button({ Title = "Teleport to Saved Point", Desc = "Different map/server asks for a second click",
            Action = "Go Saved", Callback = api.GoSaved })
        savedSection:Button({ Title = "Delete Selected Point", Desc = "Requires a second click within 6 seconds",
            Action = "Delete", Callback = api.DeleteSaved })
        api.Refresh(false)
        api.RefreshSaved()
    end
    return api
end)()

-- Interface construction ---------------------------------------------------

local window: any = SeaUI:CreateWindow({
    Title = "100 Days at Sea v58",
    ToggleKey = Enum.KeyCode.RightShift,
})
window:SetToggleKey(Enum.KeyCode.RightShift)

assert(pcall(function()
    -- v34: UI remains in its own closure/register pool.
    -- This avoids Luau's ~200 local-register limit in the parent chunk.

    local homeTab = window:Tab({ Title = "Home" })
    local teleportTab = window:Tab({ Title = "Teleport" })
    Travel.BuildUI(teleportTab)
    Builder.BuildUI(window:Tab({ Title = "Builder" }))

    local quickTravelSection = homeTab:Section({ Title = "Quick Travel" })
    quickTravelSection._wrapper.LayoutOrder = 10
    quickTravelSection:Paragraph({
        Title = "Fast access",
        Desc = "Manual travel stops movement automations. Island tours and saved coordinates are in the Teleport tab.",
    })
    quickTravelSection:Button({
        Title = "Saved Base",
        Desc = "Return to the position saved when the script started",
        Action = "Base",
        Callback = function() Travel.PrepareManual(); returnToBase() end,
    })
    quickTravelSection:Button({
        Title = "Bonfire",
        Desc = "Teleport to Spawn Island bonfire",
        Action = "Go",
        Callback = function() Travel.PrepareManual(); teleportToBonfire() end,
    })
    quickTravelSection:Button({
        Title = "Merchant",
        Desc = "Available after the Merchant spawns",
        Action = "Go",
        Callback = function() Travel.PrepareManual(); teleportToMerchant() end,
    })
    quickTravelSection:Button({
        Title = "Fisherman",
        Desc = "Teleport to Tutorial Island fisherman",
        Action = "Go",
        Callback = function() Travel.PrepareManual(); teleportToFisherman() end,
    })

    local chestRouteSection: any = homeTab:Section({ Title = "Auto Chest + Loot" })
    ChestLoot.StatusControl = chestRouteSection:Paragraph({
        Title = "Chest route status",
        Desc = "Ready. One switch searches islands, opens chests, and collects their fresh drops in proximity batches.",
    })
    ChestLoot.StatusControl.Instance.LayoutOrder = -1
    chestDropdown = chestRouteSection:Dropdown({
        Title = "Chest Type",
        Desc = "Choose one chest family or Any Chest; opened chests are skipped",
        Values = CHEST_NAMES,
        Value = selectedChest,
        Multi = false,
        AllowNone = false,
        Callback = function(option)
            selectedChest = firstSelectedValue(option)
            Config:Set("SelectedChest", selectedChest)
        end,
    })
    local chestLootDropdown = chestRouteSection:Dropdown({
        Title = "Loot Filter",
        Desc = "All Items includes materials, ammo, weapons, and Sack upgrades; or choose exact drops",
        Values = ChestLoot.Catalog,
        Value = ChestLoot.Selected,
        Multi = true,
        AllowNone = false,
        SearchBarEnabled = true,
        Callback = ChestLoot.SetSelected,
    })
    ChestLoot.SetDropdown(chestLootDropdown)
    local autoChestToggle: any = chestRouteSection:Toggle({
        Title = "Auto Chest + Loot",
        Desc = "ON = scan, teleport, open and loot; repeats until OFF",
        Value = autoOpenAfterTeleport,
        Callback = function(enabled)
            enabled = enabled == true
            if enabled then
                Travel.Stop("Auto Chest + Loot started")
                if flyRequested or flying then
                    setFlyEnabled(false)
                    setFlyToggleVisual(false)
                end
            end
            interruptAutomationMovement()
            if enabled and #ChestLoot.Selected == 0 then
                chestLootDropdown:Select({ "All Items" })
            end
            autoOpenAfterTeleport = enabled
            continueChestRoute = enabled
            ChestLoot.SetEnabled(enabled)
            Config:Set("AutoChestAndLoot", enabled)
            Config:Set("AutoOpenAfterTeleport", enabled)
            Config:Set("AutoNextChest", enabled)
            chestRouteGeneration = chestRouteGeneration + 1
            chestRouteRunning = false

            if enabled then
                WorldLoot.DisableForRoute("Auto Chest + Loot", "chest route", true)
                Automation.StopStationFarmsForWorldLoot()
                task.defer(runChestRoute)
                notify("Auto Chest + Loot", "Started: open + chest-only loot + continuous route", 2.2)
            else
                ChestLoot.SetStatus("Stopped. Enable Auto Chest + Loot to resume.")
                notify("Auto Chest + Loot", "Stopped", 1.5)
            end
        end,
    })
    autoChestToggle.Instance.LayoutOrder = -2
    chestRuntime.toggle = autoChestToggle
    chestRouteSection:Toggle({
        Title = "O2 Guard",
        Desc = "Surface at O2 25, wait for normal O2 refill, then continue safely",
        Value = o2GuardEnabled,
        Callback = function(enabled)
            o2GuardEnabled = enabled
            Config:Set("O2Guard", enabled)
        end,
    })
    chestRouteSection:Button({
        Title = "Next Chest (Manual)",
        Desc = "Manual teleport shortcut; the master toggle above handles the full automatic route",
        Action = "Go",
        Callback = function()
            if not autoOpenAfterTeleport then Travel.PrepareManual() end
            teleportToSelectedChest()
        end,
    })

    local creatureSection = teleportTab:Section({ Title = "Creature Finder" })
    creatureDropdown = creatureSection:Dropdown({
        Title = "Creature Type",
        Desc = "Choose a creature and teleport to the nearest matching spawn",
        Values = CREATURE_NAMES,
        Value = selectedCreature,
        Multi = false,
        AllowNone = false,
        SearchBarEnabled = true,
        Callback = function(option)
            selectedCreature = firstSelectedValue(option)
            Config:Set("SelectedCreature", selectedCreature)
        end,
    })
    creatureSection:Button({
        Title = "Go to Creature",
        Desc = "Move to the selected creature",
        Action = "Go",
        Callback = function() Travel.PrepareManual(); teleportToSelectedCreature() end,
    })

    local lootTab = window:Tab({ Title = "Loot" })

    local worldLootSection = lootTab:Section({ Title = "World Auto Loot" })
    worldLootSection:Paragraph({
        Title = "Full-map Sack farm",
        Desc = "Keeps the Sack equipped, searches the whole map, ignores items inside the current Bonfire Ring, empties it at Drop Here when full, and resumes automatically. The boundary grows with the base.",
    })
    WorldLoot.SetToggleControl(worldLootSection:Toggle({
        Title = "World Auto Loot",
        Desc = "Repeatedly search every island for the selected items",
        Value = WorldLoot.Enabled,
        Callback = function(enabled)
            if enabled and autoChestToggle.Value then
                autoChestToggle:Set(false)
            end
            WorldLoot.SetEnabled(enabled)
        end,
    }))
    ChestLoot.SetDropdown(worldLootSection:Dropdown({
        Title = "World Loot Types",
        Desc = "Choose All Items, exact loot, or Enemy Corpses for every supported enemy ragdoll",
        Values = ChestLoot.Catalog,
        Value = WorldLoot.Selected,
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = WorldLoot.SetSelected,
    }))
    worldLootSection:Dropdown({
        Title = "Pickup Method",
        Desc = "Smart chooses native E/Collect versus Sack StoreItem; pickup now runs from real proximity",
        Values = LOOT_MODES,
        Value = WorldLoot.Mode,
        Multi = false,
        AllowNone = false,
        Callback = WorldLoot.SetMode,
    })
    worldLootSection:Button({
        Title = "Collect Selected Now",
        Desc = "Run one collection pass immediately",
        Action = "Collect",
        Callback = WorldLoot.CollectNow,
    })
    worldLootSection:Button({
        Title = "Refresh Loot List",
        Desc = "Append newly discovered readable item names",
        Action = "Scan",
        Callback = function()
            WorldLoot.Refresh(true)
        end,
    })

    local sackDropSection = lootTab:Section({ Title = "Sack Drop Here" })
    sackDropSection:Paragraph({
        Title = "One saved drop point",
        Desc = "Native DropItem has no position argument. Auto Farm moves to this point only when the Sack is full, drops with fast counter-confirmation, keeps Sack equipped, then resumes the full-map search.",
    })
    sackDropSection:Button({
        Title = "Set Drop Here",
        Desc = "Save your current position as the one-point Sack drop location",
        Action = "Set",
        Callback = DropManager.SetHere,
    })
    sackDropSection:Button({
        Title = "Clear Drop Here",
        Desc = "Disable the saved drop location",
        Action = "Clear",
        Callback = DropManager.Clear,
    })
    sackDropSection:Toggle({
        Title = "Virtual Unlimited Sack (Auto Cycle)",
        Desc = "True capacity is server-owned. This repeatedly empties a full Sack at Drop Here and resumes; World Auto Farm uses the cycle automatically, and this toggle extends it to Chest Loot",
        Value = Config:Get("AutoEmptySack") == true,
        Callback = DropManager.SetAutoEnabled,
    })
    sackDropSection:Toggle({
        Title = "Protect Dropped Items",
        Desc = "Protect the Drop Here zone from World/Chest Loot, Auto Eat, Bonfire, and Grinder so stored items stay there",
        Value = Config:Get("ProtectDropHere") ~= false,
        Callback = DropManager.SetProtectionEnabled,
    })
    sackDropSection:Slider({
        Title = "Drop Protection Radius",
        Desc = "World/Chest Auto Loot ignores items this many studs around Drop Here",
        Step = 1,
        Value = { Min = 5, Max = 60, Default = Config:Get("DropProtectRadius") },
        Callback = DropManager.SetProtectRadius,
    })
    sackDropSection:Dropdown({
        Title = "Drop Speed",
        Desc = "Fast: up to 4 drops/frame, 16 pending; one confirmed probe, continuous position checks and full-batch confirmation",
        Values = { "Slow", "Normal", "Fast" },
        Value = Config:Get("DropSpeed"),
        Multi = false,
        AllowNone = false,
        Callback = DropManager.SetDropSpeed,
    })
    sackDropSection:Button({
        Title = "Empty Sack Now",
        Desc = "Empty the current Sack at your saved Drop Here point",
        Action = "Drop",
        Callback = function() DropManager.EmptyNow(true) end,
    })

    local chestLootSection = lootTab:Section({ Title = "Chest Loot Settings" })
    chestLootSection:Paragraph({
        Title = "Master control is on Home",
        Desc = "Auto Chest + Loot now controls teleport, opening, chest-only pickup, and continuous routing with one switch.",
    })
    chestLootSection:Dropdown({
        Title = "Pickup Method",
        Desc = "Smart chooses native E/Collect versus Sack StoreItem from real proximity",
        Values = LOOT_MODES,
        Value = ChestLoot.Mode,
        Multi = false,
        AllowNone = false,
        Callback = ChestLoot.SetMode,
    })
    chestLootSection:Slider({
        Title = "Chest Drop Radius",
        Desc = "Maximum spawn distance from the source chest; existing items are ignored",
        Step = 5,
        Value = { Min = 10, Max = 80, Default = ChestLoot.Radius },
        Callback = ChestLoot.SetRadius,
    })
    chestLootSection:Button({
        Title = "Collect Nearby Chest Loot",
        Desc = "Manual retry for the current Home loot filter; works even while Auto Chest is OFF",
        Action = "Collect",
        Callback = ChestLoot.CollectNearby,
    })

    local bringSection = lootTab:Section({ Title = "Bring Items" })
    ChestLoot.SetDropdown(bringSection:Dropdown({
        Title = "Item Types",
        Desc = "Select one or more discovered items to move to your position",
        Values = ChestLoot.Catalog,
        Value = selectedBringItems,
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = function(options)
            selectedBringItems = options
            Config:Set("BringItems", options)
        end,
    }))
    bringSection:Button({
        Title = "Bring Selected Items",
        Desc = "Move matching client-owned items and count only positions that persist nearby",
        Action = "Bring",
        Callback = bringSelectedItems,
    })

    local lootDebugSection = lootTab:Section({ Title = "Diagnostics" })
    lootDebugSection:Toggle({
        Title = "Detailed Loot Log",
        Desc = "Print collection results only while troubleshooting",
        Value = ChestLoot.DiagnosticsEnabled,
        Callback = ChestLoot.SetDiagnosticsEnabled,
    })
    lootDebugSection:Button({
        Title = "Copy Last Loot Report",
        Desc = "Copy the latest 32 attempts",
        Action = "Copy",
        Callback = ChestLoot.CopyDiagnostics,
    })
    lootDebugSection:Button({
        Title = "Clear Loot Report",
        Desc = "Remove current diagnostic history",
        Action = "Clear",
        Callback = ChestLoot.ClearDiagnostics,
    })

    local automationTab = window:Tab({ Title = "Automation" })

    local survivalAutomationSection = automationTab:Section({ Title = "Survival" })
    survivalAutomationSection:Toggle({
        Title = "Auto Eat",
        Desc = "Eat nearby world food using the native E/Eat interaction when Food is low",
        Value = Config:Get("AutoEat") == true,
        Callback = Automation.SetAutoEat,
    })
    survivalAutomationSection:Slider({
        Title = "Eat Threshold",
        Desc = "Auto Eat activates below this Food value",
        Step = 5,
        Value = { Min = 5, Max = 100, Default = Config:Get("EatThreshold") },
        Callback = function(value) Config:Set("EatThreshold", value) end,
    })

    local craftSection = automationTab:Section({ Title = "Crafting" })
    craftSection:Toggle({
        Title = "Auto Craft (Super Fast)",
        Desc = "Up to 4 concurrent crafts with material/stock reservations; Outpost stays single-request",
        Value = Config:Get("AutoCraft") == true,
        Callback = Automation.SetAutoCraft,
    })
    craftSection:Dropdown({
        Title = "Craft Item",
        Desc = "Choose one recipe or All",
        Values = Automation.GetCraftNames(),
        Value = Config:Get("AutoCraftItem"),
        Multi = false,
        AllowNone = false,
        SearchBarEnabled = true,
        Callback = function(value) Config:Set("AutoCraftItem", firstSelectedValue(value) or "All") end,
    })
    do
        local statusControl = craftSection:Paragraph({ Title = "Craft status", Desc = Automation.GetCraftStatus() })
        task.spawn(function()
            local previous
            while scriptAlive do
                local current = Automation.GetCraftStatus()
                if current ~= previous then
                    previous = current
                    statusControl:Set(current, "Craft status")
                end
                task.wait(0.25)
            end
        end)
    end

    local stationSection = automationTab:Section({ Title = "Station Sack Farms" })
    stationSection:Paragraph({
        Title = "Continuous station farming",
        Desc = "Search every island, fill the Sack, and deliver automatically. A partial Sack is delivered after an empty sweep or 20s (Bonfire) / 30s (Grinder) without a pickup. Search probes briefly hold position while streaming.",
    })
    do
        local statusControl = stationSection:Paragraph({
            Title = "Station status",
            Desc = Automation.GetStationStatusText(),
        })
        task.spawn(function()
            local previous
            while scriptAlive do
                local text = Automation.GetStationStatusText()
                if text ~= previous then
                    previous = text
                    pcall(function() statusControl:Set(text, "Station status") end)
                end
                task.wait(0.5)
            end
        end)
    end
    stationSection:Toggle({
        Title = "Continuous Full-Map Scan",
        Desc = "If nothing is nearby, search every island and retry automatically",
        Value = Config:Get("StationWorldSearch") ~= false,
        Callback = function(enabled) Config:Set("StationWorldSearch", enabled) end,
    })

    Automation.SetBonfireToggle(stationSection:Toggle({
        Title = "Auto Bonfire",
        Desc = "Teleport-search selected BonfireFuel items outside the current base Ring, fill the Sack, then hover only while dropping into SpawnIsland.Dropper",
        Value = Config:Get("AutoBonfire") == true,
        Callback = function(enabled)
            if enabled and autoChestToggle.Value then
                autoChestToggle:Set(false)
            end
            Automation.SetAutoBonfire(enabled)
        end,
    }))
    Automation.SetBonfireItemsDropdown(stationSection:Dropdown({
        Title = "Bonfire Items",
        Desc = "Only item templates with BonfireFuel > 0 are listed",
        Values = Automation.GetBonfireItems(),
        Value = Automation.GetSelectedBonfireItems(),
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = Automation.SetBonfireItems,
    }))
    stationSection:Paragraph({
        Title = "Persistent until MAX",
        Desc = "Auto Bonfire keeps scanning and delivering fuel continuously; level 7/MAX is its only automatic stop.",
    })

    Automation.SetGrinderToggle(stationSection:Toggle({
        Title = "Auto Grinder",
        Desc = "Teleport-search selected Resource items outside the current base Ring, fill the Sack, then hover only while dropping into Grinder.Collection with Sack-handle centering",
        Value = Config:Get("AutoGrinder") == true,
        Callback = function(enabled)
            if enabled and autoChestToggle.Value then
                autoChestToggle:Set(false)
            end
            Automation.SetAutoGrinder(enabled)
        end,
    }))
    Automation.SetGrinderItemsDropdown(stationSection:Dropdown({
        Title = "Grinder Items",
        Desc = "Resource items plus Enemy Corpses; the corpse group follows Ragdoll + Resource instead of temporary NPC names",
        Values = Automation.GetGrinderItems(),
        Value = Automation.GetSelectedGrinderItems(),
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = Automation.SetGrinderItems,
    }))
    stationSection:Button({
        Title = "Refresh Compatible Items",
        Desc = "Rescan valid BonfireFuel / Resource items; Enemy Corpses remains available even before a body spawns",
        Action = "Scan",
        Callback = function() Automation.RefreshStationItems(true) end,
    })

    local combatTab = window:Tab({ Title = "Combat" })
    Automation.SetUnlimitedAmmoToggle(combatTab:Section({
        Title = "Weapon Utilities",
    }):Toggle({
        Title = "Unlimited Ammo / No Reload",
        Desc = "Keeps the client magazine at 999 for compatible guns and throwables; special server-driven weapons remain unchanged",
        Value = Config:Get("UnlimitedAmmo") == true,
        Callback = Automation.SetUnlimitedAmmo,
    }))

    Automation.SetRapidFireToggle(combatTab:Section({
        Title = "Special Weapons (Experimental)",
    }):Toggle({
        Title = "Rapid Fire / Cooldown Bypass",
        Desc = "Hold attack to direct-fire Raygun, Miniguns, Void Slicer, Squid Laser, Magma Staff, or Wizard Staff; server rate limits still apply",
        Value = Config:Get("ExperimentalRapidFire") == true,
        Callback = Automation.SetExperimentalRapidFire,
    }))

    local combatSection = combatTab:Section({ Title = "Smart NPC Kill" })
    combatSection:Paragraph({
        Title = "Verified combat targets only",
        Desc = "Players, friendly/quest NPCs, companions, ragdolls, and client-only visual rigs are excluded. Live unknown types appear only when a supported server kill path is detected.",
    })
    NpcKill.SetDropdown(combatSection:Dropdown({
        Title = "NPC Types",
        Desc = "All verified creature templates; incompatible NPCs are removed",
        Values = NpcKill.InitialOptions,
        Value = NpcKill.InitialSelection,
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = NpcKill.SetSelected,
    }))
    combatSection:Toggle({
        Title = "Enable Smart Click Kill",
        Desc = "Uses only a verified server CreatureID route or compatible combat Humanoid path",
        Value = Config:Get("SmartNpcKill") == true,
        Callback = NpcKill.SetEnabled,
    })
    combatSection:Button({
        Title = "Scan NPC List Now",
        Desc = "Refresh live compatible combat rigs and purge stale invalid entries",
        Action = "Scan",
        Callback = function()
            NpcKill.Refresh(true)
        end,
    })
    combatSection:Paragraph({
        Title = "NPC Status",
        Desc = string.format(
            "%d verified combat types + %d live compatible additions; %d living now.",
            NpcKill.CatalogCount,
            NpcKill.InitialDiscoveredCount,
            NpcKill.InitialInstanceCount
        ),
    })

    local espTab = window:Tab({ Title = "ESP" })

    local espDisplaySection = espTab:Section({ Title = "ESP Display" })
    espDisplaySection:Toggle({
        Title = "Enable ESP",
        Desc = "Master switch for every ESP category below",
        Value = Config:Get("EspEnabled") == true,
        Callback = setEspEnabled,
    })
    espDisplaySection:Toggle({
        Title = "Players",
        Desc = "DisplayName, username, and distance",
        Value = espShowPlayers,
        Callback = function(enabled)
            espShowPlayers = enabled
            Config:Set("EspShowPlayers", enabled)
            if espEnabled then refreshEsp() end
        end,
    })
    espDisplaySection:Toggle({
        Title = "Creatures",
        Desc = "Highlight living creatures",
        Value = espShowCreatures,
        Callback = function(enabled)
            espShowCreatures = enabled
            Config:Set("EspShowCreatures", enabled)
            if espEnabled then refreshEsp() end
        end,
    })
    espDisplaySection:Toggle({
        Title = "Chests",
        Desc = "Highlight unopened chests",
        Value = espShowChests,
        Callback = function(enabled)
            espShowChests = enabled
            Config:Set("EspShowChests", enabled)
            if espEnabled then refreshEsp() end
        end,
    })
    espDisplaySection:Toggle({
        Title = "Resources",
        Desc = "Show Wood / Metal / Goo value and distance",
        Value = espShowResources,
        Callback = function(enabled)
            espShowResources = enabled
            Config:Set("EspShowResources", enabled)
            if espEnabled then refreshEsp() end
        end,
    })
    espDisplaySection:Button({
        Title = "Refresh ESP Now",
        Desc = "Update visible targets immediately",
        Action = "Refresh",
        Callback = updateEspFromButton,
    })

    local espItemSection = espTab:Section({ Title = "Item ESP Filter" })
    ChestLoot.SetDropdown(espItemSection:Dropdown({
        Title = "Item Types",
        Desc = "Choose which discovered ordinary loot items should also be highlighted",
        Values = ChestLoot.Catalog,
        Value = selectedEspItems,
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = function(options)
            selectedEspItems = options
            Config:Set("EspItems", options)
            if espEnabled then refreshEsp() end
        end,
    }))

    local playerTab = window:Tab({ Title = "Player" })

    local movementSection = playerTab:Section({ Title = "Movement" })
    movementSection:Slider({
        Title = "Walkspeed",
        Desc = "0 to 100",
        Step = 1,
        Value = { Min = 0, Max = 100, Default = desiredWalkSpeed },
        Callback = function(value)
            desiredWalkSpeed = value
            Config:Set("WalkSpeed", value)
            applyWalkSpeed()
        end,
    })
    movementSection:Toggle({
        Title = "Lock Walkspeed",
        Desc = "Keep the selected speed after game changes",
        Value = Config:Get("WalkSpeedLocked") == true,
        Callback = setWalkSpeedLocked,
    })
    flyToggle = movementSection:Toggle({
        Title = "Fly",
        Desc = "Toggle here or press T; Space up, Ctrl/C down",
        Value = Config:Get("FlyEnabled") == true,
        Callback = function(enabled)
            if not suppressFlyToggleCallback then
                setFlyEnabled(enabled)
            end
        end,
    })
    movementSection:Slider({
        Title = "Fly Speed",
        Desc = "1 to 500",
        Step = 1,
        Value = { Min = 1, Max = 500, Default = flySpeed },
        Callback = setFlySpeed,
    })

    local utilitySection = playerTab:Section({ Title = "Utilities" })
    utilitySection:Toggle({
        Title = "Noclip",
        Desc = "Disable character collisions and restore original values when OFF",
        Value = Config:Get("Noclip") == true,
        Callback = setNoclipEnabled,
    })
    utilitySection:Toggle({
        Title = "Instant Interact",
        Desc = "Remove proximity-prompt hold time",
        Value = Config:Get("InstantInteract") == true,
        Callback = setInstantInteractEnabled,
    })
    utilitySection:Toggle({
        Title = "Fullbright",
        Desc = "Bright local lighting; original lighting is restored when OFF",
        Value = Config:Get("Fullbright") == true,
        Callback = setFullbrightEnabled,
    })
    utilitySection:Toggle({
        Title = "Anti AFK",
        Desc = "Respond only when Roblox reports idle state",
        Value = antiAfkEnabled,
        Callback = function(enabled)
            antiAfkEnabled = enabled
            Config:Set("AntiAfk", enabled)
        end,
    })

    local settingsTab = window:Tab({ Title = "Settings" })
    local appearanceSection = settingsTab:Section({ Title = "Appearance" })
    local settingsControls: { [string]: any } = {}

    settingsControls.Transparency = appearanceSection:Slider({
        Title = "Transparency (%)",
        Desc = "0 is solid; 85 is the most transparent",
        Step = 5,
        Value = {
            Min = 0,
            Max = 85,
            Default = math.floor((Config:Get("UiTransparency") * 100) + 0.5),
        },
        Callback = function(value)
            local transparency = value / 100
            SeaUI:SetTransparency(transparency)
            Config:Set("UiTransparency", transparency)
        end,
    })
    settingsControls.Scale = appearanceSection:Slider({
        Title = "UI Scale (%)",
        Desc = "Resize the panel without changing layout",
        Step = 5,
        Value = {
            Min = 75,
            Max = 115,
            Default = math.floor((Config:Get("UiScale") * 100) + 0.5),
        },
        Callback = function(value)
            local scale = value / 100
            SeaUI:SetScale(scale)
            Config:Set("UiScale", scale)
        end,
    })
    settingsControls.Compact = appearanceSection:Toggle({
        Title = "Compact Sidebar",
        Desc = "Show tab badges only; narrow screens use this automatically",
        Value = Config:Get("UiCompactSidebar"),
        Callback = function(enabled)
            SeaUI:SetCompactSidebar(enabled)
            Config:Set("UiCompactSidebar", enabled)
        end,
    })
    settingsControls.Accent = appearanceSection:Dropdown({
        Title = "Accent Color",
        Desc = "Change UI highlights",
        Values = SeaUI:GetAccentNames(),
        Value = Config:Get("UiAccent"),
        Multi = false,
        AllowNone = false,
        Callback = function(option)
            if SeaUI:SetAccentTheme(option) then
                Config:Set("UiAccent", option)
            end
        end,
    })
    appearanceSection:Button({
        Title = "Center Window",
        Desc = "Move the panel back to screen center",
        Action = "Center",
        Callback = function()
            SeaUI:ResetPosition()
            notify("UI Position", "Window moved back to the center", 1.5)
        end,
    })

    local saveSection = settingsTab:Section({ Title = "Save & Reset" })
    saveSection:Button({
        Title = "Save Config Now",
        Desc = "Autosave already covers toggles, dropdowns, sliders, and UI settings",
        Action = "Save",
        Callback = function()
            local success, storage = Config:SaveNow()
            if success then
                notify("Config Saved", "Saved to " .. storage, 2)
            else
                notify("Save Failed", "Could not save the configuration", 2)
            end
        end,
    })
    local resetConfirmUntil = 0
    saveSection:Button({
        Title = "Reset Saved Config",
        Desc = "Clears choices AND saved coordinates; press twice to confirm",
        Action = "Reset",
        Callback = function()
            if os.clock() > resetConfirmUntil then
                resetConfirmUntil = os.clock() + 6
                notify("Confirm Reset", "Press Reset again within 6s to delete saved settings and coordinates", 4)
                return
            end
            resetConfirmUntil = 0
            Travel.Stop("Settings reset")
            local defaults = Config:Reset()
            Travel.RefreshSaved()
            Travel.Refresh(false)
            settingsControls.Transparency:Set(
                math.floor((defaults.UiTransparency * 100) + 0.5)
            )
            settingsControls.Scale:Set(
                math.floor((defaults.UiScale * 100) + 0.5)
            )
            settingsControls.Compact:Set(defaults.UiCompactSidebar)
            settingsControls.Accent:Select(defaults.UiAccent)
            SeaUI:ResetPosition()
            notify(
                "Config Reset",
                "All saved choices reset; rerun for a fully fresh state",
                2.5
            )
        end,
    })
    saveSection:Paragraph({
        Title = "Save Status",
        Desc = Config:StorageLabel()
            .. ". v58 keeps the existing v28 save slot, including named teleport coordinates.",
    })

    local controlsSection = settingsTab:Section({ Title = "Controls & Session" })
    controlsSection:Paragraph({
        Title = "Hotkeys",
        Desc = [[Right Shift  —  show / hide panel
T  —  toggle fly
Fly: Space up, Ctrl/C down
End  —  unload script]],
    })
    controlsSection:Button({
        Title = "Unload Script",
        Desc = "Stop runtime features and restore modified local settings",
        Action = "End",
        Callback = function()
            if unloadScript then
                unloadScript()
            end
        end,
    })

    local helpSection = settingsTab:Section({ Title = "Quick Guide" })
    helpSection:Paragraph({
        Title = "Recommended flow",
        Desc = [[Home: one-tap Auto Chest + Loot, live status, quick travel
Teleport: all-island tour, selected island, saved XYZ, creatures
Builder: Wrench Outpost removal, fast craft + place, repeat cycle
Loot: World Auto Loot, Sack, chest settings, and Bring
Automation: Eat, Craft, Bonfire, Grinder
Combat: NPC target selection
ESP: visibility filters
Player: movement and local utilities]],
    })
end))

assert(pcall(function()
-- Restore persistent action toggles only after every UI control and feature
-- function exists. v48 retains the existing persistent settings.
local savedSmartNpcKill = Config:Get("SmartNpcKill") == true
local savedEspEnabled = Config:Get("EspEnabled") == true
local savedWalkSpeedLocked = Config:Get("WalkSpeedLocked") == true
local savedInstantInteract = Config:Get("InstantInteract") == true
local savedFlyEnabled = Config:Get("FlyEnabled") == true
local savedAutoBonfire = Config:Get("AutoBonfire") == true
local savedAutoGrinder = Config:Get("AutoGrinder") == true
local savedAutoCraft = Config:Get("AutoCraft") == true
local savedAutoEat = Config:Get("AutoEat") == true
local savedNoclip = Config:Get("Noclip") == true
local savedFullbright = Config:Get("Fullbright") == true

if savedSmartNpcKill then
    NpcKill.SetEnabled(true, false)
end
if savedEspEnabled then
    setEspEnabled(true, false)
end
if savedWalkSpeedLocked then
    setWalkSpeedLocked(true, false)
end
if savedInstantInteract then
    setInstantInteractEnabled(true, false)
end
if savedFlyEnabled then
    flyRequested = true
    if startFly() then
        setFlyToggleVisual(true)
    end
end
if savedNoclip then
    setNoclipEnabled(true, false)
end
if savedFullbright then
    setFullbrightEnabled(true, false)
end
if Config:Get("UnlimitedAmmo") == true then
    Automation.SetUnlimitedAmmo(true, false)
end
if Config:Get("ExperimentalRapidFire") == true then
    Automation.SetExperimentalRapidFire(true, false)
end
if savedAutoCraft then
    Automation.SetAutoCraft(true, false)
end
if savedAutoEat then
    Automation.SetAutoEat(true, false)
end
-- Station automations are mutually exclusive. If an old/manual config somehow
-- has both true, Bonfire wins deterministically and the setter clears Grinder.
if savedAutoGrinder then
    Automation.SetAutoGrinder(true, false)
end
if savedAutoBonfire then
    Automation.SetAutoBonfire(true, false)
end

if autoOpenAfterTeleport and continueChestRoute and ChestLoot.Enabled then
    -- The one-tap chest route owns movement. Resolve conflicting saved toggles
    -- deterministically, then resume it automatically after reinjection/respawn.
    WorldLoot.DisableForRoute("Auto Chest + Loot", "chest route", true)
    Automation.StopStationFarmsForWorldLoot()
    runChestRoute()
else
    WorldLoot.StartIfEnabled()
end
end))

connect(UserInputService.InputBegan, function(input, processed)
    if processed or UserInputService:GetFocusedTextBox() then
        return
    end

    if input.KeyCode == Enum.KeyCode.T then
        local shouldEnableFly = not flying
        -- The visual update uses the same toggle control without double-calling fly.
        setFlyToggleVisual(shouldEnableFly)
        setFlyEnabled(shouldEnableFly)
    elseif input.KeyCode == Enum.KeyCode.End and unloadScript then
        unloadScript()
    end
end)

unloadScript = function()
    if not scriptAlive then
        return
    end

    Config:SaveNow()
    Travel.Stop()
    scriptAlive = false
    autoOpenAfterTeleport = false
    continueChestRoute = false
    ChestLoot.Enabled = false
    WorldLoot.StopForUnload()
    Builder.Stop()
    Automation.StopForUnload()
    chestRouteGeneration = chestRouteGeneration + 1
    chestRouteRunning = false
    antiAfkEnabled = false

    espEnabled = false
    espRefreshGeneration = espRefreshGeneration + 1
    removeAllEspObjects()

    if espFolder then
        pcall(function()
            espFolder:Destroy()
        end)
        espFolder = nil
    end

    if clickKillConnection then
        clickKillConnection:Disconnect()
        clickKillConnection = nil
    end

    walkSpeedLocked = false
    if walkSpeedConnection then
        walkSpeedConnection:Disconnect()
        walkSpeedConnection = nil
    end

    local humanoid = getHumanoid()
    if humanoid then
        local original = originalWalkSpeedByHumanoid[humanoid]
        if original ~= nil then
            humanoid.WalkSpeed = original
            originalWalkSpeedByHumanoid[humanoid] = nil
        end
    end

    for chest, connection in pairs(manualChestLootConnections) do
        pcall(function() connection:Disconnect() end)
        manualChestLootConnections[chest] = nil
    end

    instantInteractEnabled = false
    if instantInteractAddedConnection then
        instantInteractAddedConnection:Disconnect()
        instantInteractAddedConnection = nil
    end

    for prompt, originalDuration in pairs(originalPromptDurations) do
        if prompt.Parent then
            prompt.HoldDuration = originalDuration
        end
    end
    for prompt, connection in pairs(instantPromptConnections) do
        pcall(function() connection:Disconnect() end)
        instantPromptConnections[prompt] = nil
    end
    originalPromptDurations = setmetatable({}, { __mode = "k" })

    cleanupNoclip()
    cleanupFullbright()

    flyRequested = false
    stopFly()

    for _, connection in ipairs(trackedConnections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    trackedConnections = {}

    pcall(function()
        window:Destroy()
    end)

    if globalEnvironment and rawget(globalEnvironment, SCRIPT_CLEANUP_KEY) == unloadScript then
        globalEnvironment[SCRIPT_CLEANUP_KEY] = nil
    end
end

if globalEnvironment then
    globalEnvironment[SCRIPT_CLEANUP_KEY] = unloadScript
end

print("100 Days at Sea v58 loaded successfully!")
