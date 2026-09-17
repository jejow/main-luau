--// BAAN HUB v19 KEYLESS - AUTO SEA PEARL FARM - STABLE BURST-FILL
local ISLAND_PLACE = 139802517550914
local LOBBY_PLACE = 70411440483149
local TARGET_LEVEL = 2
local MIN_CAMPFIRE_PERCENT = 20
local FARM_TARGET = 500
local PEARL_MIN = 500
local DEFENSE_RADIUS = 120
local PASSIVE = {"Seagull", "Buku", "Crab", "_CLIENT", "Companion"}
local LEVEL1_FUEL_REQUIREMENT = 4
local FUEL_RESTAGE_DELAY = 0.05
local FUEL_OWNERSHIP_TIMEOUT = 0.04
local FUEL_ACK_TIMEOUT = 0.16
local FUEL_REPLICATION_HOLD = 0.008
local FUEL_ACQUIRE_RETRIES = 2
local FUEL_FAILED_COOLDOWN = 0.12
local FUEL_NEARBY_WINDOW = 45 -- allow a slightly wider local pool so one high-value fuel can finish the target
local FUEL_CANDIDATE_LIMIT = 8 -- inspect several nearby fuels, but still avoid chasing the whole map
local FUEL_DROP_SPEED = 30 -- short downward release to create a real server-side Dropper contact
local FUEL_QUICK_ACK = 0.07 -- never block half a second after every single drop
local FUEL_BURST_LIMIT = 3 -- allow a few drops to pipeline while Progress replication catches up
local globalEnvironment = getgenv()
globalEnvironment.__autoSea = globalEnvironment.__autoSea or {}
local state = globalEnvironment.__autoSea
state.fuelOwnershipAttempted = type(state.fuelOwnershipAttempted) == "table"
    and state.fuelOwnershipAttempted or {}
state.fuelRetryAfter = type(state.fuelRetryAfter) == "table" and state.fuelRetryAfter or {}
local jobId = game.JobId ~= "" and game.JobId or tostring(math.random(1e9))
if state.lastJobId ~= jobId then
    state.lastJobId = jobId
    state.bought = false
    state.fuelStatus = nil
    state.fuelOwnershipAttempted = {}
    state.fuelRetryAfter = {}
end
local function log(...)
    print("[auto-sea]", ...)
end
---------------------------------------------------------------------
-- transition watchdog: recover from hung teleports (island<->lobby)
local function returnToLobby(reason)
    local now = os.clock()
    if state.lastForce and now - state.lastForce < 10 then return end
    state.lastForce = now
    log("watchdog:", reason, "-> teleporting to lobby")
    pcall(function()
        game:GetService("TeleportService"):Teleport(LOBBY_PLACE, game.Players.LocalPlayer)
    end)
end
task.spawn(function()
    while true do
        task.wait(5)
        pcall(function()
            local localPlayer = game.Players.LocalPlayer
            if not (localPlayer and localPlayer.Parent) then return end
            if game.PlaceId == ISLAND_PLACE then
                state.noPadsSince = nil
                if workspace:FindFirstChild("SpawnIsland") then
                    state.noIslandSince = nil
                else
                    state.noIslandSince = state.noIslandSince or os.clock()
                    if os.clock() - state.noIslandSince > 90 then
                        state.noIslandSince = nil
                        returnToLobby("island stuck loading")
                    end
                end
            else
                state.noIslandSince = nil
                if workspace:FindFirstChild("Pads") then
                    state.noPadsSince = nil
                else
                    state.noPadsSince = state.noPadsSince or os.clock()
                    if os.clock() - state.noPadsSince > 120 then
                        state.noPadsSince = nil
                        returnToLobby("lobby stuck loading")
                    end
                end
            end
        end)
    end
end)
---------------------------------------------------------------------
-- wait for the map to finish loading before choosing a branch
do
    local startedAt = os.clock()
    while not workspace:FindFirstChild("Pads")
        and not workspace:FindFirstChild("SpawnIsland")
        and os.clock() - startedAt < 60 do
        task.wait(1)
    end
end
---------------------------------------------------------------------
-- BAAN HUB HUD (runs in every place)
task.spawn(function()
    local drawingObjects = {}
    local function make(class, props)
        local d = Drawing.new(class)
        for k, v in pairs(props) do
            d[k] = v
        end
        table.insert(drawingObjects, d)
        return d
    end
    local function destroyDrawings()
        for _, d in ipairs(drawingObjects) do
            pcall(function() d:Remove() end)
        end
        drawingObjects = {}
    end
    local X, Y, W = 14, 14, 236
    make("Square", {
        Position = Vector2.new(X, Y), Size = Vector2.new(W, 198),
        Color = Color3.fromRGB(15, 17, 22), Transparency = 0.72, Filled = true, Thickness = 1, Visible = true,
    })
    make("Square", {
        Position = Vector2.new(X, Y), Size = Vector2.new(W, 198),
        Color = Color3.fromRGB(255, 196, 60), Transparency = 0.9, Filled = false, Thickness = 1.6, Visible = true,
    })
    local logoData
    pcall(function()
		logoData = readfile("C:\\Users\\ownsu\\AppData\\Local\\Real\\autoexec\\baan-hub-logo.png")
    end)
    if not (logoData and #logoData > 0) then
        pcall(function()
			logoData = readfile("C:\\Users\\ownsu\\Desktop\\baan-hub-logo.png")
        end)
    end
    if logoData and #logoData > 0 then
        pcall(function()
            make("Image", {
                Position = Vector2.new(X + W - 29, Y + 5), Size = Vector2.new(24, 24),
                Data = logoData, Visible = true,
            })
        end)
    end
    local title = make("Text", {
        Position = Vector2.new(X + 10, Y + 7), Text = "BAAN HUB",
        Size = 19, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(255, 196, 60), Outline = true,
        OutlineColor = Color3.fromRGB(0, 0, 0), Visible = true,
    })
    local status = make("Text", {
        Position = Vector2.new(X + 10, Y + 36), Text = "Status: ...",
        Size = 15, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(120, 235, 160), Outline = true, Visible = true,
    })
    local pearlText = make("Text", {
        Position = Vector2.new(X + 10, Y + 62), Text = "Pearls: -",
        Size = 15, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(240, 240, 255), Outline = true, Visible = true,
    })
    local doubloonsText = make("Text", {
        Position = Vector2.new(X + 10, Y + 86), Text = "Doubloons: -",
        Size = 15, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(255, 220, 120), Outline = true, Visible = true,
    })
    local campfireText = make("Text", {
        Position = Vector2.new(X + 10, Y + 110), Text = "Campfire: -",
        Size = 15, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(255, 160, 90), Outline = true, Visible = true,
    })
    local roundText = make("Text", {
        Position = Vector2.new(X + 10, Y + 134), Text = "Round: -",
        Size = 13, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(170, 175, 185), Outline = true, Visible = true,
    })
    local licenseText = make("Text", {
        Position = Vector2.new(X + 10, Y + 154), Text = "License: KEYLESS",
        Size = 13, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(255, 196, 60), Outline = true, Visible = true,
    })
    local subtitle = make("Text", {
        Position = Vector2.new(X + 10, Y + 178), Text = "// 100 Days At Sea",
        Size = 11, Font = Drawing.Fonts.Plex, Color = Color3.fromRGB(150, 155, 165), Outline = true, Visible = true,
    })
    local function isRaidActiveForHud()
        if workspace:GetAttribute("RaidActive") then return true end
        local clockTime = game.Lighting.ClockTime
        return clockTime >= 18.5 or clockTime < 5.5
    end
    local function getPhaseText()
        local localPlayer = game.Players.LocalPlayer
        if not (localPlayer and localPlayer.Parent) then return "reconnecting..." end
        if workspace:FindFirstChild("Pads") then
            return state.bought and "Entering new room..." or "In lobby - making party"
        end
        local spawnIsland = workspace:FindFirstChild("SpawnIsland")
        if not spawnIsland then return "Loading island..." end
        local level = spawnIsland:GetAttribute("Level") or 1
        local doubloons = localPlayer:GetAttribute("Doubloons") or 0
        if workspace:FindFirstChild("MerchantBoat") and doubloons >= PEARL_MIN then
            return "Trading pearls with merchant..."
        end
        if isRaidActiveForHud() then
            local home = spawnIsland:FindFirstChild("Bonfire")
            local hp = home and home:GetPivot().Position or Vector3.zero
            local near = false
            for _, m in ipairs(workspace:FindFirstChild("CreatureContainer") and workspace.CreatureContainer:GetChildren() or {}) do
                local nm = m.Name
                if nm ~= "Seagull" and nm ~= "Buku Buku" and nm ~= "Crab" and not nm:find("_CLIENT")
                    and not m:GetAttribute("Dead") then
                    local ok, p = pcall(function() return m:GetPivot().Position end)
                    if ok and p and (p - hp).Magnitude <= DEFENSE_RADIUS then near = true break end
                end
            end
            if near then return "Defending base - RAID!" end
        end
        local progress = tonumber(spawnIsland:GetAttribute("Progress")) or 0
        local campfireReady = level > TARGET_LEVEL or (level == TARGET_LEVEL and progress >= MIN_CAMPFIRE_PERCENT)
        if not campfireReady and spawnIsland:FindFirstChild("Dropper") then
            return state.fuelStatus or string.format("Raising campfire to Lv%d + %d%%...", TARGET_LEVEL, MIN_CAMPFIRE_PERCENT)
        end
        if doubloons < FARM_TARGET then
            return string.format("Farming coins (target %d)", FARM_TARGET)
        end
        return "Holding base - waiting for merchant"
    end
    while true do
        pcall(function()
            local localPlayer = game.Players.LocalPlayer
            if not (localPlayer and localPlayer.Parent) then return end
            local okD = pcall(function() return title.Text end)
            if not okD then
                destroyDrawings()
                return
            end
            status.Text = "Status: " .. getPhaseText()
            pearlText.Text = "Pearls: " .. tostring(localPlayer:GetAttribute("Pearls") or 0)
            doubloonsText.Text = "Doubloons: " .. tostring(localPlayer:GetAttribute("Doubloons") or 0)
            local spawnIsland = workspace:FindFirstChild("SpawnIsland")
            if spawnIsland then
                campfireText.Text = string.format("Campfire: Lv.%s (%s%%)",
                    tostring(spawnIsland:GetAttribute("Level") or "?"), tostring(spawnIsland:GetAttribute("Progress") or 0))
                roundText.Text = string.format("Day %s | %s",
                    tostring(workspace:GetAttribute("Day") or "?"),
                    state.bought and "done - exiting" or "farming")
            else
                campfireText.Text = "Campfire: -"
                roundText.Text = "Lobby"
            end
        end)
        task.wait(0.25)
    end
end)
---------------------------------------------------------------------
if workspace:FindFirstChild("Pads") then
    -- LOBBY: create a solo party on a free pad and HOLD position until launched
    task.spawn(function()
        log("lobby: starting solo party flow")
        local localPlayer = game.Players.LocalPlayer
        while state.running ~= false and workspace:FindFirstChild("Pads") do
            local char = localPlayer.Character
            local rootPart = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
            local pads = workspace:FindFirstChild("Pads")
            if not (rootPart and pads) then task.wait(1) continue end
            -- already owned a seeded pad? just hold
            local myPad = localPlayer:GetAttribute("Pad")
            local padObj = myPad and pads:FindFirstChild("Pad" .. myPad) or nil
            if not padObj or not padObj:GetAttribute("Seed") then
                -- find a fresh open non-challenge unseeded pad
                for i = 1, 4 do
                    local p = pads:FindFirstChild("Pad" .. i)
                    if p and p:GetAttribute("Open") and not p:GetAttribute("Seed")
                        and not p:GetAttribute("Challenge") then
                        padObj = p
                        break
                    end
                end
                if not padObj then task.wait(2) continue end
                local cf = padObj:GetBoundingBox()
                rootPart.CFrame = cf + Vector3.new(0, 2.5, 0)
                rootPart.AssemblyLinearVelocity = Vector3.zero
                task.wait(0.8)
                pcall(function()
                    local net = debug.getupvalue(
                        require(game.ReplicatedStorage.Modules.Systems.PartyUI).CreateCallback, 1)
                    net:InvokeServer("EnterPad", tonumber(padObj.Name:sub(-1)))
                end)
                task.wait(0.8)
                if localPlayer:GetAttribute("Pad") then
                    pcall(function()
                        local net = debug.getupvalue(
                            require(game.ReplicatedStorage.Modules.Systems.PartyUI).CreateCallback, 1)
                        net:FireServer("CreateParty", 1, os.time())
                    end)
                    log("party created on " .. padObj.Name)
                end
            end
            -- hold position on the pad until the game teleports us away
            if padObj then
                local okC, cf = pcall(function() return padObj:GetBoundingBox() end)
                if okC then
                    rootPart.CFrame = cf + Vector3.new(0, 2.5, 0)
                    rootPart.AssemblyLinearVelocity = Vector3.zero
                end
            end
            task.wait(1)
        end
    end)
    return
end
if not workspace:FindFirstChild("SpawnIsland") then
    return -- some other map/state, do nothing
end
---------------------------------------------------------------------
-- ISLAND: full pipeline
local function disableCutscenes()
    pcall(function()
        local m = require(game.ReplicatedStorage.Modules.Systems.CutscenePlayer)
        if type(m) == "table" then
            m.isPlaying = function() return false end
            m.Start = function() return nil end
        end
    end)
end
local function isIslandSessionAlive()
    local localPlayer = game.Players.LocalPlayer
    return localPlayer ~= nil and localPlayer.Parent ~= nil and workspace:FindFirstChild("SpawnIsland") ~= nil
end
local function getRootPart()
    local c = game.Players.LocalPlayer.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart
end
local function teleportCharacter(cf)
    local localPlayer = game.Players.LocalPlayer
    local character = localPlayer and localPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false end
    -- v19: keep the character upright and kill both linear + angular momentum.
    -- This prevents the "menggelundung" state from moving the HRP away before
    -- AttemptDrag reaches the server.
    pcall(function()
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.Sit = false
            humanoid.PlatformStand = false
        end
        character:PivotTo(cf)
    end)
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            pcall(function()
                part.AssemblyLinearVelocity = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
            end)
        end
    end
    return true
end
local function clearFuelHighlight()
    local highlight = state.fuelHighlight
    if highlight then
        pcall(function() highlight:Destroy() end)
    end
    state.fuelHighlight = nil
end
local function highlightFuel(model)
    local current = state.fuelHighlight
    if current and current.Parent and current.Adornee == model then return end
    clearFuelHighlight()
    if not (model and model:IsDescendantOf(workspace)) then return end
    local highlight = Instance.new("Highlight")
    highlight.Name = "BAAN_FuelAssist"
    highlight.Adornee = model
    highlight.FillColor = Color3.fromRGB(255, 166, 55)
    highlight.FillTransparency = 0.62
    highlight.OutlineColor = Color3.fromRGB(255, 225, 130)
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = model
    state.fuelHighlight = highlight
end
local function getFuelPart(instance)
    if not instance then return nil, nil, nil end
    -- v17: live DebrisField fuel can remain Anchored until the game accepts
    -- AttemptDrag. Do NOT reject an item merely because its PrimaryPart is
    -- currently anchored. The original game-side interaction is responsible for
    -- changing its drag/network state.
    local model = instance
    if not (model:IsA("Model") or model:IsA("BasePart") or model:IsA("Tool")) then
        model = instance:FindFirstAncestorOfClass("Model")
    end
    if not model then return nil, nil, nil end
    -- Prefer the attribute on the actual DebrisField item. If this function was
    -- reached from a tagged descendant, walk upward until a BonfireFuel owner is
    -- found and normalize to that owner/model.
    local attrOwner = instance
    local fuelValue
    while attrOwner and attrOwner ~= workspace do
        fuelValue = attrOwner:GetAttribute("BonfireFuel")
        if type(fuelValue) == "number" and fuelValue > 0 then break end
        attrOwner = attrOwner.Parent
    end
    if type(fuelValue) ~= "number" or fuelValue <= 0 then
        fuelValue = model:GetAttribute("BonfireFuel")
    end
    if type(fuelValue) ~= "number" or fuelValue <= 0 then return nil, nil, nil end
    if attrOwner and attrOwner ~= workspace and attrOwner:IsA("Model") then
        model = attrOwner
    end
    local part
    if model:IsA("BasePart") then
        part = model
    elseif model:IsA("Model") then
        -- PrimaryPart is exactly what the older working script used. Keep it even
        -- if Anchored; AttemptDrag may be what transitions it into a draggable
        -- server-owned assembly.
        part = model.PrimaryPart
        if not part then
            part = model:FindFirstChildWhichIsA("BasePart", true)
        end
    elseif model:IsA("Tool") then
        part = model:FindFirstChild("Handle") or model:FindFirstChildWhichIsA("BasePart", true)
    end
    if not part then return nil, nil, nil end
    return model, part, fuelValue
end
local function getFuelItems()
    local CollectionService = game:GetService("CollectionService")
    local items = {}
    local seen = setmetatable({}, {__mode = "k"})
    local rootPart = getRootPart()
    local origin = rootPart and rootPart.Position
        or (workspace:FindFirstChild("SpawnIsland") and workspace.SpawnIsland:FindFirstChild("Dropper") and workspace.SpawnIsland.Dropper.Position)
        or Vector3.zero
    local now = os.clock()
    local taggedCount, debrisCount, fallbackCount = 0, 0, 0
    local anchoredCount = 0
    local function consider(instance, source)
        local model, part, fuelValue = getFuelPart(instance)
        if not (model and part and fuelValue) or seen[model] then return end
        seen[model] = true
        local retryAt = state.fuelRetryAfter[model]
        if retryAt and retryAt > now then return end
        if not model:IsDescendantOf(workspace) or not part:IsDescendantOf(workspace) then return end
        if model:GetAttribute("Dead") then return end
        if part.Anchored then anchoredCount += 1 end
        table.insert(items, {
            model = model,
            part = part,
            value = fuelValue,
            distance = (part.Position - origin).Magnitude,
            source = source,
            wasAnchored = part.Anchored,
        })
    end
    -- FAST PATH: this map keeps the real fuel items directly in DebrisField.
    -- Do not also enumerate all Interactable tags when DebrisField already gave
    -- us usable fuel; that was unnecessary work on every single delivery.
    local debris = workspace:FindFirstChild("DebrisField")
    if debris then
        for _, instance in ipairs(debris:GetChildren()) do
            local value = instance:GetAttribute("BonfireFuel")
            if type(value) == "number" and value > 0 then
                debrisCount += 1
                consider(instance, "debris-direct")
            end
        end
    end
    -- Only use the broader tag scan if the primary map structure returned no
    -- usable fuel. This keeps the common path very cheap.
    if #items == 0 then
        for _, instance in ipairs(CollectionService:GetTagged("Interactable")) do
            taggedCount += 1
            consider(instance, "tag")
        end
    end
    if #items == 0 then
        for _, instance in ipairs(workspace:GetDescendants()) do
            local value = instance:GetAttribute("BonfireFuel")
            if type(value) == "number" and value > 0 then
                fallbackCount += 1
                consider(instance, "workspace")
            end
        end
    end
    state.lastFuelScan = {
        tagged = taggedCount,
        debris = debrisCount,
        fallback = fallbackCount,
        usable = #items,
        anchored = anchoredCount,
    }
    table.sort(items, function(a, b)
        if math.abs(a.distance - b.distance) < 0.01 then
            if a.value == b.value then return a.model.Name < b.model.Name end
            return a.value > b.value
        end
        return a.distance < b.distance
    end)
    return items
end
local function getCampfireState(spawnIsland)
    if not spawnIsland then return 1, 0 end
    local level = tonumber(spawnIsland:GetAttribute("Level")) or 1
    local progress = tonumber(spawnIsland:GetAttribute("Progress")) or 0
    return level, math.clamp(progress, 0, 100)
end
local function campfireTargetReached(spawnIsland)
    local level, progress = getCampfireState(spawnIsland)
    if level > TARGET_LEVEL then return true end
    return level == TARGET_LEVEL and progress >= MIN_CAMPFIRE_PERCENT
end
local function bonfireRequirementForLevel(level)
    -- Mirrors the place's Bonfire.GetNextBonfireRequirement():
    -- floor(level * (5 + level^2)). Lv1 = 4, Lv2 = 18.
    return math.floor(level * (5 + level * level))
end
local function getFuelNeeded(spawnIsland)
    if not spawnIsland then return 7 end
    local level, progressPercent = getCampfireState(spawnIsland)
    if campfireTargetReached(spawnIsland) then return 0 end
    if level < TARGET_LEVEL then
        -- Do not merely target "reach Lv2". Target enough raw fuel to reach Lv2
        -- AND at least 12% of its bar in the same drop when a suitable fuel exists.
        local currentRequirement = tonumber(spawnIsland:GetAttribute("ToNextExpansion"))
            or bonfireRequirementForLevel(level)
        local remainCurrent = currentRequirement * ((100 - progressPercent) / 100)
        local targetRequirement = bonfireRequirementForLevel(TARGET_LEVEL)
        local targetRaw = targetRequirement * (MIN_CAMPFIRE_PERCENT / 100)
        return math.max(1, math.ceil(remainCurrent + targetRaw - 1e-6))
    end
    -- At Lv2 compute the actual raw amount for 12%, even when the server does
    -- not replicate ToNextExpansion. This avoids selecting tiny fuel repeatedly.
    local rawRequirement = tonumber(spawnIsland:GetAttribute("ToNextExpansion"))
        or bonfireRequirementForLevel(level)
    local percentNeeded = math.max(0, MIN_CAMPFIRE_PERCENT - progressPercent)
    return math.max(1, math.ceil(rawRequirement * (percentNeeded / 100) - 1e-6))
end
local function chooseFuelPlan(items, needed)
    if needed <= 0 or #items == 0 then return {} end
    local nearestDistance = items[1].distance or math.huge
    local localLimit = nearestDistance + FUEL_NEARBY_WINDOW
    local candidates = {}
    for _, item in ipairs(items) do
        if (item.distance or math.huge) > localLimit then break end
        table.insert(candidates, item)
    end
    -- Fastest case: one nearby fuel can finish the entire remaining target.
    -- Among those, choose the nearest one so we avoid a pointless long teleport.
    local finishers = {}
    for _, item in ipairs(candidates) do
        if (item.value or 0) >= needed then
            table.insert(finishers, item)
        end
    end
    if #finishers > 0 then
        table.sort(finishers, function(a, b)
            if math.abs(a.distance - b.distance) < 0.01 then return a.value > b.value end
            return a.distance < b.distance
        end)
        return {finishers[1]}
    end
    -- If no single fuel is enough, prefer the biggest fillers inside the local
    -- window. This minimizes total AttemptDrag/drop cycles.
    table.sort(candidates, function(a, b)
        if a.value == b.value then return a.distance < b.distance end
        return a.value > b.value
    end)
    while #candidates > FUEL_CANDIDATE_LIMIT do
        table.remove(candidates)
    end
    return candidates
end
-- DROP-RELEASE-ACK fuel path:
-- 1) teleport beside a nearby fuel,
-- 2) request the same AttemptDrag ownership used by the real DragSystem,
-- 3) stage the fuel just ABOVE Dropper while still owned,
-- 4) release ownership with a short downward velocity (normal "drop" semantics),
-- 5) only AFTER releasing wait for Level/Progress acknowledgement.
-- This mirrors the game's real drag flow better than holding ownership while
-- waiting for the bonfire to accept the item.
-- 1) teleport beside the fuel,
-- 2) request DragSystem/network ownership,
-- v16 primary path: character only approaches the fuel for AttemptDrag; after
-- ownership is granted, only the fuel assembly is moved to SpawnIsland.Dropper.
local function requestFuelSimulationRadius()
    if typeof(setsimulationradius) == "function" then
        pcall(function()
            setsimulationradius(10000)
        end)
        return
    end
    if typeof(sethiddenproperty) == "function" then
        local localPlayer = game.Players.LocalPlayer
        pcall(function()
            sethiddenproperty(localPlayer, "SimulationRadius", 10000)
        end)
        pcall(function()
            sethiddenproperty(localPlayer, "MaximumSimulationRadius", 10000)
        end)
    end
end
local function getFuelTargetCFrame(dropper)
    if not dropper then return nil end
    if dropper:IsA("BasePart") then return dropper.CFrame end
    local ok, cf = pcall(function() return dropper:GetPivot() end)
    return ok and cf or nil
end
local function getAllFuelParts(model, primaryPart)
    local parts = {}
    local seen = setmetatable({}, {__mode = "k"})
    local function add(part)
        if part and part:IsA("BasePart") and not seen[part] then
            seen[part] = true
            table.insert(parts, part)
        end
    end
    add(primaryPart)
    if model and model:IsA("Model") then
        for _, descendant in ipairs(model:GetDescendants()) do
            add(descendant)
        end
    end
    return parts
end
local function zeroFuelVelocity(item)
    -- Hot path: touching every descendant on every retry is expensive. The
    -- assembly root velocity is enough for a welded/connected fuel object.
    if not (item and item.part and item.part:IsA("BasePart")) then return end
    local part = item.part
    local ok, root = pcall(function() return part.AssemblyRootPart end)
    if ok and root then part = root end
    pcall(function()
        part.AssemblyLinearVelocity = Vector3.zero
        part.AssemblyAngularVelocity = Vector3.zero
    end)
end
local function getOwnershipPart(part)
    if not (part and part:IsA("BasePart")) then return part end
    local ok, root = pcall(function() return part.AssemblyRootPart end)
    return ok and root or part
end
local function clientOwnsFuel(part)
    if typeof(isnetworkowner) ~= "function" then
        return nil
    end
    local ownershipPart = getOwnershipPart(part)
    local ok, owned = pcall(isnetworkowner, ownershipPart)
    if not ok then return nil end
    return owned == true
end
local function attemptDragServer(dragNetwork, part)
    if not dragNetwork then return false, "no-network" end
    local ok, granted = pcall(function()
        return dragNetwork:InvokeServer("AttemptDrag", part)
    end)
    if not ok then return false, "invoke-error" end
    -- Important: pcall=true does NOT mean ownership was granted. The game's
    -- DragSystem itself aborts unless InvokeServer returns truthy.
    if not granted then return false, "server-denied" end
    return true, "granted"
end
local function getDragPartCandidates(item)
    local parts = {}
    local seen = setmetatable({}, {__mode = "k"})
    local function add(part)
        if #parts >= 3 then return end
        if part and part:IsA("BasePart") and part:IsDescendantOf(workspace) and not seen[part] then
            seen[part] = true
            table.insert(parts, part)
        end
    end
    -- The working old build used PrimaryPart. Try the known item part first,
    -- then the assembly root, then PrimaryPart. Avoid scanning every descendant.
    add(item.part)
    if item.part and item.part:IsA("BasePart") then
        local ok, root = pcall(function() return item.part.AssemblyRootPart end)
        if ok then add(root) end
    end
    if item.model and item.model:IsA("Model") then
        add(item.model.PrimaryPart)
    end
    return parts
end
local function acquireFuelOwnership(item, dragNetwork)
    if not (item and item.model and item.part and item.part:IsDescendantOf(workspace)) then
        return false
    end
    requestFuelSimulationRadius()
    local RunService = game:GetService("RunService")
    local candidates = getDragPartCandidates(item)
    local lastReason = "server-denied"
    for candidateIndex, candidatePart in ipairs(candidates) do
        if not item.model:IsDescendantOf(workspace) then return false end
        if not candidatePart:IsDescendantOf(workspace) then continue end
        item.part = candidatePart
        -- FAST-GRAB: move close enough for the server's distance validation, give
        -- that position exactly one Heartbeat to replicate, then invoke immediately.
        -- No 55-180 ms sleep and no ownership polling on the successful path.
        local pos = candidatePart.Position
        local approachPos = pos + Vector3.new(0, 2.0, 1.8)
        local flatTarget = Vector3.new(pos.X, approachPos.Y, pos.Z)
        if not teleportCharacter(CFrame.lookAt(approachPos, flatTarget)) then return false end
        zeroFuelVelocity(item)
        RunService.Heartbeat:Wait()
        -- kill any post-teleport momentum Roblox reintroduced during the heartbeat
        local root = getRootPart()
        if root then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
        if clientOwnsFuel(candidatePart) == true then
            state.fuelRetryAfter[item.model] = nil
            return true
        end
        for quickTry = 1, FUEL_ACQUIRE_RETRIES do
            local granted, reason = attemptDragServer(dragNetwork, candidatePart)
            state.fuelOwnershipAttempted[item.model] = true
            lastReason = reason
            if granted then
                -- InvokeServer truthy is the authoritative grant. Move the object now;
                -- waiting for isnetworkowner() to catch up only slowed the farm down.
                state.fuelRetryAfter[item.model] = nil
                return true
            end
            -- A denial can simply mean the teleport has not replicated on the server
            -- yet. One extra Heartbeat is the only retry delay we pay.
            if quickTry < FUEL_ACQUIRE_RETRIES then
                RunService.Heartbeat:Wait()
            end
        end
        state.fuelStatus = string.format("Fast grab fallback %d/%d (%s)", candidateIndex, #candidates, lastReason)
    end
    state.fuelRetryAfter[item.model] = os.clock() + FUEL_FAILED_COOLDOWN
    return false
end
local function setFuelPartCFrame(item, desiredPartCF)
    if not (item and item.model and item.part and desiredPartCF) then return false end
    return pcall(function()
        if item.model:IsA("Model") then
            -- Pivot the MODEL so the actual dragged PART lands exactly on the
            -- Dropper. PivotTo(desiredCF) alone can miss when model pivot is offset.
            local pivot = item.model:GetPivot()
            local relative = pivot:ToObjectSpace(item.part.CFrame)
            item.model:PivotTo(desiredPartCF * relative:Inverse())
        else
            item.part.CFrame = desiredPartCF
        end
    end)
end
local function stageOwnedFuelAboveDropper(item, targetCF, dropper)
    if not (targetCF and item.model and item.part) then return false end
    if not item.model:IsDescendantOf(workspace) or not item.part:IsDescendantOf(workspace) then return false end
    -- FAST DROP: two replicated positions are enough: first directly over the
    -- trigger, then slightly through it. v17 used three positions plus sleeps.
    local halfDropY = 0.8
    local halfFuelY = math.min(item.part.Size.Y * 0.5, 1.6)
    if dropper and dropper:IsA("BasePart") then
        halfDropY = dropper.Size.Y * 0.5
    end
    local RunService = game:GetService("RunService")
    local above = targetCF * CFrame.new(0, halfDropY + halfFuelY + 0.12, 0)
    local through = targetCF * CFrame.new(0, -math.max(0.10, halfDropY * 0.15), 0)
    if not setFuelPartCFrame(item, above) then return false end
    zeroFuelVelocity(item)
    RunService.Heartbeat:Wait()
    if not item.model:IsDescendantOf(workspace) or not item.part:IsDescendantOf(workspace) then return true end
    if not setFuelPartCFrame(item, through) then return false end
    zeroFuelVelocity(item)
    RunService.Heartbeat:Wait()
    return true
end
local function fuelWasAcknowledged(item, spawnIsland, beforeLevel, beforeProgress)
    if not item.model or not item.model:IsDescendantOf(workspace) then return true end
    if not item.part or not item.part:IsDescendantOf(workspace) then return true end
    if item.model:GetAttribute("Dead") then return true end
    if not spawnIsland or not spawnIsland:IsDescendantOf(workspace) then return false end
    local level = spawnIsland:GetAttribute("Level") or beforeLevel
    local progress = tonumber(spawnIsland:GetAttribute("Progress")) or beforeProgress
    if level > beforeLevel then return true end
    if progress > beforeProgress then return true end
    return false
end
local function waitForFuelAcknowledgement(item, spawnIsland, beforeLevel, beforeProgress, timeout)
    timeout = timeout or FUEL_ACK_TIMEOUT
    local startedAt = os.clock()
    while os.clock() - startedAt < timeout do
        if fuelWasAcknowledged(item, spawnIsland, beforeLevel, beforeProgress) then
            return true
        end
        task.wait(0.012)
    end
    return fuelWasAcknowledged(item, spawnIsland, beforeLevel, beforeProgress)
end
local function releaseFuelOwnership(item, dragNetwork, velocity)
    if not dragNetwork or not item or not item.part or not item.part:IsDescendantOf(workspace) then return false end
    velocity = velocity or Vector3.zero
    pcall(function()
        item.part.AssemblyLinearVelocity = velocity
    end)
    local ok = pcall(function()
        dragNetwork:FireServer("GiveUpOwnership", item.part, velocity)
    end)
    return ok
end
local function haulFuelToDropper(dropper)
    local spawnIsland = workspace:FindFirstChild("SpawnIsland")
    if not spawnIsland or campfireTargetReached(spawnIsland) then return end
    local items = getFuelItems()
    if #items == 0 then
        clearFuelHighlight()
        local scan = state.lastFuelScan or {}
        state.fuelStatus = string.format("No usable fuel (debris:%s usable:%s) - rescanning",
            tostring(scan.debris or 0), tostring(scan.usable or 0))
        task.wait(0.08)
        return
    end
    local targetCF = getFuelTargetCFrame(dropper)
    if not targetCF then
        state.fuelStatus = "Dropper not found; retrying..."
        task.wait(0.12)
        return
    end
    local okNetwork, dragNetwork = pcall(function()
        return require(game.ReplicatedStorage.Modules.Systems.DragSystem).Network
    end)
    if not okNetwork or not dragNetwork then
        state.fuelStatus = "Drag network unavailable"
        task.wait(0.15)
        return
    end
    local needed = getFuelNeeded(spawnIsland)
    local plan = chooseFuelPlan(items, needed)
    if #plan == 0 then
        state.fuelStatus = "No usable local fuel; rescanning..."
        task.wait(0.10)
        return
    end
    local burstDrops = 0
    local burstStartLevel, burstStartProgress = getCampfireState(spawnIsland)
    for index, item in ipairs(plan) do
        if campfireTargetReached(spawnIsland) then break end
        if burstDrops >= FUEL_BURST_LIMIT then break end
        if not item.model:IsDescendantOf(workspace) or not item.part:IsDescendantOf(workspace) then continue end
        local beforeLevel, beforeProgress = getCampfireState(spawnIsland)
        state.fuelStatus = string.format("FAST FILL %d/%d: %s | %.0f studs | +%s",
            index, #plan, item.model.Name, item.distance or 0, tostring(item.value))
        if not acquireFuelOwnership(item, dragNetwork) then
            state.fuelRetryAfter[item.model] = os.clock() + FUEL_FAILED_COOLDOWN
            continue
        end
        state.fuelStatus = "GRABBED -> direct Dropper"
        if not stageOwnedFuelAboveDropper(item, targetCF, dropper) then
            releaseFuelOwnership(item, dragNetwork, Vector3.zero)
            state.fuelRetryAfter[item.model] = os.clock() + FUEL_FAILED_COOLDOWN
            continue
        end
        releaseFuelOwnership(item, dragNetwork, Vector3.new(0, -FUEL_DROP_SPEED, 0))
        burstDrops += 1
        task.wait(FUEL_REPLICATION_HOLD)
        -- Only a very short ACK check on each item. If attribute replication is
        -- late, immediately pipeline the next nearby high-value fuel instead of
        -- blocking for ~0.5 s. Overshooting 12% is intentionally acceptable.
        local quickAck = waitForFuelAcknowledgement(item, spawnIsland, beforeLevel, beforeProgress, FUEL_QUICK_ACK)
        if quickAck then
            state.fuelRetryAfter[item.model] = nil
        else
            state.fuelRetryAfter[item.model] = os.clock() + FUEL_FAILED_COOLDOWN
        end
        if campfireTargetReached(spawnIsland) then break end
    end
    -- One short synchronization point for the whole burst, not one long wait per
    -- fuel. This is where late server Progress replication is allowed to catch up.
    if burstDrops > 0 and not campfireTargetReached(spawnIsland) then
        local startedAt = os.clock()
        while os.clock() - startedAt < FUEL_ACK_TIMEOUT do
            if campfireTargetReached(spawnIsland) then break end
            local levelNow, progressNow = getCampfireState(spawnIsland)
            if levelNow ~= burstStartLevel or progressNow ~= burstStartProgress then break end
            task.wait(0.012)
        end
    end
    clearFuelHighlight()
    local finalLevel, finalProgress = getCampfireState(spawnIsland)
    if campfireTargetReached(spawnIsland) then
        state.fuelStatus = string.format("Campfire ready: Lv%d %.0f%% -> next method", finalLevel, finalProgress)
    else
        state.fuelStatus = string.format("Campfire Lv%d %.0f%% -> fast fill continues", finalLevel, finalProgress)
    end
end
local function farmNearestChest()
    local _, open = pcall(function()
        return debug.getupvalue(getrenv()._G.OpenChest, 1)
    end)
    if not open then return end
    local localPlayer = game.Players.LocalPlayer
    local chests = {}
    for _, m in ipairs(game:GetService("CollectionService"):GetTagged("Chest")) do
        local pp = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
        if pp and m:IsDescendantOf(workspace)
            and not (m:GetAttribute("Opened" .. localPlayer.Name) or false)
            and not m:FindFirstAncestor("VendingMachine") then
            table.insert(chests, {model = m, pp = pp})
        end
    end
    if #chests == 0 then task.wait(3) return end
    local rootPart = getRootPart()
    local hp = rootPart and rootPart.Position or Vector3.zero
    table.sort(chests, function(a, b)
        return (a.pp.Position - hp).Magnitude < (b.pp.Position - hp).Magnitude
    end)
    local e = chests[1]
    if not teleportCharacter(CFrame.new(e.pp.Position + Vector3.new(0, 3, 0))) then task.wait(1) return end
    task.wait(0.12)
    pcall(function() open:InvokeServer("OpenChest", e.model) end)
end
local function isPassiveCreature(name)
    for _, p in ipairs(PASSIVE) do
        if name:find(p, 1, true) then return true end
    end
    return false
end
local function isRaidActive()
    if workspace:GetAttribute("RaidActive") then return true end
    local clockTime = game.Lighting.ClockTime
    return clockTime >= 18.5 or clockTime < 5.5
end
local function getHomePosition()
    local bonfire = workspace.SpawnIsland:FindFirstChild("Bonfire") or workspace.SpawnIsland:FindFirstChild("Dropper")
    if bonfire then
        local ok, p = pcall(function() return bonfire:GetPivot().Position end)
        if ok then return p end
    end
    return Vector3.new(256, 150, -256)
end
local function findNearbyRaiders(home)
    if not isRaidActive() then return {} end
    local out = {}
    for _, name in ipairs({"CreatureContainer", "Creatures"}) do
        local f = workspace:FindFirstChild(name)
        if f then
            for _, m in ipairs(f:GetChildren()) do
                if m:IsA("Model") and not m:GetAttribute("Dead") and not isPassiveCreature(m.Name) then
                    local ok, p = pcall(function() return m:GetPivot().Position end)
                    if ok and p and (p - home).Magnitude <= DEFENSE_RADIUS then
                        table.insert(out, {m = m, p = p})
                    end
                end
            end
        end
    end
    return out
end
local function defendBase(raiders)
    local localPlayer = game.Players.LocalPlayer
    local hum = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    if not localPlayer.Character:FindFirstChild("Hatchet") then
        local h = localPlayer.Backpack:FindFirstChild("Hatchet")
        if h then
            hum:EquipTool(h)
            task.wait(0.25)
        end
    end
    for i, r in ipairs(raiders) do
        if not r.m:IsDescendantOf(workspace) or r.m:GetAttribute("Dead") then continue end
        local ok, p = pcall(function() return r.m:GetPivot().Position end)
        if not (ok and p) then continue end
        teleportCharacter(CFrame.new(p + Vector3.new(0, 1.5, 0)))
        task.wait(0.18)
        local t = localPlayer.Character and localPlayer.Character:FindFirstChild("Hatchet")
        if t and i % 2 == 0 then
            pcall(function() t:Activate() end)
            task.delay(0.12, function() pcall(function() t:Deactivate() end) end)
        end
        if i >= 4 then break end
    end
end
local function merchantBoatExists()
    return workspace:FindFirstChild("MerchantBoat") ~= nil
end
local function tryPurchasePearls()
    local localPlayer = game.Players.LocalPlayer
    if state.bought then return true end
    local boat = workspace:FindFirstChild("MerchantBoat")
    if not boat then return false end
    if (localPlayer:GetAttribute("Doubloons") or 0) < PEARL_MIN then
        farmNearestChest()
        return false
    end
    local pos
    local pad = boat:FindFirstChild("SellPad")
    if pad and pad:FindFirstChild("Spawner") then
        pos = pad.Spawner.Position
    else
        local ok, p = pcall(function() return boat:GetPivot().Position end)
        pos = ok and p or nil
    end
    if not pos then return false end
    local before = localPlayer:GetAttribute("Pearls") or 0
    teleportCharacter(CFrame.new(pos + Vector3.new(0, 5, 6)))
    task.wait(0.4)
    local ok, res = pcall(function()
        return getrenv()._G.MerchantShopPurchase("Pearls", pos)
    end)
    log("merchant buy:", tostring(ok), tostring(res))
    task.wait(0.8)
    if (ok and res == true) or (localPlayer:GetAttribute("Pearls") or 0) > before then
        state.bought = true
        log("PEARLS PURCHASED! total=" .. tostring(localPlayer:GetAttribute("Pearls")) .. " -> leaving to lobby")
        task.wait(1.5)
        pcall(function() getrenv()._G.LeaveGame() end)
        return true
    end
    return false
end
---------------------------------------------------------------------
disableCutscenes()
do
    local initialIsland = workspace:FindFirstChild("SpawnIsland")
    log("v19 STABLE BURST-FILL campfire-12 pearl farm started L=" .. tostring(initialIsland and initialIsland:GetAttribute("Level") or "?")
        .. " D=" .. tostring(game.Players.LocalPlayer:GetAttribute("Doubloons")))
end
task.spawn(function()
    while state.running ~= false and not state.bought do
        local okLoop, err = pcall(function()
            disableCutscenes()
            if not isIslandSessionAlive() then task.wait(2) return end
            local localPlayer = game.Players.LocalPlayer
            local spawnIsland = workspace:FindFirstChild("SpawnIsland")
            if not spawnIsland then task.wait(2) return end
            local level = spawnIsland:GetAttribute("Level") or 1
            local doubloons = localPlayer:GetAttribute("Doubloons") or 0
            local home = getHomePosition()
            local campfireReady = campfireTargetReached(spawnIsland)
            if campfireReady then
                clearFuelHighlight()
                state.fuelStatus = nil
            end
            tryPurchasePearls()
            if state.bought then error("__DONE__") end
            local raiders = findNearbyRaiders(home)
            if #raiders > 0 then
                defendBase(raiders)
            elseif not campfireReady and spawnIsland:FindFirstChild("Dropper") then
                haulFuelToDropper(spawnIsland.Dropper)
                task.wait(0.03)
            elseif doubloons < FARM_TARGET or (merchantBoatExists() and doubloons < PEARL_MIN) then
                farmNearestChest()
            else
                local rootPart = getRootPart()
                if rootPart and (rootPart.Position - home).Magnitude > 200 then
                    teleportCharacter(CFrame.new(home + Vector3.new(12, 3, 0)))
                end
                task.wait(2)
            end
        end)
        if not okLoop then
            if err == "__DONE__" then break end
            log("iter err: " .. tostring(err))
            task.wait(2)
        end
    end
    if state.bought then
        log("round complete -> returning to lobby")
        task.wait(2)
        local startedAt = os.clock()
        while isIslandSessionAlive() and os.clock() - startedAt < 45 do
            pcall(function() getrenv()._G.LeaveGame() end)
            task.wait(6)
        end
        if isIslandSessionAlive() then returnToLobby("leave never fired") end
    end
end)
