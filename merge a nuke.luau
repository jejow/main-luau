--[[
    Nuke Hub v5.5 | Stable verified core for Merge a Nuke!

    Built from the client-side systems present in the supplied RBXL:
      ReplicatedStorage.Controllers.NukeController
      ReplicatedStorage.Controllers.DataController
      ReplicatedStorage.Controllers.CommanderController
      ReplicatedStorage.Controllers.LockUI
      ReplicatedStorage.Shared.UpgradeConfig / Products / MutationData
      ReplicatedStorage.Packages.Remotes
      ReplicatedStorage.NukeRemotes

    Main systems:
      - idempotent lifecycle/re-execute + validated persistent config
      - coordinated Auto-Merge + Auto-Attack scheduler (no competing hand loops)
      - smart Auto-Merge with reserve/target/protection rules
      - Auto Base-Lock with verification/retry
      - Auto-Upgrade with budget-aware rechecks
      - Smart Auto-Farm using authoritative CityState targeting and attack reserves
      - dynamic claimable Commander / Supply Drop / City targets
      - Nuke, Base, Commander and Supply Drop ESP
      - Commander inventory tracker + auto equip/upgrade/awaken
      - Rebirth eligibility + optional auto rebirth
      - Season / quest / login reward auto-claim
      - Fallout Store tracker + optional selected-item auto buy
      - Auction state tracker (read-only; never auto-purchases Robux)
      - Boost / event / inventory / progression dashboard
      - session stats, timeline, debug health, low-power mode

    Deliberately DOES NOT contain anti-cheat bypass / anti-kick logic.
    It also never automatically purchases Robux products.
]]

-- ============================================================
-- Services
-- ============================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local SUPPORTED_PLACE_ID = 128784467030899
if game.PlaceId ~= 0 and game.PlaceId ~= SUPPORTED_PLACE_ID then
    error(string.format("Unsupported PlaceId %s (expected %s)", tostring(game.PlaceId), tostring(SUPPORTED_PLACE_ID)))
end

-- ============================================================
-- Re-execute lifecycle
-- ============================================================

if _G.NukeHubV5Runtime then
    local old = _G.NukeHubV5Runtime
    if type(old.shutdown) == "function" then
        pcall(old.shutdown, "re-execute")
    else
        old.dead = true
        for _, c in ipairs(old.connections or {}) do
            pcall(function() c:Disconnect() end)
        end
        for _, fn in ipairs(old.cleanups or {}) do
            pcall(fn)
        end
    end
end

local Runtime = {
    dead = false,
    shuttingDown = false,
    connections = {},
    cleanups = {},
    pendingSave = nil,
    readinessThread = nil,
    window = nil,
    generation = HttpService:GenerateGUID(false),
    startedAt = os.clock(),
    lastError = "",
    lastAction = "Starting...",
}
_G.NukeHubV5Runtime = Runtime

local Coord = {}

local function alive()
    return not Runtime.dead and _G.NukeHubV5Runtime == Runtime
end

local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Runtime.connections, c)
    return c
end

local function onCleanup(fn)
    table.insert(Runtime.cleanups, fn)
end

local function logError(where, err)
    Runtime.lastError = string.format("%s: %s", tostring(where), tostring(err))
    warn("[NukeHub v5.5]", Runtime.lastError)
end

local function safe(where, fn, ...)
    -- Fail clearly when a callback reference is missing. In v5.3 the scheduler
    -- accidentally passed the undefined bare name `schedulerStep` instead of
    -- `Coord.schedulerStep`, which made this wrapper itself produce the vague
    -- "line 96: attempt to call a nil value" error every scheduler tick.
    if type(fn) ~= "function" then
        local err = string.format("callback '%s' is %s, expected function", tostring(where), typeof(fn))
        logError(where, err)
        return false, err
    end

    local args = table.pack(...)
    local ok, a, b, c, d = pcall(function()
        return fn(table.unpack(args, 1, args.n))
    end)
    if not ok then
        logError(where, a)
        return false, a
    end
    return true, a, b, c, d
end

-- ============================================================
-- Game modules discovered from the supplied client place
-- ============================================================

local function requiredChild(parent, name, timeout)
    local child = parent:WaitForChild(name, timeout or 15)
    if not child then
        error(string.format("Required instance missing: %s.%s", parent:GetFullName(), tostring(name)))
    end
    return child
end

local Controllers = requiredChild(ReplicatedStorage, "Controllers")
local Shared = requiredChild(ReplicatedStorage, "Shared")
local Packages = requiredChild(ReplicatedStorage, "Packages")

local Remotes = require(requiredChild(Packages, "Remotes"))
local NukeController = require(requiredChild(Controllers, "NukeController"))
local DataController = require(requiredChild(Controllers, "DataController"))
local LockUI = require(requiredChild(Controllers, "LockUI"))

pcall(function() Coord.clientConfig = require(requiredChild(Controllers, "Config", 5)) end)

local CityFeedbackController
pcall(function() CityFeedbackController = require(requiredChild(Controllers, "CityFeedbackController", 5)) end)

local UpgradeConfig = require(requiredChild(Shared, "UpgradeConfig"))
local BigNum = require(requiredChild(Shared, "BigNum"))
local Products = require(requiredChild(Shared, "Products"))
local CommanderData = require(requiredChild(Shared, "CommanderData"))
local MutationData = require(requiredChild(Shared, "MutationData"))
local MutationQuery = require(requiredChild(Shared, "MutationQuery"))

local CommanderAwakening
local CommanderUpgradeCost
local FalloutStoreData
local ReplicatorClient

pcall(function() CommanderAwakening = require(requiredChild(Shared, "CommanderAwakening", 5)) end)
pcall(function() CommanderUpgradeCost = require(requiredChild(Shared, "CommanderUpgradeCost", 5)) end)
pcall(function() FalloutStoreData = require(requiredChild(Shared, "FalloutStoreData", 5)) end)
pcall(function() ReplicatorClient = require(requiredChild(Packages, "ReplicatorClient", 5)) end)

local NukeRemotes = requiredChild(ReplicatedStorage, "NukeRemotes")
local RequestLockBase = NukeRemotes:FindFirstChild("RequestLockBase")
local PurchaseUpgrade = NukeRemotes:FindFirstChild("PurchaseUpgrade")
local RequestRebirth = NukeRemotes:FindFirstChild("RequestRebirth")
local ClaimGroupReward = NukeRemotes:FindFirstChild("ClaimGroupReward")
local PlaytimeBoostUpdate = NukeRemotes:FindFirstChild("PlaytimeBoostUpdate")
local OfflineEarningsRemote = NukeRemotes:FindFirstChild("OfflineEarnings")
local LaunchStartedRemote = NukeRemotes:FindFirstChild("LaunchStarted")
local SelfDestructNuke = NukeRemotes:FindFirstChild("SelfDestructNuke")

do
    local readyDone, readyOk, readyError = false, false, nil
    Runtime.readinessThread = task.spawn(function()
        readyOk, readyError = pcall(function() NukeController:WaitUntilReady() end)
        readyDone = true
        if Runtime.readinessThread == coroutine.running() then
            Runtime.readinessThread = nil
        end
    end)
    local deadline = os.clock() + 20
    while not readyDone and os.clock() < deadline do task.wait(0.05) end
    if readyDone and not readyOk then
        logError("WaitUntilReady", readyError)
    elseif not readyDone then
        warn("[NukeHub v5.5] NukeController readiness timed out; continuing with live signals")
    end
end

-- ============================================================
-- Constants / helpers
-- ============================================================

local NUKE_PLACED = 1
local NUKE_HELD = 2
local NUKE_AIRBORNE = 3
local MAX_NUKE_TIER = math.max(1, type(UpgradeConfig.TIER_NAMES) == "table" and #UpgradeConfig.TIER_NAMES or 110)

-- Values verified from Controllers.Config in the supplied place.
-- Keep fallbacks so the hub survives a future rename/removal of that module.
Coord.GAME_MERGE_RADIUS = tonumber(Coord.clientConfig and Coord.clientConfig.MERGE_RADIUS) or 6
Coord.GAME_PICKUP_RADIUS = tonumber(Coord.clientConfig and Coord.clientConfig.PICKUP_RADIUS) or 7
Coord.GAME_DROP_DEBOUNCE = tonumber(Coord.clientConfig and Coord.clientConfig.DROP_DEBOUNCE) or 0.75
Coord.GAME_INDIVIDUAL_DROP_DEBOUNCE = tonumber(Coord.clientConfig and Coord.clientConfig.INDIVIDUAL_DROP_DEBOUNCE) or 2.5
Coord.GAME_MERGE_POLL = tonumber(Coord.clientConfig and Coord.clientConfig.MERGE_POLL) or 0.15
Coord.GAME_PICKUP_SCAN = tonumber(Coord.clientConfig and Coord.clientConfig.PICKUP_SCAN_INTERVAL) or 0.1

local RARITY_RANK = {
    Common = 1,
    Rare = 2,
    Epic = 3,
    Legendary = 4,
    Admiral = 5,
    Limited = 6,
}

local BIG_SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function serverNow()
    return Workspace:GetServerTimeNow()
end

local function hrp()
    local ch = lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function profileReplicator()
    local ok, rep = pcall(DataController.Get)
    if ok then return rep end
    return nil
end

local function profile()
    local rep = profileReplicator()
    if not rep then return {} end
    if type(rep.Data) == "table" then return rep.Data end
    local ok, value = pcall(function() return rep:TryIndex({}) end)
    if ok and type(value) == "table" then return value end
    return {}
end

local function profileValue(key, default)
    local d = profile()
    local v = d[key]
    if v == nil then return default end
    return v
end

local function fmtClock(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    local h = math.floor(sec / 3600)
    local m = math.floor(sec / 60) % 60
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

local function fmtNumber(v)
    if type(v) == "number" then
        local n = math.abs(v)
        if n < 1000 then return string.format("%.0f", v) end
        local idx = math.floor(math.log10(n) / 3) + 1
        idx = math.clamp(idx, 1, #BIG_SUFFIX)
        return string.format("%.2f%s", v / (1000 ^ (idx - 1)), BIG_SUFFIX[idx])
    end
    return tostring(v)
end

local function fmtBigSerialized(v)
    local ok, out = pcall(function()
        return BigNum.format(BigNum.deserialize(v))
    end)
    if ok then return out end
    return tostring(v or 0)
end

local function bigGteSerialized(serialized, numberValue)
    local ok, result = pcall(function()
        return BigNum.gte(BigNum.deserialize(serialized), BigNum.new(numberValue))
    end)
    return ok and result == true
end

local function listHas(list, value)
    if type(list) ~= "table" then return false end
    for _, v in pairs(list) do
        if v == value then return true end
    end
    return false
end

local function normalizeList(v)
    if type(v) ~= "table" then return {} end
    local out = {}
    local seen = {}
    for k, x in pairs(v) do
        local value = x
        if type(k) == "string" and type(x) == "boolean" then
            if x then value = k else value = nil end
        end
        if value ~= nil and not seen[value] then
            seen[value] = true
            table.insert(out, value)
        end
    end
    return out
end

local function waitUntil(timeout, predicate, step)
    local deadline = os.clock() + (timeout or 2)
    repeat
        local ok, result = pcall(predicate)
        if ok and result then return true, result end
        task.wait(step or 0.05)
    until os.clock() >= deadline or not alive()
    return false
end

local function invokeWithTimeout(remote, timeout, ...)
    if not remote or type(remote.InvokeServer) ~= "function" then return false, "remote unavailable" end
    local args = table.pack(...)
    local done, result = false, nil
    local worker = task.spawn(function()
        result = table.pack(pcall(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end))
        done = true
    end)
    local deadline = os.clock() + math.max(0.5, tonumber(timeout) or 5)
    while not done and alive() and os.clock() < deadline do task.wait(0.05) end
    if not done then
        pcall(task.cancel, worker)
        return false, "invoke timeout"
    end
    return table.unpack(result, 1, result.n)
end

local function getOwnBase()
    local bases = Workspace:FindFirstChild("Bases")
    if not bases then return nil end
    for _, base in ipairs(bases:GetChildren()) do
        if base:GetAttribute("OwnerUserId") == lp.UserId then
            return base
        end
    end
    return nil
end

local function baseTopY()
    local base = getOwnBase()
    if not base then return nil end
    local floor = base:FindFirstChild("Floor")
    if floor and floor:IsA("BasePart") then
        return floor.Position.Y + floor.Size.Y * 0.5
    end
    local cf, size = base:GetBoundingBox()
    return cf.Position.Y + size.Y * 0.5
end

local function teleportToPosition(pos, exact)
    local root = hrp()
    if not root or typeof(pos) ~= "Vector3" then return false end
    if exact then
        root.CFrame = CFrame.new(pos)
        return true
    end
    local angle = math.random() * math.pi * 2
    local flat = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 6
    local y = baseTopY()
    if y then
        root.CFrame = CFrame.new(pos.X + flat.X, y + 4, pos.Z + flat.Z)
    else
        root.CFrame = CFrame.new(pos + Vector3.new(flat.X, 3, flat.Z))
    end
    return true
end

local function instancePosition(inst)
    if not inst or not inst.Parent then return nil end
    if inst:IsA("Model") then return inst:GetPivot().Position end
    if inst:IsA("BasePart") then return inst.Position end
    local part = inst:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

-- The stock merge helper checks horizontal distance <= MERGE_RADIUS (6 in this place).
-- v5.2 teleported at exactly 6 studs, which was needlessly close to the rejection edge.
Coord.teleportNearPosition = function(pos, radius)
    local root = hrp()
    if not root or typeof(pos) ~= "Vector3" then return false end
    local r = math.max(0.5, tonumber(radius) or 3.25)
    local angle = math.random() * math.pi * 2
    local flat = Vector3.new(math.cos(angle), 0, math.sin(angle)) * r
    local y = baseTopY() or pos.Y
    root.CFrame = CFrame.new(pos.X + flat.X, y + 4, pos.Z + flat.Z)
    return true
end

Coord.teleportNearInstance = function(inst, radius)
    local pos = instancePosition(inst)
    return pos and Coord.teleportNearPosition(pos, radius) or false
end

local function adorneeFor(inst)
    if not inst or not inst.Parent then return nil end
    if inst:IsA("BasePart") or inst:IsA("Attachment") then return inst end
    if inst:IsA("Model") then
        return inst.PrimaryPart or inst:FindFirstChild("HumanoidRootPart", true) or inst:FindFirstChildWhichIsA("BasePart", true)
    end
    return inst:FindFirstChildWhichIsA("BasePart", true)
end

local currentHeld
local function dropHeld()
    local root = hrp()
    if not root then return false end
    local dropCFrame = root.CFrame * CFrame.new(0, 2, -3)
    local held = currentHeld and currentHeld() or nil
    local instance = held and held.Instance
    if instance and instance.Parent then
        if instance:IsA("Model") then
            dropCFrame = instance:GetPivot()
        elseif instance:IsA("BasePart") then
            dropCFrame = instance.CFrame
        end
    end
    Remotes.Drop:FireServer(dropCFrame)
    return true
end

local function mutationKeys(nuke)
    local out, seen = {}, {}
    local mutations = nuke and nuke.Mutations
    if type(mutations) ~= "table" then return out end
    for k, v in pairs(mutations) do
        local key
        if type(k) == "string" and v then
            key = k
        elseif type(v) == "string" then
            key = v
        elseif type(v) == "table" then
            key = v.Key or v.key or v.Name or v.name
        end
        if key and not seen[key] then
            seen[key] = true
            table.insert(out, key)
        end
    end
    return out
end

local function mutationLabel(key)
    local data = MutationData[key]
    if type(data) == "table" then
        return string.format("%s [%s]", data.Name or key, data.Rarity or "?")
    end
    return tostring(key)
end

local function nukeTierName(tier)
    local names = UpgradeConfig.TIER_NAMES
    return type(names) == "table" and names[tier] or ("Tier " .. tostring(tier))
end

-- ============================================================
-- Persistent configuration
-- ============================================================

local CONFIG_FOLDER = "NukeHub"
local CONFIG_FILE = CONFIG_FOLDER .. "/v5_5_stable.json"
Coord.LEGACY_CONFIG_FILE = CONFIG_FOLDER .. "/v5_4_attack_first.json"
Coord.LEGACY_CONFIG_FILE_2 = CONFIG_FOLDER .. "/v5_3_full.json"
Coord.LEGACY_CONFIG_FILE_3 = CONFIG_FOLDER .. "/v5_1_full.json"

local DEFAULT = {
    AutoMerge = false,
    MergeDelay = 0.18,
    MergeOrder = "Lowest First",
    MergeTargetTier = 0,
    MergeReserve = 0,

    -- Hard protection keeps old v5.2 semantics: excluded from BOTH merge and attack.
    ProtectTier = 0,
    ProtectedMutations = {},
    -- Extra one-sided protection rules.
    MergeOnlyProtectTier = 0,
    MergeOnlyProtectedMutations = {},
    AttackOnlyProtectTier = 0,
    AttackOnlyProtectedMutations = {},
    AutoLockProtectedNukes = false,

    -- Unified scheduler. AutoMerge/AutoFarm remain independent toggles, but when both
    -- are enabled only this scheduler is allowed to use the held-nuke slot.
    SchedulerMode = "Attack First",
    AttackReserve = 0,
    PreserveMergeIngredients = false,

    -- Scheduler watchdog / self-recovery.
    WatchdogEnabled = true,
    WatchdogFailureThreshold = 3,
    WatchdogHeldSeconds = 12,
    WatchdogLockSeconds = 20,
    WatchdogRecoveryCooldown = 3,

    FarmMutationMode = "Any",
    FarmPreferredMutations = {},

    AutoLock = false,
    AutoUpgrade = false,
    -- RATE exists in shared config but is absent from the current stock upgrade UI.
    -- It remains manually selectable, but is not enabled in the safe default set.
    UpgradeKeys = { "Spawn Tier", "Max Spawns", "Lock Base" },
    UpgradeReserveCash = 0,

    AutoFarm = false,
    FarmNukeStrategy = "Highest Tier",
    FarmSelectedTiers = {},
    FarmTargetTypes = { "Claimable Commander", "Supply Drop", "City" },
    FarmPriority = "Rarity First",
    FarmCommanderRarities = { "Common", "Rare", "Epic", "Legendary", "Admiral", "Limited" },
    CityTargetMode = "Lowest HP",
    FarmStepDelay = 0.35,

    BaseESP = false,
    CommanderESP = false,
    SupplyDropESP = false,
    NukeESP = false,
    NukeEspMinTier = 8,
    NukeEspMutationFilter = {},
    EspDistance = 600,

    AutoEquipBestCommander = false,
    AutoUpgradeCommanders = false,
    AutoAwakenCommanders = false,
    EngineerBestNukeMode = false,
    EngineerCleanupWindow = 45,
    EngineerPreserveMutated = true,

    AutoRebirth = false,
    AutoClaimSeason = false,
    AutoClaimSeasonQuests = false,
    AutoClaimSeasonLogin = false,
    AutoClaimGroupReward = false,

    AutoBuyFallout = false,
    FalloutItems = {},

    LowPower = false,
    RefreshSeconds = 1.5,
    TimelineLimit = 14,
    Notifications = true,
    AntiAFK = true,
    HotkeysEnabled = true,
    HotkeyFarm = "F6",
    HotkeyMerge = "F7",
    HotkeyESP = "F8",
}

local S = {}
for key, value in pairs(DEFAULT) do
    S[key] = type(value) == "table" and table.clone(value) or value
end
_G.NukeHubV5State = S

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function setOf(values)
    local out = {}
    for _, value in ipairs(values) do out[value] = true end
    return out
end

local NUMBER_RULES = {
    MergeDelay = { 0.03, 1.5 },
    MergeTargetTier = { 0, MAX_NUKE_TIER, true },
    MergeReserve = { 0, 100, true },
    ProtectTier = { 0, MAX_NUKE_TIER, true },
    MergeOnlyProtectTier = { 0, MAX_NUKE_TIER, true },
    AttackOnlyProtectTier = { 0, MAX_NUKE_TIER, true },
    AttackReserve = { 0, 100, true },
    WatchdogFailureThreshold = { 2, 20, true },
    WatchdogHeldSeconds = { 8, 60 },
    WatchdogLockSeconds = { 12, 90 },
    WatchdogRecoveryCooldown = { 1, 30 },
    UpgradeReserveCash = { 0, 1e15 },
    FarmStepDelay = { 0.10, 2 },
    NukeEspMinTier = { 1, MAX_NUKE_TIER, true },
    EspDistance = { 100, 5000 },
    RefreshSeconds = { 0.5, 10 },
    TimelineLimit = { 5, 100, true },
    EngineerCleanupWindow = { 15, 120, true },
}

local ENUM_RULES = {
    MergeOrder = setOf({ "Lowest First", "Highest First" }),
    SchedulerMode = setOf({ "Attack First" }),
    FarmMutationMode = setOf({ "Any", "Prefer Mutated", "Prefer Selected" }),
    FarmNukeStrategy = setOf({ "Highest Tier", "Lowest Tier", "Selected Tiers" }),
    FarmPriority = setOf({ "Rarity First", "Lowest Health", "Round Robin" }),
    CityTargetMode = setOf({ "Lowest HP", "Highest HP", "Round Robin", "Random" }),
    HotkeyFarm = setOf({ "F5", "F6", "F7", "F8", "F9", "F10" }),
    HotkeyMerge = setOf({ "F5", "F6", "F7", "F8", "F9", "F10" }),
    HotkeyESP = setOf({ "F5", "F6", "F7", "F8", "F9", "F10" }),
}

local function filterList(value, allowed, maxItems)
    local out, seen = {}, {}
    for _, item in ipairs(normalizeList(value)) do
        local key = tostring(item)
        if (not allowed or allowed[key]) and not seen[key] then
            seen[key] = true
            table.insert(out, key)
            if #out >= (maxItems or 128) then break end
        end
    end
    return out
end

local function validateConfig()
    for key, defaultValue in pairs(DEFAULT) do
        if type(defaultValue) == "boolean" and type(S[key]) ~= "boolean" then
            S[key] = defaultValue
        end
    end

    for key, rule in pairs(NUMBER_RULES) do
        local value = S[key]
        if not isFiniteNumber(value) then value = DEFAULT[key] end
        value = math.clamp(value, rule[1], rule[2])
        if rule[3] then value = math.floor(value) end
        S[key] = value
    end

    for key, allowed in pairs(ENUM_RULES) do
        if not allowed[S[key]] then S[key] = DEFAULT[key] end
    end

    local mutationKeysAllowed = {}
    for key in pairs(MutationData) do mutationKeysAllowed[tostring(key)] = true end
    local tierKeysAllowed = {}
    for tier = 1, MAX_NUKE_TIER do tierKeysAllowed["T" .. tostring(tier)] = true end

    S.ProtectedMutations = filterList(S.ProtectedMutations, mutationKeysAllowed)
    S.MergeOnlyProtectedMutations = filterList(S.MergeOnlyProtectedMutations, mutationKeysAllowed)
    S.AttackOnlyProtectedMutations = filterList(S.AttackOnlyProtectedMutations, mutationKeysAllowed)
    S.FarmPreferredMutations = filterList(S.FarmPreferredMutations, mutationKeysAllowed)
    S.NukeEspMutationFilter = filterList(S.NukeEspMutationFilter, mutationKeysAllowed)
    S.UpgradeKeys = filterList(S.UpgradeKeys, setOf({ "Spawn Tier", "Max Spawns", "Spawn Rate", "Lock Base" }), 4)
    S.FarmSelectedTiers = filterList(S.FarmSelectedTiers, tierKeysAllowed, MAX_NUKE_TIER)
    S.FarmTargetTypes = filterList(S.FarmTargetTypes, setOf({ "Claimable Commander", "Supply Drop", "City" }), 3)
    S.FarmCommanderRarities = filterList(S.FarmCommanderRarities, setOf({ "Common", "Rare", "Epic", "Legendary", "Admiral", "Limited" }), 6)

    local falloutAllowed = {}
    if FalloutStoreData and type(FalloutStoreData.Items) == "table" then
        for _, item in pairs(FalloutStoreData.Items) do
            if type(item) == "table" and item.Key then falloutAllowed[tostring(item.Key)] = true end
        end
    end
    S.FalloutItems = filterList(S.FalloutItems, falloutAllowed)
    S.SchedulerMode = "Attack First"
    S.PreserveMergeIngredients = false
end

local function ensureFolder()
    if type(makefolder) == "function" and type(isfolder) == "function" then
        pcall(function()
            if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
        end)
    end
end

local function loadConfig()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return end
    local ok, decoded = pcall(function()
        local path
        for _, candidate in ipairs({ CONFIG_FILE, Coord.LEGACY_CONFIG_FILE, Coord.LEGACY_CONFIG_FILE_2, Coord.LEGACY_CONFIG_FILE_3 }) do
            if isfile(candidate) then
                path = candidate
                break
            end
        end
        if not path then return nil end
        return { data = HttpService:JSONDecode(readfile(path)), path = path }
    end)
    if ok and type(decoded) == "table" and type(decoded.data) == "table" then
        local fromLegacy = decoded.path ~= CONFIG_FILE
        decoded = decoded.data
        for k, defaultValue in pairs(DEFAULT) do
            local v = decoded[k]
            -- v5.5 deliberately replaces legacy scheduler policy and unsafe timing.
            local skipLegacyFastPolicy = fromLegacy and (k == "SchedulerMode" or k == "PreserveMergeIngredients" or k == "MergeDelay" or k == "FarmStepDelay")
            if not skipLegacyFastPolicy and v ~= nil and type(v) == type(defaultValue) then
                S[k] = v
            end
        end
    end
    validateConfig()
end

local function saveConfig()
    if type(writefile) ~= "function" then return end
    validateConfig()
    ensureFolder()
    local ok, text = pcall(function() return HttpService:JSONEncode(S) end)
    if ok then pcall(writefile, CONFIG_FILE, text) end
end

local function queueSave()
    if Runtime.pendingSave then return end
    local generation = Runtime.generation
    Runtime.pendingSave = task.delay(0.6, function()
        Runtime.pendingSave = nil
        if alive() and Runtime.generation == generation then saveConfig() end
    end)
end

loadConfig()
validateConfig()

-- ============================================================
-- Timeline / session stats
-- ============================================================

local Stats = {
    merges = 0,
    mergeFails = 0,
    launches = 0,
    launchFails = 0,
    upgrades = 0,
    locks = 0,
    commanderUpgrades = 0,
    commanderAwakens = 0,
    commanderEquipChanges = 0,
    engineerPruned = 0,
    rebirths = 0,
    rewards = 0,
    falloutPurchases = 0,
    recoveries = 0,
    antiAfkPulses = 0,
    errors = 0,
}

local Timeline = {}
local function timeline(text)
    Runtime.lastAction = tostring(text)
    table.insert(Timeline, 1, string.format("[%s] %s", os.date("%H:%M:%S"), tostring(text)))
    local limit = math.clamp(math.floor(tonumber(S.TimelineLimit) or DEFAULT.TimelineLimit), 1, 100)
    while #Timeline > limit do
        table.remove(Timeline)
    end
end

-- Roblox raises Player.Idled before its inactivity disconnect. Keep this tied
-- to Runtime.connections so re-executing the hub never stacks idle handlers.
connect(lp.Idled, function()
    if not alive() or not S.AntiAFK then return end

    local ok, err = pcall(function()
        local virtualUser = game:GetService("VirtualUser")
        virtualUser:CaptureController()
        virtualUser:ClickButton2(Vector2.new(0, 0))
    end)

    if ok then
        Stats.antiAfkPulses = Stats.antiAfkPulses + 1
        Runtime.lastAction = "Anti-AFK pulse"
    else
        logError("Anti-AFK", err)
    end
end)

local oldLogError = logError
logError = function(where, err)
    Stats.errors = Stats.errors + (1)
    oldLogError(where, err)
    timeline("ERROR " .. Runtime.lastError)
end

-- ============================================================
-- Central action locks
-- ============================================================

local Locks = {}
local LockTimes = {}
local LockWorkers = {}

local function acquire(name, owner, timeout)
    local deadline = os.clock() + (timeout or 0)
    repeat
        if not Locks[name] then
            Locks[name] = owner
            LockTimes[name] = os.clock()
            return true
        end
        if timeout == nil or timeout <= 0 then return false end
        task.wait(0.05)
    until os.clock() >= deadline or not alive()
    return false
end

local function release(name, owner)
    if Locks[name] == owner then
        Locks[name] = nil
        LockTimes[name] = nil
        LockWorkers[name] = nil
    end
end

local function lockAge(name)
    local t = LockTimes[name]
    return t and math.max(0, os.clock() - t) or 0
end

local function forceReleaseLock(name, reason)
    if not Locks[name] then return false end
    local previous = Locks[name]
    local worker = LockWorkers[name]
    if worker and coroutine.status(worker) ~= "dead" then
        local ok = pcall(task.cancel, worker)
        if not ok then
            timeline(string.format("Could not cancel stale lock %s=%s", tostring(name), tostring(previous)))
            return false
        end
    end
    Locks[name] = nil
    LockTimes[name] = nil
    LockWorkers[name] = nil
    timeline(string.format("Cancelled stale action %s=%s (%s)", tostring(name), tostring(previous), tostring(reason or "watchdog")))
    return true
end

local function withLock(name, owner, timeout, fn)
    if not acquire(name, owner, timeout) then return false, "busy" end
    local done = false
    local result
    local worker = task.spawn(function()
        result = table.pack(pcall(fn))
        done = true
    end)
    LockWorkers[name] = worker

    local actionLimit = math.clamp(tonumber(S.WatchdogLockSeconds) or DEFAULT.WatchdogLockSeconds, 12, 90)
    local deadline = os.clock() + actionLimit
    while not done and alive() and Locks[name] == owner and os.clock() < deadline do
        task.wait(0.05)
    end

    if not done then
        if Locks[name] == owner then forceReleaseLock(name, "action timeout") end
        return true, false, "Action timed out after " .. tostring(actionLimit) .. "s"
    end

    release(name, owner)
    if not result[1] then
        logError(owner, result[2])
        return false, result[2]
    end
    return true, table.unpack(result, 2, result.n)
end

-- ============================================================
-- Nuke tracker
-- ============================================================

local NukeCache = {}
local NukeVersion = 0

local function rebuildNukeCache()
    table.clear(NukeCache)
    local ok, nukes = pcall(function() return NukeController:GetNukes(lp) end)
    if not ok then return end
    for _, n in ipairs(nukes) do
        NukeCache[n.Id] = n
    end
    NukeVersion = NukeVersion + (1)
end

rebuildNukeCache()

safe("NukeAdded signal", function()
    table.insert(Runtime.connections, NukeController.NukeAdded:Connect(function(n)
        if n and n.Owner == lp then NukeCache[n.Id] = n; NukeVersion = NukeVersion + (1) end
    end))
end)

safe("NukeChanged signal", function()
    table.insert(Runtime.connections, NukeController.NukeChanged:Connect(function(n)
        if n and n.Owner == lp then NukeCache[n.Id] = n; NukeVersion = NukeVersion + (1) end
    end))
end)

safe("NukeRemoving signal", function()
    table.insert(Runtime.connections, NukeController.NukeRemoving:Connect(function(n)
        if n then NukeCache[n.Id] = nil; NukeVersion = NukeVersion + (1) end
    end))
end)

local function myNukes(state)
    local out = {}
    for _, n in pairs(NukeCache) do
        if n.Owner == lp and (state == nil or n.State == state) then
            table.insert(out, n)
        end
    end
    return out
end

currentHeld = function()
    local ok, held = pcall(function() return NukeController:GetHeld(lp) end)
    return ok and held or nil
end

Coord.hasMutationRule = function(n, list)
    if type(list) ~= "table" or #list == 0 then return false end
    for _, key in ipairs(mutationKeys(n)) do
        if listHas(list, key) then return true end
    end
    return false
end

-- "Hard" protection preserves v5.2 behavior and is also what Auto Lock uses.
Coord.shouldHardProtectNuke = function(n)
    if not n then return false end
    local protectTier = tonumber(S.ProtectTier) or 0
    if protectTier > 0 and (tonumber(n.Tier) or 0) >= protectTier then return true end
    return Coord.hasMutationRule(n, S.ProtectedMutations)
end

Coord.shouldProtectFromMerge = function(n)
    if not n then return true end
    if Coord.shouldHardProtectNuke(n) then return true end
    local tier = tonumber(S.MergeOnlyProtectTier) or 0
    if tier > 0 and (tonumber(n.Tier) or 0) >= tier then return true end
    return Coord.hasMutationRule(n, S.MergeOnlyProtectedMutations)
end

Coord.shouldProtectFromAttack = function(n)
    if not n then return true end
    if Coord.shouldHardProtectNuke(n) then return true end
    local tier = tonumber(S.AttackOnlyProtectTier) or 0
    if tier > 0 and (tonumber(n.Tier) or 0) >= tier then return true end
    return Coord.hasMutationRule(n, S.AttackOnlyProtectedMutations)
end

Coord.isMergeProtectedNuke = function(n)
    return not n or n.Locked == true or Coord.shouldProtectFromMerge(n)
end

Coord.isAttackProtectedNuke = function(n)
    return not n or n.Locked == true or Coord.shouldProtectFromAttack(n)
end

local function hasAnyMutationFrom(n, wanted)
    return Coord.hasMutationRule(n, wanted)
end

Coord.LastDroppedAt = {}
Coord.lastAnyDropAt = -math.huge

safe("Drop debounce tracker", function()
    table.insert(Runtime.connections, NukeController.OnDropped:Connect(function(n)
        if n and n.Owner == lp then
            Coord.LastDroppedAt[n.Id] = os.clock()
            Coord.lastAnyDropAt = os.clock()
        end
    end))
end)

safe("Drop debounce cleanup", function()
    table.insert(Runtime.connections, NukeController.NukeRemoving:Connect(function(n)
        if n then Coord.LastDroppedAt[n.Id] = nil end
    end))
end)

Coord.pickupDebounceLeft = function(n)
    local now = os.clock()
    local globalLeft = math.max(0, Coord.GAME_DROP_DEBOUNCE - (now - Coord.lastAnyDropAt))
    if not n then return globalLeft end
    local t = Coord.LastDroppedAt[n.Id]
    local individualLeft = t and math.max(0, Coord.GAME_INDIVIDUAL_DROP_DEBOUNCE - (now - t)) or 0
    return math.max(globalLeft, individualLeft)
end

-- Fast core: the shipped client scans pickup every 0.1s and merge every 0.15s.
-- We still give character CFrame one Heartbeat to replicate before firing a remote,
-- but remove the old fixed 0.2s/0.7s sleeps from the hot path.
Coord.fastSettle = function(frames)
    for _ = 1, math.max(1, math.floor(tonumber(frames) or 1)) do
        RunService.Heartbeat:Wait()
    end
end

Coord.horizontalDistance = function(a, b)
    if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then return math.huge end
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

Coord.teleportExactFast = function(pos)
    local root = hrp()
    if not root or typeof(pos) ~= "Vector3" then return false end
    root.CFrame = CFrame.new(pos)
    Coord.fastSettle(1)
    return true
end

-- Find a pickup point that is still inside PICKUP_RADIUS of the selected attack nuke
-- but outside MERGE_RADIUS of every same-tier peer. This prevents the stock MergeAssist
-- from stealing an attack nuke during the tiny pickup -> LaunchConfirm window.
Coord.attackPickupPosition = function(n)
    if not n or not n.Instance or not n.Instance.Parent then return nil, false end
    local targetPos = instancePosition(n.Instance)
    if not targetPos then return nil, false end

    local peers = {}
    for _, peer in ipairs(myNukes(NUKE_PLACED)) do
        if peer.Id ~= n.Id and peer.Tier == n.Tier and peer.Instance and peer.Instance.Parent and peer.Locked ~= true then
            local p = instancePosition(peer.Instance)
            if p then table.insert(peers, p) end
        end
    end

    local y = (baseTopY() or targetPos.Y) + 4
    if #peers == 0 then
        return Vector3.new(targetPos.X, y, targetPos.Z), true
    end

    local pickupMax = math.max(1.5, Coord.GAME_PICKUP_RADIUS - 0.65)
    local safeNeed = Coord.GAME_MERGE_RADIUS + 0.65
    local radii = { 0, pickupMax * 0.35, pickupMax * 0.65, pickupMax * 0.92 }
    local bestPos, bestScore

    for _, r in ipairs(radii) do
        local steps = r == 0 and 1 or 24
        for i = 1, steps do
            local angle = steps == 1 and 0 or ((i - 1) / steps) * math.pi * 2
            local candidate = Vector3.new(targetPos.X + math.cos(angle) * r, y, targetPos.Z + math.sin(angle) * r)
            local score = math.huge
            for _, peerPos in ipairs(peers) do
                score = math.min(score, Coord.horizontalDistance(candidate, peerPos))
            end
            if not bestScore or score > bestScore then
                bestScore, bestPos = score, candidate
            end
        end
    end

    return bestPos, (bestScore or 0) > safeNeed
end

Coord.fastPickup = function(n, preferredPos)
    if not n or not n.Instance or not n.Instance.Parent then return false, "nuke missing" end
    local held = currentHeld()
    if held and held.Id == n.Id then return true, "already held" end
    local left = Coord.pickupDebounceLeft(n)
    if left > 0 then return false, "pickup debounce " .. string.format("%.2f", left) end

    local pos = preferredPos or instancePosition(n.Instance)
    if not pos then return false, "no pickup position" end
    if not Coord.teleportExactFast(pos) then return false, "teleport failed" end

    -- The stock controller already scans pickup every 0.1s. Give it first chance,
    -- then send only one controlled fallback request if no state change arrived.
    local ok = waitUntil(math.max(0.32, Coord.GAME_PICKUP_SCAN * 3), function()
        local h = currentHeld()
        return h and h.Id == n.Id
    end, 0.02)
    if ok then return true, "picked-stock" end

    held = currentHeld()
    if held then return false, "different nuke was picked" end
    if n.State ~= NUKE_PLACED or not n.Instance or not n.Instance.Parent then
        return false, "pickup target changed"
    end
    Remotes.PickUp:FireServer(n.Instance)
    ok = waitUntil(1.1, function()
        local h = currentHeld()
        return h and h.Id == n.Id
    end, 0.02)
    return ok, ok and "picked-fallback" or "pickup failed"
end

-- Closest-pair merge planning. If the two pickup/merge circles overlap, stage the
-- player once at their intersection so pickup and merge can happen without a second TP.
Coord.fastMergePair = function(groups, tier)
    local list = groups and groups[tier] or nil
    if type(list) ~= "table" or #list < 2 then return nil end
    local best
    for i = 1, #list - 1 do
        local a = list[i]
        if a and a.Instance and a.Instance.Parent and Coord.pickupDebounceLeft(a) <= 0 then
            local pa = instancePosition(a.Instance)
            if pa then
                for j = i + 1, #list do
                    local b = list[j]
                    if b and b.Instance and b.Instance.Parent then
                        local pb = instancePosition(b.Instance)
                        if pb then
                            local d = Coord.horizontalDistance(pa, pb)
                            if not best or d < best.distance then
                                best = { first = a, second = b, p1 = pa, p2 = pb, distance = d }
                            end
                        end
                    end
                end
            end
        end
    end
    -- If only the second member of a pair is pickup-ready, swap it to first.
    if not best then
        for i = 1, #list - 1 do
            local a = list[i]
            local pa = a and a.Instance and a.Instance.Parent and instancePosition(a.Instance) or nil
            if pa then
                for j = i + 1, #list do
                    local b = list[j]
                    if b and b.Instance and b.Instance.Parent and Coord.pickupDebounceLeft(b) <= 0 then
                        local pb = instancePosition(b.Instance)
                        if pb then
                            local d = Coord.horizontalDistance(pa, pb)
                            if not best or d < best.distance then
                                best = { first = b, second = a, p1 = pb, p2 = pa, distance = d }
                            end
                        end
                    end
                end
            end
        end
    end
    if not best then return nil end

    local pickupR = math.max(1, Coord.GAME_PICKUP_RADIUS - 0.6)
    local mergeR = math.max(1, Coord.GAME_MERGE_RADIUS - 0.55)
    local d = best.distance
    if d <= pickupR + mergeR then
        local y = (baseTopY() or best.p1.Y) + 4
        if d < 0.001 then
            best.stage = Vector3.new(best.p1.X, y, best.p1.Z)
        else
            local dir = Vector3.new(best.p1.X - best.p2.X, 0, best.p1.Z - best.p2.Z).Unit
            local fromSecond = math.clamp(d - pickupR, 0, mergeR)
            local xz = best.p2 + dir * fromSecond
            best.stage = Vector3.new(xz.X, y, xz.Z)
        end
    end
    return best
end

local function nukeAvailableForAction(n)
    if not n or not n.Instance or not n.Instance.Parent then return false end
    if n.State ~= NUKE_PLACED or n.Locked then return false end
    if (tonumber(n.CooldownEndTime) or 0) > serverNow() then return false end
    if Coord.pickupDebounceLeft(n) > 0 then return false end
    return true
end

-- The shipped MergeAssist scans every MERGE_POLL and automatically sends MergeRequest
-- whenever a held nuke is horizontally within MERGE_RADIUS of another same-tier nuke.
-- Auto-Attack therefore moves the held nuke to a safe spot before LaunchConfirm so the
-- game's own merge helper cannot consume the attack nuke behind the scheduler's back.
Coord.moveHeldAwayFromMergeCandidates = function(held)
    if not held then return false, "no held nuke" end
    local root = hrp()
    if not root then return false, "no character root" end

    local peers = {}
    for _, n in ipairs(myNukes(NUKE_PLACED)) do
        if n.Id ~= held.Id and n.Tier == held.Tier and n.Instance and n.Instance.Parent and n.Locked ~= true then
            local pos = instancePosition(n.Instance)
            if pos then table.insert(peers, pos) end
        end
    end
    if #peers == 0 then return true, "no same-tier merge peer" end

    local center = root.Position
    local base = getOwnBase()
    local baseSize
    if base then
        local floor = base:FindFirstChild("Floor")
        if floor and floor:IsA("BasePart") then
            center = floor.Position
            baseSize = floor.Size
        else
            local cf, size = base:GetBoundingBox()
            center = cf.Position
            baseSize = size
        end
    end

    local minSafe = Coord.GAME_MERGE_RADIUS + 2
    local baseRadius = baseSize and (math.max(baseSize.X, baseSize.Z) * 0.5 + minSafe) or (minSafe + 10)
    local bestPos, bestScore
    local y = baseTopY() or root.Position.Y

    for ring = 0, 2 do
        local radius = baseRadius + ring * 8
        for i = 1, 16 do
            local angle = (i / 16) * math.pi * 2
            local candidate = Vector3.new(center.X + math.cos(angle) * radius, y + 4, center.Z + math.sin(angle) * radius)
            local score = math.huge
            for _, pos in ipairs(peers) do
                local dx, dz = candidate.X - pos.X, candidate.Z - pos.Z
                score = math.min(score, math.sqrt(dx * dx + dz * dz))
            end
            if not bestScore or score > bestScore then
                bestScore = score
                bestPos = candidate
            end
        end
        if bestScore and bestScore >= minSafe then break end
    end

    if not bestPos then return false, "no safe hold position" end
    root.CFrame = CFrame.new(bestPos)
    task.wait(math.max(0.08, Coord.GAME_MERGE_POLL + 0.03))

    local nowRoot = hrp()
    if not nowRoot then return false, "character lost" end
    for _, n in ipairs(myNukes(NUKE_PLACED)) do
        if n.Id ~= held.Id and n.Tier == held.Tier and n.Instance and n.Instance.Parent and n.Locked ~= true then
            local pos = instancePosition(n.Instance)
            if pos then
                local dx, dz = nowRoot.Position.X - pos.X, nowRoot.Position.Z - pos.Z
                if math.sqrt(dx * dx + dz * dz) <= Coord.GAME_MERGE_RADIUS + 0.25 then
                    return false, "still inside merge radius"
                end
            end
        end
    end
    return true, "safe"
end

-- ============================================================
-- Live world tracker: bases, claimable commanders, supply drops,
-- equipped commanders and city
-- ============================================================

local World = {
    bases = {},
    claimables = {},
    supplyDrops = {},
    commanders = {},
    city = nil,
    version = 0,
    lastRefresh = 0,
}

local function guiText(parent, name)
    if not parent then return nil end
    local obj = parent:FindFirstChild(name, true)
    if obj and obj:IsA("TextLabel") then return obj.Text end
    return nil
end

local function healthFractionFromBillboard(gui)
    local health = gui and gui:FindFirstChild("Health")
    local bar = health and health:FindFirstChild("Bar")
    if bar and bar:IsA("GuiObject") then
        return math.clamp(bar.Size.X.Scale, 0, 1)
    end
    return 1
end

local function commanderKeyFromModel(model, ownerUserId)
    local name = model and model.Name or ""
    local suffix = "_Commander"
    local owner = ownerUserId and Players:GetPlayerByUserId(ownerUserId) or nil
    if owner then
        local prefix = owner.Name .. "_"
        if name:sub(1, #prefix) == prefix and name:sub(-#suffix) == suffix then
            return name:sub(#prefix + 1, #name - #suffix)
        end
    end

    -- Fallback by known commander key. Longest match wins if keys overlap.
    local best
    for key in pairs(CommanderData) do
        if type(key) == "string" then
            local tail = "_" .. key .. suffix
            if name:sub(-#tail) == tail and (not best or #key > #best) then best = key end
        end
    end
    return best or name
end

local function refreshWorld()
    local bases = Workspace:FindFirstChild("Bases")
    local newBases = {}
    if bases then
        for _, b in ipairs(bases:GetChildren()) do
            if b:IsA("Model") then newBases[b] = true end
        end
    end
    World.bases = newBases

    local claimables = {}
    local pg = lp:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, ui in ipairs(pg:GetChildren()) do
            local id = tonumber(ui.Name:match("^ClaimableUI_(%d+)$"))
            if id then
                local adornee = ui.Adornee
                local model = adornee and adornee.Parent
                if model and model.Parent then
                    claimables[id] = {
                        id = id,
                        model = model,
                        pos = instancePosition(model),
                        name = guiText(ui, "Title") or "Commander",
                        rarity = guiText(ui, "Rarity") or "?",
                        healthFraction = healthFractionFromBillboard(ui),
                        ui = ui,
                    }
                end
            end
        end
    end
    World.claimables = claimables

    local drops = {}
    for _, inst in ipairs(Workspace:GetChildren()) do
        local id = tonumber(inst.Name:match("^SupplyDrop_(%d+)$"))
        if id and inst.Parent then
            local ui = pg and pg:FindFirstChild("SupplyDropUI_" .. tostring(id))
            drops[id] = {
                id = id,
                model = inst,
                pos = instancePosition(inst),
                healthFraction = healthFractionFromBillboard(ui),
                ui = ui,
            }
        end
    end
    World.supplyDrops = drops

    local commanders = {}
    for _, inst in ipairs(Workspace:GetChildren()) do
        if inst:IsA("Model") and inst.Name:sub(-10) == "_Commander" then
            local ownerId = inst:GetAttribute("OwnerUserId")
            local key = commanderKeyFromModel(inst, ownerId)
            table.insert(commanders, {
                model = inst,
                ownerUserId = ownerId,
                key = key,
                awakening = tonumber(inst:GetAttribute("AwakeningLevel")) or 0,
                pos = instancePosition(inst),
            })
        end
    end
    World.commanders = commanders

    local city = Workspace:FindFirstChild("CityModel") or Workspace:FindFirstChild("City")
    World.city = city
    World.version = World.version + (1)
    World.lastRefresh = os.clock()
end

refreshWorld()

task.spawn(function()
    while alive() do
        local interval = S.LowPower and 3 or math.max(0.4, tonumber(S.RefreshSeconds) or 1)
        safe("refreshWorld", refreshWorld)
        task.wait(interval)
    end
end)

-- ============================================================
-- Valuable nuke protection: the game only toggles lock for the held nuke,
-- so this safely serializes pickup -> toggle -> confirmation -> drop.
-- ============================================================

local function autoLockProtectedNukeStep()
    if not S.AutoLockProtectedNukes then return false, "disabled" end
    local target
    for _, n in ipairs(myNukes(NUKE_PLACED)) do
        if n.Instance and n.Instance.Parent and not n.Locked and Coord.shouldHardProtectNuke(n) then
            target = n
            break
        end
    end
    if not target then return false, "nothing to lock" end

    return withLock("hands", "nuke-protect", 0, function()
        local held = currentHeld()
        if held and held.Id ~= target.Id then
            dropHeld()
            if not waitUntil(1.5, function() return currentHeld() == nil end) then
                return false, "could not clear held nuke"
            end
        end
        if not currentHeld() then
            local picked, reason = Coord.fastPickup(target)
            if not picked then return false, reason end
        end

        Remotes.ToggleNukeLock:FireServer()
        local locked = waitUntil(2.5, function()
            local n = NukeCache[target.Id]
            return n and n.Locked == true
        end)
        dropHeld()
        waitUntil(1.5, function() return currentHeld() == nil end)
        if locked then
            timeline("Protected nuke locked: T" .. tostring(target.Tier) .. " #" .. tostring(target.Id):sub(-6))
            return true, "locked"
        end
        return false, "lock not confirmed"
    end)
end

task.spawn(function()
    while alive() do
        if S.AutoLockProtectedNukes then safe("AutoLockProtectedNukes", autoLockProtectedNukeStep) end
        task.wait(S.LowPower and 5 or 2)
    end
end)

-- ============================================================
-- Auto-Merge core (execution is coordinated by AttackFirstScheduler below)
-- ============================================================

local function mergeGroups()
    local groups = {}
    for _, n in ipairs(myNukes(NUKE_PLACED)) do
        if n.Instance and n.Instance.Parent and not Coord.isMergeProtectedNuke(n) then
            groups[n.Tier] = groups[n.Tier] or {}
            table.insert(groups[n.Tier], n)
        end
    end
    for _, list in pairs(groups) do
        table.sort(list, function(a, b) return tostring(a.Id) < tostring(b.Id) end)
    end
    return groups
end

local function chooseMergeTier(groups)
    local tiers = {}
    local reserve = math.max(0, math.floor(tonumber(S.MergeReserve) or 0))
    local target = math.floor(tonumber(S.MergeTargetTier) or 0)
    for tier, list in pairs(groups) do
        if #list >= reserve + 2 and (target <= 0 or tier < target) then
            table.insert(tiers, tier)
        end
    end
    if #tiers == 0 then return nil end
    table.sort(tiers)
    if S.MergeOrder == "Highest First" then return tiers[#tiers] end
    return tiers[1]
end

Coord.mergePlan = function()
    if not S.AutoMerge then return nil end
    local groups = mergeGroups()

    local held = currentHeld()
    if held and not Coord.isMergeProtectedNuke(held) then
        local partners = groups[held.Tier] or {}
        local reserve = math.max(0, math.floor(tonumber(S.MergeReserve) or 0))
        local target = math.floor(tonumber(S.MergeTargetTier) or 0)
        local totalAtTier = #partners + 1
        if #partners >= 1 and totalAtTier >= reserve + 2 and (target <= 0 or held.Tier < target) then
            return { tier = held.Tier, count = totalAtTier, groups = groups, held = true }
        end
    end

    -- Only advertise a merge as ready when at least one member of the pair can
    -- actually be picked up now. This prevents the fast scheduler from hammering
    -- a tier whose whole group is still inside the game's individual drop debounce.
    local reserve = math.max(0, math.floor(tonumber(S.MergeReserve) or 0))
    local target = math.floor(tonumber(S.MergeTargetTier) or 0)
    local ready = {}
    for tier, list in pairs(groups) do
        if #list >= reserve + 2 and (target <= 0 or tier < target) then
            local pair = Coord.fastMergePair(groups, tier)
            if pair then table.insert(ready, { tier = tier, pair = pair, count = #list }) end
        end
    end
    if #ready == 0 then return nil end
    table.sort(ready, function(a, b) return a.tier < b.tier end)
    local selected = S.MergeOrder == "Highest First" and ready[#ready] or ready[1]
    return { tier = selected.tier, count = selected.count, groups = groups, pair = selected.pair }
end

local function mergeOnce()
    return withLock("hands", "merge-fast", 0, function()
        local held = currentHeld()

        -- A leftover held nuke from attack/recovery must never block the next pair.
        if held then
            if Coord.isMergeProtectedNuke(held) then
                dropHeld()
                waitUntil(math.max(0.8, Coord.GAME_DROP_DEBOUNCE + 0.05), function() return currentHeld() == nil end, 0.03)
                return false, "cleared protected held nuke"
            end

            -- If a mergeable same-tier partner is already available, use it immediately.
            local partner
            local bestDist = math.huge
            local root = hrp()
            for _, n in ipairs(myNukes(NUKE_PLACED)) do
                if n.Id ~= held.Id and n.Tier == held.Tier and n.Instance and n.Instance.Parent and not Coord.isMergeProtectedNuke(n) then
                    local p = instancePosition(n.Instance)
                    local d = root and p and Coord.horizontalDistance(root.Position, p) or math.huge
                    if d < bestDist then partner, bestDist = n, d end
                end
            end
            if partner then
                local p = instancePosition(partner.Instance)
                if p and bestDist > Coord.GAME_MERGE_RADIUS - 0.5 then
                    Coord.teleportNearPosition(p, math.max(1.5, Coord.GAME_MERGE_RADIUS - 1.0))
                    Coord.fastSettle(1)
                end
                local oldTier = held.Tier
                local confirmed = waitUntil(math.max(0.38, Coord.GAME_MERGE_POLL * 2.5), function()
                    local h = currentHeld()
                    return h and h.Tier >= oldTier + 1
                end, 0.02)
                if not confirmed and partner.Instance and partner.Instance.Parent then
                    Remotes.MergeRequest:FireServer(partner.Instance)
                    confirmed = waitUntil(1.1, function()
                        local h = currentHeld()
                        return h and h.Tier >= oldTier + 1
                    end, 0.02)
                end
                if confirmed then
                    Stats.merges = Stats.merges + 1
                    timeline(string.format("Fast merge T%d -> T%d", oldTier, oldTier + 1))
                    return true, "Merged"
                end
            end

            dropHeld()
            waitUntil(math.max(0.8, Coord.GAME_DROP_DEBOUNCE + 0.05), function() return currentHeld() == nil end, 0.03)
            return false, "cleared unmatched held nuke"
        end

        local plan = Coord.mergePlan()
        if not plan then return false, "No mergeable pair" end
        local tier = plan.tier
        local pair = plan.pair or Coord.fastMergePair(plan.groups, tier)
        if not pair then return false, "No pickup-ready pair" end

        -- Best case: one TP places the character within pickup radius of nuke A and
        -- merge radius of nuke B. Otherwise use the old two-position fallback.
        local pickupPos = pair.stage
        if not pickupPos then
            local p = pair.p1 or instancePosition(pair.first.Instance)
            if not p then return false, "Pair position lost" end
            local y = (baseTopY() or p.Y) + 4
            pickupPos = Vector3.new(p.X, y, p.Z)
        end

        local picked, pickReason = Coord.fastPickup(pair.first, pickupPos)
        if not picked then
            Stats.mergeFails = Stats.mergeFails + 1
            return false, pickReason
        end

        held = currentHeld()
        if not held or held.Id ~= pair.first.Id then
            Stats.mergeFails = Stats.mergeFails + 1
            return false, "Held state changed after pickup"
        end

        if not pair.second.Instance or not pair.second.Instance.Parent then
            return false, "Merge partner vanished"
        end

        local oldTier = held.Tier
        if not pair.stage then
            local p2 = instancePosition(pair.second.Instance)
            if not p2 then return false, "Partner position lost" end
            Coord.teleportNearPosition(p2, math.max(1.5, Coord.GAME_MERGE_RADIUS - 1.0))
            Coord.fastSettle(1)
        end

        -- Prefer the stock MergeAssist so only one request reaches the server. Use a
        -- single fallback only if several stock poll intervals produced no change.
        local confirmed = waitUntil(math.max(0.38, Coord.GAME_MERGE_POLL * 2.5), function()
            local h = currentHeld()
            return h and h.Tier >= oldTier + 1
        end, 0.02)

        if not confirmed and pair.second.Instance and pair.second.Instance.Parent then
            Remotes.MergeRequest:FireServer(pair.second.Instance)
            confirmed = waitUntil(1.1, function()
                local h = currentHeld()
                return h and h.Tier >= oldTier + 1
            end, 0.02)
        end

        if confirmed then
            Stats.merges = Stats.merges + 1
            timeline(string.format("Fast merge T%d -> T%d", oldTier, oldTier + 1))
            return true, "Merged"
        end

        Stats.mergeFails = Stats.mergeFails + 1
        return false, "Fast merge not confirmed"
    end)
end

-- ============================================================
-- Auto Base-Lock
-- ============================================================

local lastLockRequest = 0
local function lockState()
    local base = getOwnBase()
    if not base then return "No base", 0, false end
    local locked = base:GetAttribute("BaseLocked") == true
    local ends = tonumber(base:GetAttribute("LockEndsAt")) or 0
    local left = math.max(0, ends - serverNow())
    if locked then return "Locked", left, true end
    local phase
    pcall(function() phase = LockUI.GetPhase() end)
    return tostring(phase or "Free"), 0, false
end

local function requestBaseLock()
    local _, _, locked = lockState()
    if locked then return true end
    if os.clock() - lastLockRequest < 2.5 then return false end
    lastLockRequest = os.clock()

    local fired = false
    local ok = pcall(function()
        if LockUI and type(LockUI.RequestLock) == "function" then
            LockUI.RequestLock()
            fired = true
        end
    end)
    if not ok or not fired then
        if RequestLockBase then
            RequestLockBase:FireServer()
            fired = true
        end
    end
    if not fired then return false end

    local confirmed = waitUntil(3.5, function()
        local base = getOwnBase()
        return base and base:GetAttribute("BaseLocked") == true
    end)
    if confirmed then
        Stats.locks = Stats.locks + (1)
        timeline("Base locked")
    end
    return confirmed
end

task.spawn(function()
    while alive() do
        if S.AutoLock then safe("AutoLock", requestBaseLock) end
        task.wait(S.LowPower and 4 or 1.5)
    end
end)

-- ============================================================
-- Auto Upgrade: uses actual UpgradeConfig and re-reads profile after
-- each confirmed purchase instead of spending from one stale snapshot.
-- ============================================================

local UP_LABEL_TO_KEY = {
    ["Spawn Tier"] = "TIER",
    ["Max Spawns"] = "MAX",
    ["Spawn Rate"] = "RATE",
    ["Lock Base"] = "LOCKBASE",
}
local UP_LEVEL_FIELD = {
    TIER = "tierLevel",
    MAX = "maxLevel",
    RATE = "rateLevel",
    LOCKBASE = "lockBaseLevel",
}
local UP_PRIORITY = { "Spawn Tier", "Max Spawns", "Spawn Rate", "Lock Base" }
local nextEconomyRequestAt = 0

local function claimEconomyRequestSlot(delaySeconds)
    local now = os.clock()
    if now < nextEconomyRequestAt then return false end
    nextEconomyRequestAt = now + (delaySeconds or 0.8)
    return true
end

local function upgradeCost(key, level)
    local cfg = UpgradeConfig[key]
    if not cfg then return nil end
    local delta = level - cfg.startLevel
    if not cfg.firstCost then
        return BigNum.new(cfg.baseCost) * BigNum.new(cfg.costMult ^ delta)
    end
    if delta == 0 then return BigNum.new(cfg.firstCost) end
    delta = delta - (1)
    return BigNum.new(cfg.baseCost) * BigNum.new(cfg.costMult ^ delta)
end

local function upgradeAvailability(key, level, data)
    local cfg = UpgradeConfig[key]
    if not cfg then return false, "Unknown upgrade" end

    local rebirth = tonumber(data.rebirthLevel) or 0
    local maxLevel = tonumber(cfg.maxLevel)
    if type(UpgradeConfig.GetMaxLevel) == "function" then
        local ok, dynamicMax = pcall(UpgradeConfig.GetMaxLevel, key, rebirth)
        if ok and tonumber(dynamicMax) then maxLevel = tonumber(dynamicMax) end
    end
    if maxLevel and level >= maxLevel then return false, "Maxed" end

    if key == "TIER" then
        local okCap, cap = pcall(Products.MergeCapForRebirth, rebirth)
        local okValue, nextValue = pcall(UpgradeConfig.GetValue, "TIER", level + 1)
        if okCap and okValue and tonumber(cap) and tonumber(nextValue) and tonumber(cap) < tonumber(nextValue) then
            return false, "Rebirth tier cap"
        end
    end
    return true
end

local function autoUpgradeStep()
    if not PurchaseUpgrade then return false, "PurchaseUpgrade missing" end
    for _, label in ipairs(UP_PRIORITY) do
        if listHas(S.UpgradeKeys, label) then
            local key = UP_LABEL_TO_KEY[label]
            local field = UP_LEVEL_FIELD[key]
            local d = profile()
            local lvl = tonumber(d[field])
            local cfg = UpgradeConfig[key]
            local available = lvl and cfg and upgradeAvailability(key, lvl, d)
            if available then
                local cost = upgradeCost(key, lvl)
                local reserve = math.max(0, tonumber(S.UpgradeReserveCash) or 0)
                local canAfford = false
                if cost then pcall(function()
                    local cash = BigNum.deserialize(d.cash)
                    canAfford = BigNum.gte(cash, cost + BigNum.new(reserve))
                end) end
                if canAfford then
                    if not claimEconomyRequestSlot(0.9) then return false, "Economy request cooling down" end
                    PurchaseUpgrade:FireServer(key)
                    local confirmed = waitUntil(3, function()
                        return tonumber(profile()[field]) and tonumber(profile()[field]) > lvl
                    end)
                    if confirmed then
                        Stats.upgrades = Stats.upgrades + (1)
                        timeline("Upgrade " .. label .. " -> " .. tostring(lvl + 1))
                        return true, label
                    end
                    return false, "Upgrade not confirmed"
                end
            end
        end
    end
    return false, "Nothing affordable"
end

task.spawn(function()
    while alive() do
        if S.AutoUpgrade then safe("AutoUpgrade", autoUpgradeStep) end
        task.wait(S.AutoUpgrade and 1.7 or 1)
    end
end)

-- ============================================================
-- Smart Auto-Farm launch scheduler
-- ============================================================

local roundRobinTargetIndex = 0
local cityRoundRobinIndex = 0

local function tierSelected(tier)
    if #S.FarmSelectedTiers == 0 then return true end
    for _, v in ipairs(S.FarmSelectedTiers) do
        local n = tonumber(tostring(v):match("%d+"))
        if n == tier then return true end
    end
    return false
end

Coord.attackInventoryCounts = function()
    local counts = {}
    for _, n in ipairs(myNukes()) do
        if (n.State == NUKE_PLACED or n.State == NUKE_HELD) and not Coord.isAttackProtectedNuke(n) then
            if n.State == NUKE_HELD or (n.Instance and n.Instance.Parent) then
                counts[n.Tier] = (counts[n.Tier] or 0) + 1
            end
        end
    end
    return counts
end

Coord.effectiveAttackReserveForTier = function(tier)
    -- v5.5 policy: attack has strict priority. Only the explicit AttackReserve and
    -- attack-protection rules can keep a nuke out of Auto-Farm; merge ingredients
    -- are no longer silently reserved ahead of an available attack.
    return math.max(0, math.floor(tonumber(S.AttackReserve) or 0))
end

local function chooseFarmNuke()
    local candidates = {}
    local counts = Coord.attackInventoryCounts()

    -- Fastest path after a merge: if the merged result is still in hand and is valid
    -- for Auto-Farm, launch it directly instead of dropping it and picking another nuke.
    local heldNow = currentHeld()
    if heldNow and not Coord.isAttackProtectedNuke(heldNow) and (tonumber(heldNow.CooldownEndTime) or 0) <= serverNow() then
        local tier = tonumber(heldNow.Tier) or 0
        local reserve = Coord.effectiveAttackReserveForTier(tier)
        local tierAllowed = S.FarmNukeStrategy ~= "Selected Tiers" or tierSelected(tier)
        if tierAllowed and (counts[tier] or 0) > reserve then
            return heldNow
        end
    end
    for _, n in ipairs(myNukes(NUKE_PLACED)) do
        if nukeAvailableForAction(n) and not Coord.isAttackProtectedNuke(n) then
            local tier = tonumber(n.Tier) or 0
            local reserve = Coord.effectiveAttackReserveForTier(tier)
            local hasExcess = (counts[tier] or 0) > reserve
            local tierAllowed = S.FarmNukeStrategy ~= "Selected Tiers" or tierSelected(tier)
            if hasExcess and tierAllowed then
                table.insert(candidates, n)
            end
        end
    end
    if #candidates == 0 then return nil end

    table.sort(candidates, function(a, b)
        local aPref, bPref = 0, 0
        if S.FarmMutationMode == "Prefer Mutated" then
            aPref = #mutationKeys(a) > 0 and 1 or 0
            bPref = #mutationKeys(b) > 0 and 1 or 0
        elseif S.FarmMutationMode == "Prefer Selected" then
            aPref = hasAnyMutationFrom(a, S.FarmPreferredMutations) and 1 or 0
            bPref = hasAnyMutationFrom(b, S.FarmPreferredMutations) and 1 or 0
        end
        if aPref ~= bPref then return aPref > bPref end
        if S.FarmNukeStrategy == "Lowest Tier" then
            if a.Tier ~= b.Tier then return a.Tier < b.Tier end
        else
            if a.Tier ~= b.Tier then return a.Tier > b.Tier end
        end
        return tostring(a.Id) < tostring(b.Id)
    end)
    return candidates[1]
end

-- City targeting is building-aware. The game's own CityFeedbackController reads
-- ReplicatorClient.get("CityState").Data.buildings and resolves a targeted building
-- from each building's bx/by/bz position. Targeting the CityModel bounding-box center
-- therefore wastes repeated launches on one point and does not follow live buildings.
local function cityStateReplicator()
    if not ReplicatorClient then return nil end
    local ok, rep = pcall(function() return ReplicatorClient.get("CityState") end)
    return ok and rep or nil
end

local CityTargetCache = {
    buildings = {},
    phase = "waiting-state",
    refreshedAt = -math.huge,
}

local function cityBuildingTargets(force)
    local now = os.clock()
    if not force and now - CityTargetCache.refreshedAt < 0.25 then
        return CityTargetCache.buildings, CityTargetCache.phase
    end

    local rep = cityStateReplicator()
    local data = rep and rep.Data
    local out = {}
    local phase = "waiting-state"

    -- CityModel/_BREAKABLES contains tens of thousands of descendants in this
    -- place. Never traverse it from a UI/scheduler loop. The replicated CityState
    -- is the authoritative and inexpensive source for phase, health and position.
    if type(data) == "table" and type(data.buildings) == "table" then
        phase = tostring(data.phase or "unknown")
        if data.phase == "attack" then
            for id, b in pairs(data.buildings) do
                if type(b) == "table" and b.collapsed ~= true then
                    local bx, by, bz = tonumber(b.bx), tonumber(b.by), tonumber(b.bz)
                    local hpPct = math.clamp(tonumber(b.hpPct) or 100, 0, 100)
                    if isFiniteNumber(bx) and isFiniteNumber(by) and isFiniteNumber(bz) and hpPct > 0 then
                        table.insert(out, {
                            id = tostring(id),
                            pos = Vector3.new(bx, by, bz),
                            hpPct = hpPct,
                            collapsed = false,
                            height = tonumber(b.height) or 0,
                            source = "CityState",
                        })
                    end
                end
            end
        end
    end

    CityTargetCache.buildings = out
    CityTargetCache.phase = phase
    CityTargetCache.refreshedAt = now
    return out, phase
end

local function cityBuildingById(id)
    if id == nil then return nil end
    local wanted = tostring(id)
    local list = cityBuildingTargets(true)
    for _, b in ipairs(list) do
        if tostring(b.id) == wanted then return b end
    end
    return nil
end

local function cityTarget(advance)
    local cached, phase = cityBuildingTargets()
    local buildings = table.clone(cached)
    if #buildings == 0 then return nil end

    table.sort(buildings, function(a, b)
        local ai, bi = tostring(a.id), tostring(b.id)
        local an, bn = tonumber(ai), tonumber(bi)
        if an and bn and an ~= bn then return an < bn end
        return ai < bi
    end)

    local mode = S.CityTargetMode
    local chosen
    if mode == "Highest HP" then
        table.sort(buildings, function(a, b)
            if a.hpPct == b.hpPct then return tostring(a.id) < tostring(b.id) end
            return a.hpPct > b.hpPct
        end)
        chosen = buildings[1]
    elseif mode == "Round Robin" then
        local nextIndex = (cityRoundRobinIndex % #buildings) + 1
        if advance ~= false then cityRoundRobinIndex = nextIndex end
        chosen = buildings[nextIndex]
    elseif mode == "Random" then
        chosen = buildings[math.random(1, #buildings)]
    else -- Lowest HP / focus damaged building until it collapses
        table.sort(buildings, function(a, b)
            if a.hpPct == b.hpPct then return tostring(a.id) < tostring(b.id) end
            return a.hpPct < b.hpPct
        end)
        chosen = buildings[1]
    end

    if not chosen then return nil end
    return {
        kind = "CityBuilding",
        label = string.format("City Building %s | %.0f%%", tostring(chosen.id), chosen.hpPct or 100),
        pos = chosen.pos,
        rank = 0,
        hp = math.clamp((chosen.hpPct or 100) / 100, 0, 1),
        buildingId = chosen.id,
        cityPhase = phase,
        source = chosen.source,
    }
end

local function targetCandidates(advance)
    local out = {}
    if listHas(S.FarmTargetTypes, "Claimable Commander") then
        for _, c in pairs(World.claimables) do
            if c.pos and listHas(S.FarmCommanderRarities, c.rarity) then
                table.insert(out, {
                    kind = "Commander",
                    label = string.format("%s [%s]", c.name, c.rarity),
                    pos = c.pos,
                    rank = RARITY_RANK[c.rarity] or 0,
                    hp = c.healthFraction or 1,
                    id = c.id,
                })
            end
        end
    end
    if listHas(S.FarmTargetTypes, "Supply Drop") then
        for _, d in pairs(World.supplyDrops) do
            if d.pos then
                table.insert(out, {
                    kind = "SupplyDrop",
                    label = "Supply Drop #" .. tostring(d.id),
                    pos = d.pos,
                    rank = 3,
                    hp = d.healthFraction or 1,
                    id = d.id,
                })
            end
        end
    end
    if listHas(S.FarmTargetTypes, "City") then
        local city = cityTarget(advance)
        if city then table.insert(out, city) end
    end

    if S.FarmPriority == "Lowest Health" then
        table.sort(out, function(a, b)
            if a.hp == b.hp then return a.rank > b.rank end
            return a.hp < b.hp
        end)
    elseif S.FarmPriority == "Round Robin" then
        table.sort(out, function(a, b) return a.label < b.label end)
        if #out > 1 then
            local nextIndex = (roundRobinTargetIndex % #out) + 1
            if advance ~= false then roundRobinTargetIndex = nextIndex end
            local chosen = out[nextIndex]
            return { chosen }
        end
    else
        table.sort(out, function(a, b)
            if a.rank == b.rank then return a.hp < b.hp end
            return a.rank > b.rank
        end)
    end
    return out
end

Coord.localLaunchGateUntil = 0
local function globalLaunchCooldown()
    local replicated = math.max(0, (tonumber(profile().nukeCdUntil) or 0) - serverNow())
    local localGate = math.max(0, (Coord.localLaunchGateUntil or 0) - os.clock())
    return math.max(replicated, localGate)
end

Coord.launchRejectVersion = 0
Coord.launchStartedVersion = 0
Coord.lastLaunchAttemptAt = -math.huge
safe("Launch rejection tracker", function()
    connect(Remotes.LaunchRejected.OnClientEvent, function()
        Coord.launchRejectVersion = Coord.launchRejectVersion + 1
    end)
end)
if LaunchStartedRemote then
    safe("Launch started tracker", function()
        connect(LaunchStartedRemote.OnClientEvent, function(payload)
            local ownerId = type(payload) == "table" and tonumber(payload.ownerUserId or payload.userId or payload.OwnerUserId) or nil
            if ownerId == nil or ownerId == lp.UserId then
                Coord.launchStartedVersion = Coord.launchStartedVersion + 1
            end
        end)
    end)
end

local function launchOneSmart()
    return withLock("hands", "attack-fast", 0, function()
        local cd = globalLaunchCooldown()
        if cd > 0 then return false, "Cooldown " .. fmtClock(cd) end

        -- Refresh world immediately when the normal tracker is older than 0.2s so a
        -- newly spawned Commander/Supply Drop does not wait for the 1s dashboard tick.
        if os.clock() - (World.lastRefresh or 0) > 0.2 then
            safe("FastWorldRefresh", refreshWorld)
        end

        local targets = targetCandidates(true)
        local target = targets[1]
        if not target or typeof(target.pos) ~= "Vector3" then return false, "No valid target" end

        local nuke = chooseFarmNuke()
        if not nuke then return false, "No launchable nuke" end
        local selectedId, selectedTier = nuke.Id, nuke.Tier

        local held = currentHeld()
        if held and held.Id ~= selectedId then
            dropHeld()
            waitUntil(math.max(0.8, Coord.GAME_DROP_DEBOUNCE + 0.05), function() return currentHeld() == nil end, 0.03)
            held = nil
        end

        local isolatedAtPickup = true
        if not held then
            local pickupPos
            pickupPos, isolatedAtPickup = Coord.attackPickupPosition(nuke)
            if not pickupPos then return false, "No attack pickup position" end
            local picked, pickReason = Coord.fastPickup(nuke, pickupPos)
            if not picked then
                Stats.launchFails = Stats.launchFails + 1
                return false, pickReason
            end
        end

        held = currentHeld()
        if not held or held.Id ~= selectedId then return false, "Attack held state changed" end
        if Coord.isAttackProtectedNuke(held) then
            dropHeld()
            return false, "Held nuke protected from attack"
        end
        if (tonumber(held.CooldownEndTime) or 0) > serverNow() then return false, "Nuke cooldown" end
        if os.clock() - Coord.lastLaunchAttemptAt < 1.5 then return false, "Launch request cooling down" end

        -- Usually no post-pickup movement is needed because attackPickupPosition already
        -- staged outside every same-tier MERGE_RADIUS. Only use the slower fallback if
        -- geometry made an isolated pickup impossible.
        if not isolatedAtPickup then
            local escaped, escapeReason = Coord.moveHeldAwayFromMergeCandidates(held)
            if not escaped then return false, "Could not isolate attack nuke: " .. tostring(escapeReason) end
            held = currentHeld()
            if not held or held.Id ~= selectedId or held.Tier ~= selectedTier then
                return false, "Attack nuke changed during isolation"
            end
        end

        -- Re-resolve moving/live targets immediately before launch.
        if target.kind == "Commander" then
            local c = World.claimables[target.id]
            if c and c.model and c.model.Parent then target.pos = instancePosition(c.model) or target.pos end
        elseif target.kind == "SupplyDrop" then
            local d = World.supplyDrops[target.id]
            if d and d.model and d.model.Parent then target.pos = instancePosition(d.model) or target.pos end
        elseif target.kind == "CityBuilding" then
            local b = cityBuildingById(target.buildingId)
            if not b then return false, "City building collapsed/changed before launch" end
            target.pos = b.pos
            target.hp = math.clamp((b.hpPct or 100) / 100, 0, 1)
            target.label = string.format("City Building %s | %.0f%%", tostring(b.id), b.hpPct or 100)
            if CityFeedbackController and type(CityFeedbackController.SetTargetedAt) == "function" then
                pcall(function() CityFeedbackController:SetTargetedAt(target.pos) end)
            end
        end

        if not (isFiniteNumber(target.pos.X) and isFiniteNumber(target.pos.Y) and isFiniteNumber(target.pos.Z)) then
            return false, "Invalid target position"
        end

        local oldId, oldTier = held.Id, held.Tier
        local oldGlobalCooldown = tonumber(profile().nukeCdUntil) or 0
        local rejectBefore = Coord.launchRejectVersion
        local startedBefore = Coord.launchStartedVersion
        Coord.lastLaunchAttemptAt = os.clock()
        Coord.localLaunchGateUntil = os.clock() + 1.5

        -- Only one launch request is sent. Server-side source is absent from the
        -- supplied place, so success is accepted only after authoritative replicated
        -- evidence (airborne state, cooldown advancement, or matching launch event).
        Remotes.LaunchConfirm:FireServer(target.pos)

        if target.kind == "CityBuilding" and CityFeedbackController and type(CityFeedbackController.ClearTargeted) == "function" then
            task.defer(function() pcall(function() CityFeedbackController:ClearTargeted() end) end)
        end

        local launched, state = waitUntil(3, function()
            if Coord.launchRejectVersion ~= rejectBefore then return "rejected" end
            local tracked = NukeCache[oldId]
            if tracked and tracked.State == NUKE_AIRBORNE then return "launched" end
            if (tonumber(profile().nukeCdUntil) or 0) > oldGlobalCooldown then return "launched" end
            local h = currentHeld()
            if Coord.launchStartedVersion ~= startedBefore and (h == nil or h.Id ~= oldId) then return "launched" end
            return false
        end, 0.05)

        if launched and state == "launched" then
            Stats.launches = Stats.launches + 1
            timeline(string.format("Confirmed launch T%d -> %s", oldTier, target.label))
            return true, target.label
        end
        if launched and state == "rejected" then
            Stats.launchFails = Stats.launchFails + 1
            return false, "Launch rejected"
        end

        Stats.launchFails = Stats.launchFails + 1
        Coord.localLaunchGateUntil = os.clock() + 3
        return false, "Launch not authoritatively confirmed"
    end)
end


-- ============================================================
-- Unified Smart Scheduler
-- Auto-Merge and Auto-Farm no longer race in independent loops. The scheduler
-- previews both actions, applies the selected strategy, then executes ONE atomic
-- hands action before rescanning current replicated state.
-- ============================================================

Coord.SchedulerState = {
    lastDecision = "Idle",
    lastKind = "none",
    balancedNext = "merge",
    lastResult = "",
    actions = 0,
    mergeFailStreak = 0,
    attackFailStreak = 0,

    -- Watchdog state.
    lastProgressAt = os.clock(),
    lastRecoveryAt = -math.huge,
    lastRecoveryReason = "none",
    recoveries = 0,
    heldKey = nil,
    heldSince = nil,
    lastDecisionKey = nil,
    sameDecisionCount = 0,
}

local function schedulerHeldKey()
    local h = currentHeld()
    if not h then return nil end
    return tostring(h.Id) .. ":T" .. tostring(h.Tier)
end

Coord.noteSchedulerProgress = function(reason)
    local st = Coord.SchedulerState
    st.lastProgressAt = os.clock()
    st.heldKey = schedulerHeldKey()
    st.heldSince = st.heldKey and os.clock() or nil
    st.sameDecisionCount = 0
    if reason then st.lastResult = tostring(reason) end
end

Coord.recoverScheduler = function(reason, aggressive)
    local st = Coord.SchedulerState
    local now = os.clock()
    local cooldown = math.max(1, tonumber(S.WatchdogRecoveryCooldown) or DEFAULT.WatchdogRecoveryCooldown)
    if now - (st.lastRecoveryAt or -math.huge) < cooldown then
        return false, "recovery cooldown"
    end

    local recoveryReason = tostring(reason or "watchdog")
    local lockLimit = math.max(12, tonumber(S.WatchdogLockSeconds) or DEFAULT.WatchdogLockSeconds)
    if Locks.hands then
        if lockAge("hands") < lockLimit then return false, "hands action still active" end
        if not forceReleaseLock("hands", recoveryReason) then
            return false, "stale hands action could not be cancelled"
        end
    end

    st.lastRecoveryAt = now
    st.lastRecoveryReason = recoveryReason
    st.recoveries = (st.recoveries or 0) + 1
    Stats.recoveries = (Stats.recoveries or 0) + 1

    safe("WatchdogRebuildNukes", rebuildNukeCache)
    safe("WatchdogRefreshWorld", refreshWorld)

    local held = currentHeld()
    if held and aggressive ~= false then
        task.wait(0.15)
        dropHeld()
        local cleared = waitUntil(2.5, function() return currentHeld() == nil end, 0.05)
        if not cleared then
            local h = currentHeld()
            if h then pcall(function() Coord.moveHeldAwayFromMergeCandidates(h) end) end
        end
    end

    st.mergeFailStreak = 0
    st.attackFailStreak = 0
    st.sameDecisionCount = 0
    st.balancedNext = st.balancedNext == "merge" and "attack" or "merge"
    st.lastProgressAt = os.clock()
    st.heldKey = schedulerHeldKey()
    st.heldSince = st.heldKey and os.clock() or nil
    timeline("Scheduler recovery: " .. st.lastRecoveryReason)
    return true, st.lastRecoveryReason
end

Coord.watchdogTick = function(kind, actionSucceeded, actionMessage)
    if not S.WatchdogEnabled or not (S.AutoMerge or S.AutoFarm) then return end

    local st = Coord.SchedulerState
    local now = os.clock()
    local key = tostring(kind or st.lastKind) .. "|" .. tostring(st.lastDecision or "")
    if key == st.lastDecisionKey then
        st.sameDecisionCount = (st.sameDecisionCount or 0) + 1
    else
        st.lastDecisionKey = key
        st.sameDecisionCount = 1
    end

    local heldKey = schedulerHeldKey()
    if heldKey ~= st.heldKey then
        st.heldKey = heldKey
        st.heldSince = heldKey and now or nil
        st.lastProgressAt = now
    elseif heldKey and not st.heldSince then
        st.heldSince = now
    end

    if actionSucceeded then
        Coord.noteSchedulerProgress(actionMessage)
        return
    end

    local lockLimit = math.max(12, tonumber(S.WatchdogLockSeconds) or DEFAULT.WatchdogLockSeconds)
    if Locks.hands then
        if lockAge("hands") >= lockLimit then
            Coord.recoverScheduler("hands lock stuck " .. tostring(Locks.hands), true)
        end
        -- A healthy lock owner is doing real work. Do not drop its held nuke or
        -- count repeated scheduler previews as a stuck farm.
        return
    end

    if tostring(actionMessage or ""):match("^Hands busy:") then return end

    local failLimit = math.max(2, math.floor(tonumber(S.WatchdogFailureThreshold) or 3))
    if (st.mergeFailStreak or 0) >= failLimit then
        Coord.recoverScheduler("merge failed " .. tostring(st.mergeFailStreak) .. "x: " .. tostring(actionMessage or st.lastResult), true)
        return
    end
    if (st.attackFailStreak or 0) >= failLimit then
        Coord.recoverScheduler("attack failed " .. tostring(st.attackFailStreak) .. "x: " .. tostring(actionMessage or st.lastResult), true)
        return
    end

    local heldLimit = math.max(8, tonumber(S.WatchdogHeldSeconds) or DEFAULT.WatchdogHeldSeconds)
    if heldKey and st.heldSince and now - st.heldSince >= heldLimit then
        Coord.recoverScheduler("held nuke stuck for " .. string.format("%.1fs", now - st.heldSince), true)
        return
    end

    if (kind == "merge" or kind == "attack") and (st.sameDecisionCount or 0) >= failLimit * 2 then
        Coord.recoverScheduler("same " .. tostring(kind) .. " decision repeated " .. tostring(st.sameDecisionCount) .. "x", true)
    end
end

Coord.attackPlan = function()
    if not S.AutoFarm then return nil, "Auto-Farm off" end
    local cd = globalLaunchCooldown()
    if cd > 0 then return nil, "Launch cooldown " .. fmtClock(cd) end
    if os.clock() - (World.lastRefresh or 0) > 0.2 then safe("FastPlanWorldRefresh", refreshWorld) end
    local targets = targetCandidates(false)
    local target = targets[1]
    if not target then return nil, "No target" end
    local nuke = chooseFarmNuke()
    if not nuke then return nil, "No attackable nuke" end
    return { nuke = nuke, target = target }, "Ready"
end

Coord.schedulerDecision = function()
    -- v5.5 fixed policy: ATTACK FIRST. If an attack is ready, merge is not considered.
    -- Merge is used immediately when attack is temporarily unavailable (global cooldown,
    -- no target, no attackable nuke, protection/reserve), so cooldown time becomes merge time.
    if not S.AutoMerge and not S.AutoFarm then return "idle", "Automation off" end

    if S.AutoFarm then
        local aPlan, aReason = Coord.attackPlan()
        if aPlan then return "attack", "ATTACK FIRST -> " .. aPlan.target.label end
        if S.AutoMerge then
            local mPlan = Coord.mergePlan()
            if mPlan then return "merge", "Attack unavailable (" .. tostring(aReason) .. ") -> merge T" .. tostring(mPlan.tier) end
        end
        return "wait", aReason or "No attack ready"
    end

    local mPlan = Coord.mergePlan()
    if mPlan then return "merge", "Merge T" .. tostring(mPlan.tier) end
    return "wait", "Waiting for merge pair"
end


Coord.schedulerStep = function()
    local kind, reason = Coord.schedulerDecision()
    Coord.SchedulerState.lastDecision = tostring(reason or kind)
    Coord.SchedulerState.lastKind = kind

    if kind == "attack" then
        local infraOk, actionOk, msg = launchOneSmart()
        if not infraOk and actionOk == "busy" then
            local busyMsg = "Hands busy: " .. tostring(Locks.hands or "unknown")
            Coord.SchedulerState.lastResult = busyMsg
            return false, "attack", busyMsg
        end
        Coord.SchedulerState.lastResult = tostring(msg or actionOk)
        if infraOk and actionOk then
            Coord.SchedulerState.actions = Coord.SchedulerState.actions + 1
            Coord.SchedulerState.attackFailStreak = 0
            return true, "attack", msg
        end
        Coord.SchedulerState.attackFailStreak = Coord.SchedulerState.attackFailStreak + 1
        return false, "attack", msg or tostring(actionOk)
    elseif kind == "merge" then
        local infraOk, actionOk, msg = mergeOnce()
        if not infraOk and actionOk == "busy" then
            local busyMsg = "Hands busy: " .. tostring(Locks.hands or "unknown")
            Coord.SchedulerState.lastResult = busyMsg
            return false, "merge", busyMsg
        end
        Coord.SchedulerState.lastResult = tostring(msg or actionOk)
        if infraOk and actionOk then
            Coord.SchedulerState.actions = Coord.SchedulerState.actions + 1
            Coord.SchedulerState.mergeFailStreak = 0
            return true, "merge", msg
        end
        Coord.SchedulerState.mergeFailStreak = Coord.SchedulerState.mergeFailStreak + 1
        return false, "merge", msg or tostring(actionOk)
    end

    Coord.SchedulerState.lastResult = tostring(reason or "waiting")
    return false, kind, reason
end


local function schedulerSelfCheck()
    local required = {
        mergePlan = Coord.mergePlan,
        attackPlan = Coord.attackPlan,
        schedulerDecision = Coord.schedulerDecision,
        schedulerStep = Coord.schedulerStep,
    }
    for name, fn in pairs(required) do
        if type(fn) ~= "function" then
            return false, string.format("%s is %s", name, typeof(fn))
        end
    end
    return true
end

local schedulerReady, schedulerInitError = schedulerSelfCheck()
if not schedulerReady then
    logError("AttackFirstSchedulerInit", schedulerInitError)
    Coord.SchedulerState.lastDecision = "Scheduler init failed"
    Coord.SchedulerState.lastResult = tostring(schedulerInitError)
end

task.spawn(function()
    while alive() do
        if S.AutoMerge or S.AutoFarm then
            if not schedulerReady then
                task.wait(0.5)
                continue
            end
            local ok, actionOk, kind, actionMsg = safe("AttackFirstScheduler", Coord.schedulerStep)
            local lastKind = Coord.SchedulerState.lastKind
            local waitFor = 0.05
            if lastKind == "merge" then
                waitFor = math.max(0.03, tonumber(S.MergeDelay) or 0.05)
            elseif lastKind == "attack" then
                waitFor = math.max(0.03, tonumber(S.FarmStepDelay) or 0.05)
            elseif lastKind == "wait" then
                waitFor = 0.08
            end
            if not ok then
                Coord.SchedulerState.lastResult = tostring(actionOk or "scheduler callback error")
                waitFor = math.max(waitFor, 0.25)
                safe("SchedulerWatchdog", Coord.watchdogTick, lastKind, false, Coord.SchedulerState.lastResult)
            else
                if actionOk == false and actionMsg ~= nil then
                    Coord.SchedulerState.lastResult = tostring(actionMsg)
                end
                safe("SchedulerWatchdog", Coord.watchdogTick, lastKind, actionOk == true, actionMsg or Coord.SchedulerState.lastResult)
            end
            task.wait(waitFor)
        else
            Coord.SchedulerState.lastDecision = "Automation off"
            Coord.SchedulerState.lastKind = "idle"
            task.wait(0.12)
        end
    end
end)

-- ============================================================
-- Commander inventory automation
-- ============================================================

local function commanderEntries()
    local out = {}
    local list = profile().Commanders
    if type(list) ~= "table" then return out end
    for _, entry in pairs(list) do
        if type(entry) == "table" and entry.CommanderKey then
            local data = CommanderData[entry.CommanderKey]
            if data then
                table.insert(out, {
                    key = entry.CommanderKey,
                    data = data,
                    equipped = entry.Equipped == true,
                    level = tonumber(entry.UpgradeLevel) or 1,
                    duplicates = tonumber(entry.DuplicateProgress) or 0,
                    awakening = tonumber(entry.AwakeningLevel) or 0,
                })
            end
        end
    end
    return out
end

local function commanderScore(e)
    local rarity = e.data.Rarity and e.data.Rarity.DisplayName or "Common"
    return (RARITY_RANK[rarity] or 0) * 100000 + e.awakening * 1000 + e.level
end

local function autoEquipBestCommanders()
    local entries = commanderEntries()
    if #entries == 0 then return false end
    table.sort(entries, function(a, b) return commanderScore(a) > commanderScore(b) end)
    local slots = 3 + (tonumber(profile().commanderSlotLevel) or 0)
    slots = math.max(1, slots)
    local wanted = {}
    for i = 1, math.min(slots, #entries) do wanted[entries[i].key] = true end

    for _, e in ipairs(entries) do
        local shouldEquip = wanted[e.key] == true
        if e.equipped ~= shouldEquip then
            -- Game's controller passes the current equipped state as argument.
            Remotes.EquipCommander:FireServer(e.key, e.equipped)
            local confirmed = waitUntil(2.5, function()
                for _, current in ipairs(commanderEntries()) do
                    if current.key == e.key then return current.equipped == shouldEquip end
                end
                return false
            end, 0.1)
            if confirmed then
                Stats.commanderEquipChanges = Stats.commanderEquipChanges + (1)
                timeline((shouldEquip and "Equip " or "Unequip ") .. (e.data.DisplayName or e.key))
                return true
            end
            return false
        end
    end
    return false
end

local function autoUpgradeCommander()
    if not CommanderUpgradeCost then return false end
    local d = profile()
    local entries = commanderEntries()
    table.sort(entries, function(a, b) return commanderScore(a) > commanderScore(b) end)
    for _, e in ipairs(entries) do
        local costOk, cost = pcall(function()
            return CommanderUpgradeCost.get(e.key, e.level, e.awakening)
        end)
        if costOk and type(cost) == "number" and cost > 0 and bigGteSerialized(d.cash, cost) then
            if not claimEconomyRequestSlot(0.9) then return false end
            local before = e.level
            Remotes.UpgradeCommander:FireServer(e.key)
            local confirmed = waitUntil(3, function()
                for _, now in ipairs(commanderEntries()) do
                    if now.key == e.key then return now.level > before end
                end
                return false
            end)
            if confirmed then
                Stats.commanderUpgrades = Stats.commanderUpgrades + (1)
                timeline("Commander upgrade " .. (e.data.DisplayName or e.key))
                return true
            end
        end
    end
    return false
end

local function autoAwakenCommander()
    if not CommanderAwakening then return false end
    for _, e in ipairs(commanderEntries()) do
        local ok, state = pcall(function()
            return CommanderAwakening.GetButtonState(e.key, e.level, e.awakening, e.duplicates)
        end)
        if ok and state == "Ready" then
            if not claimEconomyRequestSlot(0.9) then return false end
            local before = e.awakening
            Remotes.AwakenCommander:FireServer(e.key)
            local confirmed = waitUntil(4, function()
                for _, now in ipairs(commanderEntries()) do
                    if now.key == e.key then return now.awakening > before end
                end
                return false
            end)
            if confirmed then
                Stats.commanderAwakens = Stats.commanderAwakens + (1)
                timeline("Commander awaken " .. (e.data.DisplayName or e.key))
                return true
            end
        end
    end
    return false
end

-- Engineer's Field Upgrade is server-controlled and always selects the lowest
-- tier currently on the plot. Near the real cooldown, remove lower tiers via
-- the same Begin -> Complete handshake used by HoldingUI. The highest tier is
-- never selected for deletion.
Coord.engineerStatus = "Disabled"
Coord.engineerRetryAt = 0

Coord.engineerCooldownInfo = function()
    for _, commander in ipairs(World.commanders) do
        if commander.ownerUserId == lp.UserId and commander.key == "Engineer"
            and commander.model and commander.model.Parent then
            local timer = commander.model:FindFirstChild("TimerBillboard", true)
            local endTime = timer and tonumber(timer:GetAttribute("EndTime")) or 0
            return math.max(0, endTime - serverNow()), commander
        end
    end
    return nil, nil
end

Coord.engineerPruneStep = function()
    if not S.EngineerBestNukeMode then
        Coord.engineerStatus = "Disabled"
        return false
    end
    if os.clock() < (Coord.engineerRetryAt or 0) then return false end
    if not SelfDestructNuke then
        Coord.engineerStatus = "Self-destruct remote unavailable"
        return false
    end
    if (tonumber(profile().rebirthLevel) or 0) < 3 then
        Coord.engineerStatus = "Requires Rebirth 3"
        return false
    end
    if S.AutoMerge or S.AutoFarm or S.AutoLockProtectedNukes then
        Coord.engineerStatus = "Pause Auto-Merge/Farm/Protect first"
        return false
    end
    if S.AutoEquipBestCommander then
        Coord.engineerStatus = "Disable Auto Equip Best first"
        return false
    end

    local engineerEquipped = false
    for _, entry in ipairs(commanderEntries()) do
        if entry.key == "Engineer" and entry.equipped then
            engineerEquipped = true
            break
        end
    end
    if not engineerEquipped then
        Coord.engineerStatus = "Equip Engineer first"
        return false
    end

    local cooldownLeft = Coord.engineerCooldownInfo()
    if cooldownLeft == nil then
        Coord.engineerStatus = "Waiting for Engineer model"
        return false
    end
    local cleanupWindow = math.max(15, tonumber(S.EngineerCleanupWindow) or DEFAULT.EngineerCleanupWindow)
    if cooldownLeft > cleanupWindow then
        Coord.engineerStatus = "Waiting for cooldown: " .. fmtClock(cooldownLeft)
        return false
    end
    if currentHeld() then
        Coord.engineerStatus = "Drop the held nuke first"
        return false
    end

    local placed = myNukes(NUKE_PLACED)
    local maxTier = 0
    for _, nuke in ipairs(placed) do
        maxTier = math.max(maxTier, tonumber(nuke.Tier) or 0)
    end
    if maxTier <= 0 then
        Coord.engineerStatus = "No placed nuke"
        return false
    end

    local candidates = {}
    local blockers = 0
    for _, nuke in ipairs(placed) do
        if (tonumber(nuke.Tier) or 0) < maxTier then
            local preserveMutation = S.EngineerPreserveMutated and #mutationKeys(nuke) > 0
            if nuke.Locked == true or Coord.shouldHardProtectNuke(nuke) or preserveMutation then
                blockers = blockers + 1
            else
                table.insert(candidates, nuke)
            end
        end
    end

    -- Do not partially erase the plot when a protected lower tier would still
    -- remain and attract Engineer's passive anyway.
    if blockers > 0 then
        Coord.engineerStatus = string.format("Blocked by %d protected/locked lower nuke(s)", blockers)
        return false
    end
    if #candidates == 0 then
        Coord.engineerStatus = string.format("Ready: Engineer targets current best T%d", maxTier)
        return true
    end

    table.sort(candidates, function(a, b)
        if a.Tier == b.Tier then return tostring(a.Id) < tostring(b.Id) end
        return a.Tier < b.Tier
    end)
    local target = candidates[1]
    local infraOk, actionOk, message = withLock("hands", "engineer-prune", 0, function()
        local live = NukeCache[target.Id]
        if not live or live.State ~= NUKE_PLACED or live.Locked == true
            or (tonumber(live.Tier) or 0) >= maxTier or Coord.shouldHardProtectNuke(live) then
            return false, "target changed before pickup"
        end
        if S.EngineerPreserveMutated and #mutationKeys(live) > 0 then
            return false, "target gained a protected mutation"
        end

        local picked, pickupReason = Coord.fastPickup(live)
        if not picked then
            local wrong = currentHeld()
            if wrong then
                dropHeld()
                waitUntil(1.5, function() return currentHeld() == nil end, 0.05)
            end
            return false, pickupReason
        end

        local held = currentHeld()
        if not held or held.Id ~= target.Id or (tonumber(held.Tier) or 0) >= maxTier then
            if held then dropHeld() end
            return false, "held nuke identity changed"
        end

        SelfDestructNuke:FireServer("Begin")
        task.wait(0.55)
        held = currentHeld()
        if not held or held.Id ~= target.Id then
            SelfDestructNuke:FireServer("Cancel")
            return false, "self-destruct target changed"
        end
        SelfDestructNuke:FireServer("Complete")

        local removed = waitUntil(2.5, function()
            local nowHeld = currentHeld()
            return NukeCache[target.Id] == nil and (not nowHeld or nowHeld.Id ~= target.Id)
        end, 0.05)
        if not removed then
            SelfDestructNuke:FireServer("Cancel")
            if currentHeld() then dropHeld() end
            return false, "self-destruct not confirmed"
        end
        return true, "removed"
    end)

    if infraOk and actionOk then
        Stats.engineerPruned = Stats.engineerPruned + 1
        Coord.engineerRetryAt = os.clock() + 1.2
        Coord.engineerStatus = string.format("Removed T%d; preserving T%d", target.Tier, maxTier)
        timeline(string.format("Engineer setup removed T%d #%s", target.Tier, tostring(target.Id):sub(-6)))
        return true
    end

    Coord.engineerRetryAt = os.clock() + 4
    Coord.engineerStatus = "Cleanup failed: " .. tostring(message or actionOk or "unknown")
    return false
end

task.spawn(function()
    while alive() do
        if S.AutoEquipBestCommander then safe("AutoEquipBestCommander", autoEquipBestCommanders) end
        if S.AutoAwakenCommanders then safe("AutoAwakenCommanders", autoAwakenCommander) end
        if S.AutoUpgradeCommanders then safe("AutoUpgradeCommanders", autoUpgradeCommander) end
        task.wait(S.LowPower and 8 or 4)
    end
end)

task.spawn(function()
    while alive() do
        if S.EngineerBestNukeMode then
            safe("EngineerBestNuke", Coord.engineerPruneStep)
        elseif Coord.engineerStatus ~= "Disabled" then
            Coord.engineerStatus = "Disabled"
        end
        task.wait(S.LowPower and 2 or 0.6)
    end
end)

-- ============================================================
-- Rebirth eligibility / automation
-- ============================================================

local RebirthTierCache = { level = -1, highest = 0 }

local function rebirthStatus()
    local d = profile()
    local level = tonumber(d.rebirthLevel) or 0
    local maxLevel = tonumber(Products.REBIRTH and Products.REBIRTH.MAX_LEVEL) or 16
    local nextLevel = level + 1
    if level >= maxLevel then return false, "MAX", level end

    local tierReq = 0
    local mutReq = 0
    local dmgReq
    pcall(function()
        tierReq = Products.RebirthTierRequirement(nextLevel) or Products.MergeCapForRebirth(level) or 0
    end)
    pcall(function() mutReq = Products.RebirthMutationRequirement(nextLevel) or 0 end)
    pcall(function() dmgReq = Products.RebirthDamageRequirement(nextLevel) end)

    if RebirthTierCache.level ~= level then
        RebirthTierCache.level = level
        RebirthTierCache.highest = 0
    end
    local scannedHighest = 0
    for _, n in ipairs(myNukes()) do scannedHighest = math.max(scannedHighest, tonumber(n.Tier) or 0) end
    if scannedHighest > 0 then RebirthTierCache.highest = scannedHighest end
    local highest = scannedHighest > 0 and scannedHighest or RebirthTierCache.highest
    local discovered = 0
    pcall(function() discovered = MutationQuery.CountDiscoveredForRebirth(d.DiscoveredMutations) end)

    local damageOk = true
    local dmgText = ""
    if type(dmgReq) == "table" then
        local current = type(d.CityDamageTotals) == "table" and (d.CityDamageTotals[dmgReq.CityId] or 0) or 0
        damageOk = current >= (tonumber(dmgReq.Amount) or 0)
        dmgText = string.format(" | DMG %.0f/%.0f", current, tonumber(dmgReq.Amount) or 0)
    end

    local eligible = highest >= tierReq and discovered >= mutReq and damageOk
    local text = string.format("R%d -> R%d | Tier %d/%d | Mut %d/%d%s", level, nextLevel, highest, tierReq, discovered, mutReq, dmgText)
    return eligible, text, level
end

local lastRebirthRequest = 0
local function autoRebirthStep()
    if not RequestRebirth then return false end
    local eligible, _, before = rebirthStatus()
    if not eligible then return false end
    if os.clock() - lastRebirthRequest < 8 then return false end
    lastRebirthRequest = os.clock()
    RequestRebirth:FireServer()
    local confirmed = waitUntil(6, function()
        return (tonumber(profile().rebirthLevel) or 0) > before
    end)
    if confirmed then
        Stats.rebirths = Stats.rebirths + (1)
        timeline("Rebirth complete")
    end
    return confirmed
end

task.spawn(function()
    while alive() do
        if S.AutoRebirth then safe("AutoRebirth", autoRebirthStep) end
        task.wait(3)
    end
end)

-- ============================================================
-- Season / quest / login / group reward claiming
-- ============================================================

local rewardBusy = false
local groupRewardRetryAt = 0

local function claimedResultCount(result)
    if result == true then return 1 end
    if type(result) == "number" then return result > 0 and math.floor(result) or 0 end
    if type(result) == "table" then
        local count = #result
        if count > 0 then return count end
        for _, value in pairs(result) do
            if value ~= nil and value ~= false then count = count + 1 end
        end
        return count
    end
    return 0
end

local function rewardStep()
    if rewardBusy then return end
    rewardBusy = true
    local claimed = 0

    if S.AutoClaimSeason then
        local ok, result = invokeWithTimeout(Remotes.ClaimSeasonPass, 6)
        if ok then claimed = claimed + claimedResultCount(result) end
    end
    if S.AutoClaimSeasonQuests then
        local ok, result = invokeWithTimeout(Remotes.ClaimAllSeasonQuests, 6)
        if ok then claimed = claimed + claimedResultCount(result) end
    end
    if S.AutoClaimSeasonLogin then
        local ok, result = invokeWithTimeout(Remotes.ClaimSeasonLogin, 6)
        if ok and result == true then claimed = claimed + (1) end
    end
    if S.AutoClaimGroupReward and ClaimGroupReward and profile().groupRewardClaimed ~= true and os.clock() >= groupRewardRetryAt then
        local ok, result = invokeWithTimeout(ClaimGroupReward, 6)
        if ok and result == "granted" then
            claimed = claimed + (1)
        elseif ok and result == "already" then
            groupRewardRetryAt = os.clock() + 300
        elseif ok and result == "notingroup" then
            -- Do not hammer the server while group membership is absent.
            groupRewardRetryAt = os.clock() + 300
        elseif not ok then
            groupRewardRetryAt = os.clock() + 30
        end
    end

    if claimed > 0 then
        Stats.rewards = Stats.rewards + (claimed)
        timeline("Claimed " .. tostring(claimed) .. " reward action(s)")
    end
    rewardBusy = false
end

task.spawn(function()
    while alive() do
        if S.AutoClaimSeason or S.AutoClaimSeasonQuests or S.AutoClaimSeasonLogin or S.AutoClaimGroupReward then
            safe("RewardClaim", rewardStep)
        end
        task.wait(S.LowPower and 15 or 8)
    end
end)

-- ============================================================
-- Fallout Store + Auction state trackers
-- ============================================================

local Market = {
    fallout = nil,
    auction = nil,
    lastFalloutRequest = 0,
    lastAuctionRequest = 0,
    initialRequested = false,
}

safe("Fallout state listener", function()
    connect(Remotes.FalloutStoreState.OnClientEvent, function(state)
        Market.fallout = state
    end)
end)

safe("Auction state listener", function()
    connect(Remotes.AuctionState.OnClientEvent, function(state)
        Market.auction = state
    end)
end)

local function requestMarketStates()
    Market.initialRequested = true
    if os.clock() - Market.lastFalloutRequest > 30 then
        Market.lastFalloutRequest = os.clock()
        pcall(function() Remotes.FalloutStoreRequestState:FireServer() end)
    end
    if os.clock() - Market.lastAuctionRequest > 30 then
        Market.lastAuctionRequest = os.clock()
        pcall(function() Remotes.AuctionRequestState:FireServer() end)
    end
end

local function falloutItemsAvailable()
    local vals = {}
    if FalloutStoreData and type(FalloutStoreData.Items) == "table" then
        for _, item in pairs(FalloutStoreData.Items) do
            if type(item) == "table" and item.Key then table.insert(vals, item.Key) end
        end
    end
    table.sort(vals)
    return vals
end

local function autoBuyFalloutStep()
    if not S.AutoBuyFallout or #S.FalloutItems == 0 then return false end
    if not FalloutStoreData or type(Market.fallout) ~= "table" then
        requestMarketStates()
        return false
    end
    local season = profile().season
    local waste = type(season) == "table" and (tonumber(season.nuclearWaste) or 0) or 0
    local itemsState = Market.fallout.Items
    if type(itemsState) ~= "table" then return false end

    for _, key in ipairs(S.FalloutItems) do
        local st = itemsState[key]
        local price = 0
        pcall(function() price = FalloutStoreData.Price(key) end)
        if type(st) == "table" and not st.Owned and (tonumber(st.Stock) or 0) > 0 and waste >= (tonumber(price) or math.huge) then
            local beforeStock = tonumber(st.Stock) or 0
            local beforeWaste = waste
            local ok = invokeWithTimeout(Remotes.FalloutStorePurchase, 6, key)
            if ok then requestMarketStates() end
            local confirmed = ok and waitUntil(3, function()
                local currentSeason = profile().season
                local currentWaste = type(currentSeason) == "table" and (tonumber(currentSeason.nuclearWaste) or 0) or beforeWaste
                local currentItems = type(Market.fallout) == "table" and Market.fallout.Items or nil
                local current = type(currentItems) == "table" and currentItems[key] or nil
                return currentWaste < beforeWaste
                    or (type(current) == "table" and (current.Owned == true or (tonumber(current.Stock) or beforeStock) < beforeStock))
            end, 0.1)
            if confirmed then
                Stats.falloutPurchases = Stats.falloutPurchases + (1)
                timeline("Fallout Store: " .. tostring(key))
                return true
            end
        end
    end
    return false
end

task.spawn(function()
    while alive() do
        if S.AutoBuyFallout or not Market.initialRequested then requestMarketStates() end
        if S.AutoBuyFallout then safe("AutoBuyFallout", autoBuyFalloutStep) end
        task.wait(S.LowPower and 12 or 5)
    end
end)

-- ============================================================
-- Event / boost trackers
-- ============================================================

local MiscState = {
    friendBoost = 0,
    playtime = nil,
    offlineCash = 0,
    offlinePassive = 0,
}

safe("Friend boost listener", function()
    connect(Remotes.FriendBoostUpdate.OnClientEvent, function(value)
        MiscState.friendBoost = tonumber(value) or 0
    end)
end)
if PlaytimeBoostUpdate then
    safe("Playtime boost listener", function()
        connect(PlaytimeBoostUpdate.OnClientEvent, function(state) MiscState.playtime = state end)
    end)
end
if OfflineEarningsRemote then
    safe("Offline earnings listener", function()
        connect(OfflineEarningsRemote.OnClientEvent, function(cash, passive)
            MiscState.offlineCash = tonumber(cash) or 0
            MiscState.offlinePassive = tonumber(passive) or 0
        end)
    end)
end

local EventState = {
    last = "None",
    lastAt = 0,
    meltdown = false,
    volcano = false,
}

local function markEvent(name)
    EventState.last = name
    EventState.lastAt = os.clock()
    timeline("Event: " .. name)
end

safe("Event listeners", function()
    connect(Remotes.CityEventStarted.OnClientEvent, function() markEvent("City Event") end)
    connect(Remotes.MeltdownCutscene.OnClientEvent, function() EventState.meltdown = true; markEvent("Meltdown") end)
    connect(Remotes.VolcanoCutscene.OnClientEvent, function() EventState.volcano = true; markEvent("Volcano") end)
    connect(Remotes.MeltdownSiloLaunch.OnClientEvent, function() EventState.meltdown = true; markEvent("Meltdown Silo Launch") end)
    connect(Remotes.MeltdownEnded.OnClientEvent, function() EventState.meltdown = false; markEvent("Meltdown Ended") end)
end)

local function currentEventSummary()
    local volcanoEnds = tonumber(Workspace:GetAttribute("VolcanoEndsAt")) or 0
    local volcanoActive = volcanoEnds > serverNow()
    EventState.volcano = volcanoActive or EventState.volcano
    local hp = tonumber(Workspace:GetAttribute("VolcanoHP"))
    local maxHp = tonumber(Workspace:GetAttribute("VolcanoMaxHP"))
    local volcanoText = volcanoActive and ("ACTIVE " .. fmtClock(volcanoEnds - serverNow())) or "inactive"
    if hp and maxHp and maxHp > 0 then
        volcanoText = volcanoText .. string.format(" | HP %.1f%%", math.clamp(hp / maxHp, 0, 1) * 100)
    end
    local meltdownActive = lp:GetAttribute("MeltdownCutsceneActive") == true or EventState.meltdown
    return string.format("Volcano %s | Meltdown %s", volcanoText, meltdownActive and "active/seen" or "inactive")
end

local function boostSummary()
    if not ReplicatorClient then return "Boost replicator unavailable" end
    local ok, boostRep = pcall(function() return ReplicatorClient.get("Boost") end)
    if not ok or not boostRep or type(boostRep.Data) ~= "table" then return "No active boost data" end
    local active = boostRep.Data.activeBoosts
    if type(active) ~= "table" or not next(active) then return "None" end
    local lines = {}
    for id, b in pairs(active) do
        if type(b) == "table" then
            local name = tostring(b.name or id)
            local multi = b.attributes and b.attributes.boostMultiplier
            local left = b.attributes and b.attributes.doNotExpire and math.huge or ((tonumber(b.timeToExpire) or 0) - serverNow())
            local text = name
            if multi then text = text .. (string.format(" x%.2f", multi)) end
            if left ~= math.huge then text = text .. (" " .. fmtClock(left)) end
            table.insert(lines, text)
        end
    end
    table.sort(lines)
    return table.concat(lines, "\n")
end

-- ============================================================
-- ESP
-- ============================================================

local espFolder
local EspRecords = {}

local function ensureEspFolder()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    if espFolder and espFolder.Parent == cam then return espFolder end
    if espFolder then pcall(function() espFolder:Destroy() end) end
    local old = cam:FindFirstChild("_NukeHubV5ESP")
    if old then old:Destroy() end
    espFolder = Instance.new("Folder")
    espFolder.Name = "_NukeHubV5ESP"
    espFolder.Parent = cam
    table.clear(EspRecords)
    return espFolder
end

local function makeBillboard(key, adornee)
    local folder = ensureEspFolder()
    if not folder or not adornee then return nil end
    local rec = EspRecords[key]
    if rec and rec.bb and rec.bb.Parent and rec.bb.Adornee == adornee then return rec end
    if rec and rec.bb then pcall(function() rec.bb:Destroy() end) end

    local bb = Instance.new("BillboardGui")
    bb.Name = "ESP_" .. tostring(key)
    bb.Size = UDim2.fromOffset(190, 62)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = tonumber(S.EspDistance) or 600
    bb.Adornee = adornee

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundTransparency = 0.2
    frame.BackgroundColor3 = Color3.fromRGB(15, 15, 23)
    frame.BorderSizePixel = 0
    frame.Parent = bb
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local text = Instance.new("TextLabel")
    text.Size = UDim2.new(1, -10, 1, -8)
    text.Position = UDim2.fromOffset(5, 4)
    text.BackgroundTransparency = 1
    text.TextColor3 = Color3.fromRGB(240, 240, 248)
    text.TextSize = 12
    text.Font = Enum.Font.GothamMedium
    text.TextWrapped = true
    text.RichText = true
    text.TextXAlignment = Enum.TextXAlignment.Left
    text.TextYAlignment = Enum.TextYAlignment.Center
    text.Parent = frame

    bb.Parent = folder
    rec = { bb = bb, text = text, touched = os.clock() }
    EspRecords[key] = rec
    return rec
end

local function touchEsp(key, adornee, text)
    local root = hrp()
    local maxDistance = tonumber(S.EspDistance) or 600
    if root and adornee then
        local pos
        if adornee:IsA("Attachment") then pos = adornee.WorldPosition
        elseif adornee:IsA("BasePart") then pos = adornee.Position end
        if pos and (pos - root.Position).Magnitude > maxDistance then return end
    end
    local rec = makeBillboard(key, adornee)
    if rec then
        rec.touched = os.clock()
        rec.bb.MaxDistance = maxDistance
        rec.text.Text = text
    end
end

local function updateESP()
    local now = os.clock()

    if S.BaseESP then
        for base in pairs(World.bases) do
            local ad = adorneeFor(base:FindFirstChild("Floor") or base)
            if ad then
                local ownerId = base:GetAttribute("OwnerUserId")
                local ownerName = ownerId and (Players:GetPlayerByUserId(ownerId) and Players:GetPlayerByUserId(ownerId).DisplayName or ("ID " .. tostring(ownerId))) or "Free"
                local locked = base:GetAttribute("BaseLocked") == true
                local left = math.max(0, (tonumber(base:GetAttribute("LockEndsAt")) or 0) - serverNow())
                local count, maxTier = 0, 0
                local nukesFolder = base:FindFirstChild("Nukes")
                if nukesFolder then
                    for _, n in ipairs(nukesFolder:GetChildren()) do
                        count = count + (1)
                        maxTier = math.max(maxTier, tonumber(n:GetAttribute("Tier")) or 0)
                    end
                end
                touchEsp("base:" .. base:GetFullName(), ad,
                    string.format("<b>%s</b>\nNukes %d | Max T%d\n%s", ownerName, count, maxTier, locked and ("Locked " .. fmtClock(left)) or "OPEN"))
            end
        end
    end

    if S.CommanderESP then
        for id, c in pairs(World.claimables) do
            local ad = adorneeFor(c.model)
            if ad then
                touchEsp("claim:" .. tostring(id), ad,
                    string.format("<b>%s</b>\n%s | HP %.0f%%", c.name, c.rarity, (c.healthFraction or 1) * 100))
            end
        end
        for _, c in ipairs(World.commanders) do
            local ad = adorneeFor(c.model)
            if ad then
                touchEsp("cmd:" .. c.model:GetFullName(), ad,
                    string.format("<b>%s</b>\nOwner %s | Awaken %d", c.key, tostring(c.ownerUserId or "?"), c.awakening))
            end
        end
    end

    if S.SupplyDropESP then
        for id, d in pairs(World.supplyDrops) do
            local ad = adorneeFor(d.model)
            if ad then
                touchEsp("drop:" .. tostring(id), ad,
                    string.format("<b>Supply Drop #%d</b>\nHP %.0f%%", id, (d.healthFraction or 1) * 100))
            end
        end
    end

    if S.NukeESP then
        local minTier = math.max(1, math.floor(tonumber(S.NukeEspMinTier) or 1))
        for _, n in ipairs(myNukes()) do
            local mutationPass = #S.NukeEspMutationFilter == 0 or hasAnyMutationFrom(n, S.NukeEspMutationFilter)
            if n.Tier >= minTier and mutationPass and n.Instance and n.Instance.Parent then
                local ad = adorneeFor(n.Instance)
                if ad then
                    local muts = {}
                    for _, key in ipairs(mutationKeys(n)) do table.insert(muts, mutationLabel(key)) end
                    local mutText = #muts > 0 and table.concat(muts, ", ") or "No mutation"
                    touchEsp("nuke:" .. tostring(n.Id), ad,
                        string.format("<b>%s | T%d</b>\n%s\n%s", nukeTierName(n.Tier), n.Tier, mutText, n.Locked and "LOCKED" or ""))
                end
            end
        end
    end

    for key, rec in pairs(EspRecords) do
        if now - (rec.touched or 0) > 2.5 then
            pcall(function() rec.bb:Destroy() end)
            EspRecords[key] = nil
        end
    end
end

local function clearESP()
    for _, rec in pairs(EspRecords) do pcall(function() rec.bb:Destroy() end) end
    table.clear(EspRecords)
    if espFolder then pcall(function() espFolder:Destroy() end); espFolder = nil end
end

onCleanup(clearESP)
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
    clearESP()
end)

task.spawn(function()
    while alive() do
        if S.BaseESP or S.CommanderESP or S.SupplyDropESP or S.NukeESP then
            safe("ESP", updateESP)
        elseif next(EspRecords) then
            clearESP()
        end
        task.wait(S.LowPower and 2.5 or 0.8)
    end
end)

-- ============================================================
-- Respawn recovery
-- ============================================================

connect(lp.CharacterAdded, function()
    timeline("Character respawned")
    task.wait(1.5)
    if not alive() then return end
    rebuildNukeCache()
    refreshWorld()
end)

-- ============================================================
-- UI
-- ============================================================

-- Build the complete UI in its own function frame. Luau only allows 200 local
-- registers per function; keeping every control in the main chunk exceeded it.
local UI = (function()
local windOk, windSource = pcall(function()
    return game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
end)
if not windOk or type(windSource) ~= "string" or #windSource == 0 then
    error("WindUI download failed: " .. tostring(windSource))
end
local windChunk, windCompileError = loadstring(windSource, "NukeHub_WindUI")
if type(windChunk) ~= "function" then error("WindUI compile failed: " .. tostring(windCompileError)) end
local windRunOk, WindUI = pcall(windChunk)
if not windRunOk or type(WindUI) ~= "table" then error("WindUI init failed: " .. tostring(WindUI)) end

local Window = WindUI:CreateWindow({
    Title = "Nuke Hub v5.5 Stable",
    Icon = "radiation",
    Author = "Merge a Nuke!",
    Folder = "NukeHub",
    Size = UDim2.fromOffset(620, 470),
    Transparent = true,
    Theme = "Dark",
    ToggleKey = Enum.KeyCode.K,
})
Runtime.window = Window
onCleanup(function()
    if Runtime.window then
        pcall(function()
            if type(Runtime.window.Destroy) == "function" then Runtime.window:Destroy() end
        end)
        Runtime.window = nil
    end
end)

local TabFarm = Window:Tab({ Title = "Farm", Icon = "hammer" })
local TabLaunch = Window:Tab({ Title = "Smart Farm", Icon = "rocket" })
local TabCommander = Window:Tab({ Title = "Commander", Icon = "crown" })
local TabProgress = Window:Tab({ Title = "Progress", Icon = "chart-no-axes-column-increasing" })
local TabEsp = Window:Tab({ Title = "ESP", Icon = "eye" })
local TabInfo = Window:Tab({ Title = "Info", Icon = "info" })
local TabSettings = Window:Tab({ Title = "Settings", Icon = "settings" })
Window:SelectTab(1)

-- FARM
local farmStatus = TabFarm:Paragraph({ Title = "Farm status", Desc = "Ready" })
local autoMergeToggle = TabFarm:Toggle({
    Title = "Auto-Merge",
    Desc = "Stock-first merge with replicated confirmation",
    Value = S.AutoMerge,
    Callback = function(v) S.AutoMerge = v; queueSave() end,
})
TabFarm:Dropdown({
    Title = "Merge order",
    Values = { "Lowest First", "Highest First" },
    Value = S.MergeOrder,
    Callback = function(v) S.MergeOrder = v; queueSave() end,
})
TabFarm:Slider({
    Title = "Merge delay",
    Value = { Min = 0.03, Max = 1.5, Default = tonumber(S.MergeDelay) or 0.18 },
    Step = 0.05,
    Callback = function(v) S.MergeDelay = v; queueSave() end,
})
TabFarm:Slider({
    Title = "Stop merging at tier (0 = no stop)",
    Value = { Min = 0, Max = MAX_NUKE_TIER, Default = tonumber(S.MergeTargetTier) or 0 },
    Step = 1,
    Callback = function(v) S.MergeTargetTier = math.floor(v); queueSave() end,
})
TabFarm:Slider({
    Title = "Reserve nukes per tier",
    Value = { Min = 0, Max = 10, Default = tonumber(S.MergeReserve) or 0 },
    Step = 1,
    Callback = function(v) S.MergeReserve = math.floor(v); queueSave() end,
})
TabFarm:Slider({
    Title = "Hard protect tier >= (both merge + attack)",
    Value = { Min = 0, Max = MAX_NUKE_TIER, Default = tonumber(S.ProtectTier) or 0 },
    Step = 1,
    Callback = function(v) S.ProtectTier = math.floor(v); queueSave() end,
})

local mutationValues = {}
for key in pairs(MutationData) do
    if type(key) == "string" then table.insert(mutationValues, key) end
end
table.sort(mutationValues)
TabFarm:Dropdown({
    Title = "Hard protected mutations",
    Values = mutationValues,
    Value = S.ProtectedMutations,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.ProtectedMutations = normalizeList(v); queueSave() end,
})
TabFarm:Slider({
    Title = "Merge-only protect tier >= (0 = off)",
    Value = { Min = 0, Max = MAX_NUKE_TIER, Default = tonumber(S.MergeOnlyProtectTier) or 0 },
    Step = 1,
    Callback = function(v) S.MergeOnlyProtectTier = math.floor(v); queueSave() end,
})
TabFarm:Dropdown({
    Title = "Merge-only protected mutations",
    Values = mutationValues,
    Value = S.MergeOnlyProtectedMutations,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.MergeOnlyProtectedMutations = normalizeList(v); queueSave() end,
})

TabFarm:Toggle({
    Title = "Auto Lock Hard-Protected Nukes",
    Desc = "Locks hard-protected nukes. Merge-only/attack-only rules are not auto-locked.",
    Value = S.AutoLockProtectedNukes,
    Callback = function(v) S.AutoLockProtectedNukes = v; queueSave() end,
})

TabFarm:Toggle({
    Title = "Auto Base-Lock",
    Value = S.AutoLock,
    Callback = function(v) S.AutoLock = v; queueSave() end,
})
TabFarm:Toggle({
    Title = "Auto-Upgrade",
    Value = S.AutoUpgrade,
    Callback = function(v) S.AutoUpgrade = v; queueSave() end,
})
TabFarm:Dropdown({
    Title = "Upgrades",
    Values = { "Spawn Tier", "Max Spawns", "Spawn Rate", "Lock Base" },
    Value = S.UpgradeKeys,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.UpgradeKeys = normalizeList(v); queueSave() end,
})
TabFarm:Slider({
    Title = "Keep cash reserve",
    Desc = "Auto-upgrade will not spend below this amount",
    Value = { Min = 0, Max = 1000000000, Default = tonumber(S.UpgradeReserveCash) or 0 },
    Step = 1000,
    Callback = function(v) S.UpgradeReserveCash = math.max(0, v); queueSave() end,
})

-- SMART LAUNCH FARM
local launchStatus = TabLaunch:Paragraph({ Title = "Auto-Farm status", Desc = "Ready" })
TabLaunch:Paragraph({
    Title = "Attack > Merge priority",
    Desc = "Stable policy: attack whenever ready; merge only while attack is unavailable/cooling down.",
})
TabLaunch:Slider({
    Title = "Attack reserve per tier",
    Desc = "Never launch the last N attack-eligible nukes of each tier",
    Value = { Min = 0, Max = 10, Default = tonumber(S.AttackReserve) or 0 },
    Step = 1,
    Callback = function(v) S.AttackReserve = math.floor(v); queueSave() end,
})
TabLaunch:Toggle({
    Title = "Auto-Recover Stuck Farm",
    Desc = "Watchdog rebuilds caches, clears stale held state, and recovers repeated merge/attack failures",
    Value = S.WatchdogEnabled,
    Callback = function(v) S.WatchdogEnabled = v; queueSave() end,
})
TabLaunch:Slider({
    Title = "Recovery after repeated failures",
    Value = { Min = 2, Max = 10, Default = tonumber(S.WatchdogFailureThreshold) or 3 },
    Step = 1,
    Callback = function(v) S.WatchdogFailureThreshold = math.floor(v); queueSave() end,
})
TabLaunch:Slider({
    Title = "Held nuke stuck timeout",
    Desc = "Seconds the same held nuke may remain unchanged before recovery",
    Value = { Min = 8, Max = 30, Default = tonumber(S.WatchdogHeldSeconds) or 12 },
    Step = 1,
    Callback = function(v) S.WatchdogHeldSeconds = v; queueSave() end,
})
TabLaunch:Slider({
    Title = "Action lock timeout",
    Desc = "Cancels the worker before releasing a stale hands lock",
    Value = { Min = 12, Max = 60, Default = tonumber(S.WatchdogLockSeconds) or 20 },
    Step = 1,
    Callback = function(v) S.WatchdogLockSeconds = v; queueSave() end,
})
TabLaunch:Slider({
    Title = "Recovery cooldown",
    Value = { Min = 1, Max = 15, Default = tonumber(S.WatchdogRecoveryCooldown) or 3 },
    Step = 1,
    Callback = function(v) S.WatchdogRecoveryCooldown = v; queueSave() end,
})
TabLaunch:Slider({
    Title = "Attack-only protect tier >= (0 = off)",
    Value = { Min = 0, Max = MAX_NUKE_TIER, Default = tonumber(S.AttackOnlyProtectTier) or 0 },
    Step = 1,
    Callback = function(v) S.AttackOnlyProtectTier = math.floor(v); queueSave() end,
})
TabLaunch:Dropdown({
    Title = "Attack-only protected mutations",
    Values = mutationValues,
    Value = S.AttackOnlyProtectedMutations,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.AttackOnlyProtectedMutations = normalizeList(v); queueSave() end,
})
local autoFarmToggle = TabLaunch:Toggle({
    Title = "Auto-Farm",
    Desc = "Dynamic nuke + target scheduler",
    Value = S.AutoFarm,
    Callback = function(v) S.AutoFarm = v; queueSave() end,
})
TabLaunch:Dropdown({
    Title = "Nuke strategy",
    Values = { "Highest Tier", "Lowest Tier", "Selected Tiers" },
    Value = S.FarmNukeStrategy,
    Callback = function(v) S.FarmNukeStrategy = v; queueSave() end,
})
TabLaunch:Dropdown({
    Title = "Mutation preference",
    Values = { "Any", "Prefer Mutated", "Prefer Selected" },
    Value = S.FarmMutationMode,
    Callback = function(v) S.FarmMutationMode = v; queueSave() end,
})
TabLaunch:Dropdown({
    Title = "Preferred mutations",
    Values = mutationValues,
    Value = S.FarmPreferredMutations,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.FarmPreferredMutations = normalizeList(v); queueSave() end,
})
local tierValues = {}
for i = 1, MAX_NUKE_TIER do table.insert(tierValues, "T" .. tostring(i)) end
TabLaunch:Dropdown({
    Title = "Selected nuke tiers",
    Values = tierValues,
    Value = S.FarmSelectedTiers,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.FarmSelectedTiers = normalizeList(v); queueSave() end,
})
TabLaunch:Dropdown({
    Title = "Target types",
    Values = { "Claimable Commander", "Supply Drop", "City" },
    Value = S.FarmTargetTypes,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.FarmTargetTypes = normalizeList(v); queueSave() end,
})
TabLaunch:Dropdown({
    Title = "Target priority",
    Values = { "Rarity First", "Lowest Health", "Round Robin" },
    Value = S.FarmPriority,
    Callback = function(v) S.FarmPriority = v; queueSave() end,
})
TabLaunch:Dropdown({
    Title = "City building strategy",
    Desc = "Targets live CityState buildings instead of the CityModel center",
    Values = { "Lowest HP", "Highest HP", "Round Robin", "Random" },
    Value = S.CityTargetMode,
    Callback = function(v) S.CityTargetMode = v; cityRoundRobinIndex = 0; queueSave() end,
})
TabLaunch:Dropdown({
    Title = "Commander rarities",
    Values = { "Common", "Rare", "Epic", "Legendary", "Admiral", "Limited" },
    Value = S.FarmCommanderRarities,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.FarmCommanderRarities = normalizeList(v); queueSave() end,
})
TabLaunch:Slider({
    Title = "Farm step delay",
    Value = { Min = 0.10, Max = 1.5, Default = tonumber(S.FarmStepDelay) or 0.35 },
    Step = 0.05,
    Callback = function(v) S.FarmStepDelay = v; queueSave() end,
})

-- COMMANDER
local commanderInfo = TabCommander:Paragraph({ Title = "Commander inventory", Desc = "Loading..." })
TabCommander:Toggle({
    Title = "Auto Equip Best",
    Desc = "Rarity > awakening > upgrade level",
    Value = S.AutoEquipBestCommander,
    Callback = function(v) S.AutoEquipBestCommander = v; queueSave() end,
})
TabCommander:Toggle({
    Title = "Auto Upgrade Commanders",
    Value = S.AutoUpgradeCommanders,
    Callback = function(v) S.AutoUpgradeCommanders = v; queueSave() end,
})
TabCommander:Toggle({
    Title = "Auto Awaken Ready Commanders",
    Value = S.AutoAwakenCommanders,
    Callback = function(v) S.AutoAwakenCommanders = v; queueSave() end,
})
TabCommander:Toggle({
    Title = "Engineer Best-Nuke Setup",
    Desc = "PERMANENT: near Engineer cooldown, removes every unprotected nuke below your current highest tier",
    Value = S.EngineerBestNukeMode,
    Callback = function(v) S.EngineerBestNukeMode = v; queueSave() end,
})
TabCommander:Slider({
    Title = "Engineer cleanup window",
    Desc = "Start cleanup this many seconds before Field Upgrade is ready",
    Value = { Min = 15, Max = 120, Default = tonumber(S.EngineerCleanupWindow) or 45 },
    Step = 5,
    Callback = function(v) S.EngineerCleanupWindow = math.floor(v); queueSave() end,
})
TabCommander:Toggle({
    Title = "Preserve mutated lower nukes",
    Desc = "Safer default; a preserved lower nuke will block the Engineer setup",
    Value = S.EngineerPreserveMutated,
    Callback = function(v) S.EngineerPreserveMutated = v; queueSave() end,
})

-- PROGRESS
local progressInfo = TabProgress:Paragraph({ Title = "Progression", Desc = "Loading..." })
local seasonInfo = TabProgress:Paragraph({ Title = "Season", Desc = "Loading..." })
local marketInfo = TabProgress:Paragraph({ Title = "Market", Desc = "Loading..." })
TabProgress:Toggle({ Title = "Auto Rebirth", Value = S.AutoRebirth, Callback = function(v) S.AutoRebirth = v; queueSave() end })
TabProgress:Toggle({ Title = "Auto Claim Season Pass", Value = S.AutoClaimSeason, Callback = function(v) S.AutoClaimSeason = v; queueSave() end })
TabProgress:Toggle({ Title = "Auto Claim Season Quests", Value = S.AutoClaimSeasonQuests, Callback = function(v) S.AutoClaimSeasonQuests = v; queueSave() end })
TabProgress:Toggle({ Title = "Auto Claim Season Login", Value = S.AutoClaimSeasonLogin, Callback = function(v) S.AutoClaimSeasonLogin = v; queueSave() end })
TabProgress:Toggle({ Title = "Auto Claim Group Reward", Value = S.AutoClaimGroupReward, Callback = function(v) S.AutoClaimGroupReward = v; queueSave() end })

local falloutVals = falloutItemsAvailable()
TabProgress:Toggle({ Title = "Auto Buy Fallout Items", Value = S.AutoBuyFallout, Callback = function(v) S.AutoBuyFallout = v; queueSave() end })
TabProgress:Dropdown({
    Title = "Fallout items",
    Values = falloutVals,
    Value = S.FalloutItems,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.FalloutItems = normalizeList(v); queueSave() end,
})

-- ESP
local baseEspToggle = TabEsp:Toggle({ Title = "Base ESP", Value = S.BaseESP, Callback = function(v) S.BaseESP = v; if not v then clearESP() end; queueSave() end })
local commanderEspToggle = TabEsp:Toggle({ Title = "Commander ESP", Value = S.CommanderESP, Callback = function(v) S.CommanderESP = v; if not v then clearESP() end; queueSave() end })
local supplyEspToggle = TabEsp:Toggle({ Title = "Supply Drop ESP", Value = S.SupplyDropESP, Callback = function(v) S.SupplyDropESP = v; if not v then clearESP() end; queueSave() end })
local nukeEspToggle = TabEsp:Toggle({ Title = "Nuke ESP", Value = S.NukeESP, Callback = function(v) S.NukeESP = v; if not v then clearESP() end; queueSave() end })
TabEsp:Slider({
    Title = "Nuke ESP min tier",
    Value = { Min = 1, Max = MAX_NUKE_TIER, Default = tonumber(S.NukeEspMinTier) or 8 },
    Step = 1,
    Callback = function(v) S.NukeEspMinTier = math.floor(v); queueSave() end,
})
TabEsp:Dropdown({
    Title = "Nuke ESP mutation filter",
    Values = mutationValues,
    Value = S.NukeEspMutationFilter,
    Multi = true,
    AllowNone = true,
    Callback = function(v) S.NukeEspMutationFilter = normalizeList(v); queueSave() end,
})
TabEsp:Slider({
    Title = "ESP distance",
    Value = { Min = 100, Max = 2000, Default = tonumber(S.EspDistance) or 600 },
    Step = 25,
    Callback = function(v) S.EspDistance = v; queueSave() end,
})

-- INFO
local profileInfo = TabInfo:Paragraph({ Title = "Profile", Desc = "Loading..." })
local nukeInfo = TabInfo:Paragraph({ Title = "Nukes", Desc = "Loading..." })
local boostInfo = TabInfo:Paragraph({ Title = "Boosts", Desc = "Loading..." })
local eventInfo = TabInfo:Paragraph({ Title = "Events", Desc = "Loading..." })
local sessionInfo = TabInfo:Paragraph({ Title = "Session", Desc = "Loading..." })
local timelineInfo = TabInfo:Paragraph({ Title = "Timeline", Desc = "Loading..." })

-- SETTINGS
local debugInfo = TabSettings:Paragraph({ Title = "Debug", Desc = "Loading..." })
TabSettings:Toggle({ Title = "Low Power Mode", Value = S.LowPower, Callback = function(v) S.LowPower = v; queueSave() end })
TabSettings:Toggle({ Title = "Notifications", Value = S.Notifications, Callback = function(v) S.Notifications = v; queueSave() end })
TabSettings:Toggle({
    Title = "Anti-AFK",
    Desc = "Prevents Roblox's inactivity disconnect; enabled by default",
    Value = S.AntiAFK,
    Callback = function(v) S.AntiAFK = v; queueSave() end,
})
TabSettings:Toggle({ Title = "Hotkeys Enabled", Value = S.HotkeysEnabled, Callback = function(v) S.HotkeysEnabled = v; queueSave() end })
TabSettings:Dropdown({ Title = "Auto-Farm hotkey", Values = { "F5", "F6", "F7", "F8", "F9", "F10" }, Value = S.HotkeyFarm, Callback = function(v) S.HotkeyFarm = v; queueSave() end })
TabSettings:Dropdown({ Title = "Auto-Merge hotkey", Values = { "F5", "F6", "F7", "F8", "F9", "F10" }, Value = S.HotkeyMerge, Callback = function(v) S.HotkeyMerge = v; queueSave() end })
TabSettings:Dropdown({ Title = "ESP hotkey", Values = { "F5", "F6", "F7", "F8", "F9", "F10" }, Value = S.HotkeyESP, Callback = function(v) S.HotkeyESP = v; queueSave() end })
TabSettings:Slider({
    Title = "World/UI refresh seconds",
    Value = { Min = 0.5, Max = 5, Default = tonumber(S.RefreshSeconds) or 1.5 },
    Step = 0.1,
    Callback = function(v) S.RefreshSeconds = v; queueSave() end,
})
TabSettings:Slider({
    Title = "Timeline entries",
    Value = { Min = 5, Max = 30, Default = tonumber(S.TimelineLimit) or 14 },
    Step = 1,
    Callback = function(v) S.TimelineLimit = math.floor(v); queueSave() end,
})

return {
    WindUI = WindUI,
    farmStatus = farmStatus,
    autoMergeToggle = autoMergeToggle,
    launchStatus = launchStatus,
    autoFarmToggle = autoFarmToggle,
    commanderInfo = commanderInfo,
    progressInfo = progressInfo,
    seasonInfo = seasonInfo,
    marketInfo = marketInfo,
    baseEspToggle = baseEspToggle,
    commanderEspToggle = commanderEspToggle,
    supplyEspToggle = supplyEspToggle,
    nukeEspToggle = nukeEspToggle,
    profileInfo = profileInfo,
    nukeInfo = nukeInfo,
    boostInfo = boostInfo,
    eventInfo = eventInfo,
    sessionInfo = sessionInfo,
    timelineInfo = timelineInfo,
    debugInfo = debugInfo,
}
end)()

-- Hotkey manager. K remains WindUI's menu key.
local function keyMatches(input, name)
    if not name then return false end
    local ok, key = pcall(function() return Enum.KeyCode[name] end)
    return ok and key and input.KeyCode == key
end

local function syncToggle(control, value)
    pcall(function()
        if control and type(control.SetValue) == "function" then
            control:SetValue(value)
        elseif control and type(control.Set) == "function" then
            control:Set(value)
        end
    end)
end

connect(UserInputService.InputBegan, function(input, processed)
    if processed or not S.HotkeysEnabled or UserInputService:GetFocusedTextBox() then return end
    if keyMatches(input, S.HotkeyFarm) then
        S.AutoFarm = not S.AutoFarm
        syncToggle(UI.autoFarmToggle, S.AutoFarm)
        timeline("Hotkey: Auto-Farm " .. (S.AutoFarm and "ON" or "OFF"))
        queueSave()
    elseif keyMatches(input, S.HotkeyMerge) then
        S.AutoMerge = not S.AutoMerge
        syncToggle(UI.autoMergeToggle, S.AutoMerge)
        timeline("Hotkey: Auto-Merge " .. (S.AutoMerge and "ON" or "OFF"))
        queueSave()
    elseif keyMatches(input, S.HotkeyESP) then
        local newValue = not (S.BaseESP or S.CommanderESP or S.SupplyDropESP or S.NukeESP)
        S.BaseESP, S.CommanderESP, S.SupplyDropESP, S.NukeESP = newValue, newValue, newValue, newValue
        syncToggle(UI.baseEspToggle, newValue)
        syncToggle(UI.commanderEspToggle, newValue)
        syncToggle(UI.supplyEspToggle, newValue)
        syncToggle(UI.nukeEspToggle, newValue)
        if not newValue then clearESP() end
        timeline("Hotkey: ESP " .. (newValue and "ON" or "OFF"))
        queueSave()
    end
end)

local notifiedClaimables = {}
local lastNotifyEvent = ""
task.spawn(function()
    while alive() do
        if S.Notifications then
            for id, c in pairs(World.claimables) do
                if not notifiedClaimables[id] and (RARITY_RANK[c.rarity] or 0) >= (RARITY_RANK.Legendary or 4) then
                    notifiedClaimables[id] = true
                    pcall(function()
                        UI.WindUI:Notify({ Title = "Commander Spawn", Content = string.format("%s [%s]", c.name, c.rarity), Duration = 5, Icon = "crown" })
                    end)
                end
            end
            for id in pairs(notifiedClaimables) do
                if not World.claimables[id] then notifiedClaimables[id] = nil end
            end
            if EventState.last ~= "None" and EventState.last ~= lastNotifyEvent and os.clock() - EventState.lastAt < 4 then
                lastNotifyEvent = EventState.last
                pcall(function() UI.WindUI:Notify({ Title = "Game Event", Content = EventState.last, Duration = 5, Icon = "radio" }) end)
            end
        end
        task.wait(S.LowPower and 4 or 1.5)
    end
end)

-- ============================================================
-- UI refresh / dashboards
-- ============================================================

local function setDesc(obj, text)
    pcall(function() obj:SetDesc(tostring(text)) end)
end

local function nukeSummary()
    local placed, held, airborne = 0, 0, 0
    local maxTier = 0
    local locked = 0
    local mutationCount = 0
    for _, n in ipairs(myNukes()) do
        maxTier = math.max(maxTier, tonumber(n.Tier) or 0)
        if n.State == NUKE_PLACED then placed = placed + (1) elseif n.State == NUKE_HELD then held = held + (1) elseif n.State == NUKE_AIRBORNE then airborne = airborne + (1) end
        if n.Locked then locked = locked + (1) end
        mutationCount = mutationCount + (#mutationKeys(n))
    end
    return string.format("Placed %d | Held %d | Flying %d\nMax T%d | Locked %d | Mutations %d\nGlobal CD %s",
        placed, held, airborne, maxTier, locked, mutationCount, fmtClock(globalLaunchCooldown()))
end

local function commanderPassiveSummary()
    local ready, cooling = 0, 0
    local soonest
    for _, c in ipairs(World.commanders) do
        if c.ownerUserId == lp.UserId and c.model and c.model.Parent then
            local timer = c.model:FindFirstChild("TimerBillboard", true)
            local ends = timer and tonumber(timer:GetAttribute("EndTime")) or 0
            if ends and ends > serverNow() then
                cooling = cooling + 1
                if not soonest or ends < soonest then soonest = ends end
            else
                ready = ready + 1
            end
        end
    end
    return ready, cooling, soonest and math.max(0, soonest - serverNow()) or 0
end

local function commanderSummary()
    local entries = commanderEntries()
    local equipped = 0
    local best
    for _, e in ipairs(entries) do
        if e.equipped then equipped = equipped + (1) end
        if not best or commanderScore(e) > commanderScore(best) then best = e end
    end
    local claimCount = 0
    for _ in pairs(World.claimables) do claimCount = claimCount + (1) end
    local bestText = "None"
    if best then
        local data = type(best.data) == "table" and best.data or {}
        local rarity = type(data.Rarity) == "table" and data.Rarity.DisplayName or data.Rarity
        bestText = string.format("%s | %s | Lv%d | A%d",
            tostring(data.DisplayName or best.key), tostring(rarity or "Unknown"),
            tonumber(best.level) or 0, tonumber(best.awakening) or 0)
    end
    local readyPassive, coolingPassive, nextPassive = commanderPassiveSummary()
    return string.format("Owned %d | Equipped %d/%d\nBest: %s\nClaimable %d | Passive ready %d | cooling %d%s\nEngineer setup: %s",
        #entries, equipped, 3 + (tonumber(profile().commanderSlotLevel) or 0), bestText,
        claimCount, readyPassive, coolingPassive,
        coolingPassive > 0 and (" | next " .. fmtClock(nextPassive)) or "",
        tostring(Coord.engineerStatus or "Disabled"))
end

local function seasonSummary()
    local s = profile().season
    if type(s) ~= "table" then return "No season data" end
    local activeQuestCount, completedQuestCount, claimableQuestCount = 0, 0, 0
    if type(s.quests) == "table" and type(s.quests.active) == "table" then
        for _, q in pairs(s.quests.active) do
            activeQuestCount = activeQuestCount + (1)
            if type(q) == "table" and q.Completed == true then
                completedQuestCount = completedQuestCount + (1)
                if q.Claimed ~= true then claimableQuestCount = claimableQuestCount + (1) end
            end
        end
    end
    local claimedLogin = 0
    if type(s.login) == "table" and type(s.login.claimed) == "table" then
        for _, v in pairs(s.login.claimed) do if v then claimedLogin = claimedLogin + (1) end end
    end
    return string.format("Season %s | Tier %s | XP %s\nNuclear Waste %s | Premium %s\nActive quests %d | Login claimed %d | Crate spins %s",
        tostring(s.id or "?"), tostring(s.tier or 0), fmtNumber(s.xp or 0), fmtNumber(s.nuclearWaste or 0), tostring(s.premium == true), activeQuestCount, claimedLogin, tostring(s.crateSpins or 0))
        .. string.format("\nQuest completed %d | claimable %d", completedQuestCount, claimableQuestCount)
end

local function marketSummary()
    local lines = {}
    local f = Market.fallout
    if type(f) == "table" and type(f.Items) == "table" then
        local inStock, owned = 0, 0
        for _, st in pairs(f.Items) do
            if type(st) == "table" then
                if (tonumber(st.Stock) or 0) > 0 then inStock = inStock + (1) end
                if st.Owned then owned = owned + (1) end
            end
        end
        local restockText = "?"
        pcall(function() restockText = fmtClock(math.max(0, FalloutStoreData.NextRestockAt() - os.time())) end)
        table.insert(lines, string.format("Fallout Store: %d in-stock | %d owned | restock %s", inStock, owned, restockText))
    else
        table.insert(lines, "Fallout Store: waiting for state")
    end

    local a = Market.auction
    if type(a) == "table" then
        if a.active == true then
            table.insert(lines, string.format("Auction: %s | price %s | stock %s | %s",
                tostring(a.displayName or a.itemId or "item"), fmtNumber(a.price or 0), tostring(a.stock or "?"), a.soldOut and "SOLD" or (a.owned and "OWNED" or "ACTIVE")))
            if a.robuxProductId then table.insert(lines, "Robux offer detected (never auto-purchased)") end
        else
            table.insert(lines, "Auction: inactive")
        end
    else
        table.insert(lines, "Auction: waiting for state")
    end
    return table.concat(lines, "\n")
end

local fps = 0
local frameCount = 0
local frameClock = os.clock()
connect(RunService.RenderStepped, function()
    frameCount = frameCount + (1)
    if os.clock() - frameClock >= 1 then
        fps = frameCount
        frameCount = 0
        frameClock = os.clock()
    end
end)

local function upgradeSummary()
    local d = profile()
    local lines = {}
    for _, label in ipairs(UP_PRIORITY) do
        local key = UP_LABEL_TO_KEY[label]
        local field = UP_LEVEL_FIELD[key]
        local lvl = tonumber(d[field])
        local cfg = UpgradeConfig[key]
        if lvl and cfg then
            local available, reason = upgradeAvailability(key, lvl, d)
            if not available then
                table.insert(lines, string.format("%s Lv%d %s", label, lvl, tostring(reason or "blocked")))
            else
                local cost = upgradeCost(key, lvl)
                local costText = "?"
                pcall(function() costText = BigNum.format(cost) end)
                table.insert(lines, string.format("%s Lv%d -> %s", label, lvl, costText))
            end
        end
    end
    return table.concat(lines, " | ")
end

local function refreshUI()
    local d = profile()
    local lockPhase, lockLeft, locked = lockState()
    local cash = fmtBigSerialized(d.cash)
    local rebirth = tonumber(d.rebirthLevel) or 0
    local maxTier = tonumber(d.maxNukeTier) or 0

    setDesc(UI.profileInfo, string.format("Cash %s | Rebirth %d | Profile max T%d\nBase %s%s | Codes %d | Group reward %s\nBase skin %s (%d owned) | Explosion VFX %s (%d owned)\nFriend boost +%d%% | Offline %s\nUpgrades: %s",
        cash, rebirth, maxTier, lockPhase, locked and (" " .. fmtClock(lockLeft)) or "",
        type(d.redeemedCodes) == "table" and (function() local c=0 for _ in pairs(d.redeemedCodes) do c=c+1 end return c end)() or 0,
        d.groupRewardClaimed and "claimed" or "not claimed",
        type(d.BaseSkins) == "table" and tostring(d.BaseSkins.Equipped or "?") or "?",
        type(d.BaseSkins) == "table" and type(d.BaseSkins.Owned) == "table" and (function() local c=0 for _,v in pairs(d.BaseSkins.Owned) do if v then c=c+1 end end return c end)() or 0,
        type(d.ExplosionVFXs) == "table" and tostring(d.ExplosionVFXs.Equipped or "?") or "?",
        type(d.ExplosionVFXs) == "table" and type(d.ExplosionVFXs.Owned) == "table" and (function() local c=0 for _,v in pairs(d.ExplosionVFXs.Owned) do if v then c=c+1 end end return c end)() or 0,
        math.max(0, MiscState.friendBoost) * 10,
        fmtNumber(MiscState.offlineCash), upgradeSummary()))

    setDesc(UI.nukeInfo, nukeSummary())
    setDesc(UI.commanderInfo, commanderSummary())

    local eligible, rebirthText = rebirthStatus()
    setDesc(UI.progressInfo, (eligible and "READY | " or "") .. rebirthText)
    setDesc(UI.seasonInfo, seasonSummary())
    setDesc(UI.marketInfo, marketSummary())
    local playtimeText = "none"
    if type(MiscState.playtime) == "table" then
        playtimeText = string.format("%s/%s%s", tostring(MiscState.playtime.elapsed or 0), tostring(MiscState.playtime.required or 0), MiscState.playtime.completed and " complete" or "")
    end
    setDesc(UI.boostInfo, boostSummary() .. "\nFriend boost: +" .. tostring(math.max(0, MiscState.friendBoost) * 10) .. "% | Playtime: " .. playtimeText)

    setDesc(UI.eventInfo, string.format("Last: %s (%s ago)\n%s\nYour volcano damage: %s",
        EventState.last, EventState.lastAt > 0 and fmtClock(os.clock() - EventState.lastAt) or "-", currentEventSummary(), fmtNumber(lp:GetAttribute("VolcanoDamage") or 0)))

    setDesc(UI.sessionInfo, string.format("Uptime %s | FPS %d\nMerges %d/%d fail | Launches %d/%d fail | Scheduler %d | Recoveries %d | Upgrades %d | Locks %d\nCommander: equip %d upgrade %d awaken %d | Engineer removed %d | Rebirth %d | Rewards %d | Fallout buys %d | Errors %d",
        fmtClock(os.clock() - Runtime.startedAt), fps,
        Stats.merges, Stats.mergeFails, Stats.launches, Stats.launchFails, Coord.SchedulerState.actions, Stats.recoveries, Stats.upgrades, Stats.locks,
        Stats.commanderEquipChanges, Stats.commanderUpgrades, Stats.commanderAwakens, Stats.engineerPruned, Stats.rebirths, Stats.rewards, Stats.falloutPurchases, Stats.errors))

    setDesc(UI.timelineInfo, #Timeline > 0 and table.concat(Timeline, "\n") or "No actions yet")

    local held = currentHeld()
    local lockText = {}
    for k, v in pairs(Locks) do table.insert(lockText, k .. "=" .. tostring(v)) end
    local cityBuildings, cityPhase = cityBuildingTargets()
    setDesc(UI.debugInfo, string.format("Nukes %d | World v%d | Claimables %d | Drops %d | City %s/%d buildings\nHeld %s | Locks %s\nScheduler %s / %s | actions %d | fail M%d/A%d | recoveries %d\nWatchdog %s | same %d | last recovery: %s\nGame radius: merge %.1f pickup %.1f | drop %.2fs/%.2fs\nLast action: %s\nLast error: %s",
        #myNukes(), World.version,
        (function() local n=0 for _ in pairs(World.claimables) do n = n + (1) end return n end)(),
        (function() local n=0 for _ in pairs(World.supplyDrops) do n = n + (1) end return n end)(),
        tostring(cityPhase), #cityBuildings,
        held and ("T" .. tostring(held.Tier) .. " #" .. tostring(held.Id):sub(-6)) or "none",
        #lockText > 0 and table.concat(lockText, ", ") or "none",
        "Attack > Merge", tostring(Coord.SchedulerState.lastDecision), Coord.SchedulerState.actions,
        Coord.SchedulerState.mergeFailStreak, Coord.SchedulerState.attackFailStreak, Coord.SchedulerState.recoveries or 0,
        S.WatchdogEnabled and "ON" or "OFF", Coord.SchedulerState.sameDecisionCount or 0, tostring(Coord.SchedulerState.lastRecoveryReason or "none"),
        Coord.GAME_MERGE_RADIUS, Coord.GAME_PICKUP_RADIUS, Coord.GAME_DROP_DEBOUNCE, Coord.GAME_INDIVIDUAL_DROP_DEBOUNCE,
        Runtime.lastAction, Runtime.lastError ~= "" and Runtime.lastError or "none"))

    local mPlan = Coord.mergePlan()
    local farmText = S.AutoMerge
        and (mPlan and ("Auto-Merge ready: T" .. tostring(mPlan.tier) .. " (" .. tostring(mPlan.count) .. " available)") or "Auto-Merge: waiting for pair")
        or "Auto-Merge off"
    farmText = farmText .. (" | Base " .. lockPhase)
    setDesc(UI.farmStatus, farmText)

    local targets = S.AutoFarm and targetCandidates(false) or {}
    local n = S.AutoFarm and chooseFarmNuke() or nil
    local decisionKind, decisionWhy = Coord.schedulerDecision()
    setDesc(UI.launchStatus, string.format("Scheduler %s | %s\nAttack %s | Nuke %s | Target %s | CD %s\nLast %s: %s",
        "Attack > Merge", tostring(decisionWhy),
        S.AutoFarm and "ON" or "OFF", n and ("T" .. tostring(n.Tier)) or "none",
        targets[1] and targets[1].label or "none", fmtClock(globalLaunchCooldown()),
        tostring(Coord.SchedulerState.lastKind), tostring(Coord.SchedulerState.lastResult)))
end

task.spawn(function()
    while alive() do
        safe("UI refresh", refreshUI)
        task.wait(S.LowPower and 3 or math.max(0.5, tonumber(S.RefreshSeconds) or DEFAULT.RefreshSeconds))
    end
end)

-- ============================================================
-- Cleanup / final notification
-- ============================================================

local function shutdownRuntime(reason)
    if Runtime.shuttingDown then return end
    Runtime.shuttingDown = true

    if Runtime.pendingSave then
        pcall(task.cancel, Runtime.pendingSave)
        Runtime.pendingSave = nil
    end
    if Runtime.readinessThread and Runtime.readinessThread ~= coroutine.running()
        and coroutine.status(Runtime.readinessThread) ~= "dead" then
        pcall(task.cancel, Runtime.readinessThread)
    end
    Runtime.readinessThread = nil
    pcall(saveConfig)
    Runtime.dead = true

    for name, worker in pairs(LockWorkers) do
        if worker and worker ~= coroutine.running() and coroutine.status(worker) ~= "dead" then
            pcall(task.cancel, worker)
        end
        LockWorkers[name] = nil
        Locks[name] = nil
        LockTimes[name] = nil
    end

    for _, c in ipairs(Runtime.connections) do pcall(function() c:Disconnect() end) end
    table.clear(Runtime.connections)
    for index = #Runtime.cleanups, 1, -1 do pcall(Runtime.cleanups[index]) end
    table.clear(Runtime.cleanups)

    Runtime.shutdownReason = tostring(reason or "manual")
    if _G.NukeHubV5Runtime == Runtime then
        _G.NukeHubV5Runtime = nil
        _G.NukeHubV5State = nil
        _G.NukeHubV5 = nil
        _G.NukeHubV5Shutdown = nil
    end
end
Runtime.shutdown = shutdownRuntime
_G.NukeHubV5Shutdown = shutdownRuntime

_G.NukeHubV5 = {
    Runtime = Runtime,
    State = S,
    Stats = Stats,
    World = World,
    Scheduler = Coord.SchedulerState,
    RefreshWorld = refreshWorld,
    Recover = Coord.recoverScheduler,
    MergeOnce = mergeOnce,
    LaunchOnce = launchOneSmart,
    LockBase = requestBaseLock,
    UpgradeOnce = autoUpgradeStep,
    ProtectOne = autoLockProtectedNukeStep,
    EngineerPruneOnce = Coord.engineerPruneStep,
    RebirthStatus = rebirthStatus,
    Shutdown = _G.NukeHubV5Shutdown,
}

UI.WindUI:Notify({
    Title = "Nuke Hub v5.5 Stable loaded",
    Content = "K menu | F6 farm | F7 merge | F8 ESP | cached CityState core",
    Duration = 6,
    Icon = "radiation",
})

timeline("Nuke Hub v5.5 Stable loaded")
