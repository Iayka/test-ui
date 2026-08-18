--[[
AnimationTracker V2.3 Known-ID Calibrator for Matcha
- No startup HTTP.
- Read-only memory access.
- Uses the legacy layout first.
- If Roblox moved animation internals, it discovers the live layout while a
  configured attack animation is playing.
- Validation is strict: a candidate layout is accepted only when the decoded
  animation ID is one of the attack IDs supplied by the main script.
]]

local VERSION = "2.3-known-id-calibrator"

local LEGACY = {
    ActiveAnimations = 0x868,
    NodeTrack = 0x10,
    Animation = 0xD0,
    AnimationId = 0xD0,
    SpeedDelta = 0x14,
    TimeDelta = 0x18,
}

local Layout = {
    ActiveAnimations = LEGACY.ActiveAnimations,
    NodeTrack = LEGACY.NodeTrack,
    Animation = LEGACY.Animation,
    AnimationId = LEGACY.AnimationId,
    Speed = LEGACY.Animation + LEGACY.SpeedDelta,
    TimePosition = LEGACY.Animation + LEGACY.TimeDelta,
    Locked = false,
    Source = "legacy",
}

local function finite(n)
    return type(n) == "number"
        and n == n
        and n > -math.huge
        and n < math.huge
end

local function plausiblePtr(p)
    return finite(p)
        and p >= 0x10000
        and p <= 0x7FFFFFFFFFFF
end

local function readPtr(address)
    if not plausiblePtr(address) then return 0 end

    local ok, value = pcall(function()
        return memory_read("uintptr_t", address)
    end)

    if not ok or not plausiblePtr(value) then
        return 0
    end

    return value
end

local function readFloat(address)
    if not plausiblePtr(address) then return nil end

    local ok, value = pcall(function()
        return memory_read("float", address)
    end)

    if not ok or not finite(value) then
        return nil
    end

    return value
end

local function readString(address)
    if not plausiblePtr(address) then return nil end

    local ok, value = pcall(function()
        return memory_read("string", address)
    end)

    if not ok or type(value) ~= "string" or #value == 0 then
        return nil
    end

    return value
end

local function normalizeAssetId(value)
    local text = tostring(value or "")
    local digits = string.match(text, "(%d%d%d%d%d%d+)")

    if not digits or #digits > 20 then
        return nil, nil
    end

    return "rbxassetid://" .. digits, tonumber(digits)
end

local function findHumanoid(character)
    if not character then return nil end

    local humanoid

    pcall(function()
        humanoid = character:FindFirstChildWhichIsA("Humanoid")
    end)

    if not humanoid then
        pcall(function()
            humanoid = character:FindFirstChildOfClass("Humanoid")
        end)
    end

    if not humanoid then
        pcall(function()
            humanoid = character:FindFirstChild("Humanoid")
        end)
    end

    return humanoid
end

local function findAnimator(character)
    local humanoid = findHumanoid(character)
    if not humanoid then return nil end

    local animator

    pcall(function()
        animator = humanoid:FindFirstChildWhichIsA("Animator")
    end)

    if not animator then
        pcall(function()
            animator = humanoid:FindFirstChildOfClass("Animator")
        end)
    end

    if not animator then
        pcall(function()
            animator = humanoid:FindFirstChild("Animator")
        end)
    end

    return animator
end

local function getAnimatorAddress(character)
    local animator = findAnimator(character)
    if not animator then return nil end

    local address

    pcall(function()
        address = animator.Address
    end)

    if not plausiblePtr(address) then
        return nil
    end

    return address
end

local function getList(animatorAddress, activeOffset)
    local head = readPtr(animatorAddress + activeOffset)
    if head == 0 then return nil end

    local firstNode = readPtr(head)

    if firstNode == 0 or firstNode == head then
        return {
            Head = head,
            First = firstNode,
            Tracks = {},
        }
    end

    local tracks = {}
    local visited = {}
    local currentNode = firstNode

    while currentNode ~= 0
        and currentNode ~= head
        and not visited[currentNode]
        and #tracks < 50 do

        visited[currentNode] = true

        local trackAddress =
            readPtr(currentNode + LEGACY.NodeTrack)

        if trackAddress ~= 0 then
            tracks[#tracks + 1] = trackAddress
        end

        local nextNode = readPtr(currentNode)

        if nextNode == 0 or nextNode == head then
            break
        end

        currentNode = nextNode
    end

    return {
        Head = head,
        First = firstNode,
        Tracks = tracks,
    }
end

local function readIdWithLayout(trackAddress, animationOffset, animationIdOffset)
    local animation =
        readPtr(trackAddress + animationOffset)

    if animation == 0 then return nil end

    local idPointer =
        readPtr(animation + animationIdOffset)

    if idPointer == 0 then return nil end

    local raw = readString(idPointer)
    if not raw then return nil end

    local animationId, numericId =
        normalizeAssetId(raw)

    if not animationId then return nil end

    return animationId, numericId
end

local function idIsKnown(knownIds, numericId)
    if not numericId or type(knownIds) ~= "table" then
        return false
    end

    if knownIds[numericId] == true then
        return true
    end

    for i = 1, #knownIds do
        if tonumber(knownIds[i]) == numericId then
            return true
        end
    end

    return false
end

local function tryLegacy(character, knownIds)
    local animatorAddress =
        getAnimatorAddress(character)

    if not animatorAddress then
        return false
    end

    local list =
        getList(animatorAddress, LEGACY.ActiveAnimations)

    if not list or #list.Tracks == 0 then
        return false
    end

    for i = 1, #list.Tracks do
        local animationId, numericId =
            readIdWithLayout(
                list.Tracks[i],
                LEGACY.Animation,
                LEGACY.AnimationId
            )

        if animationId and (
            type(knownIds) ~= "table"
            or next(knownIds) == nil
            or idIsKnown(knownIds, numericId)
        ) then
            Layout.ActiveAnimations =
                LEGACY.ActiveAnimations

            Layout.Animation =
                LEGACY.Animation

            Layout.AnimationId =
                LEGACY.AnimationId

            Layout.Speed =
                Layout.Animation + LEGACY.SpeedDelta

            Layout.TimePosition =
                Layout.Animation + LEGACY.TimeDelta

            Layout.Locked = true
            Layout.Source = "legacy-validated"

            return true
        end
    end

    return false
end

local function calibrateFromKnownAttack(character, knownIds)
    if type(knownIds) ~= "table"
        or next(knownIds) == nil then
        return false
    end

    local animatorAddress =
        getAnimatorAddress(character)

    if not animatorAddress then
        return false
    end

    for activeOffset = 0x700, 0xB80, 0x8 do
        local list =
            getList(animatorAddress, activeOffset)

        if list and #list.Tracks > 0 then
            local maxTracks =
                math.min(#list.Tracks, 6)

            for trackIndex = 1, maxTracks do
                local trackAddress =
                    list.Tracks[trackIndex]

                for animationOffset = 0x80, 0x160, 0x8 do
                    local animation =
                        readPtr(trackAddress + animationOffset)

                    if animation ~= 0 then
                        for animationIdOffset = 0x80, 0x160, 0x8 do
                            local idPointer =
                                readPtr(animation + animationIdOffset)

                            if idPointer ~= 0 then
                                local raw =
                                    readString(idPointer)

                                if raw then
                                    local animationId, numericId =
                                        normalizeAssetId(raw)

                                    if animationId
                                        and idIsKnown(knownIds, numericId) then

                                        Layout.ActiveAnimations =
                                            activeOffset

                                        Layout.Animation =
                                            animationOffset

                                        Layout.AnimationId =
                                            animationIdOffset

                                        Layout.Speed =
                                            animationOffset + LEGACY.SpeedDelta

                                        Layout.TimePosition =
                                            animationOffset + LEGACY.TimeDelta

                                        Layout.Locked = true
                                        Layout.Source = "known-id-calibrated"

                                        print(string.format(
                                            "[AnimationTracker V2.3] CALIBRATED from attack %s | Active=0x%X Animation=0x%X AnimationId=0x%X Speed=0x%X Time=0x%X",
                                            tostring(animationId),
                                            Layout.ActiveAnimations,
                                            Layout.Animation,
                                            Layout.AnimationId,
                                            Layout.Speed,
                                            Layout.TimePosition
                                        ))

                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

local function getTracksWithLayout(character)
    local animatorAddress =
        getAnimatorAddress(character)

    if not animatorAddress then
        return {}
    end

    local list =
        getList(
            animatorAddress,
            Layout.ActiveAnimations
        )

    return list and list.Tracks or {}
end

local function extractTrackInfo(trackAddress)
    local animationId, numericId =
        readIdWithLayout(
            trackAddress,
            Layout.Animation,
            Layout.AnimationId
        )

    if not animationId then
        return nil
    end

    local timePosition =
        readFloat(
            trackAddress + Layout.TimePosition
        )

    if not timePosition
        or timePosition < -0.25
        or timePosition > 5 then
        timePosition = 0
    end

    local speed =
        readFloat(
            trackAddress + Layout.Speed
        )

    if not speed
        or speed < -16
        or speed > 16 then
        speed = 1
    end

    return {
        Address = trackAddress,
        Name = animationId,
        AnimationId = animationId,
        NumericAnimationId = numericId,
        TimePosition = timePosition,
        Speed = speed,
        IsPlaying = 1,
        Source = Layout.Source,
    }
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({
        _listeners = {}
    }, Signal)
end

function Signal:Connect(callback)
    self._listeners[#self._listeners + 1] =
        callback

    local connected = true

    return {
        Disconnect = function()
            if not connected then return end
            connected = false

            for i = #self._listeners, 1, -1 do
                if self._listeners[i] == callback then
                    table.remove(self._listeners, i)
                    break
                end
            end
        end
    }
end

function Signal:Fire(...)
    for i = 1, #self._listeners do
        local ok, err =
            pcall(self._listeners[i], ...)

        if not ok then
            print(
                "[AnimationTracker V2.3] listener error: "
                .. tostring(err)
            )
        end
    end
end

local AnimationTracker = {}
AnimationTracker.__index = AnimationTracker
AnimationTracker.Version = VERSION

function AnimationTracker.new(ignoreIds)
    local self =
        setmetatable({}, AnimationTracker)

    self.AnimationAdded =
        Signal.new()

    self.AnimationUpdated =
        Signal.new()

    self.AnimationRemoved =
        Signal.new()

    self.IgnoreIds =
        ignoreIds or {}

    self.KnownIds = {}

    self.Debug = false

    self._cachedTracks = {}
    self._lastDiag = 0
    self._lastCalibrateAttempt = 0
    self._legacyTried = false

    return self
end

local function ignored(ignoreIds, numericId)
    if not numericId then return false end

    for i = 1, #ignoreIds do
        if tonumber(ignoreIds[i]) == numericId then
            return true
        end
    end

    return false
end

local function charName(character)
    local value = "?"

    pcall(function()
        value = character.Name
    end)

    return tostring(value or "?")
end

function AnimationTracker:_diag(character, text)
    if not self.Debug then return end

    local now = os.clock()

    if now - self._lastDiag < 2 then
        return
    end

    self._lastDiag = now

    print(
        "[AnimationTracker V2.3] "
        .. charName(character)
        .. " | "
        .. tostring(text)
    )
end

function AnimationTracker:Update(character)
    if not Layout.Locked and not self._legacyTried then
        self._legacyTried = true

        if tryLegacy(character, self.KnownIds) then
            print(
                "[AnimationTracker V2.3] legacy layout validated"
            )
        end
    end

    local trackAddresses =
        getTracksWithLayout(character)

    if #trackAddresses == 0
        and not Layout.Locked then

        local now = os.clock()

        if now - self._lastCalibrateAttempt >= 0.10 then
            self._lastCalibrateAttempt = now

            calibrateFromKnownAttack(
                character,
                self.KnownIds
            )

            if Layout.Locked then
                trackAddresses =
                    getTracksWithLayout(character)
            end
        end
    end

    if #trackAddresses == 0 then
        self:_diag(
            character,
            string.format(
                "tracks=0 | locked=%s | layout=%s | waiting for configured attack to calibrate",
                tostring(Layout.Locked),
                tostring(Layout.Source)
            )
        )

        for key, cachedInfo in pairs(self._cachedTracks) do
            self.AnimationRemoved:Fire(cachedInfo)
            self._cachedTracks[key] = nil
        end

        return {}
    end

    local currentKeys = {}
    local activeSnapshot = {}

    for i = 1, #trackAddresses do
        local address =
            trackAddresses[i]

        local info =
            extractTrackInfo(address)

        if info then
            local key = address
            currentKeys[key] = true

            local cached =
                self._cachedTracks[key]

            local newlyExtracted =
                cached == nil

            if not cached then
                cached = info
                self._cachedTracks[key] = cached
            else
                cached.AnimationId =
                    info.AnimationId

                cached.NumericAnimationId =
                    info.NumericAnimationId

                cached.TimePosition =
                    info.TimePosition

                cached.Speed =
                    info.Speed

                cached.Source =
                    info.Source
            end

            if not ignored(
                self.IgnoreIds,
                cached.NumericAnimationId
            ) then

                if newlyExtracted then
                    self.AnimationAdded:Fire(cached)
                end

                self.AnimationUpdated:Fire(
                    cached,
                    cached.TimePosition
                )

                activeSnapshot[#activeSnapshot + 1] =
                    cached
            end
        end
    end

    for key, cachedInfo in pairs(self._cachedTracks) do
        if not currentKeys[key] then
            self.AnimationRemoved:Fire(cachedInfo)
            self._cachedTracks[key] = nil
        end
    end

    if #activeSnapshot > 0 then
        self:_diag(
            character,
            string.format(
                "active=%d | first=%s | source=%s",
                #activeSnapshot,
                tostring(activeSnapshot[1].AnimationId),
                tostring(Layout.Source)
            )
        )
    end

    return activeSnapshot
end

local ENV =
    (getgenv and getgenv()) or _G

ENV.AnimationTracker = AnimationTracker
_G.AnimationTracker = AnimationTracker

print(
    "[AnimationTracker V2.3] loaded "
    .. VERSION
    .. " | strict known-ID calibration"
)

return AnimationTracker
