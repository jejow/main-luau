-- Farm Pearl v23: Bonfire -> Volcano -> 500 Doubloons -> Base -> Pearl.
local Settings = {
    ISLAND_PLACE = 139802517550914,
    LOBBY_PLACE = 70411440483149,
    GAME_DELAY = 10,
    TARGET_LEVEL = 2,
    MIN_CAMPFIRE_PERCENT = 20,
    FARM_TARGET = 500,
    PEARL_MIN = 500,
    PEARL_QUANTITY = 10,
    DEFENSE_RADIUS = 120,
    DEFENSE_CLEAR_SECONDS = 3,
    SAFE_COMBAT_COOLDOWN = 0.4,
    AUTO_EXECUTE_FILE = "farm pearl.txt",
    CUSTOM_SEED = "123456789",
    MAGMA_GOLEM_TARGET = 3,
    DROP_TELEPORT_INTERVAL = 0.3,
    VOLCANO_DROP_HEIGHT = 6,
    VOLCANO_FLY_SPEED = 115,
    VOLCANO_NO_DAMAGE_TIMEOUT = 45,
    TELEPORT_REACH_RADIUS = 8,
    WORLD_SCAN_SAFE_MIN_Y = 178,
    VOLCANO_DROP_PROTOCOL_VERSION = 10,
    STREAM_REQUEST_TIMEOUT = 1.35,
    PASSIVE = {"Seagull", "Crab", "_CLIENT", "Companion"},
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

-- Robust bootstrap for executor auto-execute / teleport reinjection.
pcall(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
end)

local player = Players.LocalPlayer
while not player do
    task.wait(0.05)
    player = Players.LocalPlayer
end
local env = getgenv()
env.__sf = env.__sf or {}
local state: any = env.__sf
-- Release the previous run before a new worker can acquire the same character.
if type(state.cleanup) == "function" then
    pcall(state.cleanup)
end
state.retryAfter = type(state.retryAfter) == "table" and state.retryAfter or setmetatable({}, {__mode = "k"})
state.running = true
state.volcanoHoverActive = false
local runToken = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1000000000))
state.runToken = runToken

local function isRunning()
    return state.running ~= false and state.runToken == runToken
end

-- Same file/getgenv persistence pattern as the existing metrics/config systems.
local Preferences = (function()
    local api = {}
    local path = "SeaPearl_settings_v1_" .. tostring(player.UserId) .. ".json"
    local saved = state.preferences
    if type(saved) ~= "table" and type(readfile) == "function" then
        pcall(function() saved = game:GetService("HttpService"):JSONDecode(readfile(path)) end)
    end
    saved = type(saved) == "table" and saved or {}
    function api.SetGameDelay(value)
        local seconds = tonumber(value)
        if not seconds or seconds ~= seconds or math.abs(seconds) == math.huge then return false end
        Settings.GAME_DELAY = math.clamp(math.floor(seconds), 0, 300)
        saved.GameDelay, state.preferences = Settings.GAME_DELAY, saved
        if type(writefile) == "function" then
            pcall(function() writefile(path, game:GetService("HttpService"):JSONEncode(saved)) end)
        end
        return true
    end
    api.SetGameDelay(saved.GameDelay or Settings.GAME_DELAY)
    return api
end)()

-- Metrics count observed rewards only. They survive reinjection through __sf;
-- file support additionally carries the counters across lobby teleports.
local Metrics = (function()
    local api: any = {}
    local path = "SeaPearl_metrics_v1_" .. tostring(player.UserId) .. ".json"
    local data: any = state.metrics
    if type(data) ~= "table" and type(readfile) == "function" then
        pcall(function()
            data = game:GetService("HttpService"):JSONDecode(readfile(path))
        end)
    end
    if type(data) ~= "table" or data.version ~= 1 then data = {version = 1} end
    for _, key in ipairs({"seconds", "completed", "failed", "pearls", "timeouts", "recoveries",
        "dropsSent", "dropsBlocked", "fuelConfirmed", "golemsConfirmed", "chestsOpened", "roundSeconds"}) do
        local value = tonumber(data[key])
        data[key] = value and value == value and value >= 0 and value < 1e12 and value or 0
    end
    data.phases = type(data.phases) == "table" and data.phases or {}
    data.recent = type(data.recent) == "table" and data.recent or {}
    while #data.recent > 10 do table.remove(data.recent, 1) end
    state.metrics = data
    local lastTick, lastSave = os.clock(), os.clock()
    local phase = "Loading"
    local activeJob: any = nil

    function api.Save()
        if type(writefile) == "function" then
            pcall(function()
                writefile(path, game:GetService("HttpService"):JSONEncode(data))
            end)
        end
        lastSave = os.clock()
    end
    function api.Tick()
        local now = os.clock()
        local elapsed = math.max(0, now - lastTick)
        lastTick = now
        data.seconds += elapsed
        data.phases[phase] = (tonumber(data.phases[phase]) or 0) + elapsed
        if type(data.round) == "table" and not data.round.finished then
            data.round.seconds = (tonumber(data.round.seconds) or 0) + elapsed
            data.round.phases = type(data.round.phases) == "table" and data.round.phases or {}
            data.round.phases[phase] = (tonumber(data.round.phases[phase]) or 0) + elapsed
        end
        if now - lastSave >= 10 then api.Save() end
    end
    function api.Phase(name)
        if phase == name then return end
        api.Tick()
        phase = name
    end
    function api.Add(key, count)
        if type(data[key]) == "number" then data[key] += count or 1 end
    end
    local function finish(success, reward)
        local round = data.round
        if type(round) ~= "table" or round.finished then return false end
        api.Tick()
        round.finished, round.success = true, success
        if success then
            data.completed += 1
            data.pearls += reward
            data.roundSeconds += round.seconds
        else
            data.failed += 1
        end
        data.recent[#data.recent + 1] = {job = round.job, success = success,
            seconds = round.seconds, pearls = reward, endedAt = os.time(), phases = round.phases}
        while #data.recent > 10 do table.remove(data.recent, 1) end
        api.Save()
        return true
    end
    function api.Bind(kind)
        activeJob = kind == "island" and game.JobId or nil
        local round = data.round
        if type(round) == "table" and not round.finished
            and (kind == "lobby" or round.job ~= activeJob) then
            -- A late replicated reward after teleport can complete only an already
            -- acknowledged purchase, never an arbitrary change in the wallet.
            local balance = tonumber(player:GetAttribute("Pearls"))
            local baseline = tonumber(round.purchaseBaseline)
            if round.purchaseAccepted == true and round.volcanoDone == true
                and balance and baseline and balance - baseline >= Settings.PEARL_QUANTITY then
                finish(true, balance - baseline)
            else
                finish(false, 0)
            end
        end
        if kind == "island" and (type(data.round) ~= "table" or data.round.job ~= activeJob) then
            data.round = {job = activeJob, seconds = 0, phases = {}, finished = false}
            api.Save()
        end
        api.Phase(kind == "lobby" and "Lobby" or "Volcano")
    end
    function api.Purchase(baseline, accepted)
        local round = data.round
        if type(round) ~= "table" or round.job ~= activeJob or round.finished then return end
        local changed = round.purchaseBaseline ~= baseline
            or (accepted == true and round.purchaseAccepted ~= true)
        if round.purchaseAccepted ~= true then round.purchaseBaseline = baseline end
        round.purchaseAccepted = round.purchaseAccepted == true or accepted == true
        round.volcanoDone = state.volcano and state.volcano.bossDefeated == true
        if changed then api.Save() end
    end
    function api.Complete(baseline)
        local round = data.round
        local balance = tonumber(player:GetAttribute("Pearls"))
        if type(round) ~= "table" or round.job ~= activeJob
            or not state.volcano or state.volcano.bossDefeated ~= true
            or round.purchaseAccepted ~= true or not balance or not baseline
            or balance - baseline < Settings.PEARL_QUANTITY then
            return false
        end
        if round.finished then return round.success == true end
        return finish(true, balance - baseline)
    end
    function api.Report()
        local ended = data.completed + data.failed
        local round = type(data.round) == "table" and data.round or {}
        local phases = type(round.phases) == "table" and round.phases or data.phases
        return {
            pearls = data.pearls, perHour = data.seconds >= 1 and data.pearls * 3600 / data.seconds or 0,
            completed = data.completed, failed = data.failed,
            success = ended > 0 and 100 * data.completed / ended or nil,
            average = data.completed > 0 and data.roundSeconds / data.completed or 0,
            phase = phase, phaseSeconds = tonumber(phases[phase]) or 0,
            roundSeconds = type(data.round) == "table" and data.round.seconds or 0,
            timeouts = data.timeouts, recoveries = data.recoveries,
            dropsSent = data.dropsSent, dropsBlocked = data.dropsBlocked,
            fuelConfirmed = data.fuelConfirmed, golemsConfirmed = data.golemsConfirmed,
            chestsOpened = data.chestsOpened,
        }
    end
    return api
end)()

-- A pcall does not protect the controller from a RemoteFunction that yields
-- forever. Keep every state-critical InvokeServer bounded so one saturated
-- server cannot stop all later teleport, scan, and recovery pulses.
state.boundedInvocations = type(state.boundedInvocations) == "table"
    and state.boundedInvocations or setmetatable({}, {__mode = "k"})
state.invokeBounded = function(timeoutSeconds, callback, requestKey)
    if type(callback) ~= "function" then
        return false, nil, "invalid-callback"
    end
    if not isRunning() then return false, nil, "stopped" end
    local registry: any = state.boundedInvocations
    local result: any = requestKey ~= nil and registry[requestKey] or nil
    if type(result) ~= "table" then
        result = {done = false, ok = false, value = nil}
        if requestKey ~= nil then
            registry[requestKey] = result
        end
        task.spawn(function()
            if isRunning() then result.ok, result.value = pcall(callback) end
            result.done = true
        end)
    end
    local deadline = os.clock() + math.max(0.1, tonumber(timeoutSeconds) or 1)
    repeat
        if result.done then
            if requestKey ~= nil and registry[requestKey] == result then
                registry[requestKey] = nil
            end
            return result.ok == true, result.value,
                result.ok == true and "complete" or tostring(result.value)
        end
        task.wait(0.025)
    until not isRunning() or os.clock() >= deadline
    if isRunning() then Metrics.Add("timeouts") end
    return false, nil, isRunning() and "timeout" or "stopped"
end

state.fuelInSack = tonumber(state.fuelInSack) or 0

local jobId = game.JobId ~= "" and game.JobId or tostring(math.random(1, 1000000000))
if state.lastJobId ~= jobId then
    state.lastJobId = jobId
    state.bought = false
    state.retryAfter = setmetatable({}, {__mode = "k"})
    state.fuelInSack = 0
    state.toolProcessor = nil
    state.volcano = nil
    state.phase = nil
    state.homePosition = nil
    state.farmWorldCursor = 0
    state.lastError = nil
    state.lastErrorAt = nil
    state.errorCount = 0
    state.purchase = nil
    state.pendingFuelDrop = nil
    state.pendingStore = nil
    state.farmRoute = nil
    state.nextFarmWorldScanAt = nil
    state.streamPool, state.chestPool = nil, nil
    state.pearlFlow = nil
    state.fuelDeliveryLease = nil
    state.fuelBatch = nil
    state.lastForce = nil
    state.teleportQueued = nil
    state.boundedInvocations = setmetatable({}, {__mode = "k"})
end

-- Persist only observed milestones within this map. Each new JobId gets a fresh delay.
local Flow = (function()
    local api: any = {}
    api.steps = {
        "Game Delay", "Fuel / Lv.2 + " .. Settings.MIN_CAMPFIRE_PERCENT .. "%",
        "Magma Golem + pickup", "Volcano delivery", "Golem Boss",
        "Chests / " .. Settings.FARM_TARGET .. " Doubloons",
        "Return / Defend Base", "Merchant / Pearl", "Return to Lobby",
    }
    local data = type(state.pearlFlow) == "table" and state.pearlFlow or {}
    if data.version ~= 20 then
        -- Fresh maps start with Bonfire. Reinjection preserves an actual purchase,
        -- completed boss, or carried golems instead of dropping those at Bonfire.
        local ritual = state.volcano
        data.version, data.step = 20, 1
        data.stage = "fuel"
        if ritual and ritual.bossDefeated == true then
            data.stage = state.purchase and "merchant" or "chests"
        elseif ritual and ((tonumber(ritual.held) or 0) > 0
            or (tonumber(ritual.delivered) or 0) > 0 or ritual.bossSeen
            or ritual.dropTransaction or ritual.pendingCorpse
            or (state.pendingStore and state.pendingStore.kind == "golem")) then
            data.stage = "volcano"
        elseif state.pendingFuelDrop or state.fuelBatch then
            data.stage = "fuel"
        elseif data.initialBonfireReady == true and data.sackCleared == true then
            data.stage = "volcano"
        end
        data.defenseSeen, data.defenseDone = data.defenseSeen == true, data.defenseDone == true
    end
    data.stage = data.stage or "fuel"
    state.pearlFlow, api.data = data, data
    function api.Set(step, message)
        api.data.step = step
        if message then state.phase = message end
        Metrics.Phase(api.steps[step] or "Lobby")
    end
    return api
end)()

state.volcano = type(state.volcano) == "table" and state.volcano or {
    stored = 0,
    delivered = 0,
    bossSeen = false,
    bossDefeated = false,
    completed = false,
    nextDirectStreamAt = 0,
    nextBasaltStreamAt = 0,
}
-- Older revisions counted a successful Sack decrement as a successful Volcano
-- sacrifice. That can leave delivered=3 even though DropPoint accepted nothing.
if tonumber(state.volcano.dropProtocolVersion) ~= Settings.VOLCANO_DROP_PROTOCOL_VERSION then
    -- A completion flag from older revisions may have come from boss visibility
    -- or an unacknowledged Sack decrement. Preserve completion only when this
    -- revision has explicit evidence that the boss fight itself finished.
    if state.volcano.bossDefeated ~= true then
        state.volcano.delivered = 0
        state.volcano.bossSeen = false
        state.volcano.bossDefeated = false
        state.volcano.completed = false
    end
    state.volcano.pendingDrop = nil
    state.volcano.pendingDropEvidence = nil
    state.volcano.firstDropPrepared = nil
    state.volcano.firstDropActivationTried = nil
    state.volcano.firstDropWaitStartedAt = nil
    state.volcano.fallbackDropVerified = nil
    state.volcano.sackBaseline = nil
    state.volcano.emptySince = nil
    state.volcano.held = 0
    state.volcano.submitted = 0
    state.volcano.receipts = {}
    state.volcano.dropTransaction = nil
    state.volcano.dropProtocolVersion = Settings.VOLCANO_DROP_PROTOCOL_VERSION
end

local function getCharacter(): any
    local current = Players.LocalPlayer
    if current and current.Parent then
        player = current
    end
    return player and player.Character
end

local function getRoot(): any
    local character = getCharacter()
    return character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart) or nil
end

local function getHumanoid(): any
    local character = getCharacter()
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local teleportRevision = 0
local streamPool: any = type(state.streamPool) == "table" and state.streamPool
    or {inFlight = 0, serial = 0, recent = {}}
state.streamPool = streamPool
local recentStreamRequests: {[string]: number} = streamPool.recent

local function requestStreamNear(position: any): boolean
    if not isRunning() or typeof(position) ~= "Vector3" or streamPool.inFlight >= 2 then
        return false
    end

    local key = string.format("%.0f:%.0f", position.X / 40, position.Z / 40)
    local now = os.clock()
    if now - (recentStreamRequests[key] or 0) < 0.25 then
        return true
    end
    recentStreamRequests[key] = now

    streamPool.inFlight += 1
    streamPool.serial += 1
    local requestId = streamPool.serial
    local released = false
    local function releaseSlot()
        if released then
            return
        end
        released = true
        streamPool.inFlight = math.max(0, streamPool.inFlight - 1)
    end

    -- A timeout ends our wait, not the actual engine call. Keep the real slot
    -- occupied until completion so a stalled provider cannot accumulate requests.
    task.delay(Settings.STREAM_REQUEST_TIMEOUT, function()
        if isRunning() and not released and requestId <= streamPool.serial then
            Metrics.Add("timeouts")
        end
    end)
    task.spawn(function()
        pcall(function()
            if isRunning() then player:RequestStreamAroundAsync(position, 0.8) end
        end)
        releaseSlot()
    end)
    return true
end

local function zeroCharacterMotion(character: any)
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            part.AssemblyLinearVelocity = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end
end

local function validTeleportCFrame(cf: any): boolean
    if typeof(cf) ~= "CFrame" then
        return false
    end
    for _, component in ipairs({cf:GetComponents()}) do
        if component ~= component or math.abs(component) == math.huge then
            return false
        end
    end
    return true
end

-- One owner holds character physics through travel AND the delivery receipt.
-- Stability is sampled before correction on distinct Heartbeats. Reading CFrame
-- immediately after assigning it is deliberately never an arrival certificate.
local Motion = (function()
    local api: any = {}
    function api.Close(reason)
        local active = state.motionLease
        if active and type(active.Close) == "function" then active:Close(reason) end
    end
    function api.Begin(cf, options)
        options = options or {}
        if not validTeleportCFrame(cf) or not isRunning() then return nil end
        if state.volcanoHoverContext and state.volcanoHoverContext.close then
            state.volcanoHoverContext.close()
        end
        api.Close("superseded")
        local character, root, humanoid = getCharacter(), getRoot(), getHumanoid()
        if not character or not root or not humanoid or humanoid.Health <= 0
            or character:GetAttribute("Dead") then return nil end
        teleportRevision += 1
        local lease: any = {
            character = character, root = root, humanoid = humanoid, revision = teleportRevision,
            goal = cf, aim = options.aim, sack = options.sack, valid = options.valid,
            drop = options.drop == true, stabilize = options.stabilize == true, anchored = root.Anchored,
            fly = options.fly == true, teleportCount = 0, lastTeleportAt = nil,
            handleHeadroom = options.handleHeadroom,
            autoRotate = humanoid.AutoRotate, platformStand = humanoid.PlatformStand,
            stableSince = nil, samples = 0, lastSampleAt = 0, createdAt = os.clock(),
            collisions = {}, closed = false, reason = "settling",
        }
        state.motionLease = lease
        function lease:Owns()
            return not self.closed and state.motionLease == self and isRunning()
                and self.revision == teleportRevision and getCharacter() == self.character
                and getRoot() == self.root and self.root.Parent ~= nil
                and self.humanoid.Health > 0 and not self.character:GetAttribute("Dead")
        end
        function lease:Close(reason)
            if self.closed then return end
            self.closed, self.reason = true, reason or "finished"
            if self.connection then self.connection:Disconnect() end
            if self.descendantConnection then self.descendantConnection:Disconnect() end
            for _, key in ipairs({"flyOrientation", "flyPosition", "flyAttachment"}) do
                local instance = self[key]
                if instance then pcall(function() instance:Destroy() end); self[key] = nil end
            end
            -- A stale callback may dispose its own connections, never newer physics.
            if state.motionLease ~= self then return end
            state.motionLease = nil
            state.dropHoldActive = false
            state.anchorLeaseRoot = nil
            if self.root.Parent then
                pcall(function()
                    self.root.Anchored = self.anchored
                    zeroCharacterMotion(self.character)
                end)
            end
            if self.humanoid.Parent then
                self.humanoid.AutoRotate = self.autoRotate
                if self.stabilize then
                    self.humanoid.PlatformStand, self.humanoid.Sit = false, false
                    if self.humanoid.Health > 0 then
                        pcall(function() self.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
                    end
                else
                    self.humanoid.PlatformStand = self.platformStand
                    if self.fly and not self.platformStand and self.humanoid.Health > 0 then
                        pcall(function() self.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
                    end
                end
            end
            for part, original in pairs(self.collisions) do
                if part.Parent then pcall(function() part.CanCollide = original end) end
            end
        end
        function lease:SetTarget(destination, aim)
            if not self:Owns() or not validTeleportCFrame(destination) then return false end
            if (self.goal.Position - destination.Position).Magnitude > 0.15
                or (self.goal.LookVector - destination.LookVector).Magnitude > 0.05
                or (aim and self.aim and (aim - self.aim).Magnitude > 0.15) then
                self.stableSince, self.samples = nil, 0
            end
            self.goal, self.aim = destination, aim
            return true
        end
        function lease:StartFly()
            local attachment = Instance.new("Attachment")
            self.flyAttachment = attachment
            attachment.Name = "SeaPearlDropFly"
            attachment.Parent = self.root

            local position = Instance.new("AlignPosition")
            self.flyPosition = position
            position.Name = "SeaPearlDropPosition"
            position.Mode = Enum.PositionAlignmentMode.OneAttachment
            position.Attachment0 = attachment
            position.ApplyAtCenterOfMass = true
            position.RigidityEnabled = false
            position.MaxForce = 1e8
            position.MaxVelocity = 60
            position.Responsiveness = 100
            position.Position = self.goal.Position
            position.Enabled = true
            position.Parent = self.root

            local orientation = Instance.new("AlignOrientation")
            self.flyOrientation = orientation
            orientation.Name = "SeaPearlDropOrientation"
            orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
            orientation.Attachment0 = attachment
            orientation.RigidityEnabled = false
            orientation.MaxTorque = 1e8
            orientation.MaxAngularVelocity = 20
            orientation.Responsiveness = 100
            orientation.CFrame = self.goal
            orientation.Enabled = true
            orientation.Parent = self.root

            self.root.Anchored = false
            self.humanoid.PlatformStand = true
            state.anchorLeaseRoot = nil
        end
        function lease:FlyReady()
            return not self.fly or (self.teleportCount == 2 and not self.root.Anchored
                and self.flyAttachment and self.flyAttachment.Parent == self.root
                and self.flyPosition and self.flyPosition.Parent == self.root and self.flyPosition.Enabled
                and self.flyOrientation and self.flyOrientation.Parent == self.root and self.flyOrientation.Enabled)
        end
        function lease:RawReady()
            if not self:Owns() then return false end
            if self.valid and not self.valid() then self.reason = "target-unavailable"; return false end
            if not self:FlyReady() then self.reason = "fly-not-ready"; return false end
            if (self.root.Position - self.goal.Position).Magnitude > (self.drop and 1.25 or 2)
                or (self.root.CFrame.LookVector - self.goal.LookVector).Magnitude > 0.05
                or ((self.stabilize or self.fly) and self.root.CFrame.UpVector.Y < 0.995)
                or self.root.AssemblyLinearVelocity.Magnitude > 3
                or self.root.AssemblyAngularVelocity.Magnitude > 2 then
                self.reason = "character-moving"
                return false
            end
            if self.drop then
                local handle = self.sack and self.sack:FindFirstChild("Handle")
                if not self.sack or self.sack.Parent ~= self.character or not handle
                    or not handle:IsA("BasePart") or not self.aim then
                    self.reason = "sack-not-ready"
                    return false
                end
                local offset = handle.Position - self.aim
                -- Only Volcano supplies headroom above its raised stand. Fuel retains 14 studs.
                local maxHeight = self.handleHeadroom
                    and math.max(14, self.goal.Position.Y - self.aim.Y + self.handleHeadroom) or 14
                if Vector2.new(offset.X, offset.Z).Magnitude > 1.5
                    or offset.Y < -1 or offset.Y > maxHeight
                    or (handle.Position - self.root.Position).Magnitude > 12 then
                    self.reason = "sack-not-aligned"
                    return false
                end
            end
            return true
        end
        function lease:Pulse()
            if not self:Owns() then self:Close("cancelled"); return end
            local now = os.clock()
            if self.fly and self.teleportCount < 2 then
                if self.valid and not self.valid() then self:Close("target-unavailable"); return end
                self.stableSince, self.samples, self.lastSampleAt = nil, 0, now
                self.reason = "double-teleport"
                self.root.Anchored = true
                self.humanoid.AutoRotate, self.humanoid.Sit = false, false
                state.dropHoldActive, state.anchorLeaseRoot = true, self.root
                if not self.lastTeleportAt or now - self.lastTeleportAt >= Settings.DROP_TELEPORT_INTERVAL then
                    -- Two separate placements, even if the first already looks correct locally.
                    self.character:PivotTo(self.goal)
                    self.root.CFrame = self.goal
                    zeroCharacterMotion(self.character)
                    self.teleportCount += 1
                    self.lastTeleportAt = now
                    if self.teleportCount == 2 then self:StartFly() end
                end
                return
            end
            if not self:FlyReady() then self:Close("fly-interrupted"); return end
            -- This sample precedes all writes below and must be a fresh frame.
            if now - self.lastSampleAt >= 0.008 then
                if self:RawReady() then
                    self.stableSince = self.stableSince or now
                    self.samples += 1
                else
                    self.stableSince, self.samples = nil, 0
                end
                self.lastSampleAt = now
            end
            self.root.Anchored = not self.fly
            self.humanoid.AutoRotate = false
            self.humanoid.Sit = false
            if self.fly then self.humanoid.PlatformStand = true
            elseif self.stabilize then self.humanoid.PlatformStand = false end
            if self.drop then
                state.dropHoldActive = true
                state.anchorLeaseRoot = not self.fly and self.root or nil
                -- Only correct a small, measured grip offset after the character
                -- itself arrives; a Handle still at the departure point is rejected.
                local handle = self.sack and self.sack.Parent == self.character
                    and self.sack:FindFirstChild("Handle")
                if handle and self.aim and (self.root.Position - self.goal.Position).Magnitude <= 1.25
                    and (handle.Position - self.root.Position).Magnitude <= 12 then
                    local correction = Vector3.new(self.aim.X - handle.Position.X, 0, self.aim.Z - handle.Position.Z)
                    if correction.Magnitude > 1.5 and correction.Magnitude <= 8 then
                        self.goal = self.goal + correction
                        self.stableSince, self.samples = nil, 0
                    end
                end
            end
            if self.fly then
                -- After the second teleport, physics holds the character without more CFrame snaps.
                self.flyPosition.Position = self.goal.Position
                self.flyOrientation.CFrame = self.goal
            elseif (self.root.Position - self.goal.Position).Magnitude > 0.15
                or (self.root.CFrame.LookVector - self.goal.LookVector).Magnitude > 0.05
                or (self.stabilize and self.root.CFrame.UpVector.Y < 0.995) then
                self.character:PivotTo(self.goal)
                self.root.CFrame = self.goal
            end
            if not self.fly then zeroCharacterMotion(self.character) end
        end
        function lease:Ready(seconds)
            return self:RawReady() and self.samples >= 4 and self.stableSince ~= nil
                and os.clock() - self.stableSince >= (seconds or 0.75)
                and os.clock() - self.lastSampleAt <= 0.15
        end
        function lease:WaitStable(seconds, timeout)
            local deadline = os.clock() + (timeout or 6)
            repeat
                if not self:Owns() then return false end
                if self:Ready(seconds) then self.reason = "ready"; return true end
                task.wait(0.04)
            until os.clock() >= deadline
            if self.drop then Metrics.Add("dropsBlocked") end
            return false
        end
        function lease:SendDrop(network)
            -- No yield is permitted between this final observation and FireServer.
            if not self:Ready(0.75) or not network or type(network.FireServer) ~= "function" then
                Metrics.Add("dropsBlocked")
                return false
            end
            local ok = pcall(function() network:FireServer("DropItem") end)
            if ok then self.sentAt = os.clock(); Metrics.Add("dropsSent") end
            return ok
        end
        if lease.drop or lease.stabilize then
            local function suppress(part)
                if lease:Owns() and part:IsA("BasePart") then
                    if lease.collisions[part] == nil then lease.collisions[part] = part.CanCollide end
                    part.CanCollide = false
                end
            end
            for _, part in ipairs(character:GetDescendants()) do suppress(part) end
            lease.descendantConnection = character.DescendantAdded:Connect(suppress)
        end
        lease.connection = RunService.Heartbeat:Connect(function()
            local ok, err = pcall(lease.Pulse, lease)
            if not ok then state.lastError = tostring(err); lease:Close("physics-error") end
        end)
        lease:Pulse()
        return lease
    end
    return api
end)()

state.cleanup = function()
    if state.runToken ~= runToken then return end
    Motion.Close("unload")
    Metrics.Tick()
    Metrics.Save()
    state.running = false
    if state.volcanoHoverContext and state.volcanoHoverContext.close then
        pcall(state.volcanoHoverContext.close)
    end
    if state.infoGui then pcall(function() state.infoGui:Destroy() end); state.infoGui = nil end
    if type(state.restoreCombatPatches) == "function" then pcall(state.restoreCombatPatches) end
    for _, key in ipairs({"infoInputChangedConnection", "volcanoTargetIndexConnection", "creatureFeedConnection",
        "queueTeleportConnection", "raidConnection"}) do
        if state[key] then pcall(function() state[key]:Disconnect() end); state[key] = nil end
    end
end

local function teleportCharacter(cf: any, holdSeconds: any?, anchorDuringHold: any?): boolean
    if not validTeleportCFrame(cf) then
        return false
    end

    local character = getCharacter()
    local root = getRoot()
    local humanoid = getHumanoid()
    if not character or not root or not humanoid or humanoid.Health <= 0
        or character:GetAttribute("Dead") then
        return false
    end

    if (root.Position - cf.Position).Magnitude >= 160 then
        requestStreamNear(cf.Position)
    end

    local lease = Motion.Begin(cf)
    if not lease then return false end
    local minimum = math.max(0.12, tonumber(holdSeconds) or 0.12)
    local reached = lease:WaitStable(minimum, math.max(2.5, minimum + 1.5))
    reached = reached and lease:Owns()
    lease:Close(reached and "arrived" or "arrival-failed")

    if reached then
        state.lastTeleportAt = os.clock()
        state.lastTeleportTarget = cf.Position
    end

    return reached
end

local function queueNextExecution()
    if state.teleportQueued then return true end
    local queue = queue_on_teleport or (type(syn) == "table" and syn.queue_on_teleport)
        or (type(fluxus) == "table" and fluxus.queue_on_teleport)
    if type(queue) ~= "function" then return false end
    local source = state.autoExecuteSource or env.SeaPearlSource
    if type(source) ~= "string" and type(readfile) == "function" then
        local paths = {Settings.AUTO_EXECUTE_FILE, "autoexec/" .. Settings.AUTO_EXECUTE_FILE}
        if type(env.SeaPearlSourcePath) == "string" then table.insert(paths, 1, env.SeaPearlSourcePath) end
        for _, path in ipairs(paths) do
            local ok, content = pcall(readfile, path)
            if ok and type(content) == "string" and #content > 0 then source = content; break end
        end
    end
    if type(source) ~= "string" or source == "" then return false end
    state.autoExecuteSource = source
    -- Carry the source into each new executor environment, including setups that
    -- supplied SeaPearlSource directly and have no readable source file there.
    local payload = string.format("local source = %q\ngetgenv().SeaPearlSource = source\nassert(loadstring(source))()", source)
    local ok = pcall(queue, payload)
    state.teleportQueued = ok
    return ok
end
queueNextExecution()
state.queueTeleportConnection = player.OnTeleport:Connect(function(teleportState)
    if isRunning() and teleportState == Enum.TeleportState.Started then queueNextExecution() end
end)

local function returnToLobby()
    local now = os.clock()
    if state.lastForce and now - state.lastForce < 10 then
        return
    end
    state.lastForce = now
    queueNextExecution()
    pcall(function()
        TeleportService:Teleport(Settings.LOBBY_PLACE, player)
    end)
end

task.spawn(function()
    while isRunning() do
        task.wait(5)
        pcall(function()
            if not player or not player.Parent then
                return
            end

            if game.PlaceId == Settings.ISLAND_PLACE then
                -- SpawnIsland is allowed to stream out while Volcano is loaded.
                -- Its absence is not a dead session and must never force a lobby
                -- teleport or stop the continuous route.
                state.noPadsSince = nil
                state.noIslandSince = nil
            else
                state.noIslandSince = nil
                if Workspace:FindFirstChild("Pads") then
                    state.noPadsSince = nil
                else
                    state.noPadsSince = state.noPadsSince or os.clock()
                    if os.clock() - state.noPadsSince > 120 then
                        state.noPadsSince = nil
                        returnToLobby()
                    end
                end
            end
        end)
    end
end)

local function waitForWorldReady()
    local startedAt = os.clock()
    while isRunning() do
        local current = Players.LocalPlayer
        if current and current.Parent then
            player = current
        end

        if game.PlaceId == Settings.ISLAND_PLACE then
            -- Reinjection can happen while the player is already at Volcano and
            -- SpawnIsland is streamed out. PlaceId + a live character + either
            -- island/creature container is sufficient; all individual systems
            -- below already retry until their own dependencies replicate.
            if getRoot() and getHumanoid() and getHumanoid().Health > 0
                and (Workspace:FindFirstChild("SpawnIsland") or Workspace:FindFirstChild("IslandContainer")
                    or Workspace:FindFirstChild("CreatureContainer")) then
                return "island"
            end
        elseif game.PlaceId == Settings.LOBBY_PLACE then
            if Workspace:FindFirstChild("Pads") then
                return "lobby"
            end
        elseif Workspace:FindFirstChild("SpawnIsland") and getRoot() and getHumanoid()
            and getHumanoid().Health > 0 then
            return "island"
        elseif Workspace:FindFirstChild("Pads") then
            return "lobby"
        end

        if os.clock() - startedAt > 180 then
            return nil
        end
        task.wait(0.25)
    end
    return nil
end

local worldKind = waitForWorldReady()
if not worldKind then
    return
end

Metrics.Bind(worldKind)
if worldKind == "island" then
    if Workspace:GetAttribute("RaidActive") == true then Flow.data.defenseSeen = true end
    state.raidConnection = Workspace:GetAttributeChangedSignal("RaidActive"):Connect(function()
        if isRunning() and Workspace:GetAttribute("RaidActive") == true then
            Flow.data.defenseSeen = true
            Flow.data.defenseDone, Flow.data.clearSince = false, nil
        end
    end)
end
task.spawn(function()
    while isRunning() do
        Metrics.Tick()
        task.wait(1)
    end
end)

local function recoverCharacterMobility()
    Motion.Close("recovery")
    if state.volcanoHoverContext and state.volcanoHoverContext.close then
        state.volcanoHoverContext.close()
    end
    local character = getCharacter()
    local root = getRoot()
    local humanoid = getHumanoid()
    if not character or not root or not humanoid or humanoid.Health <= 0 then
        return
    end
    pcall(function()
        root.Anchored = false
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        humanoid.Sit = false
        humanoid.PlatformStand = false
        humanoid.AutoRotate = true
    end)
    state.anchorLeaseRoot = nil
    state.dropHoldActive = false
    state.volcanoHoverActive = false
end

if worldKind == "island" then
    -- An executor stop/reinjection can interrupt a hold between Anchored=true and
    -- its cleanup. Clear only character movement state; never respawn the player.
    recoverCharacterMobility()
end

-- Keep detailed controller phases in diagnostics, outside the player-facing UI.
local function friendlyFarmStatus()
    if state.bought then return "Pearl purchased", "Returning to the Lobby automatically." end
    if worldKind == "lobby" then return "Waiting for a game", "Farming starts automatically after you enter the map." end
    local character, humanoid = getCharacter(), getHumanoid()
    if not character or character:GetAttribute("Dead") or not getRoot() or not humanoid or humanoid.Health <= 0 then
        return "Waiting for your character", "Farming resumes when your character is ready."
    end
    if Flow.data.delayDone ~= true then
        local started = Flow.data.delayStartedAt
        if not started then return "Preparing game", "Game Delay starts when your character is ready." end
        local remaining = math.max(0, math.ceil(Settings.GAME_DELAY - (os.clock() - started)))
        return "Starting in " .. remaining .. "s", "You can adjust Game Delay below."
    end
    if state.lastError and os.clock() - (tonumber(state.lastErrorAt) or 0) < 3 then
        return "Retrying", "Farming will continue automatically."
    end
    local step = Flow.data.step
    if step == 6 then
        return "Opening chests", "Collecting " .. Settings.FARM_TARGET .. " Doubloons for Pearl."
    elseif step == 2 then
        if Flow.data.stage == "refuel" then
            return "Refilling Bonfire", "Restoring at least " .. Settings.MIN_CAMPFIRE_PERCENT .. "% fire while the Base is safe."
        end
        return "Preparing Bonfire", "Reaching Level 2 and emptying the Sack before Volcano."
    elseif step == 3 then
        return "Collecting Magma Golems", "Farming Pearl automatically."
    elseif step == 4 then
        return "Delivering Magma Golems", "Farming Pearl automatically."
    elseif step == 5 then
        return state.volcano.bossSeen and "Fighting Golem Boss" or "Waiting for Golem Boss",
            "Farming Pearl automatically."
    elseif step == 7 then
        return "Returning / Defending Base", "Checking the fire and protecting the Base."
    elseif step == 8 then
        return state.purchase and "Buying Pearl" or "Waiting for Merchant",
            "Pearl is purchased automatically."
    end
    return "Farming Pearl", "Your next Pearl run is in progress."
end

local function createInfoUI()
    if not isRunning() then return end
    local parent
    if typeof(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok then parent = result end
    end
    parent = parent or game:GetService("CoreGui")
    local old = parent:FindFirstChild("SeaInfo")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset = "SeaInfo", false, true
    gui.ZIndexBehavior, gui.DisplayOrder, gui.Parent = Enum.ZIndexBehavior.Sibling, 100, parent
    state.infoGui = gui
    local width, height = 260, 214
    local textColor = Color3.fromRGB(225, 228, 234)
    local muted = Color3.fromRGB(156, 163, 175)
    local accent = Color3.fromRGB(128, 218, 174)
    local frame = Instance.new("Frame")
    frame.Name, frame.Position, frame.Size = "FarmHUD", UDim2.fromOffset(14, 14), UDim2.fromOffset(width, height)
    frame.BackgroundColor3, frame.BackgroundTransparency = Color3.fromRGB(20, 22, 27), 0.12
    frame.BorderSizePixel, frame.Parent = 0, gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius, corner.Parent = UDim.new(0, 5), frame
    local border = Instance.new("UIStroke")
    border.Color, border.Thickness, border.Transparency, border.Parent = Color3.fromRGB(65, 69, 78), 1, 0.45, frame
    local scale = Instance.new("UIScale")
    scale.Parent = frame
    local function label(container, name, y, text, size, color)
        local item = Instance.new("TextLabel")
        item.Name, item.Text, item.Position = name, text, UDim2.fromOffset(12, y)
        item.Size, item.BackgroundTransparency = UDim2.fromOffset(width - 24, size + 6), 1
        item.TextXAlignment, item.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Center
        item.Font, item.TextSize, item.TextColor3 = Enum.Font.Roboto, size, color
        item.TextTruncate, item.Parent = Enum.TextTruncate.AtEnd, container
        return item
    end
    local status = label(frame, "Status", 8, "Preparing game", 14, accent)
    status.Size, status.Active = UDim2.fromOffset(width - 50, 23), true
    local toggle = Instance.new("TextButton")
    toggle.Name, toggle.Text, toggle.Position = "Minimize", "-", UDim2.fromOffset(width - 36, 8)
    toggle.Size, toggle.BackgroundTransparency = UDim2.fromOffset(24, 22), 1
    toggle.Font, toggle.TextSize, toggle.TextColor3, toggle.Parent = Enum.Font.Roboto, 17, muted, frame
    local body = Instance.new("Frame")
    body.Name, body.Position, body.Size = "Details", UDim2.fromOffset(0, 36), UDim2.fromOffset(width, height - 36)
    body.BackgroundTransparency, body.Parent = 1, frame
    local pearls = label(body, "Pearls", 0, "Pearls: --", 13, textColor)
    local rate = label(body, "PearlRate", 23, "Pearl/hour: 0.0", 14, accent)
    local coins = label(body, "Doubloons", 46, "Doubloons: -- / 500", 13, textColor)
    local fire = label(body, "Bonfire", 69, "Bonfire: --", 13, textColor)
    local totals = label(body, "Totals", 92, "Runs: 0  |  Time: 00:00", 12, muted)
    local delayTitle = label(body, "DelayLabel", 122, "Game Delay (s)", 12, textColor)
    delayTitle.Size = UDim2.fromOffset(150, 22)
    local delayInput = Instance.new("TextBox")
    delayInput.Name, delayInput.Position, delayInput.Size = "GameDelay", UDim2.fromOffset(width - 76, 120), UDim2.fromOffset(64, 24)
    delayInput.Text, delayInput.ClearTextOnFocus, delayInput.PlaceholderText = tostring(Settings.GAME_DELAY), false, "0-300"
    delayInput.Font, delayInput.TextSize, delayInput.TextColor3 = Enum.Font.Roboto, 13, textColor
    delayInput.BackgroundColor3, delayInput.BorderSizePixel, delayInput.Parent = Color3.fromRGB(32, 35, 42), 0, body
    local inputBorder = Instance.new("UIStroke")
    inputBorder.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    inputBorder.Color, inputBorder.Thickness, inputBorder.Transparency, inputBorder.Parent = muted, 1, 0.7, delayInput
    local hint = label(body, "DelayHint", 148, "Starts after entering the map.", 11, muted)
    delayInput.FocusLost:Connect(function()
        if not isRunning() then return end
        local valid = Preferences.SetGameDelay(delayInput.Text)
        delayInput.Text = tostring(Settings.GAME_DELAY)
        hint.Text = valid and "Saved. Starts after entering the map." or "Enter a number from 0 to 300."
    end)
    local collapsed = false
    toggle.Activated:Connect(function()
        collapsed = not collapsed
        body.Visible, toggle.Text = not collapsed, collapsed and "+" or "-"
        frame.Size = UDim2.fromOffset(width, collapsed and 36 or height)
    end)
    local dragging, dragStart, startPosition = false, nil, nil
    status.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPosition = true, input.Position, frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    state.infoInputChangedConnection = UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end)
    while gui.Parent and isRunning() do
        local report = Metrics.Report()
        status.Text = friendlyFarmStatus()
        pearls.Text = string.format("Pearls: %s  (+%d farmed)", tostring(player:GetAttribute("Pearls") or "--"), report.pearls)
        rate.Text = string.format("Pearl/hour: %.1f", report.perHour)
        coins.Text = string.format("Doubloons: %s / %d", tostring(player:GetAttribute("Doubloons") or "--"), Settings.FARM_TARGET)
        local base = Workspace:FindFirstChild("SpawnIsland")
        local level = base and tonumber(base:GetAttribute("Level"))
        local percent = base and tonumber(base:GetAttribute("Progress"))
        if level and level >= 7 then percent = 100 end
        fire.Text = string.format("Bonfire: Lv.%s  |  Fire: %s%%", tostring(level or "--"),
            percent and tostring(math.floor(percent + 0.5)) or "--")
        local elapsed = math.floor(report.roundSeconds)
        totals.Text = string.format("Runs: %d  |  Time: %02d:%02d", report.completed, math.floor(elapsed / 60), elapsed % 60)
        local camera = Workspace.CurrentCamera
        if camera then
            scale.Scale = math.clamp(math.min((camera.ViewportSize.X - 28) / width,
                (camera.ViewportSize.Y - 28) / (collapsed and 36 or height)), 0.4, 1)
        end
        task.wait(0.25)
    end
end

task.spawn(function()
    local ok, err = pcall(createInfoUI)
    if not ok and isRunning() then warn("[Sea Pearl UI] " .. tostring(err)) end
end)

local cachedPartyNetwork: any = nil
local function getPartyNetwork()
    if cachedPartyNetwork and type(cachedPartyNetwork.FireServer) == "function"
        and type(cachedPartyNetwork.InvokeServer) == "function" then
        return cachedPartyNetwork
    end

    local ok, first, second = pcall(function()
        local partyUI = require(ReplicatedStorage.Modules.Systems.PartyUI)
        local debugLibrary: any = debug
        if type(partyUI) ~= "table" or type(partyUI.CreateCallback) ~= "function"
            or type(debugLibrary) ~= "table"
            or type(debugLibrary.getupvalue) ~= "function" then
            return nil, nil
        end
        return debugLibrary.getupvalue(partyUI.CreateCallback, 1)
    end)
    if not ok then
        return nil
    end

    -- Standard Lua returns name,value while common executors return value only.
    local net = second ~= nil and second or first
    if net and type(net.FireServer) == "function"
        and type(net.InvokeServer) == "function" then
        cachedPartyNetwork = net
        return net
    end
    return nil
end

local function createSeededParty(net: any): boolean
    if not net then
        return false
    end
    local now = os.clock()
    if now < (tonumber(state.nextCreatePartyAt) or 0) then
        return false
    end
    state.nextCreatePartyAt = now + 3
    local ok = pcall(function()
        net:FireServer("CreateParty", 1, Settings.CUSTOM_SEED)
    end)
    return ok
end

if worldKind == "lobby" then
    task.spawn(function()
        while isRunning() and Workspace:FindFirstChild("Pads") do
            local root = getRoot()
            local pads = Workspace:FindFirstChild("Pads")
            if not root or not pads then
                task.wait(1)
                continue
            end

            local myPad = player:GetAttribute("Pad")
            local pad = myPad and pads:FindFirstChild("Pad" .. tostring(myPad)) or nil
            local net = getPartyNetwork()

            state.phase = "Lobby: seed " .. tostring(Settings.CUSTOM_SEED)

            if pad and pad:GetAttribute("Seed") ~= nil
                and tostring(pad:GetAttribute("Seed")) ~= tostring(Settings.CUSTOM_SEED) then
                if net and os.clock() >= (tonumber(state.nextLeavePadAt) or 0) then
                    state.nextLeavePadAt = os.clock() + 2
                    pcall(function()
                        net:FireServer("LeavePad")
                    end)
                end
                task.wait(0.8)
                continue
            end

            if not pad then
                for i = 1, 4 do
                    local candidate = pads:FindFirstChild("Pad" .. i)
                    if candidate
                        and candidate:GetAttribute("Open")
                        and not candidate:GetAttribute("Seed")
                        and not candidate:GetAttribute("Challenge") then
                        pad = candidate
                        break
                    end
                end

                if not pad then
                    task.wait(2)
                    continue
                end

                local cf = pad:GetBoundingBox()
                teleportCharacter(cf + Vector3.new(0, 2.5, 0), 0.12, false)
                task.wait(0.8)

                local entered = false
                if net then
                    local enterOk, response = state.invokeBounded(1.5, function()
                        return net:InvokeServer("EnterPad", tonumber(pad.Name:sub(-1)))
                    end, pad)
                    entered = enterOk and (response == true or response == "joined")
                end

                task.wait(0.8)
                if (entered or player:GetAttribute("Pad")) and net then
                    createSeededParty(net)
                end
            elseif pad:GetAttribute("Seed") == nil and net then
                createSeededParty(net)
            end

            if pad and root.Parent then
                local ok, cf = pcall(function()
                    return pad:GetBoundingBox()
                end)
                if ok then
                    teleportCharacter(cf + Vector3.new(0, 2.5, 0), 0.12, false)
                end
            end

            task.wait(1)
        end
    end)
    return
end

if worldKind ~= "island" then
    return
end

-- The countdown is map/character gated and runs once per JobId, never in Lobby.
do
    Flow.Set(1, "Waiting for a live character in the map")
    while isRunning() and Flow.data.delayDone ~= true do
        local character, root, humanoid = getCharacter(), getRoot(), getHumanoid()
        if not root or not humanoid or humanoid.Health <= 0 or character:GetAttribute("Dead") then
            Flow.data.delayStartedAt, Flow.data.delayCharacter = nil, nil
            state.phase = "Waiting for a live character in the map"
        else
            if Flow.data.delayCharacter ~= character then
                Flow.data.delayStartedAt, Flow.data.delayCharacter = os.clock(), character
            end
            local remaining = Settings.GAME_DELAY - (os.clock() - Flow.data.delayStartedAt)
            state.phase = string.format("Game Delay: %ds", math.max(0, math.ceil(remaining)))
            if remaining <= 0 then Flow.data.delayDone = true end
        end
        if not Flow.data.delayDone then task.wait(0.1) end
    end
    if not isRunning() then return end
    local nextStep = ({fuel = 2, volcano = 3, chests = 6, defense = 7, refuel = 2, merchant = 8})[Flow.data.stage] or 2
    Flow.Set(nextStep, "Farm Pearl running")
end

local function disableCutscenes()
    pcall(function()
        local module = require(ReplicatedStorage.Modules.Systems.CutscenePlayer)
        if type(module) == "table" then
            module.isPlaying = function()
                return false
            end
            module.Start = function()
                return nil
            end
        end
    end)
end

local function isIslandAlive()
    return player ~= nil
        and player.Parent ~= nil
        and (
            game.PlaceId == Settings.ISLAND_PLACE
            or worldKind == "island"
            or Workspace:FindFirstChild("SpawnIsland") ~= nil
        )
end

local function getModuleNet(name)
    local systems = ReplicatedStorage:FindFirstChild("Modules")
    systems = systems and systems:FindFirstChild("Systems")
    local moduleScript = systems and systems:FindFirstChild(name)
    if not moduleScript then
        return nil
    end

    local ok, module = pcall(require, moduleScript)
    if not ok or type(module) ~= "table" then
        return nil
    end

    local net = module.Net
    if net and type(net.FireServer) == "function" then
        return net
    end
    return nil
end

local cachedSackNet
local function sackNet()
    if cachedSackNet then
        return cachedSackNet
    end
    cachedSackNet = getModuleNet("SackClient")
    return cachedSackNet
end

local function isSackTool(tool)
    if not tool or not tool:IsA("Tool") then
        return false
    end

    local tagged = false
    pcall(function()
        tagged = tool:HasTag("Sack")
    end)
    if not tagged then
        pcall(function()
            tagged = CollectionService:HasTag(tool, "Sack")
        end)
    end

    return tagged or string.find(string.lower(tool.Name), "sack", 1, true) ~= nil
end

local function getEquippedSack()
    local character = getCharacter()
    if not character then
        return nil
    end

    for _, child in ipairs(character:GetChildren()) do
        if isSackTool(child) then
            return child
        end
    end
    return nil
end

local function equipSack()
    local equipped = getEquippedSack()
    if equipped then
        return equipped
    end

    local humanoid = getHumanoid()
    local backpack = player and player:FindFirstChild("Backpack")
    if not humanoid or not backpack then
        return nil
    end

    for _, child in ipairs(backpack:GetChildren()) do
        if isSackTool(child) then
            humanoid:EquipTool(child)
            local started = os.clock()
            repeat
                task.wait()
                equipped = getEquippedSack()
                if equipped then
                    return equipped
                end
            until os.clock() - started > 1
            return nil
        end
    end

    return nil
end

local function getSackText(sack)
    sack = sack or getEquippedSack()
    local handle = sack and sack:FindFirstChild("Handle")
    local billboard = handle and handle:FindFirstChild("BillboardGui")
    local label = billboard and billboard:FindFirstChild("TextLabel")
    if not label and sack then
        label = sack:FindFirstChildWhichIsA("TextLabel", true)
    end
    return label and label:IsA("TextLabel") and label.Text or nil
end

local function getSackCount()
    local sack = getEquippedSack()
    local text = getSackText(sack)
    local used, capacity
    if text then
        local usedText, capacityText = string.match(text, "^%s*(%d+)%s*/%s*(%d+)")
        used, capacity = tonumber(usedText), tonumber(capacityText)
    end

    if sack then
        capacity = capacity or tonumber(sack:GetAttribute("Max"))
            or tonumber(sack:GetAttribute("Capacity"))
        if used == nil then
            for _, descendant in ipairs(sack:GetDescendants()) do
                if descendant:IsA("ValueBase") then
                    local normalized = string.lower(descendant.Name):gsub("[^%w]", "")
                    if normalized == "count" or normalized == "stored"
                        or normalized == "itemcount" or normalized == "sackcount" then
                        local ok, value = pcall(function()
                            return descendant.Value
                        end)
                        if ok and tonumber(value) then
                            used = tonumber(value)
                            break
                        end
                    end
                end
            end
        end
    end
    state.sackProgress = used and capacity and string.format("%d/%d", used, capacity) or "--"
    return used, capacity
end

local function worldScanPosition(instance: any): any
    if not instance then
        return nil
    end
    if instance:IsA("BasePart") then
        return instance.Position
    end
    if instance:IsA("Model") then
        local ok, pivot = pcall(instance.GetPivot, instance)
        if ok then
            return pivot.Position
        end
    end
    return nil
end

local function worldFarmAnchors(): {any}
    local anchors: {any} = {}
    local seen: {[string]: boolean} = {}
    local function add(instance: any, label: string)
        local position = worldScanPosition(instance)
        if typeof(position) ~= "Vector3" then
            return
        end
        local key = label .. ":" .. string.format("%.0f:%.0f", position.X, position.Z)
        if seen[key] then
            return
        end
        seen[key] = true
        anchors[#anchors + 1] = {position = position, label = label}
    end

    local distant = ReplicatedStorage:FindFirstChild("DistantIslands")
    if distant then
        for _, marker in ipairs(distant:GetChildren()) do
            add(marker, marker.Name)
        end
    end
    local islands = Workspace:FindFirstChild("IslandContainer")
    if islands then
        for _, island in ipairs(islands:GetChildren()) do
            add(island, island.Name)
        end
    end
    table.sort(anchors, function(a, b)
        if math.abs(a.position.X - b.position.X) > 0.01 then
            return a.position.X < b.position.X
        end
        if math.abs(a.position.Z - b.position.Z) > 0.01 then
            return a.position.Z < b.position.Z
        end
        return a.label < b.label
    end)
    return anchors
end

local function advanceFarmWorldScan(reason: string): boolean
    local now = os.clock()
    if now < (tonumber(state.nextFarmWorldScanAt) or 0) then
        return false
    end
    local seed = tostring(player:GetAttribute("DisplaySeed") or "")
    local container = Workspace:FindFirstChild("IslandContainer")
    local route = state.farmRoute
    if not route or route.seed ~= seed or route.container ~= container or route.cursor >= #route.anchors then
        route = {seed = seed, container = container, cursor = 0, anchors = worldFarmAnchors()}
        state.farmRoute = route
    end
    local anchors = route.anchors
    if #anchors == 0 then
        state.nextFarmWorldScanAt = now + 0.5
        return false
    end

    local cursor = route.cursor + 1
    state.nextFarmWorldScanAt = now + 0.55
    local anchor = anchors[cursor]
    local rawPosition = anchor.position
    local destination = Vector3.new(
        rawPosition.X,
        math.max(rawPosition.Y + 35, Settings.WORLD_SCAN_SAFE_MIN_Y + 30),
        rawPosition.Z
    )
    state.phase = string.format("%s: scanning %s (%d/%d)", reason, anchor.label, cursor, #anchors)
    requestStreamNear(rawPosition)
    -- DistantIslands entries are streaming coordinates, not guaranteed ground.
    -- Keep the root anchored for the same proven scan window as the main SEA
    -- world scanner; releasing after 0.18 s let gravity/server correction move
    -- the player before chests or fuel had replicated and looked like a stall.
    local moved = teleportCharacter(CFrame.new(destination), 0.78, true)
    state.farmWorldCursor = cursor
    route.cursor = cursor
    if moved then
        task.wait(0.04)
    end
    return moved
end

local function getCampfireState(spawnIsland)
    if not spawnIsland then
        return 1, 0
    end
    local level = tonumber(spawnIsland:GetAttribute("Level")) or 1
    local progress = math.clamp(tonumber(spawnIsland:GetAttribute("Progress")) or 0, 0, 100)
    -- Bonfire.MaxBonfire stops decay/fueling at Level 7 and stores Progress=0.
    return level, level >= 7 and 100 or progress
end

local function campfireReady(spawnIsland)
    local level, progress = getCampfireState(spawnIsland)
    return spawnIsland ~= nil and level >= Settings.TARGET_LEVEL
        and progress >= Settings.MIN_CAMPFIRE_PERCENT
end

local function getNativeStorePart(item)
    if not item then
        return nil
    end

    local target = item.model or item.owner
    if not target then
        return item.part
    end

    if target:IsA("BasePart") then
        return target
    end

    local root = getRoot()
    local bestPart
    local bestDistance = math.huge

    for _, descendant in ipairs(target:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant:IsDescendantOf(Workspace) then
            local usable = true
            pcall(function()
                if descendant.CanQuery == false then
                    usable = false
                end
            end)
            if usable then
                local distance = root and (descendant.Position - root.Position).Magnitude or 0
                if not bestPart or distance < bestDistance then
                    bestPart = descendant
                    bestDistance = distance
                end
            end
        end
    end

    return bestPart or item.part
end

-- One pickup receipt owns its target and count baseline until reconciliation.
local SackTransfer = (function()
    local api = {}
    local function expireFuelStore(pending)
        if pending.kind ~= "fuel" then return end
        local age = os.clock() - (tonumber(pending.sentAt) or 0)
        if age < 6 then return end
        if state.pendingStore == pending then state.pendingStore = nil end
        if pending.owner then state.retryAfter[pending.owner] = os.clock() + 8 end
        state.lastStoreError = "Fuel pickup unconfirmed; selecting another item"
    end
    function api.ReconcileStore()
        local pending = state.pendingStore
        if not pending then return false end
        if pending.character ~= getCharacter() then state.pendingStore = nil; return false end
        if pending.sack ~= getEquippedSack() then expireFuelStore(pending); return false end
        local used = select(1, getSackCount())
        local removed = not pending.owner.Parent or not pending.owner:IsDescendantOf(Workspace)
            or pending.owner:GetAttribute("Stored") == true
        if removed and used and used > pending.beforeUsed then
            state.pendingStore = nil
            if pending.kind == "fuel" then state.fuelInSack += 1
            elseif pending.kind == "golem" then
                state.volcano.held = (tonumber(state.volcano.held) or 0) + 1
                state.volcano.pendingCorpse = nil
            end
            state.lastStoreError = nil
            return true, pending.owner
        end
        -- Only a still-present target with an unchanged Sack is safe to retry.
        if not removed and used == pending.beforeUsed and os.clock() - pending.sentAt >= 3 then state.pendingStore = nil end
        -- Keep the first version's pickup acknowledgement, but do not retain an
        -- unresolved fuel receipt forever when adapting it to a continuous route.
        if state.pendingStore == pending then expireFuelStore(pending) end
        return false
    end
    function api.Store(owner, part, net, sack, timeout, kind)
        local character, root = getCharacter(), getRoot()
        local used = select(1, getSackCount())
        if not owner or not owner.Parent or not part or not part.Parent or not root
            or not sack or sack.Parent ~= character or type(used) ~= "number" then return false end
        local confirmed, confirmedOwner = api.ReconcileStore()
        if confirmed and confirmedOwner == owner then return true end
        local pending = state.pendingStore
        if pending and pending.owner ~= owner then return false end
        if not pending then
            if (root.Position - part.Position).Magnitude > 12 then return false end
            pending = {owner = owner, sack = sack, beforeUsed = used,
                sentAt = os.clock(), character = character, origin = root.Position, kind = kind}
            if not isRunning() then return false end
            local sent = pcall(function() net:FireServer("StoreItem", part) end)
            if not sent then return false end
            state.pendingStore = pending
        end
        local deadline = os.clock() + (timeout or 1.8)
        repeat
            task.wait(0.04)
            if not isRunning() or getCharacter() ~= pending.character or not root.Parent
                or sack.Parent ~= character or (root.Position - pending.origin).Magnitude > 15 then return false end
            local received, receivedOwner = api.ReconcileStore()
            if received and receivedOwner == owner then return true end
        until os.clock() >= deadline
        return false
    end
    function api.ObserveGolemDrop(transaction)
        if not transaction or transaction.released then return end
        local used = select(1, getSackCount())
        local sack = getEquippedSack()
        if transaction.sack and sack ~= transaction.sack then return end
        if transaction.character and getCharacter() ~= transaction.character then return end
        if used and used < transaction.beforeUsed then
            transaction.released = true
            state.volcano.held = math.max(0, (tonumber(state.volcano.held) or 0) - 1)
            state.volcano.submitted = (tonumber(state.volcano.submitted) or 0) + 1
        end
    end
    function api.ConfirmGolems(count)
        local ritual = state.volcano
        local confirmed = math.clamp(math.floor(tonumber(count) or 0), 0, Settings.MAGMA_GOLEM_TARGET)
        ritual.delivered = math.max(tonumber(ritual.delivered) or 0, confirmed)
        local measured = tonumber(ritual.measuredConfirmed) or 0
        if ritual.delivered > measured then
            Metrics.Add("golemsConfirmed", ritual.delivered - measured)
            ritual.measuredConfirmed = ritual.delivered
        end
    end
    return api
end)()

-- Native station pickup path from script utama.luau:
-- StationSackFarm -> ChestLoot.InteractBatch -> StoreItem(BasePart).
-- Keep this inside one scope so its helpers do not share the corpse receipt.
local MainFuelFarm = (function()
    local api = {}
    local localPlayer = player
    local getHumanoidRootPart = getRoot
    local blockedUntil = setmetatable({}, {__mode = "k"})
    local pickupFailures = setmetatable({}, {__mode = "k"})
    local forceSearch = false
    local observedSack, observedCharacter, observedCount
    local partialSince, lastPickupAt = 0, 0

local function normalizeInstanceName(name)
    -- Makes "Warrior Chest", "WarriorChest", and "warrior_chest" comparable.
    return string.lower((tostring(name):gsub("[^%w]", "")))
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

    local function containsAnyToken(value, tokens)
        local normalized = normalizeInstanceName(value)
        for _, token in ipairs(tokens) do
            if string.find(normalized, token, 1, true) then
                return true
            end
        end
        return false
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

    local isInsideBase = (function()
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


    local function displayName(candidate)
        return candidate and tostring(candidate:GetAttribute("Item") or candidate.Name) or "fuel"
    end
    -- Same compatibility and nearest-first selection as loadedCandidates.
    -- All compatible fuel is selected for Farm Pearl; no dropdown is required.
    local function loadedCandidates(maximum)
        local root = getRoot()
        if not root then return {} end
        local result, seen = {}, {}
        for _, raw in ipairs(CollectionService:GetTagged("Interactable")) do
            local item = getTopInteractable(raw)
            if item and item.Parent and item:IsDescendantOf(Workspace) and not seen[item] then
                seen[item] = true
                if CollectionService:HasTag(item, "Interactable")
                    and os.clock() >= (blockedUntil[item] or 0)
                    and not hasActiveGrabber(item) and not isInsideBase(item)
                    and not candidateHasStoredMarker(item) and isBonfireFuel(item) then
                    result[#result + 1] = item
                end
            end
        end
        table.sort(result, function(left, right)
            local lp, rp = itemPosition(left), itemPosition(right)
            return (lp and (lp - root.Position).Magnitude or math.huge)
                < (rp and (rp - root.Position).Magnitude or math.huge)
        end)
        if maximum then
            for index = #result, maximum + 1, -1 do result[index] = nil end
        end
        return result
    end
    local function nearbyCandidates(_originPosition, _radius, _includeAll)
        return loadedCandidates()
    end

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
        until not isRunning() or not rootPart.Parent or os.clock() >= deadline

        return candidate, nil
    end


    function api.ObserveSack(sack)
        local snapshot = readSackState(sack)
        local used = snapshot.count
        if observedSack ~= sack or observedCharacter ~= getCharacter() then
            observedSack, observedCharacter, observedCount = sack, getCharacter(), used
            partialSince, lastPickupAt = used and used > 0 and os.clock() or 0, 0
        elseif type(used) == "number" then
            if type(observedCount) == "number" and used > observedCount then
                state.fuelInSack = math.min(used, (tonumber(state.fuelInSack) or 0) + used - observedCount)
                lastPickupAt = os.clock()
            end
            observedCount = used
        end
        if type(used) == "number" then
            state.fuelInSack = math.min(tonumber(state.fuelInSack) or 0, used)
            if used <= 0 then partialSince, lastPickupAt = 0, 0
            elseif partialSince == 0 then partialSince = os.clock() end
            state.sackProgress = snapshot.counterText
        end
        return snapshot
    end

    local function interact(candidate, sackTool, canRun)
        if not canRun() then return false, "batch-cancelled", candidate end
        local rootPart = getRoot()
        local targetPart
        candidate, targetPart = resolveLiveInteractionCandidate(candidate, rootPart, true)
        if not canRun() then return false, "batch-cancelled", candidate end
        if not rootPart or not targetPart or not candidate or not candidate.Parent then
            return false, "missing-target", candidate
        end
        local initial = readSackState(sackTool)
        if initial.full then return false, "sack-full", candidate end
        local beforeStorage = storageSnapshot(sackTool)
        local function movementInterrupted()
            return not canRun()
        end
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
            local autonomousMovement = true
            if not autonomousMovement
                and humanoid
                and humanoid.MoveDirection.Magnitude > 0.05
            then
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
            rootPart.AssemblyLinearVelocity = Vector3.zero
            rootPart.AssemblyAngularVelocity = Vector3.zero
            rootPart.CFrame = destinationCFrame

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


        if not travelIntoNativeRange() then return false, "native-travel-failed", candidate end
        -- StationSackFarm uses nativeOnly=true, maximumAttempts=2. Item removal
        -- or its stored marker confirms pickup; the Sack counter is read separately.
        for attempt = 1, 2 do
            if not canRun() then return false, "batch-cancelled", candidate end
            if candidateWasCollected(candidate, "sack", sackTool, beforeStorage, nil, true) then
                return true, "native-proximity-confirmed", candidate
            end
            if fireSilentStore(candidate)
                and waitForCollection(candidate, "sack", sackTool, beforeStorage, nil, 6, canRun, true) then
                return true, "StoreItem-proximity", candidate
            end
            if not canRun() then return false, "batch-cancelled", candidate end
            if attempt < 2 then task.wait(0.1) end
        end
        local final = readSackState(sackTool)
        return false, final.full and "sack-full" or "native-proximity-unconfirmed", candidate
    end

    function api.PartialDeliveryDue(used)
        -- Same 20-second no-progress fallback as StationSackFarm's Bonfire route.
        return used > 0 and partialSince > 0
            and os.clock() - math.max(partialSince, lastPickupAt) >= 20
    end

    function api.Gather(sack, canContinue)
        local character, root, humanoid = getCharacter(), getRoot(), getHumanoid()
        local function mayGather()
            return isRunning() and getCharacter() == character and root and root.Parent
                and getRoot() == root and humanoid and humanoid.Health > 0
                and not character:GetAttribute("Dead") and sack and sack.Parent == character
                and (not canContinue or canContinue())
        end
        if not mayGather() then return false end
        local snapshot = api.ObserveSack(sack)
        if type(snapshot.count) ~= "number" or type(snapshot.maximum) ~= "number" then
            state.phase = "Waiting for Sack counter"
            return false
        end
        if snapshot.full then return "full" end
        local batchLimit = math.min(16, math.max(1, snapshot.maximum - snapshot.count))
        local candidates = loadedCandidates(batchLimit)
        if #candidates == 0 or forceSearch then
            forceSearch = false
            if not mayGather() then return false end
            local moved = advanceFarmWorldScan("Fuel")
            local refreshDeadline = os.clock() + (moved and 0.85 or 0)
            repeat
                if not mayGather() then return false end
                candidates = loadedCandidates(batchLimit)
                if #candidates > 0 or os.clock() >= refreshDeadline then break end
                task.wait(0.05)
            until not mayGather()
        end
        if not mayGather() or #candidates == 0 then return false end
        -- The native station batch owns movement and keeps Sack equipped. It uses
        -- direct root CFrame placement, with no arrival lease or shared pickup wait.
        Motion.Close("native-fuel-batch")
        local revision = teleportRevision
        local deadline = os.clock() + 4.5
        local function canRun()
            return mayGather() and teleportRevision == revision and os.clock() < deadline
        end
        if equipSack() ~= sack then return false end
        task.wait(0.05)
        local collected, firstFailure = 0, nil
        for _, candidate in ipairs(candidates) do
            if not canRun() then break end
            snapshot = api.ObserveSack(sack)
            if snapshot.full then break end
            state.phase = "Gathering " .. displayName(candidate)
            local ok, success, method, resolved = pcall(interact, candidate, sack, canRun)
            if not ok then success, method = false, tostring(success) end
            candidate = resolved or candidate
            api.ObserveSack(sack)
            if success then
                collected += 1
                pickupFailures[candidate] = nil
                blockedUntil[candidate] = os.clock() + 20
                lastPickupAt = os.clock()
                state.lastStoreError = nil
            elseif method == "sack-full" then
                break
            elseif method ~= "batch-cancelled" and method ~= "movement-interrupted" then
                local failures = math.min(5, (pickupFailures[candidate] or 0) + 1)
                pickupFailures[candidate] = failures
                blockedUntil[candidate] = os.clock() + math.min(45, 4 * 2 ^ (failures - 1))
                firstFailure = firstFailure or (displayName(candidate) .. ": " .. tostring(method))
            end
        end
        local after = api.ObserveSack(sack)
        if mayGather() then equipSack() end
        if after.full then return "full" end
        if collected == 0 then
            forceSearch = true
            if firstFailure then
                state.lastStoreError = firstFailure
                state.phase = "Pickup not accepted; searching another area"
                if os.clock() - (tonumber(state.lastFuelWarningAt) or 0) >= 3 then
                    state.lastFuelWarningAt = os.clock()
                    warn("[Sea Pearl Fuel] " .. firstFailure)
                end
            end
        end
        return collected > 0
    end

    -- Retire the old fuel-only receipt on reinjection. Magma corpse receipts
    -- remain owned by SackTransfer and retain their existing confirmation rules.
    local pending = state.pendingStore
    if pending and pending.kind == "fuel" then
        if pending.pickupLease then pcall(function() pending.pickupLease:Close("native-fuel-method") end) end
        local sack = equipSack()
        if sack then
            local snapshot = api.ObserveSack(sack)
            local before = tonumber(pending.beforeUsed)
            if snapshot.count and before and pending.sack == sack and snapshot.count > before then
                state.fuelInSack = math.min(snapshot.count, (tonumber(state.fuelInSack) or 0) + snapshot.count - before)
            end
        end
        state.pendingStore = nil
    end
    return api
end)()

local function dropFuelAtCampfire(dropper, spawnIsland, emptySack, canContinue)
    emptySack = emptySack == true
    local function pauseForDefense()
        local lease = state.fuelDeliveryLease
        if lease then lease:Close("fuel-paused-for-defense") end
        state.fuelDeliveryLease = nil
        -- Keep an already-sent receipt for reconciliation after the raid.
        state.phase = "Fuel paused; returning to defend Base"
        return false
    end
    local function finishAtTarget()
        if state.pendingFuelDrop or not campfireReady(spawnIsland) then return false end
        if emptySack then
            local used = select(1, getSackCount())
            if used == nil or used > 0 then return false end
        end
        local batch, lease = state.fuelBatch, state.fuelDeliveryLease
        if batch and batch.released > 0 then Metrics.Add("fuelConfirmed", batch.released) end
        state.fuelBatch, state.fuelDeliveryLease, state.lastDropError = nil, nil, nil
        if lease then lease:Close("bonfire-target-reached") end
        state.phase = emptySack and "Bonfire ready; Sack empty for Magma Golems"
            or "Bonfire ready: Level 2 and at least " .. Settings.MIN_CAMPFIRE_PERCENT .. "% fire"
        return true
    end
    if canContinue and not canContinue() then return pauseForDefense() end
    -- Before Volcano, the Sack must also be empty; top-ups use the configured target.
    if finishAtTarget() then return true end
    local net = sackNet()
    local sack = equipSack()
    if not net or not sack or not dropper or not dropper:IsA("BasePart")
        or not dropper:IsDescendantOf(Workspace) then
        return false
    end
    Metrics.Phase("Fuel delivery")
    local character, root = getCharacter(), getRoot()
    local previous = state.pendingFuelDrop
    if previous and (previous.sack ~= sack or previous.character ~= character
        or previous.spawnIsland ~= spawnIsland) then
        state.lastDropError = "Fuel receipt interrupted by character/Sack replacement"
        state.pendingFuelDrop, state.fuelInSack = nil, 0
        Motion.Close("fuel-receipt-replaced")
        Metrics.Add("recoveries")
        return false
    end
    local handle = sack:FindFirstChild("Handle")
    if not root or not handle or not handle:IsA("BasePart")
        or (handle.Position - root.Position).Magnitude > 12 then return false end
    local dropPosition = dropper.Position + Vector3.new(0, dropper.Size.Y * 0.5, 0)
    local forward = Vector3.new(dropper.CFrame.LookVector.X, 0, dropper.CFrame.LookVector.Z)
    if forward.Magnitude < 0.05 then forward = Vector3.new(0, 0, -1) else forward = forward.Unit end
    local orientation = CFrame.lookAt(Vector3.zero, forward)
    local offset = orientation:VectorToWorldSpace(root.CFrame:PointToObjectSpace(handle.Position))
    local stand = dropPosition + Vector3.new(-offset.X, math.max(4.5, 3 - offset.Y), -offset.Z)
    local lease = state.fuelDeliveryLease
    if not lease or not lease:Owns() or lease.sack ~= sack then
        lease = Motion.Begin(CFrame.lookAt(stand, stand + forward), {
            drop = true, fly = true, sack = sack, aim = dropPosition,
            valid = function()
                return dropper.Parent ~= nil and dropper:IsDescendantOf(Workspace)
                    and spawnIsland.Parent ~= nil and (dropper.Position
                        + Vector3.new(0, dropper.Size.Y * 0.5, 0) - dropPosition).Magnitude <= 0.5
            end,
        })
        state.fuelDeliveryLease = lease
    end
    if not lease then return false end
    state.phase = "Double teleport and fly above campfire before releasing fuel"
    if not lease:WaitStable(0.75, 6) then
        state.lastDropError = "Fuel held in Sack: " .. tostring(lease.reason)
        if not (state.pendingFuelDrop and not state.pendingFuelDrop.released and lease:Owns()) then
            lease:Close("fuel-arrival-failed")
        end
        return false
    end
    if canContinue and not canContinue() then return pauseForDefense() end
    local used = select(1, getSackCount())
    if not used then return false end
    if not state.pendingFuelDrop then
        state.fuelInSack = emptySack and used or math.min(state.fuelInSack, used)
    end
    if not state.fuelBatch then
        local level, progress = getCampfireState(spawnIsland)
        state.fuelBatch = {level = level, progress = progress, released = 0, startedAt = os.clock()}
    end
    local batch = state.fuelBatch
    local ok, result = pcall(function()
        -- Reuse one 2x-teleport/fly delivery for the whole Sack before Volcano.
        while isRunning() and lease:Owns() and (state.fuelInSack > 0 or state.pendingFuelDrop) do
            if canContinue and not canContinue() then return pauseForDefense() end
            local pending = state.pendingFuelDrop
            if not pending then
                if not emptySack and campfireReady(spawnIsland) then break end
                local beforeUsed = select(1, getSackCount())
                if not beforeUsed or beforeUsed <= 0 or not lease:WaitStable(0.75, 5) then break end
                if canContinue and not canContinue() then return pauseForDefense() end
                if not emptySack and campfireReady(spawnIsland) then break end
                local beforeLevel, beforeProgress = getCampfireState(spawnIsland)
                pending = {beforeUsed = beforeUsed, sentAt = os.clock(), released = false,
                    beforeLevel = beforeLevel, beforeProgress = beforeProgress,
                    sack = sack, character = character, spawnIsland = spawnIsland}
                if not lease:SendDrop(net) then break end
                state.pendingFuelDrop = pending
            end
            local deadline = os.clock() + 2
            repeat
                task.wait(0.04)
                if not lease:Owns() or sack.Parent ~= character then return false end
                if canContinue and not canContinue() then return pauseForDefense() end
                local afterUsed = select(1, getSackCount())
                if not pending.released and afterUsed and afterUsed < pending.beforeUsed then
                    pending.released = true
                    state.fuelInSack = math.max(0, state.fuelInSack - 1)
                end
            until pending.released or os.clock() >= deadline
            if not pending.released then
                state.lastDropError = "Fuel DropItem pending; holding Bonfire without a duplicate"
                return false
            end
            if not emptySack then
                -- A top-up waits for the fire update before deciding on another item.
                local fireDeadline = os.clock() + 1.2
                repeat
                    task.wait(0.04)
                    if not isRunning() or not lease:Owns() then return false end
                    if canContinue and not canContinue() then return pauseForDefense() end
                    local level, progress = getCampfireState(spawnIsland)
                    if campfireReady(spawnIsland) or level > (pending.beforeLevel or batch.level)
                        or (level == (pending.beforeLevel or batch.level)
                            and progress > (pending.beforeProgress or batch.progress)) then break end
                until os.clock() >= fireDeadline
            end
            batch.released += 1
            state.pendingFuelDrop = nil
            batch.settleUntil = os.clock() + 4
        end
        if finishAtTarget() then return true end
        if state.fuelInSack > 0 or state.pendingFuelDrop then return false end
        local level, progress = getCampfireState(spawnIsland)
        local advanced = level > batch.level or (level == batch.level and progress > batch.progress) or level >= 7
        if batch.released > 0 and not advanced and os.clock() < (batch.settleUntil or 0) then
            state.phase = "Fuel dropped; waiting for Bonfire progress"
            return false
        end
        if advanced then Metrics.Add("fuelConfirmed", batch.released); state.lastDropError = nil
        elseif batch.released > 0 then
            state.lastDropError = "No Bonfire progress after fuel landed; collecting more fuel"
            Metrics.Add("recoveries")
        end
        state.fuelBatch, state.fuelDeliveryLease = nil, nil
        lease:Close("fuel-batch-ended")
        return advanced
    end)
    if not ok then state.lastDropError = tostring(result); Metrics.Add("recoveries") end
    return ok and result == true
end

local function haulFuel(dropper, emptySack, canContinue)
    if canContinue and not canContinue() then return end
    local spawnIsland = Workspace:FindFirstChild("SpawnIsland")
    if state.pendingFuelDrop or state.fuelBatch then
        if not spawnIsland or not dropper then return "deliver" end
        dropFuelAtCampfire(dropper, spawnIsland, emptySack, canContinue)
        return
    end
    local sack = equipSack()
    if not sack then state.phase = "Waiting for Sack"; return end
    local snapshot = MainFuelFarm.ObserveSack(sack)
    local used, capacity = snapshot.count, snapshot.maximum
    if type(used) ~= "number" or type(capacity) ~= "number" or capacity <= 0 then
        state.phase = "Waiting for Sack counter"
        return
    end
    local function deliver()
        if canContinue and not canContinue() then return end
        local island = Workspace:FindFirstChild("SpawnIsland")
        local station = island and island:FindFirstChild("Dropper")
        if not station or not station:IsA("BasePart") then return "deliver" end
        dropFuelAtCampfire(station, island, emptySack, canContinue)
        MainFuelFarm.ObserveSack(sack)
    end
    if campfireReady(spawnIsland) then
        if emptySack and used > 0 then
            state.phase = "Emptying Sack at Bonfire before Volcano"
            return deliver()
        end
        return
    end
    local partialDue = MainFuelFarm.PartialDeliveryDue(used)
    if snapshot.full or partialDue or (not emptySack and state.fuelInSack > 0) then
        if not emptySack and state.fuelInSack <= 0 then
            state.lastStoreError = "Sack full of untracked items; waiting for fuel space"
            return
        end
        return deliver()
    end
    state.phase = "Gathering fuel: Sack " .. snapshot.counterText
    MainFuelFarm.Gather(sack, canContinue)
    if canContinue and not canContinue() then return end
    snapshot = MainFuelFarm.ObserveSack(sack)
    if snapshot.full or (snapshot.count and MainFuelFarm.PartialDeliveryDue(snapshot.count))
        or (not emptySack and state.fuelInSack > 0) then
        return deliver()
    end
end

local function runtimeGlobalFunction(name: string): any
    if type(getrenv) == "function" then
        local ok, runtime = pcall(getrenv)
        local candidate = ok and type(runtime) == "table"
            and type(runtime._G) == "table" and runtime._G[name] or nil
        if type(candidate) == "function" then
            return candidate
        end
    end
    local candidate = type(_G) == "table" and _G[name] or nil
    return type(candidate) == "function" and candidate or nil
end

state.invokeNativeLeaveGame = function(): boolean
    local leaveGame = runtimeGlobalFunction("LeaveGame")
    if leaveGame then
        local ok = pcall(leaveGame)
        if ok then
            return true
        end
    end

    -- Client.luau implements LeaveGame as the IMAFK event on the shared Net.
    local network = sackNet()
    if network and type(network.FireServer) == "function" then
        return pcall(function()
            network:FireServer("IMAFK")
        end)
    end
    return false
end

-- Keep Baan's chest and teleport functions together in their original scope.
local farmNearestChest = (function()
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
return farmNearestChest
end)()

local function isPassive(name)
    local lowered = string.lower(tostring(name or ""))
    for _, token in ipairs(Settings.PASSIVE) do
        if string.find(lowered, string.lower(token), 1, true) then
            return true
        end
    end
    return false
end

local function raidActive()
    local active = Workspace:GetAttribute("RaidActive")
    if type(active) == "boolean" then return active end
    local clock = Lighting.ClockTime
    return clock >= 18.5 or clock < 5.5
end

local DEFAULT_HOME_POSITION = Vector3.new(256, 150, -256)

local function homePosition()
    local spawn = Workspace:FindFirstChild("SpawnIsland")
    local home = spawn and (spawn:FindFirstChild("Bonfire") or spawn:FindFirstChild("Dropper"))
    if home then
        local ok, cf = pcall(function()
            return home:GetPivot()
        end)
        if ok then
            state.homePosition = cf.Position
            return cf.Position
        end
        if home:IsA("BasePart") then
            state.homePosition = home.Position
            return home.Position
        end
    end
    if typeof(state.homePosition) == "Vector3" then
        return state.homePosition
    end
    return DEFAULT_HOME_POSITION
end

local function nearbyRaiders(home)
    local out = {}
    for _, folderName in ipairs({"CreatureContainer", "Creatures"}) do
        local folder = Workspace:FindFirstChild(folderName)
        if folder then
            for _, model in ipairs(folder:GetChildren()) do
                if model:IsA("Model") and not model:GetAttribute("Dead") and not isPassive(model.Name)
                    and not model:GetAttribute("Ragdoll") and not model:GetAttribute("Companion")
                    and (model:FindFirstChild("CreatureID") or model:GetAttribute("CreatureID") ~= nil
                        or model:FindFirstChildOfClass("Humanoid")) then
                    local ok, cf = pcall(function()
                        return model:GetPivot()
                    end)
                    local humanoid = model:FindFirstChildOfClass("Humanoid")
                    local healthValue = model:FindFirstChild("Health")
                    local health = humanoid and humanoid.Health or tonumber(model:GetAttribute("Health"))
                        or (healthValue and healthValue:IsA("ValueBase") and tonumber(healthValue.Value))
                    if ok and (not health or health > 0) and (cf.Position - home).Magnitude <= Settings.DEFENSE_RADIUS then
                        table.insert(out, model)
                    end
                end
            end
        end
    end

    table.sort(out, function(a, b)
        local okA, cfA = pcall(function() return a:GetPivot() end)
        local okB, cfB = pcall(function() return b:GetPivot() end)
        if not okA then return false end
        if not okB then return true end
        return (cfA.Position - home).Magnitude < (cfB.Position - home).Magnitude
    end)

    return out
end

local MELEE_TOKENS = {
    "hatchet", "axe", "machete", "knife", "claymore", "saber",
    "cutlass", "sword", "spear", "poke", "poku", "thump", "boku",
}

local NON_MELEE_TOKENS = {
    "rifle", "shotgun", "gun", "pistol", "revolver", "blaster",
    "raygun", "minigun", "flintlock", "boomstick", "cannon", "laser",
    "slicer", "flare", "staff", "magic", "mage", "grenade", "bomb",
    "airdrop", "harpoon", "riptide",
}

local UTILITY_TOOL_NAMES = {
    Sack = true,
    Compass = true,
    Binoculars = true,
    Lantern = true,
    Flashlight = true,
}

local function nameContains(name, tokens)
    name = string.lower(name or "")
    for _, token in ipairs(tokens) do
        if string.find(name, token, 1, true) then
            return true
        end
    end
    return false
end

local function isMeleeWeapon(tool)
    if not tool or not tool:IsA("Tool") or UTILITY_TOOL_NAMES[tool.Name] then
        return false
    end

    local okSack, isSack = pcall(function()
        return CollectionService:HasTag(tool, "Sack")
    end)
    if okSack and isSack then
        return false
    end

    local lowerName = string.lower(tool.Name)
    if tool:GetAttribute("IsGun") == true
        or tool:GetAttribute("AmmoType") ~= nil
        or tool:GetAttribute("Magic") ~= nil
        or nameContains(lowerName, NON_MELEE_TOKENS) then
        return false
    end

    local okMelee, taggedMelee = pcall(function()
        return CollectionService:HasTag(tool, "Melee")
    end)
    local damage = tonumber(tool:GetAttribute("Damage")) or 0
    return (okMelee and taggedMelee) or damage > 0 or nameContains(lowerName, MELEE_TOKENS)
end


-- Volcano prelude ----------------------------------------------------------
-- Seed 123456789 contains the Volcano route. This controller deliberately
-- performs only one bounded action per main-loop pass, so a failed stream,
-- respawn, StoreItem request, or boss spawn is retried instead of wedging the
-- original pearl-farm loop forever.
local VOLCANO_IDENTITY_ATTRIBUTES = {
    "Item", "Creature", "CreatureID", "CreatureName", "DisplayName", "Enemy",
    "EnemyName", "Mob", "MobName", "NPC", "NPCName", "NPCType", "Type",
}

local function normalizedEntityName(value: any): string
    local normalized = string.lower(tostring(value or "")):gsub("[^%w]", "")
    -- Runtime variants can be NPC_MagmaGolem12, MagmaGolem_CLIENT, or a
    -- rig/model wrapper. Use the same canonical prefix/suffix cleanup as the
    -- main script's NPC registry instead of relying on one literal name.
    for _ = 1, 4 do
        local previous = normalized
        for _, prefix in ipairs({"npc", "enemy", "mob", "creature", "animal"}) do
            if #normalized > #prefix and string.sub(normalized, 1, #prefix) == prefix then
                normalized = string.sub(normalized, #prefix + 1)
                break
            end
        end
        local withoutDigits = normalized:gsub("%d+$", "")
        if withoutDigits ~= "" then
            normalized = withoutDigits
        end
        normalized = normalized:gsub("clone%d*$", "")
        for _, suffix in ipairs({
            "client", "rig", "model", "npc", "enemy", "mob", "creature", "animal",
        }) do
            if #normalized > #suffix and string.sub(normalized, -#suffix) == suffix then
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

-- Native creature batches carry the identity separately from the server model's name.
local runtimeCreatureNames: any = setmetatable({}, {__mode = "k"})
local function identityMatches(model: any, wanted: any): boolean
    if not model then
        return false
    end
    if wanted[normalizedEntityName(model.Name)]
        or wanted[normalizedEntityName(runtimeCreatureNames[model])] then
        return true
    end
    for _, attributeName in ipairs(VOLCANO_IDENTITY_ATTRIBUTES) do
        local value = model:GetAttribute(attributeName)
        if value ~= nil and wanted[normalizedEntityName(value)] then
            return true
        end
        local valueObject = model:FindFirstChild(attributeName)
        if valueObject and valueObject:IsA("ValueBase")
            and wanted[normalizedEntityName(valueObject.Value)] then
            return true
        end
    end
    return false
end

local MAGMA_GOLEM_NAMES = {
    magmagolem = true,
    magmagolemcorpse = true,
    firegolem = true,
    firegolemcorpse = true,
}
local GOLEM_BOSS_NAMES = {
    golemboss = true,
    lordoflava = true,
    magmaboss = true,
}

-- Mirror the main script's event-driven NPC discovery, but keep the index scoped
-- to the two Volcano identities. This catches server revisions that parent a
-- combat model below the island (instead of directly in CreatureContainer)
-- without repeatedly walking all of Workspace.
local indexedVolcanoModels: any = setmetatable({}, {__mode = "k"})

local function volcanoModelHasCombatEvidence(model: any): boolean
    return model:FindFirstChild("CreatureID") ~= nil
        or model:FindFirstChildWhichIsA("Humanoid", true) ~= nil
        or model:FindFirstChild("Health", true) ~= nil
end

local function volcanoModelInCombatScope(model: any): boolean
    local current = model
    for _ = 1, 14 do
        if not current or current == Workspace then
            break
        end
        local normalized = string.lower(tostring(current.Name or "")):gsub("[^%w]", "")
        if normalized == "companionfolder" or normalized == "companionmodels"
            or normalized == "cutscenes" or normalized == "effects" then
            return false
        end
        if normalized == "creaturecontainer" or normalized == "creatures"
            or normalized == "islandcontainer" or normalized == "volcanopoi" then
            return true
        end
        current = current.Parent
    end
    return volcanoModelHasCombatEvidence(model)
end

local function trackVolcanoModelFrom(instance: any): any
    local current = instance
    for _ = 1, 10 do
        if not current or current == Workspace then
            break
        end
        if current:IsA("Model")
            and (identityMatches(current, MAGMA_GOLEM_NAMES)
                or identityMatches(current, GOLEM_BOSS_NAMES))
            and volcanoModelInCombatScope(current) then
            indexedVolcanoModels[current] = true
            return current
        end
        current = current.Parent
    end
    return nil
end

for _, containerName in ipairs({"CreatureContainer", "Creatures", "IslandContainer", "DebrisField"}) do
    local container = Workspace:FindFirstChild(containerName)
    if container then
        trackVolcanoModelFrom(container)
        for _, descendant in ipairs(container:GetDescendants()) do
            if descendant:IsA("Model") or descendant.Name == "CreatureID"
                or descendant.Name == "Health" then
                trackVolcanoModelFrom(descendant)
            end
        end
    end
end
if state.volcanoTargetIndexConnection then
    pcall(function()
        state.volcanoTargetIndexConnection:Disconnect()
    end)
end
state.volcanoTargetIndexConnection = Workspace.DescendantAdded:Connect(function(descendant)
    if isRunning() and (descendant:IsA("Model") or descendant.Name == "CreatureID"
        or descendant.Name == "Health") then
        trackVolcanoModelFrom(descendant)
    end
end)

local function entityHealth(model)
    if not model or not model.Parent then
        return 0, nil
    end

    -- CreatureClient mirrors the server Health value; a rig's Humanoid may only
    -- drive animation and still report its template health after the NPC dies.
    local health = model:FindFirstChild("Health", true)
    if health and health:IsA("ValueBase") then
        return tonumber(health.Value), health
    end

    for _, attributeName in ipairs({"Health", "HP", "CurrentHealth"}) do
        local value = tonumber(model:GetAttribute(attributeName))
        if value then
            return value, model
        end
    end
    local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        return humanoid.Health, humanoid
    end
    return nil, nil
end

local function entityIsAlive(model)
    if not model or not model.Parent or model:GetAttribute("Dead") == true then
        return false
    end
    -- Creature death is sometimes replicated as a draggable ragdoll before its
    -- Health object/Dead attribute updates. Never feed that corpse back into the
    -- combat selector.
    local tagOk, interactable = pcall(function()
        return CollectionService:HasTag(model, "Interactable")
    end)
    if model:GetAttribute("Ragdoll") == true
        or model:FindFirstAncestor("DebrisField") ~= nil
        or (tagOk and interactable == true) then
        return false
    end
    local health = entityHealth(model)
    return health == nil or health > 0
end

local function entityPart(model)
    if not model then
        return nil
    end
    for _, name in ipairs({"HumanoidRootPart", "Root", "Hitbox", "Torso", "UpperTorso"}) do
        local part = model:FindFirstChild(name, true)
        if part and part:IsA("BasePart") then
            return part
        end
    end
    return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

local function entityPosition(model)
    local part = entityPart(model)
    if part then
        return part.Position
    end
    local ok, cf = pcall(function()
        return model:GetPivot()
    end)
    return ok and cf.Position or nil
end

-- Assigned after the executor/upvalue helpers are initialized. The live game
-- keeps its complete CreatureClient state in a private registry upvalue.
local findRuntimeCreatureTargets: any

local function findCombatEntities(wanted: any, aliveOnly: any): {any}
    local results: {any} = {}
    local added: any = setmetatable({}, {__mode = "k"})
    local function addModel(model: any)
        if model and model:IsA("Model") and model:IsDescendantOf(Workspace) and not added[model]
            and not string.find(string.upper(model.Name), "_CLIENT", 1, true)
            and entityPart(model) ~= nil
            and (not aliveOnly or entityIsAlive(model)) then
            added[model] = true
            table.insert(results, model)
        end
    end

    local root = getRoot()
    local seenContainers = setmetatable({}, {__mode = "k"})
    for _, containerName in ipairs({"CreatureContainer", "Creatures"}) do
        local container = Workspace:FindFirstChild(containerName)
        if container and not seenContainers[container] then
            seenContainers[container] = true
            for _, model in ipairs(container:GetChildren()) do
                if model:IsA("Model")
                    and not string.find(string.upper(model.Name), "_CLIENT", 1, true)
                    and identityMatches(model, wanted)
                    and (not aliveOnly or entityIsAlive(model)) then
                    addModel(model)
                end
            end
        end
    end

    for model in pairs(indexedVolcanoModels) do
        if model.Parent and identityMatches(model, wanted) then
            addModel(model)
        elseif not model.Parent then
            indexedVolcanoModels[model] = nil
        end
    end

    if type(findRuntimeCreatureTargets) == "function" then
        for _, entry in ipairs(findRuntimeCreatureTargets(wanted)) do
            addModel(entry.serverModel)
        end
    end

    table.sort(results, function(a, b)
        local aPosition = entityPosition(a)
        local bPosition = entityPosition(b)
        if not aPosition then return false end
        if not bPosition then return true end
        local origin = root and root.Position or Vector3.zero
        return (aPosition - origin).Magnitude < (bPosition - origin).Magnitude
    end)
    return results
end

-- CreatureClient clones every streamed creature beside its authoritative server
-- model in Workspace.CreatureContainer and appends _CLIENT to the clone name.
-- The visual clone can arrive a frame earlier, so use it only as a locator; all
-- damage continues to target the server model returned by findCombatEntities.
local function findNearestCombatLocator(wanted: any): (any, boolean)
    local root = getRoot()
    local origin = root and root.Position or Vector3.zero
    local bestServer: any
    local bestServerDistance = math.huge
    local bestClient: any
    local bestClientDistance = math.huge
    local seenContainers = setmetatable({}, {__mode = "k"})

    for _, containerName in ipairs({"CreatureContainer", "Creatures"}) do
        local container = Workspace:FindFirstChild(containerName)
        if container and not seenContainers[container] then
            seenContainers[container] = true
            for _, model in ipairs(container:GetChildren()) do
                if model:IsA("Model") and identityMatches(model, wanted) and entityPart(model)
                    and entityIsAlive(model) then
                    local position = entityPosition(model)
                    if position then
                        local distance = (position - origin).Magnitude
                        local clientOnly = string.find(
                            string.upper(model.Name),
                            "_CLIENT",
                            1,
                            true
                        ) ~= nil
                        if clientOnly then
                            if distance < bestClientDistance then
                                bestClient = model
                                bestClientDistance = distance
                            end
                        elseif distance < bestServerDistance then
                            bestServer = model
                            bestServerDistance = distance
                        end
                    end
                end
            end
        end
    end

    for model in pairs(indexedVolcanoModels) do
        if model.Parent and identityMatches(model, wanted) and entityPart(model) and entityIsAlive(model) then
            local position = entityPosition(model)
            if position then
                local distance = (position - origin).Magnitude
                local clientOnly = string.find(
                    string.upper(model.Name),
                    "_CLIENT",
                    1,
                    true
                ) ~= nil
                if clientOnly then
                    if distance < bestClientDistance then
                        bestClient = model
                        bestClientDistance = distance
                    end
                elseif distance < bestServerDistance then
                    bestServer = model
                    bestServerDistance = distance
                end
            end
        elseif not model.Parent then
            indexedVolcanoModels[model] = nil
        end
    end

    if type(findRuntimeCreatureTargets) == "function" then
        for _, entry in ipairs(findRuntimeCreatureTargets(wanted)) do
            local serverModel = entry.serverModel
            if serverModel and entityIsAlive(serverModel) then
                local position = entityPosition(serverModel) or entry.position
                if position then
                    local distance = (position - origin).Magnitude
                    if distance < bestServerDistance then
                        bestServer = serverModel
                        bestServerDistance = distance
                    end
                end
            elseif not serverModel and entry.position then
                local distance = (entry.position - origin).Magnitude
                if distance < bestClientDistance then
                    bestClient = entry.locator
                    bestClientDistance = distance
                end
            end
        end
    end

    return bestServer or bestClient, bestServer ~= nil
end

local function teleportDirectlyToCombatLocator(locator: any, boss: any): boolean
    local runtimeCFrame = type(locator) == "table" and rawget(locator, "targetCF") or nil
    local runtimeModel = type(locator) == "table" and rawget(locator, "model") or nil
    local targetPosition = typeof(runtimeCFrame) == "CFrame" and runtimeCFrame.Position
        or (typeof(locator) == "Instance" and entityPosition(locator))
        or (typeof(runtimeModel) == "Instance" and entityPosition(runtimeModel))
    if not targetPosition then
        return false
    end

    requestStreamNear(targetPosition)
    local targetPart = typeof(locator) == "Instance" and entityPart(locator)
        or (typeof(runtimeModel) == "Instance" and entityPart(runtimeModel))
    local facing = typeof(runtimeCFrame) == "CFrame" and runtimeCFrame.LookVector
        or (targetPart and targetPart.CFrame.LookVector)
        or Vector3.new(0, 0, -1)
    local horizontal = Vector3.new(facing.X, 0, facing.Z)
    if horizontal.Magnitude < 0.1 then
        horizontal = Vector3.new(0, 0, -1)
    end

    local range = boss and 48 or 32
    local height = boss and 22 or 14
    local destination = targetPosition - horizontal.Unit * range
        + Vector3.new(0, height, 0)
    return teleportCharacter(
        CFrame.lookAt(destination, targetPosition + Vector3.new(0, 2, 0)),
        0.10,
        false
    )
end

local function isTagged(instance, tag)
    local ok, tagged = pcall(function()
        return CollectionService:HasTag(instance, tag)
    end)
    return ok and tagged == true
end

local function findMagmaCorpse()
    local candidates = {}
    local seen = setmetatable({}, {__mode = "k"})

    local function add(candidate)
        if not candidate or seen[candidate] then
            return
        end
        seen[candidate] = true

        local model
        local current = candidate
        for _ = 1, 10 do
            if not current or current == Workspace then
                break
            end
            if current:IsA("Model") and identityMatches(current, MAGMA_GOLEM_NAMES) then
                model = current
                break
            end
            current = current.Parent
        end
        if not model or not model:IsDescendantOf(Workspace) or model:FindFirstAncestor("Mission")
            or entityIsAlive(model) then
            return
        end

        if isTagged(model, "Interactable")
            or isTagged(candidate, "Interactable")
            or model:GetAttribute("Dead") == true
            or model:FindFirstAncestor("DebrisField") then
            table.insert(candidates, model)
        end
    end

    for _, instance in ipairs(CollectionService:GetTagged("Interactable")) do
        add(instance)
    end
    for _, model in ipairs(findCombatEntities(MAGMA_GOLEM_NAMES, false)) do
        add(model)
    end
    local debris = Workspace:FindFirstChild("DebrisField")
    if debris then
        for _, instance in ipairs(debris:GetChildren()) do
            add(instance)
        end
    end

    local root = getRoot()
    table.sort(candidates, function(a, b)
        local aPosition = entityPosition(a)
        local bPosition = entityPosition(b)
        if not aPosition then return false end
        if not bPosition then return true end
        local origin = root and root.Position or Vector3.zero
        return (aPosition - origin).Magnitude < (bPosition - origin).Magnitude
    end)
    return candidates[1]
end

-- Combat profiles are fallbacks for tools whose runtime Damage attribute is
-- unavailable. Runtime damage and fire interval are still included in scoring.
local VOLCANO_WEAPON_PROFILES: {[string]: any} = {
    ["squid laser"] = {kind = "laser", base = 250, nativeInterval = 0.05, interval = 0.03, ideal = 48, maxRange = 185, bypassCanFire = true, maxInFlight = 3},
    ["corrupt minigun"] = {kind = "gun", base = 235, nativeInterval = 0.067, interval = 0.055, ideal = 42, maxRange = 185, bypassCanFire = true, maxInFlight = 3},
    ["minigun"] = {kind = "gun", base = 225, nativeInterval = 0.067, interval = 0.055, ideal = 42, maxRange = 185, bypassCanFire = true, maxInFlight = 3},
    ["void slicer"] = {kind = "gun", base = 215, nativeInterval = 0.067, interval = 0.055, ideal = 42, maxRange = 185, bypassCanFire = true, maxInFlight = 3},
    ["raygun"] = {kind = "gun", base = 205, nativeInterval = 0.20, interval = 0.06, ideal = 40, maxRange = 185, bypassCanFire = true, maxInFlight = 3},
    ["ice staff"] = {kind = "ice", base = 195, interval = 0.06, ideal = 34, maxRange = 120},
    ["magma staff"] = {kind = "magma", base = 190, nativeInterval = 1.0, interval = 0.08, ideal = 40, maxRange = 120, bypassCanFire = true, maxInFlight = 3},
    ["wizard staff"] = {kind = "wizard", base = 185, nativeInterval = 0.30, interval = 0.08, ideal = 40, maxRange = 120, bypassCanFire = true, maxInFlight = 3},
    ["combat shotgun"] = {kind = "gun", base = 180, interval = 0.34, ideal = 25, maxRange = 145, shotgun = true, damageMultiplier = 9},
    ["assault rifle"] = {kind = "gun", base = 175, interval = 0.12, ideal = 38, maxRange = 185},
    ["dualpistols"] = {kind = "gun", base = 170, interval = 0.13, ideal = 36, maxRange = 185},
    ["dual pistols"] = {kind = "gun", base = 170, interval = 0.13, ideal = 36, maxRange = 185},
    ["boomstick"] = {kind = "boomstick", base = 165, interval = 0.65, ideal = 25, maxRange = 145},
    ["ghost blaster"] = {kind = "ghost", base = 160, interval = 0.50, ideal = 38, maxRange = 185},
    ["hand cannon"] = {kind = "gun", base = 155, interval = 0.28, ideal = 34, maxRange = 185},
    ["blunderbuss"] = {kind = "gun", base = 150, interval = 0.45, ideal = 24, maxRange = 145, shotgun = true, damageMultiplier = 9},
    ["necromancer staff"] = {kind = "necro", base = 145, interval = 1.05, ideal = 38, maxRange = 95},
    ["revolver"] = {kind = "gun", base = 140, interval = 0.20, ideal = 34, maxRange = 185},
    ["rifle"] = {kind = "gun", base = 135, interval = 0.18, ideal = 38, maxRange = 185},
    ["flintlock"] = {kind = "gun", base = 125, interval = 0.35, ideal = 34, maxRange = 185},
    ["riptide"] = {kind = "harpoon", base = 115, interval = 0.18, ideal = 15, maxRange = 28},
    ["harpoon"] = {kind = "harpoon", base = 110, interval = 0.18, ideal = 15, maxRange = 28},
}

-- Keep the discriminator dynamically typed. Some executor analyzers preserve a
-- narrowed literal union across this table and then reject otherwise valid arms.
local function volcanoWeaponKind(profile): string
    if type(profile) ~= "table" then
        return ""
    end
    return tostring((profile :: any).kind or "")
end

local VOLCANO_IGNORES_CAN_FIRE: {[string]: boolean} = {
    melee = true,
    harpoon = true,
    magma = true,
    wizard = true,
    ice = true,
}

-- Conventional firearms keep the loaded magazine in the first shared upvalue
-- of Fire/Reload/Restock. Raygun/heat weapons and magic staffs use a completely
-- different CanFire/debounce path, handled by SPECIAL_COOLDOWN_PATCHES below.
local UNLIMITED_MAGAZINE_VALUE = 999
local unlimitedAmmoPatches: any = setmetatable({}, {__mode = "k"})
local specialCooldownPatches: any = setmetatable({}, {__mode = "k"})
local specialOriginals: any = setmetatable({}, {__mode = "k"})
local SPECIAL_COOLDOWN_PATCHES: {[string]: any} = {
    ["raygun"] = {canFire = true, heat = true, debounce = {1}},
    ["magma staff"] = {debounce = {1, 2}},
    ["wizard staff"] = {debounce = {1, 2}},
    ["squid laser"] = {canFire = true, heat = true, debounce = {1}},
    ["minigun"] = {canFire = true, heat = true},
    ["corrupt minigun"] = {canFire = true, heat = true},
    ["void slicer"] = {canFire = true, heat = true},
}

local function executorFunction(name: string): any
    local candidate = type(env) == "table" and rawget(env :: any, name) or nil
    if type(candidate) ~= "function" and type(getfenv) == "function" then
        local ok, currentEnvironment = pcall(getfenv)
        if ok and type(currentEnvironment) == "table" then
            candidate = rawget(currentEnvironment, name)
        end
    end
    return type(candidate) == "function" and candidate or nil
end

local function resolveUpvalueReader(): (any, boolean)
    local debugLibrary: any = debug
    if type(debugLibrary) == "table" and type(debugLibrary.getupvalue) == "function" then
        return debugLibrary.getupvalue, false
    end
    local singleReader = executorFunction("getupvalue")
    if singleReader then
        return singleReader, false
    end
    if type(debugLibrary) == "table" and type(debugLibrary.getupvalues) == "function" then
        return debugLibrary.getupvalues, true
    end
    local allReader = executorFunction("getupvalues")
    if allReader then
        return allReader, true
    end
    return nil, false
end

local function resolveUpvalueWriter(): any
    local debugLibrary: any = debug
    if type(debugLibrary) == "table" and type(debugLibrary.setupvalue) == "function" then
        return debugLibrary.setupvalue
    end
    return executorFunction("setupvalue")
end

local function readClosureUpvalue(closure: any, index: number): (boolean, any)
    local reader: any, readsAll = resolveUpvalueReader()
    if not reader then
        return false, nil
    end

    local ok, first, second
    if readsAll then
        ok, first, second = pcall(reader, closure)
    else
        ok, first, second = pcall(reader, closure, index)
    end
    if not ok then
        return false, nil
    end
    if readsAll then
        if type(first) ~= "table" then
            return false, nil
        end
        return true, (first :: any)[index]
    end
    -- Do not use the `a and b or c` idiom here: a legitimate boolean-false
    -- upvalue would be replaced by its name on standard debug.getupvalue.
    if second ~= nil then
        return true, second
    end
    return true, first
end

-- Reuse Network.RE + DecodeData from SackClient.Net. Network.OnEvent has one
-- handler per name, so observe the native signal without replacing game handlers.
local CreatureFeed = (function()
    local api: any = {records = {}}
    function api.Connect()
        local net = sackNet()
        local remote = net and net.RE
        if typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent")
            or type(net.DecodeData) ~= "function" then return end
        if state.creatureFeedConnection and state.creatureFeedConnection.Connected
            and api.remote == remote then return end
        if state.creatureFeedConnection then state.creatureFeedConnection:Disconnect() end
        api.remote = remote
        state.creatureFeedConnection = remote.OnClientEvent:Connect(function(event, ...)
            if not isRunning() or (event ~= "CreatureBatchUpdate" and event ~= "Creature_Action") then return end
            local ok, payload, action = pcall(net.DecodeData, ...)
            if not ok then return end
            if event == "Creature_Action" then
                if action == "Remove" and api.records[payload] then
                    api.records[payload].cleaned = true
                    api.records[payload] = nil
                end
                return
            end
            if type(payload) ~= "table" then return end
            -- Client.AddCreature(id, name, root, cframe) uses exactly this batch layout.
            for id, item in pairs(payload) do
                if type(item) == "table" and typeof(item[1]) == "CFrame" then
                    local previous = api.records[id]
                    local name = item[2] or (previous and previous.name)
                    local normalized = normalizedEntityName(name)
                    if GOLEM_BOSS_NAMES[normalized] or MAGMA_GOLEM_NAMES[normalized] then
                        api.records[id] = {id = id, name = name, targetCF = item[1],
                            rootAttach = item[3] or (previous and previous.rootAttach),
                            networkObserved = true, lastSeen = os.clock(),
                            rootStreamed = previous and previous.rootStreamed or false}
                    end
                end
            end
        end)
    end
    return api
end)()
CreatureFeed.Connect()

local runtimeCreatureRegistry: any = nil
local nextRuntimeRegistryResolveAt = 0
local cachedGcCreatureRecords: {any} = {}
local nextGcCreatureRefreshAt = 0
local nextCreatureRadiusAt = 0

local function requestCreatureSimulationRadius()
    local now = os.clock()
    if now < nextCreatureRadiusAt then
        return
    end
    nextCreatureRadiusAt = now + 5

    -- Same capability-checked radius method used by Smart NPC Kill in the main
    -- SEA script. It helps the authoritative Root/CreatureID stay replicated.
    local setRadius = executorFunction("setsimulationradius")
    if setRadius then
        pcall(setRadius, 10000)
    end
    local setHidden = executorFunction("sethiddenproperty")
    if setHidden then
        pcall(setHidden, player, "SimulationRadius", 10000)
        pcall(setHidden, player, "MaximumSimulationRadius", 10000)
    end
end

local function findMainClientLocalScript(): any
    local playerScripts = player:FindFirstChild("PlayerScripts")
    if not playerScripts then
        return nil
    end
    local direct = playerScripts:FindFirstChild("Client")
    if direct and direct:IsA("LocalScript") then
        return direct
    end
    for _, descendant in ipairs(playerScripts:GetDescendants()) do
        if descendant:IsA("LocalScript") and descendant.Name == "Client" then
            return descendant
        end
    end
    return nil
end

local function resolveRuntimeCreatureRegistry(): any
    if type(runtimeCreatureRegistry) == "table" then
        return runtimeCreatureRegistry
    end

    local now = os.clock()
    if now < nextRuntimeRegistryResolveAt then
        return nil
    end
    nextRuntimeRegistryResolveAt = now + 2

    local getsenvFunction = executorFunction("getsenv")
    local clientScript = findMainClientLocalScript()
    if not getsenvFunction or not clientScript then
        return nil
    end

    local envOk, clientEnvironment = pcall(getsenvFunction, clientScript)
    local addCreature = envOk and type(clientEnvironment) == "table"
        and rawget(clientEnvironment, "AddCreature") or nil
    if type(addCreature) ~= "function" then
        return nil
    end

    -- Validate the record shape even for upvalue 2. Caching an unrelated/empty
    -- table here used to suppress all future resolution when the boss spawned.
    for _, index in ipairs({2, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}) do
        local ok, possible = readClosureUpvalue(addCreature, index)
        if ok and type(possible) == "table" then
            for _, value in pairs(possible) do
                if type(value) == "table"
                    and type(rawget(value, "name")) == "string"
                    and (typeof(rawget(value, "targetCF")) == "CFrame"
                        or typeof(rawget(value, "rootAttach")) == "Instance") then
                    runtimeCreatureRegistry = possible
                    return possible
                end
            end
        end
    end
    return nil
end

local function validRuntimeCreatureRecord(record: any): boolean
    if type(record) ~= "table" or type(rawget(record, "name")) ~= "string"
        or rawget(record, "cleaned") == true then return false end
    local model, rootAttach = rawget(record, "model"), rawget(record, "rootAttach")
    local liveRoot = typeof(rootAttach) == "Instance" and rootAttach:IsDescendantOf(Workspace)
    local liveModel = typeof(model) == "Instance" and model:IsDescendantOf(Workspace)
        and string.find(string.upper(model.Name), "_CLIENT", 1, true) ~= nil
    if liveRoot and rawget(record, "networkObserved") == true then record.rootStreamed = true end
    -- A fresh spawn can locate a Root that has not arrived yet. Once that Root
    -- has streamed in, its later removal must not resurrect a stale boss locator.
    local freshBatch = rawget(record, "networkObserved") == true
        and rawget(record, "rootStreamed") ~= true
        and os.clock() - (tonumber(rawget(record, "lastSeen")) or 0) <= 2
        and typeof(rawget(record, "targetCF")) == "CFrame"
    return liveRoot or liveModel or freshBatch
end

local function gcCreatureRecords(): {any}
    local now = os.clock()
    if now < nextGcCreatureRefreshAt then
        return cachedGcCreatureRecords
    end
    -- getgc(true) walks the executor heap. It is only a last-resort locator and
    -- must not compete with physics, streaming, and RemoteFunction traffic.
    nextGcCreatureRefreshAt = now + 3

    local records: {any} = {}
    local seen: any = setmetatable({}, {__mode = "k"})
    local getGc = executorFunction("getgc")
    if getGc then
        local ok, objects = pcall(getGc, true)
        if not ok then
            ok, objects = pcall(getGc)
        end
        if ok and type(objects) == "table" then
            for _, object in pairs(objects) do
                if type(object) == "table" and not seen[object]
                    and validRuntimeCreatureRecord(object) then
                    seen[object] = true
                    records[#records + 1] = object
                end
            end
        end
    end
    cachedGcCreatureRecords = records
    return records
end

local function runtimeRecordServerModel(record: any): any
    local rootAttach = rawget(record, "rootAttach")
    local current = typeof(rootAttach) == "Instance" and rootAttach.Parent or nil
    for _ = 1, 5 do
        if not current or current == Workspace then break end
        if current:IsA("Model") and current:IsDescendantOf(Workspace)
            and not string.find(string.upper(current.Name), "_CLIENT", 1, true)
            and (current:FindFirstChild("CreatureID") or current:FindFirstChild("Health")) then
            runtimeCreatureNames[current] = rawget(record, "name")
            return current
        end
        current = current.Parent
    end
    return nil
end

findRuntimeCreatureTargets = function(wanted: any): {any}
    CreatureFeed.Connect()
    local results: {any} = {}
    local seen: any = setmetatable({}, {__mode = "k"})
    local registry: any = resolveRuntimeCreatureRegistry()
    for _, records in ipairs({CreatureFeed.records, registry or gcCreatureRecords()}) do
        for _, record in pairs(records) do
            if not seen[record] and validRuntimeCreatureRecord(record)
                and wanted[normalizedEntityName(rawget(record, "name"))] then
                seen[record] = true
                local serverModel = runtimeRecordServerModel(record)
                local targetCFrame, model = rawget(record, "targetCF"), rawget(record, "model")
                local rootAttach = rawget(record, "rootAttach")
                local position = typeof(targetCFrame) == "CFrame" and targetCFrame.Position
                    or (typeof(rootAttach) == "Instance" and rootAttach:IsA("BasePart") and rootAttach.Position)
                    or (typeof(model) == "Instance" and entityPosition(model))
                if position and (not serverModel or entityIsAlive(serverModel)) then
                    results[#results + 1] = {locator = record, position = position, serverModel = serverModel}
                end
            end
        end
    end
    return results
end

local function writeClosureUpvalue(closure: any, index: number, value: any): boolean
    local writer: any = resolveUpvalueWriter()
    if not writer then
        return false
    end
    local ok = pcall(writer, closure, index, value)
    if not ok then
        return false
    end
    local readOk, current = readClosureUpvalue(closure, index)
    return not readOk or current == value
end

-- Keep this capability gate in sync with the main SEA script. Unsupported
-- executors must not hammer every Tool/LocalScript on the fast attack loop.
local function ammoPatchSupported(): boolean
    local reader: any = select(1, resolveUpvalueReader())
    return executorFunction("getsenv") ~= nil
        and reader ~= nil
        and resolveUpvalueWriter() ~= nil
end

local function patchAmmoLocalScript(localScript: any): boolean
    local existing = unlimitedAmmoPatches[localScript]
    if existing then
        return writeClosureUpvalue(existing.closure, existing.index, UNLIMITED_MAGAZINE_VALUE)
    end

    local getScriptEnvironment = executorFunction("getsenv")
    if not getScriptEnvironment then
        return false
    end
    local ok, environment = pcall(getScriptEnvironment, localScript)
    if not ok or type(environment) ~= "table" then
        return false
    end

    local fire = rawget(environment, "Fire")
    local restock = rawget(environment, "Restock")
    local reload = rawget(environment, "Reload")
    if type(fire) ~= "function"
        or type(restock) ~= "function"
        or type(reload) ~= "function"
        or type(rawget(environment, "MouseDown")) ~= "function" then
        return false
    end

    local readOk, magazine = readClosureUpvalue(fire, 1)
    if not readOk or type(magazine) ~= "number" then
        return false
    end
    if not writeClosureUpvalue(fire, 1, UNLIMITED_MAGAZINE_VALUE) then
        return false
    end

    -- The supplied gun scripts share the same magazine cell between Fire,
    -- Restock, and Reload (at possibly different indices). Verify that shape so
    -- a game update cannot turn index 1 into an unrelated numeric upvalue.
    local function closureSeesPatchedMagazine(closure: any): boolean
        for index = 1, 10 do
            local valueOk, value = readClosureUpvalue(closure, index)
            if valueOk and value == UNLIMITED_MAGAZINE_VALUE then
                return true
            end
        end
        return false
    end
    if not closureSeesPatchedMagazine(restock) or not closureSeesPatchedMagazine(reload) then
        writeClosureUpvalue(fire, 1, magazine)
        return false
    end

    unlimitedAmmoPatches[localScript] = {
        closure = fire,
        index = 1,
        original = math.max(0, magazine),
        updateUi = rawget(environment, "UpdateUI"),
    }
    local updateUi = unlimitedAmmoPatches[localScript].updateUi
    if type(updateUi) == "function" then
        pcall(updateUi)
    end
    return true
end

local function patchSpecialCooldownTool(tool: any): number
    if not tool or not tool:IsA("Tool") then
        return 0
    end
    local profile = SPECIAL_COOLDOWN_PATCHES[string.lower(tool.Name)]
    if not profile then
        return 0
    end

    if not specialOriginals[tool] then
        specialOriginals[tool] = {enabled = tool.Enabled, canFire = tool:GetAttribute("CanFire"),
            heat = tool:GetAttribute("Heat"), debounce = {}}
    end
    local original = specialOriginals[tool]
    local patched = false
    pcall(function()
        tool.Enabled = true
        if profile.canFire then
            -- CanFire is a client input gate on Raygun/heat weapons. Direct
            -- ToolProcessor calls below still remain subject to server checks.
            tool:SetAttribute("CanFire", true)
            patched = true
        end
        if profile.heat and type(tool:GetAttribute("Heat")) == "number" then
            tool:SetAttribute("Heat", 0)
            patched = true
        end
    end)

    if type(profile.debounce) == "table" then
        local cached = specialCooldownPatches[tool]
        if not cached or not cached.localScript or not cached.localScript.Parent
            or type(cached.mouseDown) ~= "function" then
            cached = nil
            local getScriptEnvironment = executorFunction("getsenv")
            if getScriptEnvironment then
                for _, descendant in ipairs(tool:GetDescendants()) do
                    if descendant:IsA("LocalScript") then
                        local ok, environment = pcall(getScriptEnvironment, descendant)
                        local mouseDown = ok and type(environment) == "table"
                            and rawget(environment, "MouseDown") or nil
                        if type(mouseDown) == "function" then
                            cached = {
                                localScript = descendant,
                                mouseDown = mouseDown,
                            }
                            specialCooldownPatches[tool] = cached
                            break
                        end
                    end
                end
            end
        end

        if cached then
            for _, index in ipairs(profile.debounce) do
                local readOk, current = readClosureUpvalue(cached.mouseDown, index)
                if readOk and type(current) == "boolean" and not original.debounce[index] then
                    original.debounce[index] = {closure = cached.mouseDown, value = current}
                end
                if readOk and type(current) == "boolean"
                    and writeClosureUpvalue(cached.mouseDown, index, false) then
                    patched = true
                end
            end
        end
    end
    return patched and 1 or 0
end

local function patchUnlimitedAmmoTool(tool: any): number
    if not ammoPatchSupported() then return 0 end
    if not tool or not tool:IsA("Tool")
        or (type(tool:GetAttribute("AmmoType")) ~= "string"
            and tool:GetAttribute("IsGun") ~= true) then
        return 0
    end

    local patched = 0
    local descendants: any = tool:GetDescendants()
    for _, rawDescendant in ipairs(descendants) do
        local descendant: any = rawDescendant
        if descendant:IsA("LocalScript") and patchAmmoLocalScript(descendant) then
            patched += 1
        end
    end
    return patched
end

state.restoreCombatPatches = function()
    for localScript, patch in pairs(unlimitedAmmoPatches) do
        if localScript.Parent then
            writeClosureUpvalue(patch.closure, patch.index, patch.original)
            if type(patch.updateUi) == "function" then pcall(patch.updateUi) end
        end
    end
    for tool, original in pairs(specialOriginals) do
        if tool.Parent then
            pcall(function()
                tool.Enabled = original.enabled
                tool:SetAttribute("CanFire", original.canFire)
                tool:SetAttribute("Heat", original.heat)
            end)
            for index, saved in pairs(original.debounce) do writeClosureUpvalue(saved.closure, index, saved.value) end
        end
    end
    table.clear(unlimitedAmmoPatches)
    table.clear(specialOriginals)
end

local function patchAvailableAmmoTools(): (number, number)
    local patched = 0
    local cooldowns = 0
    local containers: {any} = {player:FindFirstChildOfClass("Backpack"), getCharacter()}
    for _, container in ipairs(containers) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                patched += patchUnlimitedAmmoTool(tool)
                cooldowns += patchSpecialCooldownTool(tool)
            end
        end
    end
    return patched, cooldowns
end

task.spawn(function()
    local supported = ammoPatchSupported()
    state.unlimitedAmmoSupported = supported
    local nextSupportCheck = 0
    while isRunning() do
        local now = os.clock()
        if now >= nextSupportCheck then
            nextSupportCheck = now + 1
            supported = ammoPatchSupported()
            state.unlimitedAmmoSupported = supported
        end
        -- Attribute-based Raygun/heat patches remain useful even when an
        -- executor lacks the upvalue API needed by conventional magazines.
        local ok, patched, cooldowns = pcall(patchAvailableAmmoTools)
        state.ammoPatches = ok and type(patched) == "number" and patched or 0
        state.cooldownPatches = ok and type(cooldowns) == "number" and cooldowns or 0
        task.wait(supported and 0.5 or 1.0)
    end
end)

local function getToolProcessor()
    if type(state.toolProcessor) == "function" then
        return state.toolProcessor
    end

    if type(getrenv) == "function" then
        local ok, runtime = pcall(getrenv)
        local candidate = ok and type(runtime) == "table"
            and type(runtime._G) == "table" and runtime._G.ToolProcessor or nil
        if type(candidate) == "function" then
            state.toolProcessor = candidate
            return candidate
        end
    end

    if type(_G) == "table" and type(_G.ToolProcessor) == "function" then
        state.toolProcessor = _G.ToolProcessor
        return state.toolProcessor
    end

    local playerScripts = player:FindFirstChild("PlayerScripts")
    local client = playerScripts and playerScripts:FindFirstChild("Client")
    if client and type(getsenv) == "function" then
        local ok, environment = pcall(getsenv, client)
        if ok and type(environment) == "table" then
            local candidate = environment.ToolProcessor
                or (type(environment._G) == "table" and environment._G.ToolProcessor)
            if type(candidate) == "function" then
                state.toolProcessor = candidate
                return candidate
            end
        end
    end
    return nil
end

local function invokeToolProcessor(...)
    local processor = getToolProcessor()
    if type(processor) ~= "function" then
        return false
    end
    local arguments = table.pack(...)
    state.toolProcessorRequestKeys = type(state.toolProcessorRequestKeys) == "table"
        and state.toolProcessorRequestKeys or {}
    local signature = tostring(arguments[1]) .. "\0" .. tostring(arguments[2])
    local pool = state.toolProcessorRequestKeys[signature]
    if type(pool) ~= "table" then pool = {}; state.toolProcessorRequestKeys[signature] = pool end
    local requestKey
    for index = 1, 3 do
        pool[index] = pool[index] or {}
        local pending = state.boundedInvocations[pool[index]]
        if not pending or pending.done then
            state.boundedInvocations[pool[index]] = nil
            requestKey = pool[index]
            break
        end
    end
    if not requestKey then return false, "combat-network-busy" end
    local ok, result, status = state.invokeBounded(1.15, function()
        return processor(table.unpack(arguments, 1, arguments.n))
    end, requestKey)
    if not ok then
        if status ~= "timeout" then
            state.toolProcessor = nil
        end
        state.lastCombatError = status == "timeout"
            and "ToolProcessor timed out; waiting for prior request"
            or "ToolProcessor request failed"
    else
        state.lastCombatError = nil
    end
    return ok, result
end

local function volcanoWeaponProfile(tool): any
    if not tool or not tool:IsA("Tool") or UTILITY_TOOL_NAMES[tool.Name] then
        return nil
    end

    local lowerName = string.lower(tool.Name)
    local known = VOLCANO_WEAPON_PROFILES[lowerName]
    if known then return table.clone(known) end
    if isMeleeWeapon(tool) then
        return {kind = "melee", base = 60, interval = 0.16, ideal = 5.5, maxRange = 11}
    end
    if tool:GetAttribute("IsGun") == true
        or tool:GetAttribute("AmmoType") ~= nil
        or nameContains(lowerName, {"gun", "rifle", "pistol", "revolver", "blaster", "minigun"}) then
        return {kind = "gun", base = 120, interval = 0.18, ideal = 36, maxRange = 185}
    end
    return nil
end

local function volcanoWeaponDamage(tool)
    local damage = tonumber(tool:GetAttribute("Damage"))
    if damage then
        return math.max(0, damage)
    end
    local value = tool:FindFirstChild("Damage", true)
    if value and value:IsA("ValueBase") then
        return math.max(0, tonumber(value.Value) or 0)
    end
    return 0
end

local function chooseBestVolcanoWeapon(blocked)
    local character = getCharacter()
    local backpack = player:FindFirstChild("Backpack")
    local now = os.clock()
    local bestTool, bestProfile, bestScore

    for _, container in ipairs({character, backpack}) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                local profile = volcanoWeaponProfile(tool)
                local blockedUntil = blocked and blocked[tool]
                if profile and (not blockedUntil or blockedUntil <= now) then
                    local kind: string = volcanoWeaponKind(profile)
                    local damage = volcanoWeaponDamage(tool)
                    local damageMultiplier = tonumber(profile.damageMultiplier) or 1
                    local score = profile.base
                        + damage * damageMultiplier / math.max(profile.interval, 0.08)
                    if kind ~= "melee" and kind ~= "harpoon" then
                        score += 35
                    end
                    if tool.Parent == character then
                        score += 0.01
                    end
                    if not bestScore or score > bestScore then
                        bestTool, bestProfile, bestScore = tool, profile, score
                    end
                end
            end
        end
    end
    return bestTool, bestProfile
end

local function equipBestVolcanoWeapon(blocked)
    local character = getCharacter()
    local humanoid = getHumanoid()
    if not character or not humanoid then
        state.currentWeapon = nil
        return nil, nil
    end

    local tool, profile = chooseBestVolcanoWeapon(blocked)
    if not tool then
        state.currentWeapon = nil
        return nil, nil
    end
    if tool.Parent ~= character then
        pcall(function()
            humanoid:EquipTool(tool)
        end)
        task.wait(0.12)
    end
    if tool.Parent ~= character then
        state.currentWeapon = nil
        return nil, nil
    end
    pcall(patchUnlimitedAmmoTool, tool)
    pcall(patchSpecialCooldownTool, tool)
    state.currentWeapon = tool.Name
    return tool, profile
end

local function weaponPrimary(tool)
    if not tool then
        return nil
    end
    local primary = tool:FindFirstChild("PrimaryPart")
        or tool:FindFirstChild("Handle")
        or tool:FindFirstChildWhichIsA("BasePart", true)
    return primary and primary:IsA("BasePart") and primary or nil
end

local function shotData(tool, targetPosition, shotgun)
    local primary = weaponPrimary(tool)
    if not primary or not targetPosition then
        return nil, nil, nil
    end

    local origin = primary.Position
    local muzzle = primary:FindFirstChild("Muzzle", true)
    if muzzle then
        if muzzle:IsA("Attachment") or muzzle:IsA("Bone") then
            origin = muzzle.WorldPosition
        elseif muzzle:IsA("BasePart") then
            origin = muzzle.Position
        end
    end

    if (targetPosition - origin).Magnitude < 0.01 then
        return nil, nil, nil
    end
    local aim = CFrame.lookAt(origin, targetPosition)
    local center = CFrame.new(targetPosition) * (aim - aim.Position)
    local shots = {center}
    if shotgun then
        for x = -1, 1 do
            for y = -1, 1 do
                if x ~= 0 or y ~= 0 then
                    table.insert(shots, center * CFrame.new(x * 1.5, y * 1.5, 0))
                end
            end
        end
    end
    return primary, origin, shots
end

local function performVolcanoAttack(tool, profile, model)
    if not tool or not profile or tool.Parent ~= getCharacter()
        or not model or not entityIsAlive(model) then
        return false
    end

    pcall(patchUnlimitedAmmoTool, tool)
    pcall(patchSpecialCooldownTool, tool)

    local targetPosition = entityPosition(model)
    if not targetPosition then
        return false
    end
    local kind: string = volcanoWeaponKind(profile)
    local canFire = tool:GetAttribute("CanFire")
    if canFire == false and profile.bypassCanFire ~= true
        and not VOLCANO_IGNORES_CAN_FIRE[kind] then
        return false
    end

    if profile.activate then
        pcall(function()
            tool:Activate()
        end)
    end

    if kind == "gun" then
        local primary, _, shots = shotData(tool, targetPosition, profile.shotgun)
        return primary ~= nil and select(1, invokeToolProcessor("Gun", "Shoot", primary, shots))
    elseif kind == "boomstick" then
        local _, origin = shotData(tool, targetPosition, false)
        return origin ~= nil and select(1, invokeToolProcessor("Boomstick", "Shoot", origin, targetPosition))
    elseif kind == "ghost" then
        return select(1, invokeToolProcessor("Ghost Blaster", "Fire", targetPosition))
    elseif kind == "magma" then
        return select(1, invokeToolProcessor("Magma Staff", "Fire", targetPosition))
    elseif kind == "wizard" then
        return select(1, invokeToolProcessor("Wizard Staff", "Fire", targetPosition))
    elseif kind == "laser" then
        return select(1, invokeToolProcessor("Laser", "Shoot", targetPosition))
    elseif kind == "ice" then
        local remote = tool:FindFirstChild("IceRemote", true)
        local root = getRoot()
        if remote and remote:IsA("RemoteEvent") and root then
            player:SetAttribute("IceStaffActive", true)
            return pcall(function()
                remote:FireServer((targetPosition - root.Position).Unit)
            end)
        end
        return false
    elseif kind == "necro" then
        local remote = tool:FindFirstChild("NecroRemote", true)
        if remote and remote:IsA("RemoteEvent") then
            return pcall(function()
                remote:FireServer("Strike", targetPosition)
            end)
        end
        return false
    elseif kind == "harpoon" then
        -- Reuse script utama invokeCreatureServerHit: Fire must precede HitEnemy.
        local source = tool:FindFirstChild("Harpoon1", true) or getRoot()
        if not source then return false end
        if not select(1, invokeToolProcessor(tool.Name, "Fire", source.Position, targetPosition)) then return false end
        task.wait(0.035)
        if tool.Parent ~= getCharacter() or not entityIsAlive(model) then return false end
        return select(1, invokeToolProcessor(tool.Name, "HitEnemy", model))
    end

    local activated = pcall(function()
        tool:Activate()
    end)
    -- Melee retains native Tool activation; HitEnemy is the Harpoon protocol.
    task.delay(0.08, function()
        if tool and tool.Parent then
            pcall(function()
                tool:Deactivate()
            end)
        end
    end)
    return activated
end

local ATTACK_BOOL_ATTRIBUTES = {
    "Attacking", "IsAttacking", "AttackActive", "AttackInProgress",
    "ChargingAttack", "CastingAttack", "LaserAttack", "StompAttack", "RockAttack",
}
local ATTACK_TOKENS = {
    "attack", "swing", "slam", "stomp", "laser", "rock", "throw",
    "cast", "punch", "smash", "strike", "bite", "charge",
}

local function textHasToken(value, tokens)
    local textValue = string.lower(tostring(value or ""))
    for _, token in ipairs(tokens) do
        if string.find(textValue, token, 1, true) then
            return true
        end
    end
    return false
end

local function targetValueMatch(value)
    local valueType = typeof(value)
    local character = getCharacter()
    if valueType == "Instance" then
        if value == player or value == character
            or (character and value:IsDescendantOf(character)) then
            return true, true
        end
        for _, other in ipairs(Players:GetPlayers()) do
            if other ~= player and (value == other or value == other.Character
                or (other.Character and value:IsDescendantOf(other.Character))) then
                return false, true
            end
        end
    elseif valueType == "string" then
        local normalized = string.lower(value)
        if normalized == string.lower(player.Name)
            or normalized == string.lower(player.DisplayName) then
            return true, true
        end
        for _, other in ipairs(Players:GetPlayers()) do
            if other ~= player and (normalized == string.lower(other.Name)
                or normalized == string.lower(other.DisplayName)) then
                return false, true
            end
        end
    elseif valueType == "number" then
        if value == player.UserId then
            return true, true
        end
        for _, other in ipairs(Players:GetPlayers()) do
            if other ~= player and value == other.UserId then
                return false, true
            end
        end
    end
    return false, false
end

local function enemyTargetsPlayer(model)
    local foundTarget = false
    for _, name in ipairs({"Target", "AttackTarget", "CurrentTarget", "TargetName", "TargetUserId"}) do
        local value = model:GetAttribute(name)
        if value ~= nil then
            local matches, recognized = targetValueMatch(value)
            if recognized then
                foundTarget = true
                if matches then
                    return true
                end
            end
        end
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        local normalized = normalizedEntityName(descendant.Name)
        if normalized == "target" or normalized == "attacktarget"
            or normalized == "currenttarget" then
            local ok, value = pcall(function()
                return descendant.Value
            end)
            if ok then
                local matches, recognized = targetValueMatch(value)
                if recognized then
                    foundTarget = true
                    if matches then
                        return true
                    end
                end
            end
        end
    end
    if foundTarget then
        return false
    end
    return nil
end

local function enemyIsAttacking(model)
    local targetsPlayer = enemyTargetsPlayer(model)
    if targetsPlayer == false then
        return false
    end

    for _, name in ipairs(ATTACK_BOOL_ATTRIBUTES) do
        if model:GetAttribute(name) == true then
            return true
        end
    end
    for _, name in ipairs({"State", "Action", "Mode"}) do
        if textHasToken(model:GetAttribute(name), ATTACK_TOKENS) then
            return true
        end
    end

    -- CreatureClient keeps the authoritative root/Health on the server model but
    -- plays animations and attack sounds on its paired *_CLIENT clone. Inspect
    -- both halves of that exact registry record; nearby unrelated clone rigs must
    -- never make this enemy appear to be attacking.
    local animationSources: {any} = {model}
    local wanted = identityMatches(model, GOLEM_BOSS_NAMES) and GOLEM_BOSS_NAMES
        or identityMatches(model, MAGMA_GOLEM_NAMES) and MAGMA_GOLEM_NAMES
        or {[normalizedEntityName(model.Name)] = true}
    if type(findRuntimeCreatureTargets) == "function" then
        for _, entry in ipairs(findRuntimeCreatureTargets(wanted)) do
            if entry.serverModel == model and type(entry.locator) == "table" then
                local visual = rawget(entry.locator, "model")
                if typeof(visual) == "Instance" and visual.Parent and visual ~= model then
                    animationSources[#animationSources + 1] = visual
                    break
                end
                -- A native batch has no visual model; continue to the paired
                -- CreatureClient registry record for attack animations.
            end
        end
    end

    for _, source in ipairs(animationSources) do
        local humanoid = source:FindFirstChildWhichIsA("Humanoid", true)
        local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
        if animator then
            local ok, tracks = pcall(function()
                return animator:GetPlayingAnimationTracks()
            end)
            if ok then
                for _, track in ipairs(tracks) do
                    local label = track.Name
                    pcall(function()
                        if track.Animation then
                            label ..= " " .. track.Animation.Name
                        end
                    end)
                    local actionPriority = track.Priority == Enum.AnimationPriority.Action
                        or track.Priority == Enum.AnimationPriority.Action2
                        or track.Priority == Enum.AnimationPriority.Action3
                        or track.Priority == Enum.AnimationPriority.Action4
                    local nonAttack = textHasToken(label, {
                        "idle", "walk", "run", "swim", "fall", "hit", "hurt",
                        "flinch", "stun", "death", "die", "spawn",
                    })
                    if textHasToken(label, ATTACK_TOKENS)
                        or (actionPriority and not nonAttack) then
                        return true
                    end
                end
            end
        end
    end

    for _, source in ipairs(animationSources) do
        for _, descendant in ipairs(source:GetDescendants()) do
            if descendant:IsA("BoolValue") and descendant.Value
                and textHasToken(descendant.Name, ATTACK_TOKENS) then
                return true
            end
            if descendant:IsA("Sound") and descendant.Playing
                and textHasToken(descendant.Name, ATTACK_TOKENS) then
                return true
            end
        end
    end
    return false
end

local function finishVolcanoHover(context)
    if not context or context.closed then return end
    context.closed = true
    if context.connection then context.connection:Disconnect() end
    if context.descendantConnection then context.descendantConnection:Disconnect() end
    if state.volcanoHoverContext ~= context then return end
    state.volcanoHoverContext, state.volcanoHoverActive = nil, false
    state.combatMode = "Safe combat ready"
    for part, canCollide in pairs(context.collision) do
        if part.Parent then pcall(function() part.CanCollide = canCollide end) end
    end
    local humanoid = context.humanoid
    if humanoid and humanoid.Parent then
        humanoid.PlatformStand = context.platformStand
        humanoid.AutoRotate = context.autoRotate
        humanoid.Sit = false
        if not context.platformStand and humanoid.Health > 0 then
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
    end
    player:SetAttribute("IceStaffActive", nil)
    if context.usedLaser then
        task.spawn(function()
            if state.runToken == runToken and not state.volcanoHoverContext then
                invokeToolProcessor("Laser", "End")
            end
        end)
    end
end

-- Include height in the weapon range budget, even during an emergency dodge.
local function combatOffsets(profile, boss, evading)
    local maxRange = math.max(1, tonumber(profile and profile.maxRange) or 35) * 0.85
    local melee = volcanoWeaponKind(profile) == "melee"
    local height = math.min(melee and (evading and 4 or 3) or (boss and 20 or 14), maxRange * 0.5)
    local horizontalLimit = math.sqrt(math.max(0, maxRange * maxRange - height * height))
    local ideal = tonumber(profile and profile.ideal) or 30
    local distance = evading and math.max(ideal * 1.5, boss and 90 or 50) or ideal
    return math.min(distance, horizontalLimit), height
end

local function safeCombatPosition(model, profile, boss, evading)
    local root, enemy = getRoot(), entityPosition(model)
    if not root or not enemy or not profile then return nil end
    local range, height = combatOffsets(profile, boss, evading)
    local away = Vector3.new(root.Position.X - enemy.X, 0, root.Position.Z - enemy.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(0, 0, 1) else away = away.Unit end
    local params = RaycastParams.new()
    params.FilterType, params.IgnoreWater = Enum.RaycastFilterType.Exclude, true
    local excluded = {getCharacter(), model}
    local visual = model.Parent and model.Parent:FindFirstChild(model.Name .. "_CLIENT")
    if visual then excluded[#excluded + 1] = visual end
    params.FilterDescendantsInstances, params.RespectCanCollide = excluded, true
    local threats = {enemy}
    local container = Workspace:FindFirstChild("CreatureContainer")
    if container then
        for _, other in ipairs(container:GetChildren()) do
            if other ~= model and other:IsA("Model") and not isPassive(other.Name) and entityIsAlive(other) then
                local position = entityPosition(other)
                if position and (position - enemy).Magnitude < profile.maxRange * 2 then threats[#threats + 1] = position end
            end
        end
    end
    local best, bestScore
    for i = 0, 7 do
        local angle = math.rad((evading and 90 or 0) + i * 45)
        local direction = Vector3.new(away.X * math.cos(angle) - away.Z * math.sin(angle), 0,
            away.X * math.sin(angle) + away.Z * math.cos(angle))
        local candidate = enemy + direction * range + Vector3.new(0, height, 0)
        local clear = not Workspace:Raycast(candidate, enemy - candidate, params)
            and not Workspace:Raycast(candidate - Vector3.new(0, 2, 0), Vector3.new(0, 5, 0), params)
            and not Workspace:Raycast(candidate - direction * 2, direction * 4, params)
        if clear then
            local clearance = math.huge
            for _, threat in ipairs(threats) do clearance = math.min(clearance, (candidate - threat).Magnitude) end
            local score = clearance + (evading and math.min((candidate - root.Position).Magnitude, range) * 0.1 or -i * 0.1)
            if not bestScore or score > bestScore then best, bestScore = candidate, score end
        end
    end
    return best
end

local function beginVolcanoHover(model, profile)
    local character, humanoid = getCharacter(), getHumanoid()
    local targetPosition = entityPosition(model)
    if not character or not humanoid or not targetPosition or not profile then return nil end
    local boss = identityMatches(model, GOLEM_BOSS_NAMES)
    local initialKind: string = volcanoWeaponKind(profile)
    local arrival = safeCombatPosition(model, profile, boss, false)
    if not arrival then state.lastCombatError = "Waiting for a clear attack position"; return nil end
    if not teleportCharacter(CFrame.lookAt(arrival, Vector3.new(targetPosition.X, arrival.Y, targetPosition.Z)), 0.12, false) then
        return nil
    end
    if not isRunning() or getCharacter() ~= character then return nil end
    state.volcanoHoverActive = true

    local context: any = {
        character = character,
        humanoid = humanoid,
        profile = profile,
        boss = boss,
        evading = false,
        collision = {},
        autoRotate = humanoid.AutoRotate,
        platformStand = humanoid.PlatformStand,
        usedLaser = initialKind == "laser",
    }
    state.volcanoHoverContext = context
    context.close = function() finishVolcanoHover(context) end
    function context:Dodge()
        if not isRunning() or self.closed or state.volcanoHoverContext ~= self
            or os.clock() < (self.nextDodgeAt or 0) then return false end
        self.nextDodgeAt = os.clock() + Settings.SAFE_COMBAT_COOLDOWN
        local position = safeCombatPosition(model, self.profile, self.boss, true)
        local enemy, root = entityPosition(model), getRoot()
        if not position or not enemy or not root then return false end
        self.evadeDirection = Vector3.new(position.X - enemy.X, 0, position.Z - enemy.Z).Unit
        local cf = CFrame.lookAt(position, Vector3.new(enemy.X, position.Y, enemy.Z))
        -- The same placement as teleportCharacter, keeping this combat hover alive.
        -- Motion.Begin would close the hover before the emergency dodge.
        self.character:PivotTo(cf)
        root.CFrame = cf
        zeroCharacterMotion(self.character)
        state.combatMode = "Safe teleport / attacking"
        return true
    end

    local function suppressCollision(instance: any)
        if instance and instance:IsA("BasePart") then
            if context.collision[instance] == nil then
                context.collision[instance] = instance.CanCollide
            end
            instance.CanCollide = false
        end
    end
    for _, descendant in ipairs(character:GetDescendants()) do
        suppressCollision(descendant)
    end
    context.descendantConnection = character.DescendantAdded:Connect(suppressCollision)

    context.connection = RunService.Heartbeat:Connect(function(deltaTime)
        if state.volcanoHoverContext ~= context or not isRunning() or not model.Parent
            or getCharacter() ~= context.character then
            finishVolcanoHover(context)
            return
        end
        pcall(function()
            local root = getRoot()
            local currentHumanoid = getHumanoid()
            local enemyPosition = entityPosition(model)
            if not root or not currentHumanoid or not enemyPosition or currentHumanoid.Health <= 0 then
                return
            end

            currentHumanoid.Sit = false
            currentHumanoid.PlatformStand = true
            currentHumanoid.AutoRotate = false

            local activeProfile = context.profile
            local desiredRange, desiredHeight = combatOffsets(activeProfile, context.boss, context.evading)

            local away = Vector3.new(
                root.Position.X - enemyPosition.X,
                0,
                root.Position.Z - enemyPosition.Z
            )
            if away.Magnitude < 0.25 then
                local enemyPart = entityPart(model)
                away = enemyPart and -Vector3.new(
                    enemyPart.CFrame.LookVector.X,
                    0,
                    enemyPart.CFrame.LookVector.Z
                ) or Vector3.new(0, 0, 1)
            end
            if away.Magnitude < 0.25 then
                away = Vector3.new(0, 0, 1)
            end

            if context.evading and context.evadeDirection then away = context.evadeDirection end
            local desired = enemyPosition + away.Unit * desiredRange
                + Vector3.new(0, desiredHeight, 0)
            local offset = desired - root.Position
            local step = math.min(offset.Magnitude, Settings.VOLCANO_FLY_SPEED * math.min(deltaTime, 0.10))
            local nextPosition = root.Position
            if offset.Magnitude > 0.01 then
                nextPosition += offset.Unit * step
            end
            root.CFrame = CFrame.lookAt(nextPosition, Vector3.new(enemyPosition.X, nextPosition.Y, enemyPosition.Z))
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end)
    return context
end

local function fightEntity(model, options)
    if not model or not model.Parent then
        return false
    end

    options = options or {}
    local bossTarget = identityMatches(model, GOLEM_BOSS_NAMES)
    local blocked = setmetatable({}, {__mode = "k"})
    local tool, profile = equipBestVolcanoWeapon(blocked)
    if not tool or not profile then state.lastCombatError = "Waiting for a usable weapon"; return false end
    local hover = beginVolcanoHover(model, profile)
    if not hover then
        return false
    end

    local basePhase = state.phase or "Volcano combat"
    local targetHealth = entityHealth(model)
    local lastHealth = targetHealth
    local damageObserved = false
    local explicitDeathObserved = false
    local lastKnownPosition = entityPosition(model)
    local humanoid = getHumanoid()
    local lastPlayerHealth = humanoid and humanoid.Health or 0
    local nextEquipAt = 0
    local nextAttackAt = 0
    local lastWeaponProgress = os.clock()
    local progressDeadline = os.clock() + Settings.VOLCANO_NO_DAMAGE_TIMEOUT
    local evadeUntil = 0
    local attacksInFlight = 0
    local nextAttackSignalAt = 0
    local cachedAttackSignal = false
    local fightDeadline = options.maxSeconds and (os.clock() + options.maxSeconds) or math.huge
    local nativeFallback = setmetatable({}, {__mode = "k"})

    local battleOk, battleError = pcall(function()
    while isRunning() and model.Parent and entityIsAlive(model)
        and os.clock() < progressDeadline and os.clock() < fightDeadline
        and (not options.canContinue or options.canContinue()) do
        local now = os.clock()
        humanoid = getHumanoid()
        local root = getRoot()
        if not humanoid or humanoid.Health <= 0 or not root
            or getCharacter() ~= hover.character then
            break
        end

        local currentHealth = entityHealth(model)
        if currentHealth and lastHealth and currentHealth < lastHealth - 0.001 then
            damageObserved = true
            state.lastCombatError = nil
            progressDeadline = now + Settings.VOLCANO_NO_DAMAGE_TIMEOUT
            lastWeaponProgress = now
        end
        if currentHealth ~= nil and currentHealth <= 0
            or model:GetAttribute("Dead") == true then
            explicitDeathObserved = true
        end
        if currentHealth ~= nil then
            lastHealth = currentHealth
        end
        local currentPosition = entityPosition(model)
        if currentPosition then
            lastKnownPosition = currentPosition
        end

        local takingDamage = humanoid.Health < lastPlayerHealth - 0.001
        if takingDamage then
            evadeUntil = math.max(evadeUntil, now + 2.0)
        end
        lastPlayerHealth = humanoid.Health
        if now >= nextAttackSignalAt then
            nextAttackSignalAt = now + 0.18
            cachedAttackSignal = enemyIsAttacking(model)
        end
        if cachedAttackSignal then
            evadeUntil = math.max(evadeUntil, now + (hover.boss and 1.25 or 0.85))
        end
        local distance = currentPosition and (root.Position - currentPosition).Magnitude or math.huge
        local tooClose = profile and distance < math.min(profile.ideal * 0.6, profile.maxRange * 0.45)
        if tooClose then evadeUntil = math.max(evadeUntil, now + 0.85) end
        hover.evading = now < evadeUntil
        if (takingDamage or cachedAttackSignal or tooClose) and hover.profile then hover:Dodge() end
        state.combatMode = hover.evading and "Safe teleport / attacking" or "Attacking"

        if not tool or not tool.Parent or tool.Parent ~= getCharacter()
            or now >= nextEquipAt then
            local selected, selectedProfile = equipBestVolcanoWeapon(blocked)
            nextEquipAt = now + 0.75
            if selected then
                if selected ~= tool then
                    lastWeaponProgress = now
                    nextAttackAt = 0
                end
                if selected == tool then selectedProfile = profile end
                tool, profile = selected, selectedProfile
                if nativeFallback[tool] and profile.nativeInterval then profile.interval = profile.nativeInterval end
                hover.profile = profile
                if volcanoWeaponKind(profile) == "laser" then
                    hover.usedLaser = true
                end
            end
        end

        if tool and profile and profile.nativeInterval and not nativeFallback[tool]
            and now - lastWeaponProgress > 3 then
            nativeFallback[tool] = true
            profile.interval = profile.nativeInterval
            state.fireMode = "native fallback"
        end
        if tool and now - lastWeaponProgress > 8 then
            -- Keep a non-damaging/empty weapon out for this target. If it was
            -- the only weapon, the all-blocked branch clears the set and retries.
            blocked[tool] = math.huge
            tool, profile = nil, nil
            hover.profile = nil
            lastWeaponProgress = now
            nextEquipAt = 0
        end
        if not tool then
            local retryTool = chooseBestVolcanoWeapon(blocked)
            if not retryTool then
                table.clear(blocked)
            end
        end

        local mode = hover.evading and "Evading" or "Attacking"
        state.phase = string.format("%s | %s", basePhase, mode)
        local maxInFlight = profile and math.clamp(
            math.floor(tonumber(profile.maxInFlight) or 1),
            1,
            6
        ) or 1
        if tool and profile and now >= nextAttackAt and attacksInFlight < maxInFlight then
            local targetPosition = entityPosition(model)
            local attackDistance = targetPosition and (targetPosition - root.Position).Magnitude or math.huge
            if attackDistance <= profile.maxRange then
                state.fireMode = profile.nativeInterval and not nativeFallback[tool] and "fast" or "native"
                nextAttackAt = now + profile.interval
                attacksInFlight += 1
                local attackTool, attackProfile = tool, profile
                local released = false
                local completed = false
                local function releaseAttackSlot()
                    if released then
                        return
                    end
                    released = true
                    attacksInFlight = math.max(0, attacksInFlight - 1)
                end
                task.spawn(function()
                    if isRunning() and state.volcanoHoverContext == hover and not hover.closed then
                        pcall(performVolcanoAttack, attackTool, attackProfile, model)
                    end
                    completed = true
                    releaseAttackSlot()
                end)
                task.delay(1.5, function()
                    if not completed then
                        releaseAttackSlot()
                        blocked[attackTool] = os.clock() + 2
                        state.lastCombatError = "ToolProcessor timeout: " .. tostring(attackTool.Name)
                    end
                end)
            end
        end
        task.wait(0.025)
    end
    end)

    finishVolcanoHover(hover)
    state.phase = basePhase
    local remainingHealth = model.Parent and entityHealth(model) or nil
    explicitDeathObserved = explicitDeathObserved
        or model:GetAttribute("Dead") == true
        or (remainingHealth ~= nil and remainingHealth <= 0)
    local root = getRoot()
    local removalNearTarget = not model.Parent and damageObserved and root
        and lastKnownPosition and (root.Position - lastKnownPosition).Magnitude <= 220
    local confirmedRemoval = removalNearTarget == true

    -- A streamed boss can briefly disappear while its island/model is rebuilt.
    -- Magma Golems still require a sackable corpse after this function, but the
    -- boss has no equivalent downstream proof, so confirm sustained absence
    -- before allowing the pearl state machine to advance.
    if bossTarget and confirmedRemoval and not explicitDeathObserved then
        confirmedRemoval = false
        state.phase = basePhase .. " | Confirming Lord of Lava defeat"
        local confirmationDeadline = os.clock() + 1.35
        repeat
            if lastKnownPosition then
                requestStreamNear(lastKnownPosition)
            end
            local locator = select(1, findNearestCombatLocator(GOLEM_BOSS_NAMES))
            if locator then
                state.lastCombatError = "Lord of Lava disappeared before death confirmation; reacquiring"
                break
            end
            if os.clock() >= confirmationDeadline then
                confirmedRemoval = true
                break
            end
            task.wait(0.08)
        until not isRunning()
    end

    local defeated = explicitDeathObserved or confirmedRemoval
    if defeated then
        state.lastCombatError = nil
    end
    if not defeated then
        state.phase = battleOk and (basePhase .. " | Retrying combat")
            or (basePhase .. " | Combat recovered")
        if not battleOk then
            state.lastCombatError = tostring(battleError)
        end
    end
    return defeated
end

local function storeMagmaCorpse(model)
    if not model or not model:IsDescendantOf(Workspace) then return false end
    local sack, net = equipSack(), sackNet()
    local part = getNativeStorePart({model = model, owner = model, part = entityPart(model)})
    if not sack or not net or not part or not part:IsDescendantOf(Workspace) then return false end
    local used, capacity = getSackCount()
    if not used or not capacity then state.phase = "Waiting for Sack counter"; return false end
    if used >= capacity then state.phase = "Sack full: waiting for room for Magma Golem"; return false end
    local position = part.Position
    if not teleportCharacter(CFrame.lookAt(position + Vector3.new(0, 2.5, 2.5), position)) then return false end
    if SackTransfer.Store(model, part, net, sack, 1.8, "golem") then
        state.lastStoreError = nil
        return true
    end
    state.lastStoreError = "Magma Golem storage unconfirmed: target and Sack counter must agree"
    return false
end

local function reconcileVolcanoSack(ritual: any): (any, any)
    local used, capacity = getSackCount()
    SackTransfer.ObserveGolemDrop(ritual.dropTransaction)
    ritual.held = math.max(0, tonumber(ritual.held) or 0)
    ritual.submitted = math.clamp(tonumber(ritual.submitted) or 0, 0, Settings.MAGMA_GOLEM_TARGET)
    -- A lower inventory can invalidate our count; a higher count can never prove
    -- that some unrelated item was a Magma Golem.
    if type(used) == "number" and not ritual.dropTransaction then
        ritual.held = math.min(ritual.held, used)
    end
    ritual.stored = math.clamp(ritual.held + ritual.submitted, 0, Settings.MAGMA_GOLEM_TARGET)
    return used, capacity
end

local function findVolcano()
    local islands = Workspace:FindFirstChild("IslandContainer")
    if not islands then
        return nil
    end
    local direct = islands:FindFirstChild("VolcanoPOI")
    if direct and direct:IsA("Model") then
        return direct
    end
    for _, instance in ipairs(islands:GetDescendants()) do
        if instance:IsA("Model") and normalizedEntityName(instance.Name) == "volcanopoi" then
            return instance
        end
    end
    return nil
end

local function volcanoCenter(volcano)
    local ok, cf = pcall(function()
        return volcano:GetPivot()
    end)
    return ok and cf.Position or nil
end

local function volcanoCraterPosition(volcano)
    local center = volcanoCenter(volcano)
    if not center then
        return nil
    end

    -- On the captured map the POI pivot is at sea level while the magma rim is
    -- about 190 studs higher. Prefer streamed summit parts when available.
    local summitY = center.Y + 188
    for _, descendant in ipairs(volcano:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local horizontal = Vector2.new(
                descendant.Position.X - center.X,
                descendant.Position.Z - center.Z
            ).Magnitude
            if horizontal < 180 and descendant.Position.Y < center.Y + 270 then
                summitY = math.max(summitY, descendant.Position.Y + 5)
            end
        end
    end
    return Vector3.new(center.X, summitY, center.Z)
end

local function volcanoMarkerCFrame(): any
    local distant = ReplicatedStorage:FindFirstChild("DistantIslands")
    local marker = distant and distant:FindFirstChild("VolcanoPOI")
    if marker and marker:IsA("BasePart") then
        return marker.CFrame
    elseif marker and marker:IsA("Model") then
        local ok, pivot = pcall(marker.GetPivot, marker)
        if ok then
            return pivot
        end
    end
    return nil
end

-- VolcanoPOI's marker/pivot is the crater centre, not a valid player landing.
-- Use the same surface-validation principle as SEA Island Travel, but search the
-- Volcano's outer slope first. These are local raycasts; the character does not
-- hop around the ring. A streamed SpikyPalm is the preferred real-island anchor.
local VOLCANO_LANDING_RADII = {228, 190, 265, 155, 305, 125}
local VOLCANO_LANDING_DIRECTIONS = {
    Vector3.new(1, 0, 0),
    Vector3.new(-1, 0, 0),
    Vector3.new(0, 0, 1),
    Vector3.new(0, 0, -1),
    Vector3.new(1, 0, 1).Unit,
    Vector3.new(-1, 0, 1).Unit,
    Vector3.new(1, 0, -1).Unit,
    Vector3.new(-1, 0, -1).Unit,
}

local function safeVolcanoSurface(hit: any, minimumY: number): boolean
    if not hit or hit.Position.Y < minimumY or hit.Normal.Y < 0.62
        or hit.Material == Enum.Material.Water
        or hit.Material == Enum.Material.CrackedLava then
        return false
    end

    local instance = hit.Instance
    if not instance then
        return false
    end
    if instance:IsA("BasePart") and not instance.CanCollide then
        return false
    end

    local current: any = instance
    for _ = 1, 5 do
        if not current or current == Workspace then
            break
        end
        local lowered = string.lower(current.Name)
        for _, hazard in ipairs({
            "lava", "water", "killbrick", "damage", "spike", "leaves", "foliage",
        }) do
            if string.find(lowered, hazard, 1, true) then
                return false
            end
        end
        current = current.Parent
    end
    return true
end

local function appendVolcanoLandingCandidate(
    candidates: {any},
    seen: {[string]: boolean},
    center: Vector3,
    position: any
)
    if typeof(position) ~= "Vector3" then
        return
    end
    local horizontal = Vector3.new(position.X - center.X, 0, position.Z - center.Z)
    if horizontal.Magnitude < 105 or horizontal.Magnitude > 340 then
        return
    end
    local key = string.format("%.0f:%.0f", position.X, position.Z)
    if seen[key] then
        return
    end
    seen[key] = true
    candidates[#candidates + 1] = position
end

local function volcanoIslandLanding(volcano: any, center: Vector3, cached: any): any
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if not terrain then
        return nil
    end

    local candidates: {any} = {}
    local seen: {[string]: boolean} = {}
    appendVolcanoLandingCandidate(candidates, seen, center, cached)

    local palm = volcano and volcano:FindFirstChild("SpikyPalm", true)
    local palmPosition = palm and entityPosition(palm) or nil
    if palmPosition then
        local radial = Vector3.new(palmPosition.X - center.X, 0, palmPosition.Z - center.Z)
        if radial.Magnitude > 1 then
            local outward = radial.Unit
            local tangent = Vector3.new(-outward.Z, 0, outward.X)
            appendVolcanoLandingCandidate(candidates, seen, center, palmPosition + outward * 12)
            appendVolcanoLandingCandidate(candidates, seen, center, palmPosition + tangent * 14)
            appendVolcanoLandingCandidate(candidates, seen, center, palmPosition - tangent * 14)
            appendVolcanoLandingCandidate(candidates, seen, center, palmPosition - outward * 12)
        end
    end

    for _, radius in ipairs(VOLCANO_LANDING_RADII) do
        for _, direction in ipairs(VOLCANO_LANDING_DIRECTIONS) do
            appendVolcanoLandingCandidate(
                candidates,
                seen,
                center,
                center + direction * radius
            )
        end
    end

    -- The actual Volcano land mass is Terrain; excluding the POI decorations
    -- prevents a chest lid or palm canopy from being mistaken for safe ground.
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = {terrain}
    params.IgnoreWater = true
    params.RespectCanCollide = true

    local minimumY = math.max(147.5, center.Y - 400)
    local castY = math.max(500, center.Y + 280)
    for _, candidate in ipairs(candidates) do
        local origin = Vector3.new(candidate.X, castY, candidate.Z)
        local hit = Workspace:Raycast(
            origin,
            Vector3.new(0, minimumY - castY - 1, 0),
            params
        )
        if safeVolcanoSurface(hit, minimumY) then
            local supported = true
            for _, side in ipairs({
                Vector3.new(2, 0, 0),
                Vector3.new(-2, 0, 0),
                Vector3.new(0, 0, 2),
                Vector3.new(0, 0, -2),
            }) do
                local ground = Workspace:Raycast(
                    hit.Position + side + Vector3.new(0, 4, 0),
                    Vector3.new(0, -8, 0),
                    params
                )
                if not safeVolcanoSurface(ground, minimumY)
                    or math.abs(ground.Position.Y - hit.Position.Y) > 3 then
                    supported = false
                    break
                end
            end
            local ceiling = Workspace:Raycast(
                hit.Position + Vector3.new(0, 0.4, 0),
                Vector3.new(0, 7, 0),
                params
            )
            if supported and not ceiling then
                return hit.Position
            end
        end
    end
    return nil
end

local function volcanoOuterProbe(volcano: any, center: Vector3, markerCFrame: any): Vector3
    local palm = volcano and volcano:FindFirstChild("SpikyPalm", true)
    local palmPosition = palm and entityPosition(palm) or nil
    local horizontal
    if palmPosition then
        horizontal = Vector3.new(palmPosition.X - center.X, 0, palmPosition.Z - center.Z)
    elseif typeof(markerCFrame) == "CFrame" then
        local right = markerCFrame.RightVector
        horizontal = Vector3.new(right.X, 0, right.Z)
    end
    if not horizontal or horizontal.Magnitude < 1 then
        horizontal = Vector3.new(1, 0, 0)
    end
    horizontal = horizontal.Unit * 228
    return Vector3.new(
        center.X + horizontal.X,
        math.max(center.Y + 150, Settings.WORLD_SCAN_SAFE_MIN_Y + 90),
        center.Z + horizontal.Z
    )
end

local BASALT_LANDING_RADII = {52, 76, 102, 124, 30, 0}

local function basaltTowerMarkers(): {any}
    local records: {any} = {}
    local seen: {[string]: boolean} = {}
    local distant = ReplicatedStorage:FindFirstChild("DistantIslands")
    if not distant then
        return records
    end

    for _, marker in ipairs(distant:GetChildren()) do
        if normalizedEntityName(marker.Name) == "basalttowerpoi" then
            local markerCFrame
            if marker:IsA("BasePart") then
                markerCFrame = marker.CFrame
            elseif marker:IsA("Model") then
                local ok, pivot = pcall(marker.GetPivot, marker)
                if ok then
                    markerCFrame = pivot
                end
            end

            local biome = marker:GetAttribute("Biome")
            if typeof(markerCFrame) == "CFrame"
                and (biome == nil or normalizedEntityName(biome) == "volcano") then
                local position = markerCFrame.Position
                local key = string.format("%.0f:%.0f", position.X, position.Z)
                if not seen[key] then
                    seen[key] = true
                    local record: any = {
                        marker = marker,
                        cframe = markerCFrame,
                        position = position,
                        key = key,
                    }
                    records[#records + 1] = record
                end
            end
        end
    end

    -- Same-name POIs must keep a deterministic order even if Roblox returns
    -- DistantIslands children in a different insertion order after re-injection.
    table.sort(records, function(a: any, b: any): boolean
        if a.position.X == b.position.X then
            return a.position.Z < b.position.Z
        end
        return a.position.X < b.position.X
    end)
    return records
end

local function basaltTowerLanding(record: any, cached: any): any
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    local center = record and record.position
    if not terrain or typeof(center) ~= "Vector3" then
        return nil
    end

    local candidates: {any} = {}
    local seen: {[string]: boolean} = {}
    local function append(position: any)
        if typeof(position) ~= "Vector3" then
            return
        end
        local horizontal = Vector3.new(position.X - center.X, 0, position.Z - center.Z)
        if horizontal.Magnitude > 138 then
            return
        end
        local key = string.format("%.0f:%.0f", position.X, position.Z)
        if not seen[key] then
            seen[key] = true
            candidates[#candidates + 1] = position
        end
    end

    append(cached)
    for _, radius in ipairs(BASALT_LANDING_RADII) do
        for _, direction in ipairs(VOLCANO_LANDING_DIRECTIONS) do
            append(center + direction * radius)
        end
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = {terrain}
    params.IgnoreWater = true
    params.RespectCanCollide = true

    local minimumY = math.max(147.5, center.Y - 220)
    local castY = math.max(430, center.Y + 230)
    for _, candidate in ipairs(candidates) do
        local hit = Workspace:Raycast(
            Vector3.new(candidate.X, castY, candidate.Z),
            Vector3.new(0, minimumY - castY - 1, 0),
            params
        )
        if safeVolcanoSurface(hit, minimumY) then
            local supported = true
            for _, side in ipairs({
                Vector3.new(2, 0, 0),
                Vector3.new(-2, 0, 0),
                Vector3.new(0, 0, 2),
                Vector3.new(0, 0, -2),
            }) do
                local ground = Workspace:Raycast(
                    hit.Position + side + Vector3.new(0, 4, 0),
                    Vector3.new(0, -8, 0),
                    params
                )
                if not safeVolcanoSurface(ground, minimumY)
                    or math.abs(ground.Position.Y - hit.Position.Y) > 3 then
                    supported = false
                    break
                end
            end
            if supported and not Workspace:Raycast(
                hit.Position + Vector3.new(0, 0.4, 0),
                Vector3.new(0, 7, 0),
                params
            ) then
                return hit.Position
            end
        end
    end
    return nil
end

local function basaltTowerProbe(record: any): Vector3
    local center = record.position
    local markerCFrame = record.cframe
    local right = typeof(markerCFrame) == "CFrame" and markerCFrame.RightVector
        or Vector3.new(1, 0, 0)
    local horizontal = Vector3.new(right.X, 0, right.Z)
    if horizontal.Magnitude < 0.1 then
        horizontal = Vector3.new(1, 0, 0)
    end
    horizontal = horizontal.Unit * 76
    return Vector3.new(
        center.X + horizontal.X,
        math.max(center.Y + 130, Settings.WORLD_SCAN_SAFE_MIN_Y + 80),
        center.Z + horizontal.Z
    )
end

local function advanceBasaltTower(ritual: any, index: any)
    local current = tonumber(index) or tonumber(ritual.basaltIndex)
    ritual.basaltIndex = current and math.floor(current) + 1 or nil
    ritual.basaltMarkerKey = nil
    ritual.basaltLanding = nil
    ritual.basaltArrivedAt = nil
    ritual.nextBasaltStreamAt = 0
end

-- Magma Golems belong to the duplicate BasaltTowerPOI destinations, not the
-- Volcano crater marker. Visit each coordinate in turn, land once, and remain
-- there long enough for its server creature to replicate before advancing.
local function focusBasaltTowerRegion(wanted: any): boolean
    local ritual = state.volcano
    requestCreatureSimulationRadius()

    local locator, authoritative = findNearestCombatLocator(wanted)
    if locator then
        state.phase = authoritative and "Teleporting to Magma Golem"
            or "Locking Magma Golem"
        if not teleportDirectlyToCombatLocator(locator, false) then
            task.wait(0.05)
        end
        return true
    end

    local markers = basaltTowerMarkers()
    if #markers == 0 then
        state.phase = "Waiting for Basalt Tower POI markers"
        task.wait(0.12)
        return false
    end

    local root = getRoot()
    if not root then
        task.wait(0.08)
        return false
    end

    local rawIndex = tonumber(ritual.basaltIndex)
    local index
    if rawIndex then
        index = ((math.floor(rawIndex) - 1) % #markers) + 1
    else
        local nearestDistance = math.huge
        index = 1
        for candidateIndex, candidate in ipairs(markers) do
            local distance = (root.Position - candidate.position).Magnitude
            if distance < nearestDistance then
                nearestDistance = distance
                index = candidateIndex
            end
        end
    end
    ritual.basaltIndex = index

    local record = markers[index]
    if ritual.basaltMarkerKey ~= record.key then
        ritual.basaltMarkerKey = record.key
        ritual.basaltLanding = nil
        ritual.basaltArrivedAt = nil
        ritual.nextBasaltStreamAt = 0
    end

    local center = record.position
    local now = os.clock()
    if now >= (tonumber(ritual.nextBasaltStreamAt) or 0) then
        ritual.nextBasaltStreamAt = now + 0.45
        requestStreamNear(center)
        if typeof(ritual.basaltLanding) == "Vector3" then
            requestStreamNear(ritual.basaltLanding)
        end
    end

    if typeof(ritual.basaltLanding) == "Vector3"
        and (root.Position - ritual.basaltLanding).Magnitude <= 65 then
        ritual.basaltArrivedAt = tonumber(ritual.basaltArrivedAt) or now
        state.phase = string.format(
            "Scanning Basalt Tower %d/%d [%.0f, %.0f]",
            index,
            #markers,
            center.X,
            center.Z
        )
        local scanDeadline = os.clock() + 0.60
        repeat
            locator = select(1, findNearestCombatLocator(wanted))
            if locator then
                return teleportDirectlyToCombatLocator(locator, false)
            end
            task.wait(0.04)
        until not isRunning() or os.clock() >= scanDeadline

        if os.clock() - ritual.basaltArrivedAt >= 4.5 then
            advanceBasaltTower(ritual, index)
            state.phase = "Moving to next Basalt Tower"
        end
        return true
    end

    local landing = basaltTowerLanding(record, ritual.basaltLanding)
    if landing then
        ritual.basaltLanding = landing
        ritual.basaltArrivedAt = os.clock()
        local humanoid = getHumanoid()
        local height = humanoid and math.max(3, humanoid.HipHeight + root.Size.Y / 2 + 0.5) or 4
        state.phase = string.format("Landing at Basalt Tower %d/%d", index, #markers)
        return teleportCharacter(
            CFrame.lookAt(landing + Vector3.new(0, height, 0), center),
            0.12,
            false
        )
    end

    local probe = basaltTowerProbe(record)
    local originCFrame = root.CFrame
    local originalAnchored = root.Anchored
    if not teleportCharacter(CFrame.lookAt(probe, center), 0.08, true) then
        task.wait(0.08)
        return false
    end

    local lockedLocator
    local deadline = os.clock() + 2.6
    local nextGroundCheck = 0
    local nextStreamRequest = 0
    pcall(function()
        root.Anchored = true
        repeat
            if not isRunning() or not root.Parent then
                break
            end
            root.CFrame = CFrame.lookAt(probe, center)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero

            lockedLocator = select(1, findNearestCombatLocator(wanted))
            if lockedLocator then
                break
            end

            local clock = os.clock()
            if clock >= nextStreamRequest then
                nextStreamRequest = clock + 0.45
                requestStreamNear(center)
                requestStreamNear(probe)
            end
            if clock >= nextGroundCheck then
                nextGroundCheck = clock + 0.14
                landing = basaltTowerLanding(record, ritual.basaltLanding)
                if landing then
                    break
                end
            end
            task.wait(0.04)
        until os.clock() >= deadline
    end)

    if root and root.Parent then
        pcall(function()
            root.Anchored = originalAnchored
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    if lockedLocator then
        return teleportDirectlyToCombatLocator(lockedLocator, false)
    end
    if landing then
        ritual.basaltLanding = landing
        ritual.basaltArrivedAt = os.clock()
        local humanoid = getHumanoid()
        local height = humanoid and math.max(3, humanoid.HipHeight + root.Size.Y / 2 + 0.5) or 4
        state.phase = string.format("Landing at Basalt Tower %d/%d", index, #markers)
        return teleportCharacter(
            CFrame.lookAt(landing + Vector3.new(0, height, 0), center),
            0.12,
            false
        )
    end

    teleportCharacter(originCFrame, 0.08, originalAnchored)
    advanceBasaltTower(ritual, index)
    task.wait(0.08)
    return false
end

-- Lock a replicated creature immediately. Until it exists, stream from one
-- bounded outer-air probe and then land on the validated Volcano surface. The
-- crater centre is deliberately never used as a waiting/landing destination.
local function focusVolcanoRegion(volcano: any, wanted: any, bossPhase: any): boolean
    local ritual = state.volcano
    requestCreatureSimulationRadius()
    local locator, authoritative = findNearestCombatLocator(wanted)
    if locator then
        state.phase = authoritative
            and (bossPhase and "Teleporting to Lord of Lava" or "Teleporting to Magma Golem")
            or (bossPhase and "Locking Lord of Lava" or "Locking Magma Golem")
        if not teleportDirectlyToCombatLocator(locator, bossPhase) then
            task.wait(0.05)
        end
        return true
    end

    local markerCFrame = volcanoMarkerCFrame()
    local markerPosition = markerCFrame and markerCFrame.Position or nil
    local center = markerPosition or (volcano and volcanoCenter(volcano))
    if not center then
        task.wait(0.12)
        return false
    end

    local now = os.clock()
    if now >= (tonumber(ritual.nextDirectStreamAt) or 0) then
        ritual.nextDirectStreamAt = now + 0.55
        requestStreamNear(center)
        if typeof(ritual.volcanoLanding) == "Vector3" then
            requestStreamNear(ritual.volcanoLanding)
        end
    end

    local root = getRoot()
    if not root then
        task.wait(0.08)
        return false
    end

    -- Once the surface landing succeeded, stay on that island and keep polling;
    -- do not jump back to a centre probe on every main-loop iteration.
    if typeof(ritual.volcanoLanding) == "Vector3"
        and (root.Position - ritual.volcanoLanding).Magnitude <= 75 then
        state.phase = bossPhase and "Scanning Lord of Lava from Volcano island"
            or "Scanning Magma Golems from Volcano island"
        local islandDeadline = os.clock() + 0.55
        repeat
            locator = select(1, findNearestCombatLocator(wanted))
            if locator then
                return teleportDirectlyToCombatLocator(locator, bossPhase)
            end
            task.wait(0.04)
        until not isRunning() or os.clock() >= islandDeadline
        return true
    end

    local landing = volcanoIslandLanding(volcano, center, ritual.volcanoLanding)
    if landing then
        ritual.volcanoLanding = landing
        local humanoid = getHumanoid()
        local height = humanoid and math.max(3, humanoid.HipHeight + root.Size.Y / 2 + 0.5) or 4
        local destination = landing + Vector3.new(0, height, 0)
        state.phase = "Landing on Volcano island"
        return teleportCharacter(CFrame.lookAt(destination, center), 0.12, false)
    end

    local probe = volcanoOuterProbe(volcano, center, markerCFrame)
    local originCFrame = root.CFrame
    local originalAnchored = root.Anchored
    if not teleportCharacter(
        CFrame.lookAt(probe, center),
        0.08,
        true
    ) then
        task.wait(0.08)
        return false
    end

    local lockedLocator
    local currentVolcano = volcano
    local deadline = os.clock() + 2.8
    local nextGroundCheck = 0
    local nextStreamRequest = 0
    pcall(function()
        root.Anchored = true
        repeat
            if not isRunning() or not root.Parent then
                break
            end
            root.CFrame = CFrame.lookAt(probe, center)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            lockedLocator = select(1, findNearestCombatLocator(wanted))
            if lockedLocator then
                break
            end
            local clock = os.clock()
            if clock >= nextStreamRequest then
                nextStreamRequest = clock + 0.45
                requestStreamNear(center)
                requestStreamNear(probe)
            end
            if clock >= nextGroundCheck then
                nextGroundCheck = clock + 0.14
                currentVolcano = currentVolcano or findVolcano()
                landing = volcanoIslandLanding(currentVolcano, center, ritual.volcanoLanding)
                if landing then
                    break
                end
            end
            task.wait(0.04)
        until os.clock() >= deadline
    end)

    if root and root.Parent then
        pcall(function()
            root.Anchored = originalAnchored
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    if lockedLocator then
        return teleportDirectlyToCombatLocator(lockedLocator, bossPhase)
    end
    if landing then
        ritual.volcanoLanding = landing
        local humanoid = getHumanoid()
        local height = humanoid and math.max(3, humanoid.HipHeight + root.Size.Y / 2 + 0.5) or 4
        local destination = landing + Vector3.new(0, height, 0)
        state.phase = "Landing on Volcano island"
        return teleportCharacter(CFrame.lookAt(destination, center), 0.12, false)
    end

    -- A failed stream request must not leave the character suspended at a probe.
    -- Restore the previous live character and let the continuous loop retry.
    teleportCharacter(originCFrame, 0.08, originalAnchored)
    task.wait(0.08)
    return false
end

local VOLCANO_PROGRESS_NAMES: {[string]: boolean} = {
    progress = true,
    progresstext = true,
    golemprogress = true,
    golemsdropped = true,
    golemcount = true,
    delivered = true,
    sacrificed = true,
    sacrifices = true,
    offerings = true,
    inserted = true,
    filled = true,
    currentcount = true,
}

local function isVolcanoProgressName(value: any): boolean
    local normalized = string.lower(tostring(value or "")):gsub("[^%w]", "")
    if string.find(normalized, "required", 1, true)
        or string.find(normalized, "maximum", 1, true)
        or string.find(normalized, "goal", 1, true)
        or string.find(normalized, "total", 1, true) then
        return false
    end
    return VOLCANO_PROGRESS_NAMES[normalized] == true
end

-- Capture only mission-related values. This supplies an acknowledgement even on
-- revisions where the corpse is consumed between two DebrisField polling frames.
local function volcanoProgressSnapshot(volcano: any, dropPoint: any): any
    local fields: {string} = {}
    local bestCount = nil
    local seen: any = setmetatable({}, {__mode = "k"})

    if not volcano or not volcano.Parent then
        volcano = findVolcano()
    end

    local function consider(label: string, name: any, value: any, isText: boolean?)
        local textValue = tostring(value or "")
        local numerator, denominator = string.match(textValue, "(%d+)%s*/%s*(%d+)")
        if isText and isVolcanoProgressName(name) and numerator
            and tonumber(denominator) == Settings.MAGMA_GOLEM_TARGET then
            bestCount = math.max(bestCount or 0, math.clamp(tonumber(numerator) or 0, 0, Settings.MAGMA_GOLEM_TARGET))
            fields[#fields + 1] = label .. "=" .. textValue
            return
        end
        if not isText and isVolcanoProgressName(name) then
            fields[#fields + 1] = label .. "=" .. textValue
            local numberValue = tonumber(value)
            if numberValue and numberValue >= 0 and numberValue <= Settings.MAGMA_GOLEM_TARGET then
                bestCount = math.max(bestCount or 0, numberValue)
            end
        end
    end

    local function capture(instance: any)
        if not instance or seen[instance] then
            return
        end
        seen[instance] = true
        local ok, attributes = pcall(instance.GetAttributes, instance)
        if ok and type(attributes) == "table" then
            for name, value in pairs(attributes) do
                consider(instance:GetFullName() .. "." .. tostring(name), name, value, false)
            end
        end
        if instance:IsA("ValueBase") then
            local valueOk, value = pcall(function()
                return instance.Value
            end)
            if valueOk then
                consider(instance:GetFullName(), instance.Name, value, false)
            end
        elseif instance:IsA("TextLabel") or instance:IsA("TextButton") then
            consider(instance:GetFullName(), instance.Name, instance.Text, true)
        end
    end

    local mission = volcano and volcano:FindFirstChild("Mission")
    if (not dropPoint or not dropPoint.Parent) and mission then
        local liveDropPoint = mission:FindFirstChild("DropPoint", true)
        if liveDropPoint and liveDropPoint:IsA("BasePart") then
            dropPoint = liveDropPoint
        end
    end
    local scopes = {}
    if mission then
        scopes[#scopes + 1] = mission
    end
    if dropPoint and dropPoint ~= mission then
        scopes[#scopes + 1] = dropPoint
    end
    for _, scope in ipairs(scopes) do
        if scope then
            capture(scope)
            for _, descendant in ipairs(scope:GetDescendants()) do
                capture(descendant)
            end
        end
    end
    table.sort(fields)
    return {
        count = bestCount,
        signature = table.concat(fields, "|")
    }
end

local function volcanoProgressAdvanced(before: any, after: any): boolean
    if not before or not after then
        return false
    end
    local beforeCount = type(before.count) == "number" and before.count or 0
    if type(after.count) == "number" and after.count > beforeCount then
        return true
    end
    -- Signature changes are diagnostic only. ProgressRequired, visual text, and
    -- late-streamed mission descendants can all change without accepting a body.
    return false
end

local function magmaDropOwner(raw: any): any
    local current = raw
    local matched = nil
    for _ = 1, 12 do
        if not current or current == Workspace then
            break
        end
        if current:IsA("Model") and identityMatches(current, MAGMA_GOLEM_NAMES) then
            matched = current
        end
        current = current.Parent
    end
    return matched
end

local function magmaCorpsesNear(position: any, horizontalRadius: number): {any}
    local results: {any} = {}
    local seen: any = setmetatable({}, {__mode = "k"})

    local function add(raw: any)
        local owner = magmaDropOwner(raw)
        if not owner or seen[owner] or not owner:IsDescendantOf(Workspace) then
            return
        end
        local inDebris = owner:FindFirstAncestor("DebrisField") ~= nil
        local ragdoll = owner:GetAttribute("Ragdoll") == true
        local interactable = isTagged(owner, "Interactable")
            or isTagged(raw, "Interactable")
        local deadEvidence = owner:GetAttribute("Dead") == true
            or ragdoll
            or inDebris
            or interactable
        local health = entityHealth(owner)
        local demonstrablyAlive = health ~= nil and health > 0
            and owner:GetAttribute("Dead") ~= true
            and not ragdoll and not interactable
        if not deadEvidence or (demonstrablyAlive and not inDebris) then
            return
        end
        local ownerPosition = entityPosition(owner)
        if not ownerPosition then
            return
        end
        local horizontal = Vector2.new(
            ownerPosition.X - position.X,
            ownerPosition.Z - position.Z
        ).Magnitude
        if horizontal > horizontalRadius or math.abs(ownerPosition.Y - position.Y) > 260 then
            return
        end
        seen[owner] = true
        results[#results + 1] = owner
    end

    for _, tagged in ipairs(CollectionService:GetTagged("Interactable")) do
        add(tagged)
    end
    local debris = Workspace:FindFirstChild("DebrisField")
    if debris then
        for _, child in ipairs(debris:GetChildren()) do
            add(child)
        end
    end
    for model in pairs(indexedVolcanoModels) do
        add(model)
    end
    table.sort(results, function(left, right)
        local leftPosition = entityPosition(left)
        local rightPosition = entityPosition(right)
        if not leftPosition then return false end
        if not rightPosition then return true end
        return (leftPosition - position).Magnitude < (rightPosition - position).Magnitude
    end)
    return results
end

local cachedVolcanoDragSystem: any = nil
local function volcanoDragNetwork(): any
    if cachedVolcanoDragSystem and cachedVolcanoDragSystem.Network then
        return cachedVolcanoDragSystem.Network
    end
    local systems = ReplicatedStorage:FindFirstChild("Modules")
    systems = systems and systems:FindFirstChild("Systems")
    local moduleScript = systems and systems:FindFirstChild("DragSystem")
    if not moduleScript then
        return nil
    end
    local ok, module = pcall(require, moduleScript)
    if ok and type(module) == "table" then
        cachedVolcanoDragSystem = module
        return module.Network
    end
    return nil
end

local function moveMagmaCorpseTo(owner: any, desiredPosition: any): any
    if not owner or not owner.Parent or typeof(desiredPosition) ~= "Vector3" then
        return nil
    end
    local reference = entityPart(owner)
    if not reference then
        return nil
    end
    local moved = pcall(function()
        if owner:IsA("Model") then
            owner:PivotTo(owner:GetPivot() + (desiredPosition - reference.Position))
        else
            reference.CFrame = CFrame.new(desiredPosition)
        end
        for _, descendant in ipairs(owner:GetDescendants()) do
            if descendant:IsA("BasePart") then
                descendant.AssemblyLinearVelocity = Vector3.zero
                descendant.AssemblyAngularVelocity = Vector3.zero
            end
        end
        reference.AssemblyLinearVelocity = Vector3.zero
        reference.AssemblyAngularVelocity = Vector3.zero
    end)
    if not moved or not reference.Parent then
        return nil, false
    end
    return reference, (reference.Position - desiredPosition).Magnitude <= 5
end

local function volcanoBossVisible(): boolean
    -- Visuals/native batches can arrive before the authoritative combat model.
    -- Presence confirms the ritual, never the boss's defeat.
    local locator = select(1, findNearestCombatLocator(GOLEM_BOSS_NAMES))
    if not locator then return false end
    state.volcano.bossSeen = true
    local target = type(locator) == "table" and rawget(locator, "targetCF")
    local position = typeof(target) == "CFrame" and target.Position
        or (typeof(locator) == "Instance" and entityPosition(locator))
    if position then requestStreamNear(position) end
    return true
end

local function releaseVolcanoDeliveryForBoss(): boolean
    if not volcanoBossVisible() then return false end
    local ritual = state.volcano
    local pending = ritual.dropTransaction
    if pending then
        -- Native DropItem has no position argument. Keep the flight until the
        -- final Sack decrement even if the boss/DropPoint changed during spawn.
        equipSack()
        SackTransfer.ObserveGolemDrop(pending)
        if not pending.released then return false end
        ritual.receipts = ritual.receipts or {}
        ritual.receipts[#ritual.receipts + 1] = pending
        ritual.dropTransaction = nil
    end
    SackTransfer.ConfirmGolems(Settings.MAGMA_GOLEM_TARGET)
    for _, receipt in ipairs(ritual.receipts or {}) do receipt.confirmed = true end
    local lease = ritual.deliveryLease
    ritual.deliveryLease, ritual.pendingDrop = nil, nil
    if lease then lease:Close("boss-spawned") end
    state.lastDropError = nil
    return true
end

local function findVolcanoDropPoint(volcano: any): any
    if not volcano or not volcano.Parent then
        volcano = findVolcano()
    end
    if not volcano or not volcano.Parent then
        return nil
    end
    local mission = volcano:FindFirstChild("Mission")
    local direct = mission and mission:FindFirstChild("DropPoint", true)
    if direct and direct:IsA("BasePart") then
        return direct
    end
    -- Effects.VolcanoEruption reads VolcanoPOI.Mission.DropPoint explicitly.
    -- Never substitute a similarly named decorative part elsewhere in the POI.
    return nil
end

local function volcanoFallbackDropPosition(volcano: any): (any, boolean)
    local rough = volcanoCraterPosition(volcano)
    local marker = volcanoMarkerCFrame()
    if not rough and typeof(marker) == "CFrame" then
        -- The distant marker is centred vertically inside the island bounds. A
        -- streamed Volcano normally supplies a better summit Y, but this remains
        -- a usable temporary target while its terrain finishes streaming.
        rough = marker.Position + Vector3.new(0, 105, 0)
    elseif rough and typeof(marker) == "CFrame" then
        rough = Vector3.new(marker.Position.X, rough.Y, marker.Position.Z)
    end
    if typeof(rough) ~= "Vector3" then
        return nil, false
    end

    -- Terrain owns the Volcano. Restrict the raycast to Terrain so a MagmaChest,
    -- palm, effect, or previously missed corpse cannot move the next drop target.
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if not terrain then
        return rough, false
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = {terrain}
    params.IgnoreWater = true
    params.RespectCanCollide = false
    local castY = math.max(650, rough.Y + 260)
    local hit = Workspace:Raycast(
        Vector3.new(rough.X, castY, rough.Z),
        Vector3.new(0, 80 - castY, 0),
        params
    )
    if hit and hit.Material ~= Enum.Material.Water then
        local target = hit.Position + Vector3.new(0, 1.25, 0)
        local cached = state.volcano and state.volcano.fallbackDropPosition
        if typeof(cached) == "Vector3" then
            -- Streaming may replace a coarse/low Terrain sample with the actual
            -- crater surface at a very different Y. Reject only an X/Z jump to a
            -- different island; always accept the fresher height in this column.
            local horizontalShift = Vector2.new(
                target.X - cached.X,
                target.Z - cached.Z
            ).Magnitude
            if horizontalShift > 45 then
                return cached, false
            end
        end
        state.volcano.fallbackDropPosition = target
        return target, true
    end
    local cached = state.volcano and state.volcano.fallbackDropPosition
    if typeof(cached) == "Vector3" then
        return cached, false
    end
    return rough, false
end

local function resolveVolcanoDropTarget(volcano: any): (any, any, string)
    if not volcano or not volcano.Parent then
        volcano = findVolcano()
    end
    local dropPoint = findVolcanoDropPoint(volcano)
    if dropPoint then
        return dropPoint, dropPoint.Position, "DropPoint"
    end
    local fallback, terrainVerified = volcanoFallbackDropPosition(volcano)
    return nil, fallback, terrainVerified and "TerrainCrater" or "StreamTarget"
end

local function forceMagmaCorpseIntoVolcano(
    owner: any,
    volcano: any,
    dropPoint: any,
    targetPosition: any,
    beforeProgress: any,
    holdPosition: any
): boolean
    if not owner or not owner.Parent or typeof(targetPosition) ~= "Vector3" then
        return false
    end

    local ritual: any = state.volcano
    local evidence: any = ritual.pendingDropEvidence
    if type(evidence) ~= "table" or evidence.owner ~= owner then
        local nearbyBefore: any = setmetatable({}, {__mode = "k"})
        for _, existing in ipairs(magmaCorpsesNear(targetPosition, 120)) do
            if existing ~= owner then
                nearbyBefore[existing] = true
            end
        end
        evidence = {
            owner = owner,
            ownershipGranted = false,
            enteredTarget = false,
            releasedAt = nil,
            targetPosition = targetPosition,
            beforeProgress = beforeProgress,
            exactDropPoint = dropPoint,
            fallbackTarget = dropPoint == nil,
            corpsesBefore = nearbyBefore,
        }
        ritual.pendingDropEvidence = evidence
    else
        evidence.beforeProgress = evidence.beforeProgress or beforeProgress
        if dropPoint and dropPoint.Parent then
            evidence.exactDropPoint = dropPoint
        end
    end

    local function insideAcceptance(position: any): boolean
        if typeof(position) ~= "Vector3" then
            return false
        end
        if dropPoint and dropPoint.Parent and dropPoint:IsA("BasePart") then
            local localPosition = dropPoint.CFrame:PointToObjectSpace(position)
            local half = dropPoint.Size * 0.5
            return math.abs(localPosition.X) <= half.X + 4
                and math.abs(localPosition.Z) <= half.Z + 4
                and localPosition.Y <= half.Y + 7
                and localPosition.Y >= -half.Y - 12
        end
        local delta = position - targetPosition
        return Vector2.new(delta.X, delta.Z).Magnitude <= 12
            and math.abs(delta.Y) <= 18
    end

    local function explicitServerAcceptance(): boolean
        if volcanoBossVisible() then
            state.lastDropError = nil
            return true
        end
        if volcanoProgressAdvanced(
            beforeProgress,
            volcanoProgressSnapshot(volcano, dropPoint)
        ) then
            state.lastDropError = nil
            return true
        end
        local activeVolcano = volcano and volcano.Parent and volcano or findVolcano()
        local mission = activeVolcano and activeVolcano:FindFirstChild("Mission")
        if owner.Parent and mission and owner:IsDescendantOf(mission) then
            state.lastDropError = nil
            return true
        end
        -- Disappearance alone is not a server acknowledgement.
        return false
    end

    -- Native DragSystem grants client network ownership before moving a corpse.
    -- This makes the final PivotTo visible to the server instead of a local-only snap.
    local humanoid = getHumanoid()
    if humanoid then
        pcall(function()
            humanoid:UnequipTools()
        end)
        task.wait(0.04)
    end

    local network = volcanoDragNetwork()
    if not network or type(network.InvokeServer) ~= "function"
        or type(network.FireServer) ~= "function" then
        state.lastDropError = "DragSystem network unavailable"
        return false
    end

    local deadline = os.clock() + 3.4
    local nextPushAt = 0
    repeat
        if type(holdPosition) == "function"
            and not holdPosition(targetPosition, dropPoint) then
            return false
        end
        if explicitServerAcceptance() then
            return true
        end
        -- DropPoint can be inserted only after the first body reaches the ritual.
        -- Adopt it immediately if it appears while the fallback delivery is active.
        if not dropPoint or not dropPoint.Parent then
            local replicatedDropPoint = findVolcanoDropPoint(volcano)
            if replicatedDropPoint then
                dropPoint = replicatedDropPoint
                targetPosition = replicatedDropPoint.Position
                evidence.exactDropPoint = replicatedDropPoint
                evidence.targetPosition = targetPosition
            end
        end
        local now = os.clock()
        if now >= nextPushAt then
            nextPushAt = now + 0.55
            local dragPart = getNativeStorePart({
                model = owner,
                owner = owner,
                part = entityPart(owner),
            })
            if not dragPart or not dragPart.Parent then
                task.wait(0.05)
                continue
            end

            local dragOk, granted, dragStatus = state.invokeBounded(1.1, function()
                return network:InvokeServer("AttemptDrag", dragPart)
            end, dragPart)
            -- DragSystem's native client checks only `if not response`; some
            -- Network wrappers return a truthy ownership token instead of true.
            if not dragOk or not granted then
                state.lastDropError = dragOk
                    and "AttemptDrag rejected by server"
                    or (dragStatus == "timeout"
                        and "AttemptDrag timed out; controller will retry"
                        or "AttemptDrag request failed")
                task.wait(0.10)
                continue
            end

            evidence.ownershipGranted = true
            evidence.targetPosition = targetPosition
            -- Give replicated network ownership one physics frame before moving
            -- the ragdoll through the server's touch volume.
            RunService.Heartbeat:Wait()
            local halfY = dropPoint and dropPoint.Parent and dropPoint:IsA("BasePart")
                and dropPoint.Size.Y * 0.5 or 2
            local top = math.max(5, halfY + 4)
            local bottom = -math.max(7, halfY + 5)
            for step = 0, 12 do
                if not owner.Parent then
                    break
                end
                if type(holdPosition) == "function"
                    and not holdPosition(targetPosition, dropPoint) then
                    return false
                end
                local alpha = step / 12
                local desired = targetPosition + Vector3.new(
                    0,
                    top + (bottom - top) * alpha,
                    0
                )
                local movedPart, reached = moveMagmaCorpseTo(owner, desired)
                if movedPart and reached and insideAcceptance(movedPart.Position) then
                    evidence.enteredTarget = true
                end
                RunService.Heartbeat:Wait()
            end

            if owner.Parent and dragPart.Parent then
                local downward = Vector3.new(0, -26, 0)
                local released = pcall(function()
                    dragPart.AssemblyLinearVelocity = downward
                    network:FireServer("GiveUpOwnership", dragPart, downward)
                end)
                if released then
                    evidence.releasedAt = os.clock()
                end
                RunService.Heartbeat:Wait()
                RunService.Heartbeat:Wait()
            end
        else
            task.wait(0.04)
        end
    until not isRunning()
        or (os.clock() >= deadline
            and (type(evidence.removedAt) ~= "number"
                or os.clock() - evidence.removedAt >= 0.85))

    return explicitServerAcceptance()
end

local function volcanoDropStandCFrame(
    root: any,
    sack: any,
    dropPoint: any,
    targetPosition: any
): any
    local markerCFrame = volcanoMarkerCFrame()
    local rawForward = dropPoint and dropPoint.CFrame.LookVector
        or (markerCFrame and markerCFrame.LookVector)
        or Vector3.new(0, 0, -1)
    local forward = Vector3.new(rawForward.X, 0, rawForward.Z)
    if forward.Magnitude < 0.05 then
        forward = Vector3.new(0, 0, -1)
    else
        forward = forward.Unit
    end

    -- DropItem is emitted beside the equipped Sack Handle. Solve the HRP position so
    -- that the Handle is six studs above DropPoint's top, including its Y offset.
    local top = dropPoint and dropPoint.Size.Y * 0.5 or 0
    local hoverHeight = Settings.VOLCANO_DROP_HEIGHT + top
    local rootPosition = targetPosition + Vector3.new(0, hoverHeight, 0)
    local handle = sack and sack:FindFirstChild("Handle")
    if handle and handle:IsA("BasePart") then
        local localHandleOffset = root.CFrame:PointToObjectSpace(handle.Position)
        local orientation = CFrame.lookAt(Vector3.zero, forward)
        local worldHandleOffset = orientation:VectorToWorldSpace(localHandleOffset)
        rootPosition = rootPosition - worldHandleOffset
        rootPosition = Vector3.new(rootPosition.X, math.max(rootPosition.Y, targetPosition.Y + top + 3), rootPosition.Z)
    end
    return CFrame.lookAt(rootPosition, rootPosition + forward)
end

local function dropMagmaCorpse(volcano: any): boolean
    local ritual: any = state.volcano
    -- Eruption can remove Mission.DropPoint. Check the boss before resolving or
    -- waiting on that old part, otherwise the retained delivery lease wedges.
    if releaseVolcanoDeliveryForBoss() then return true end
    Metrics.Phase("Volcano delivery")
    local dropPoint, targetPosition, targetKind = resolveVolcanoDropTarget(volcano)
    if typeof(targetPosition) ~= "Vector3" or targetKind == "StreamTarget" then
        if typeof(targetPosition) == "Vector3" then requestStreamNear(targetPosition) end
        state.phase = "Streaming real Volcano terrain before delivery"
        return false
    end
    local sack = equipSack()
    local net = sackNet()
    local root, character = getRoot(), getCharacter()
    local handle = sack and sack:FindFirstChild("Handle")
    if not sack or not net or not root or not handle or not handle:IsA("BasePart")
        or (handle.Position - root.Position).Magnitude > 12 then
        state.phase = "Waiting for equipped Sack before Volcano delivery"
        return false
    end
    local stand = volcanoDropStandCFrame(root, sack, dropPoint, targetPosition)
    local lease = ritual.deliveryLease
    if not lease or not lease:Owns() or lease.sack ~= sack
        or not lease.aim or (lease.aim - targetPosition).Magnitude > 0.5 then
        lease = Motion.Begin(stand, {
        drop = true, fly = true, sack = sack, aim = targetPosition, handleHeadroom = 6,
        valid = function()
            if not volcano or not volcano.Parent then return false end
            if targetKind == "DropPoint" then
                return dropPoint and dropPoint.Parent ~= nil
                    and dropPoint:IsDescendantOf(Workspace)
                    and (dropPoint.Position - targetPosition).Magnitude <= 0.5
            end
            return targetKind == "TerrainCrater"
        end,
    })
        ritual.deliveryLease = lease
    end
    if not lease then return false end
    lease.drop = true
    state.phase = "Double teleport and fly above Volcano before releasing all Magma Golems"
    local ok, result = pcall(function()
        if not lease:WaitStable(0.75, 6) then
            state.lastDropError = "Magma Golem kept in Sack: " .. tostring(lease.reason)
            return false
        end
        local function accepted(transaction)
            if volcanoBossVisible() then
                SackTransfer.ConfirmGolems(Settings.MAGMA_GOLEM_TARGET)
                return true
            end
            local progress = volcanoProgressSnapshot(volcano, dropPoint)
            if type(progress.count) == "number" then SackTransfer.ConfirmGolems(progress.count) end
            local mission = volcano:FindFirstChild("Mission")
            local owner = transaction.owner
            if owner ~= nil and owner.Parent ~= nil and mission ~= nil and owner:IsDescendantOf(mission) then
                ritual.acceptedOwners = ritual.acceptedOwners or {}
                ritual.acceptedOwners[owner] = true
                local unique = 0
                for _ in pairs(ritual.acceptedOwners) do unique += 1 end
                SackTransfer.ConfirmGolems(unique)
                return true
            end
            -- Each submission has its own ordinal. One late 1/3 replication must
            -- never acknowledge all three receipts that initially observed 0/3.
            return type(progress.count) == "number" and progress.count >= transaction.ordinal
        end
        local function holdPosition(position, part)
            if not lease:Owns() then return false end
            if typeof(position) == "Vector3" and (position - targetPosition).Magnitude > 0.15 then
                targetPosition = position
                if part and part.Parent then dropPoint, targetKind = part, "DropPoint" end
                lease:SetTarget(volcanoDropStandCFrame(root,
                    sack.Parent == character and sack or nil, dropPoint, position), position)
                if not lease:WaitStable(0.75, 5) then return false end
            end
            return lease:WaitStable(0.75, 5)
        end
        -- Reuse the same two-teleport/fly lease for all bodies; mission/boss proof
        -- remains separate from Sack decrements. Recover misses after the full batch.
        ritual.receipts = type(ritual.receipts) == "table" and ritual.receipts or {}
        while isRunning() and lease:Owns() and ((tonumber(ritual.held) or 0) > 0 or ritual.dropTransaction) do
            local transaction = ritual.dropTransaction
            if transaction and (transaction.character ~= character or transaction.sack ~= sack) then
                state.lastDropError = "Volcano receipt interrupted by character/Sack replacement"
                return false
            end
            if not transaction then
                local used = select(1, getSackCount())
                if not used or used <= 0 then break end
                if not lease:WaitStable(0.75, 5) then return false end
                local baseline: any = {}
                for _, corpse in ipairs(magmaCorpsesNear(targetPosition, 120)) do baseline[corpse] = true end
                transaction = {beforeUsed = used, beforeProgress = volcanoProgressSnapshot(volcano, dropPoint),
                    beforeCorpses = baseline, sack = sack, sentAt = os.clock(), targetPosition = targetPosition,
                    released = false, confirmed = false, character = character,
                    ordinal = (tonumber(ritual.submitted) or 0) + 1}
                if not lease:SendDrop(net) then return false end
                ritual.dropTransaction = transaction
            end
            local deadline = os.clock() + 2
            repeat
                task.wait(0.04)
                if not lease:Owns() then return false end
                SackTransfer.ObserveGolemDrop(transaction)
            until transaction.released or os.clock() >= deadline
            if not transaction.released then
                state.lastDropError = "Magma Golem DropItem pending; holding Volcano without a duplicate"
                return false
            end
            ritual.receipts[#ritual.receipts + 1] = transaction
            ritual.dropTransaction = nil
            state.phase = string.format("Dropping all golems: %d/%d submitted", ritual.submitted, Settings.MAGMA_GOLEM_TARGET)
        end
        local allConfirmed, claimed = true, {}
        for _, receipt in ipairs(ritual.receipts) do if receipt.owner then claimed[receipt.owner] = true end end
        for _, receipt in ipairs(ritual.receipts) do
            if not receipt.confirmed then receipt.confirmed = accepted(receipt) end
            if not receipt.confirmed and not receipt.owner then
                for _, corpse in ipairs(magmaCorpsesNear(receipt.targetPosition, 120)) do
                    if not receipt.beforeCorpses[corpse] and not claimed[corpse] then
                        receipt.owner, claimed[corpse] = corpse, true
                        break
                    end
                end
            end
            if not receipt.confirmed and receipt.owner and receipt.owner.Parent
                and os.clock() - receipt.sentAt >= 1 then
                lease.drop = false
                ritual.pendingDrop = receipt.owner
                forceMagmaCorpseIntoVolcano(receipt.owner, volcano, dropPoint,
                    targetPosition, receipt.beforeProgress, holdPosition)
                ritual.pendingDrop = nil
                if not lease:Owns() then return false end
                receipt.confirmed = accepted(receipt)
                lease.drop = true
            end
            if not receipt.confirmed then allConfirmed = false end
        end
        if allConfirmed or ritual.delivered >= Settings.MAGMA_GOLEM_TARGET then
            state.lastDropError = nil
            ritual.deliveryLease = nil
            lease:Close("volcano-batch-confirmed")
            return true
        end
        state.phase = "All golems dropped; waiting for Volcano acknowledgement / boss"
        return false
    end)
    if not ok then state.lastDropError = tostring(result); Metrics.Add("recoveries"); return false end
    return result == true
end

local function runVolcanoPrelude()
    local ritual: any = state.volcano
    requestCreatureSimulationRadius()
    ritual.stored = math.clamp(tonumber(ritual.stored) or 0, 0, Settings.MAGMA_GOLEM_TARGET)
    ritual.delivered = math.clamp(tonumber(ritual.delivered) or 0, 0, Settings.MAGMA_GOLEM_TARGET)
    if ritual.completed == true and ritual.bossDefeated == true then
        state.phase = nil
        return true
    end
    -- `completed` from any interrupted/older run is not authoritative unless the
    -- same state also recorded a successful boss fight.
    ritual.completed = false
    reconcileVolcanoSack(ritual)

    if ritual.bossDefeated == true then
        ritual.completed = true
        state.phase = nil
        return true
    end
    Flow.Set(3)
    -- Detect the boss independently of the local delivered counter. This recovers
    -- when one sacrifice was accepted just before reinjection or between polls.
    local boss = findCombatEntities(GOLEM_BOSS_NAMES, true)[1]
    if boss then
        SackTransfer.ConfirmGolems(Settings.MAGMA_GOLEM_TARGET)
        ritual.bossSeen = true
        Flow.Set(5, "Defeating Golem Boss / Lord of Lava")
        if fightEntity(boss) then
            ritual.bossDefeated = true
            ritual.completed = true
            state.phase = "Volcano complete"
            task.wait(0.5)
            state.phase = nil
            state.currentWeapon = nil
            return true
        end
        return false
    end

    if volcanoBossVisible() then
        SackTransfer.ConfirmGolems(Settings.MAGMA_GOLEM_TARGET)
        Flow.Set(5, "Acquiring the spawned Golem Boss combat model")
        focusVolcanoRegion(findVolcano(), GOLEM_BOSS_NAMES, true)
        return false
    end

    local markers = ReplicatedStorage:FindFirstChild("DistantIslands")
    if not findVolcano() and not (markers and markers:FindFirstChild("VolcanoPOI", true)) then
        state.phase = "VolcanoThenPearl: waiting for Volcano map / POI markers"
        task.wait(1)
        return false
    end

    local volcano = nil
    if ritual.stored >= Settings.MAGMA_GOLEM_TARGET or ritual.delivered > 0 then
        volcano = findVolcano()
        if volcano then
            local mission = volcano:FindFirstChild("Mission")
            local dropPoint = mission and mission:FindFirstChild("DropPoint", true)
            if dropPoint and dropPoint:IsA("BasePart") then
                local replicated = volcanoProgressSnapshot(volcano, dropPoint)
                if type(replicated.count) == "number" then
                    SackTransfer.ConfirmGolems(replicated.count)
                end
            end
        end
    end

    if ritual.delivered >= Settings.MAGMA_GOLEM_TARGET then
        Flow.Set(5)
        if not volcano then
            state.phase = "Streaming Volcano for Lord of Lava"
            focusVolcanoRegion(nil, GOLEM_BOSS_NAMES, true)
            return false
        end
        state.phase = ritual.bossSeen == true
            and "Reacquiring Lord of Lava"
            or "Waiting for Lord of Lava"
        focusVolcanoRegion(volcano, GOLEM_BOSS_NAMES, true)
        return false
    end

    if ritual.stored >= Settings.MAGMA_GOLEM_TARGET
        or (ritual.held > 0 and select(2, reconcileVolcanoSack(ritual)) == ritual.held) then
        Flow.Set(4)
        if not volcano then volcano = findVolcano() end
        if not volcano then
            state.phase = "Streaming Volcano crater"
            focusVolcanoRegion(nil, GOLEM_BOSS_NAMES, true)
            return false
        end
        state.phase = string.format(
            "Dropping golems in crater (%d/%d)",
            ritual.delivered,
            Settings.MAGMA_GOLEM_TARGET
        )
        if dropMagmaCorpse(volcano) then
            ritual.pendingDrop = nil
            ritual.pendingDropEvidence = nil
            ritual.pendingDropAttempts = 0
            reconcileVolcanoSack(ritual)
            if ritual.delivered >= Settings.MAGMA_GOLEM_TARGET then
                state.phase = "Volcano erupting"
                task.wait(2)
            end
        else
            task.wait(0.25)
        end
        return false
    end

    local corpse = findMagmaCorpse()
    if ritual.pendingCorpse and not corpse then
        requestStreamNear(ritual.pendingCorpse.position)
        if os.clock() < ritual.pendingCorpse.untilTime then
            state.phase = "Waiting for the defeated Magma Golem corpse before the next target"
            return false
        end
        state.lastStoreError = "Corpse did not replicate; reacquiring the same area"
        ritual.pendingCorpse = nil
    end
    if corpse then
        state.phase = string.format(
            "Storing Magma Golem (%d/%d)",
            ritual.stored + 1,
            Settings.MAGMA_GOLEM_TARGET
        )
        if storeMagmaCorpse(corpse) then
            ritual.pendingCorpse = nil
            ritual.stored = math.min(
                Settings.MAGMA_GOLEM_TARGET,
                (tonumber(ritual.stored) or 0) + 1
            )
            reconcileVolcanoSack(ritual)
            advanceBasaltTower(ritual, ritual.basaltIndex)
        else
            task.wait(0.2)
        end
        return false
    end

    local golems = findCombatEntities(MAGMA_GOLEM_NAMES, true)
    local golem = golems[1]
    if golem then
        state.phase = string.format(
            "Defeating Magma Golem (%d/%d)",
            ritual.stored + 1,
            Settings.MAGMA_GOLEM_TARGET
        )
        local deathPosition = entityPosition(golem)
        if fightEntity(golem) then
            ritual.pendingCorpse = {position = deathPosition, untilTime = os.clock() + 8}
            -- Stay beside the death position until the server changes the rig
            -- into its sackable Interactable/DebrisField form. This prevents a
            -- any later search movement from de-streaming the corpse before StoreItem.
            local corpseDeadline = os.clock() + 2.5
            repeat
                corpse = findMagmaCorpse()
                if corpse then
                    state.phase = string.format(
                        "Storing Magma Golem (%d/%d)",
                        ritual.stored + 1,
                        Settings.MAGMA_GOLEM_TARGET
                    )
                    if storeMagmaCorpse(corpse) then
                        ritual.pendingCorpse = nil
                        ritual.stored = math.min(
                            Settings.MAGMA_GOLEM_TARGET,
                            (tonumber(ritual.stored) or 0) + 1
                        )
                        reconcileVolcanoSack(ritual)
                        advanceBasaltTower(ritual, ritual.basaltIndex)
                    end
                    break
                end
                task.wait(0.10)
            until os.clock() >= corpseDeadline
        else
            task.wait(0.25)
        end
    else
        state.phase = string.format(
            "Finding Magma Golems at Basalt Towers (%d/%d)",
            ritual.stored,
            Settings.MAGMA_GOLEM_TARGET
        )
        focusBasaltTowerRegion(MAGMA_GOLEM_NAMES)
    end
    return false
end

local function returnToBase()
    local home, root = homePosition(), getRoot()
    if not root then return false end
    if Workspace:FindFirstChild("SpawnIsland") and (root.Position - home).Magnitude <= 35 then return true end
    state.phase = "Returning to Base"
    requestStreamNear(home)
    return teleportCharacter(CFrame.new(home + Vector3.new(12, 5, 0)), 0.2, false)
end

local function defend(raiders)
    for _, model in ipairs(raiders) do
        if entityIsAlive(model) then
            state.phase = "Defending Base: " .. model.Name
            return fightEntity(model, {maxSeconds = 20, canContinue = function()
                local position = entityPosition(model)
                return position and (position - homePosition()).Magnitude <= Settings.DEFENSE_RADIUS * 1.5
            end})
        end
    end
    return false
end

local function merchantExists()
    local boat = Workspace:FindFirstChild("MerchantBoat")
    if not boat then return false end
    local ok, cf = pcall(function() return boat:GetPivot() end)
    return ok and (cf.Position - homePosition()).Magnitude <= Settings.DEFENSE_RADIUS + 100
end

local function buyPearls()
    if state.bought then return true end
    if not isRunning() or not state.volcano or state.volcano.bossDefeated ~= true
        or Flow.data.defenseDone ~= true then return false end
    Metrics.Phase("Merchant")
    local transaction = state.purchase
    if transaction and not transaction.accepted then
        local pearls, coins = tonumber(player:GetAttribute("Pearls")), tonumber(player:GetAttribute("Doubloons"))
        -- Recover a lost response only when both server wallets prove this purchase.
        if pearls and coins and pearls - transaction.beforePearls >= Settings.PEARL_QUANTITY
            and transaction.beforeCoins - coins >= Settings.PEARL_MIN then transaction.accepted = true end
    end
    if transaction and transaction.done and not transaction.accepted then
        local balance = tonumber(player:GetAttribute("Pearls"))
        local coins = tonumber(player:GetAttribute("Doubloons"))
        -- Retry only a definite rejection with unchanged balances. A timeout or a
        -- lost response remains one pending transaction, even across reinjection.
        if transaction.ok and (transaction.result == false or type(transaction.result) == "string")
            and balance == transaction.beforePearls
            and coins == transaction.beforeCoins and os.clock() >= transaction.retryAt then
            state.purchase, transaction = nil, nil
        elseif transaction.cancelled then
            state.purchase, transaction = nil, nil
        else
            state.phase = "Waiting for Pearl purchase confirmation"
            state.lastPurchaseError = transaction.result == false and "Merchant rejected purchase; retry delayed"
                or "Purchase response uncertain; checking the same transaction"
            return false
        end
    end
    local lease
    if not transaction then
        local boat = Workspace:FindFirstChild("MerchantBoat")
        local beforeCoins = tonumber(player:GetAttribute("Doubloons"))
        local beforePearls = tonumber(player:GetAttribute("Pearls"))
        if not boat or not beforeCoins or beforeCoins < Settings.PEARL_MIN or not beforePearls then return false end
        local pad = boat:FindFirstChild("SellPad")
        local spawner = pad and pad:FindFirstChild("Spawner")
        local position = spawner and spawner:IsA("BasePart") and spawner.Position or nil
        if not position then
            local ok, cf = pcall(function() return boat:GetPivot() end)
            position = ok and cf.Position or nil
        end
        if typeof(position) ~= "Vector3" then return false end
        local purchase = runtimeGlobalFunction("MerchantShopPurchase")
        local network = not purchase and sackNet() or nil
        if not purchase and (not network or type(network.InvokeServer) ~= "function") then return false end
        lease = Motion.Begin(CFrame.new(position + Vector3.new(0, 5, 6)), {
            valid = function() return boat.Parent == Workspace end,
        })
        if not lease then return false end
        if not lease:WaitStable(0.4, 4) then
            lease:Close("merchant-arrival-failed")
            state.lastPurchaseError = "Merchant arrival not stable; purchase held back"
            return false
        end
        transaction = {boat = boat, beforePearls = beforePearls, beforeCoins = beforeCoins,
            sentAt = os.clock(), done = false, accepted = false, retryAt = os.clock() + 5}
        state.purchase = transaction
        Metrics.Purchase(beforePearls, false)
        local arrival = lease
        task.spawn(function()
            if not isRunning() or state.purchase ~= transaction or not arrival:Ready(0.4) then
                transaction.cancelled, transaction.done = true, true
                return
            end
            transaction.ok, transaction.result = pcall(function()
                if purchase then return purchase("Pearls", position) end
                return network:InvokeServer("MerchantShopPurchase", "Pearls", position)
            end)
            -- Store the response on its own receipt. An old worker never completes
            -- a new run or sends another purchase after it has been cancelled.
            transaction.accepted = transaction.ok and transaction.result == true
            transaction.done = true
        end)
    end
    local deadline = os.clock() + 1.8
    repeat
        if not isRunning() then break end
        if transaction.accepted then
            Metrics.Purchase(transaction.beforePearls, true)
            if Metrics.Complete(transaction.beforePearls) then
                state.bought, state.lastPurchaseError = true, nil
                Flow.Set(9, "Pearls received and verified; returning to Lobby")
                if lease then lease:Close("purchase-confirmed") end
                return true
            end
        elseif transaction.done then break end
        task.wait(0.04)
    until os.clock() >= deadline
    if lease then lease:Close("merchant-receipt-wait-ended") end
    if isRunning() and not transaction.done and not transaction.timedOut then
        transaction.timedOut = true
        Metrics.Add("timeouts")
    end
    state.phase = "Waiting for Pearl purchase confirmation"
    state.lastPurchaseError = transaction.accepted and "Purchase accepted; waiting for Pearl balance to increase"
        or "Pearl purchase pending; no duplicate request"
    return false
end

-- One controller follows Bonfire/empty Sack -> Volcano -> chests -> Base/Pearl.
-- Fuel receipts survive a defense interruption and are reconciled before resuming.
local function stepFarm()
    disableCutscenes()
    local character, humanoid = getCharacter(), getHumanoid()
    if not isIslandAlive() or not character or not getRoot() or not humanoid
        or humanoid.Health <= 0 or character:GetAttribute("Dead") then
        state.phase = "Waiting for character"
        return
    end
    local flow, ritual = Flow.data, state.volcano
    flow.stage = flow.stage or "fuel"
    if flow.character and flow.character ~= character then
        recoverCharacterMobility()
        state.pendingStore, state.pendingFuelDrop, state.fuelBatch, state.fuelDeliveryLease = nil, nil, nil, nil
        state.fuelInSack, ritual.held = 0, 0
        if ritual.dropTransaction and ritual.dropTransaction.released then
            ritual.receipts[#ritual.receipts + 1] = ritual.dropTransaction
        end
        ritual.dropTransaction, ritual.deliveryLease, ritual.pendingCorpse = nil, nil, nil
    end
    flow.character = character

    if flow.stage == "defense" or flow.stage == "merchant" or flow.stage == "refuel" then
        if ritual.bossDefeated ~= true then flow.stage = "volcano"; return end
        -- Return after Volcano and the chest target. Refilling may collect fuel away from Base,
        -- while every pulse still gives a newly started raid first priority.
        if flow.stage ~= "refuel" or (flow.defenseSeen and not flow.defenseDone) then
            if not returnToBase() then return end
        end
        local spawnIsland = Workspace:FindFirstChild("SpawnIsland")
        local raiders = nearbyRaiders(homePosition())
        if raidActive() or #raiders > 0 then
            flow.defenseSeen, flow.defenseDone, flow.clearSince = true, false, nil
            flow.stage = "defense"
            local lease = state.fuelDeliveryLease
            if lease then lease:Close("defense-priority") end
            state.fuelDeliveryLease = nil
            if not returnToBase() then return end
            raiders = nearbyRaiders(homePosition())
            Flow.Set(7, #raiders > 0 and "Defending Base" or "Waiting for the next raid wave")
            if #raiders > 0 then defend(raiders) end
            return
        end
        local function canRefuel()
            return isRunning() and not raidActive() and #nearbyRaiders(homePosition()) == 0
        end
        if not spawnIsland then
            -- StationSackFarm only resolves Base at delivery time. Gathering at a
            -- remote island can continue while SpawnIsland is streamed out.
            if flow.stage == "refuel" then
                Flow.Set(2, "Gathering fuel for Base")
                if haulFuel(nil, false, canRefuel) == "deliver" then returnToBase() end
            else
                requestStreamNear(homePosition())
            end
            return
        end
        if not flow.defenseDone and (flow.defenseSeen or merchantExists()) then
            flow.clearSince = flow.clearSince or os.clock()
            if os.clock() - flow.clearSince < Settings.DEFENSE_CLEAR_SECONDS then
                Flow.Set(7, "Confirming defense complete: raid ended and Base clear")
                return
            end
            flow.defenseDone = true
        end
        -- Finish an existing purchase receipt without starting another fuel trip.
        if state.purchase and flow.defenseDone then
            Flow.Set(8, "Confirming Pearl purchase")
            buyPearls()
            return
        end
        if state.pendingStore then
            equipSack()
            SackTransfer.ReconcileStore()
            if state.pendingStore then state.phase = "Confirming fuel pickup"; return end
        end
        if state.pendingFuelDrop or state.fuelBatch then
            flow.stage = "refuel"
            Flow.Set(2, "Resuming Bonfire delivery after defense")
            dropFuelAtCampfire(spawnIsland:FindFirstChild("Dropper"), spawnIsland, false, canRefuel)
            return
        end
        if not campfireReady(spawnIsland) then
            flow.stage = "refuel"
            Flow.Set(2, "Checking Base fire: refilling to at least " .. Settings.MIN_CAMPFIRE_PERCENT .. "%")
            local dropper = spawnIsland:FindFirstChild("Dropper")
            if haulFuel(dropper, false, canRefuel) == "deliver" then returnToBase() end
            return
        end
        local lease = state.fuelDeliveryLease
        if lease then lease:Close("base-fire-ready") end
        state.fuelDeliveryLease = nil
        flow.stage = flow.defenseDone and "merchant" or "defense"
        if not returnToBase() then return end
        if not flow.defenseDone then
            Flow.Set(7, "Bonfire ready; at Base waiting for defense to begin")
            return
        end
        Flow.Set(8, "Base safe and fire ready; waiting for Merchant")
        local coins = tonumber(player:GetAttribute("Doubloons"))
        if coins and coins < Settings.PEARL_MIN then
            flow.stage = "chests"
            return
        end
        if merchantExists() then buyPearls() end
        return
    end

    if state.pendingStore then
        equipSack()
        SackTransfer.ReconcileStore()
        if state.pendingStore then state.phase = "Confirming pickup before continuing"; return end
    end
    local spawnIsland = Workspace:FindFirstChild("SpawnIsland")
    if spawnIsland then homePosition() end
    if state.pendingFuelDrop or state.fuelBatch then
        flow.stage = "fuel"
        Flow.Set(2)
        if spawnIsland then
            dropFuelAtCampfire(spawnIsland:FindFirstChild("Dropper"), spawnIsland, true)
        else
            returnToBase()
        end
        return
    end
    if ritual.dropTransaction or ritual.deliveryLease then
        flow.stage = "volcano"
        if not releaseVolcanoDeliveryForBoss() then
            Flow.Set(4)
            local volcano = findVolcano()
            if volcano then dropMagmaCorpse(volcano)
            elseif ritual.dropTransaction then requestStreamNear(ritual.dropTransaction.targetPosition) end
            return
        end
    end
    if flow.stage == "chests" then
        -- A stale saved chest stage must not skip the new Bonfire/Volcano order.
        if ritual.bossDefeated ~= true then
            flow.stage = flow.initialBonfireReady and flow.sackCleared and "volcano" or "fuel"
            Flow.Set(flow.stage == "volcano" and 3 or 2)
            return
        end
        Flow.Set(6)
        local coins = tonumber(player:GetAttribute("Doubloons"))
        if not coins then state.phase = "Waiting for Dubloon balance"; return end
        if coins < Settings.FARM_TARGET then farmNearestChest(); return end
        flow.stage = "defense"
        Flow.Set(7, "Doubloons ready; returning to Base")
        returnToBase()
        return
    end
    if flow.stage == "fuel" then
        if ritual.bossDefeated == true then
            flow.stage = "chests"
            Flow.Set(6, "Volcano complete; checking Doubloons before returning to Base")
            return
        end
        Flow.Set(2)
        -- A resumed run may already carry a tracked golem; preserve its sacrifice.
        if (tonumber(ritual.held) or 0) > 0 then flow.stage = "volcano"; return end
        if not spawnIsland then
            -- Keep gathering remotely until the native route has a load to deliver.
            if haulFuel(nil, true) == "deliver" then returnToBase() end
            return
        end
        if not equipSack() then state.phase = "Waiting for Sack"; return end
        local used = select(1, getSackCount())
        if used == nil then state.phase = "Waiting for Sack counter"; return end
        if campfireReady(spawnIsland) and used == 0 then
            state.fuelInSack = 0
            local lease = state.fuelDeliveryLease
            if lease then lease:Close("sack-empty-before-volcano") end
            state.fuelDeliveryLease = nil
            flow.initialBonfireReady, flow.sackCleared = true, true
            flow.stage = "volcano"
            Flow.Set(3, "Bonfire ready and Sack empty; collecting Magma Golems")
            return
        end
        local dropper = spawnIsland:FindFirstChild("Dropper")
        if haulFuel(dropper, true) == "deliver" then returnToBase() end
        return
    end
    if flow.stage == "volcano" then
        if runVolcanoPrelude() then
            flow.stage, flow.clearSince = "chests", nil
            Flow.Set(6, "Volcano complete; collecting " .. Settings.FARM_TARGET .. " Doubloons before returning to Base")
        end
    end
end

task.spawn(function()
    while isRunning() and not state.bought do
        local ok, err = pcall(stepFarm)
        if not isRunning() then break end
        if not ok then
            local message = tostring(err)
            state.lastError, state.lastErrorAt = message, os.clock()
            state.errorCount = (tonumber(state.errorCount) or 0) + 1
            state.phase = "Recovering from script error"
            Metrics.Phase("Recovery")
            Metrics.Add("recoveries")
            if state.lastWarnedError ~= message
                or os.clock() - (tonumber(state.lastWarnedErrorAt) or 0) > 8 then
                state.lastWarnedError, state.lastWarnedErrorAt = message, os.clock()
                warn("[Sea Pearl Farm] " .. message)
            end
            recoverCharacterMobility()
            task.wait(1)
        else
            state.lastMainPulseAt = os.clock()
            if state.lastError ~= nil and os.clock()
                - (tonumber(state.lastErrorAt) or os.clock()) > 8 then state.lastError = nil end
        end
        -- Even an unchanged preflight result must yield to physics/replication.
        task.wait(0.1)
    end
    if isRunning() and state.bought then
        Metrics.Save()
        task.wait(2)
        local started = os.clock()
        while isRunning() and isIslandAlive() and os.clock() - started < 45 do
            queueNextExecution()
            state.invokeNativeLeaveGame()
            task.wait(6)
        end
        if isRunning() and isIslandAlive() then returnToLobby() end
    end
end)
