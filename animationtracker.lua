--[[
AnimationTracker V2 for Matcha
- No startup HTTP requests.
- Exports _G.AnimationTracker immediately.
- Uses memory_read only.
- Fast path uses the last known AnimationTrack layout.
- If Roblox shifts the Animator active-animation-list offset, it discovers it
  from the live Animator object instead of waiting on an offsets website.
- If the Animation / AnimationId pair shifts, it performs a bounded scan and
  caches the discovered layout for the rest of the session.
]]

local VERSION = "2.0-self-healing"

local DEFAULTS = {
    ActiveAnimations = 0x868,
    NodeTrack = 0x10,
    Animation = 0xD0,
    AnimationId = 0xD0,
    Speed = 0xE4,
    TimePosition = 0xE8,
}

local Layout = {
    ActiveAnimations = DEFAULTS.ActiveAnimations,
    NodeTrack = DEFAULTS.NodeTrack,
    Animation = DEFAULTS.Animation,
    AnimationId = DEFAULTS.AnimationId,
    Speed = DEFAULTS.Speed,
    TimePosition = DEFAULTS.TimePosition,
    Calibrated = false,
}

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function readPtr(address)
    if not finite(address) or address <= 0 then return 0 end
    local value = memory_read("uintptr_t", address)
    if not finite(value) then return 0 end
    return value
end

local function readFloat(address)
    if not finite(address) or address <= 0 then return nil end
    local value = memory_read("float", address)
    if not finite(value) then return nil end
    return value
end

local function readString(address)
    if not finite(address) or address <= 0 then return nil end
    local value = memory_read("string", address)
    if type(value) ~= "string" or #value == 0 then return nil end
    return value
end

local function normalizeAssetId(value)
    if type(value) ~= "string" then return nil end

    local digits = string.match(value, "(%d%d%d%d%d%d+)")
    if not digits then return nil end

    -- Roblox asset IDs are far smaller than this; reject obviously bogus
    -- strings produced by scanning unrelated memory.
    if #digits > 20 then return nil end

    return "rbxassetid://" .. digits, tonumber(digits)
end

local function getAnimatorAddress(character)
    if not character or character.Address == 0 then return nil end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return nil end

    local animator = humanoid:FindFirstChildOfClass("Animator")

    if not animator or not animator.Address or animator.Address == 0 then
        return nil
    end

    return animator.Address
end

local function getFirstTrackForActiveOffset(animatorAddress, activeOffset)
    local head = readPtr(animatorAddress + activeOffset)
    if head == 0 then return nil end

    local firstNode = readPtr(head)
    if firstNode == 0 or firstNode == head then return nil end

    local track = readPtr(firstNode + DEFAULTS.NodeTrack)
    if track == 0 then return nil end

    return track, head, firstNode
end

local function readAssetWithLayout(trackAddress, animationOffset, animationIdOffset)
    local animation = readPtr(trackAddress + animationOffset)
    if animation == 0 then return nil end

    local idPointer = readPtr(animation + animationIdOffset)
    if idPointer == 0 then return nil end

    local text = readString(idPointer)
    if not text then return nil end

    return normalizeAssetId(text)
end

local function findAnimationLayout(trackAddress)
    -- Fast path: layout used by the previous tracker.
    local assetId = readAssetWithLayout(
        trackAddress,
        DEFAULTS.Animation,
        DEFAULTS.AnimationId
    )

    if assetId then
        return DEFAULTS.Animation, DEFAULTS.AnimationId
    end

    -- Most Roblox layout shifts keep these fields in the same small region.
    -- Keep the scan bounded so calibration cannot create a long freeze.
    for animationOffset = 0xA0, 0x110, 0x8 do
        local animation = readPtr(trackAddress + animationOffset)
        if animation ~= 0 then
            for animationIdOffset = 0xA0, 0x110, 0x8 do
                local idPointer = readPtr(animation + animationIdOffset)
                if idPointer ~= 0 then
                    local text = readString(idPointer)
                    if text and normalizeAssetId(text) then
                        return animationOffset, animationIdOffset
                    end
                end
            end
        end
    end

    return nil
end

local function findActiveAnimationsOffset(animatorAddress)
    -- Try the historical value first.
    local track = getFirstTrackForActiveOffset(
        animatorAddress,
        DEFAULTS.ActiveAnimations
    )

    if track then
        local animOff, idOff = findAnimationLayout(track)
        if animOff then
            return DEFAULTS.ActiveAnimations, animOff, idOff
        end
    end

    -- Animator.ActiveAnimations has historically lived in this region.
    -- Scan pointer-aligned offsets only and validate through a real
    -- AnimationId before accepting a candidate.
    for activeOffset = 0x700, 0xA80, 0x8 do
        if activeOffset ~= DEFAULTS.ActiveAnimations then
            local candidateTrack = getFirstTrackForActiveOffset(
                animatorAddress,
                activeOffset
            )

            if candidateTrack then
                local animOff, idOff = findAnimationLayout(candidateTrack)
                if animOff then
                    return activeOffset, animOff, idOff
                end
            end
        end
    end

    return nil
end

local function calibrate(character)
    local animatorAddress = getAnimatorAddress(character)
    if not animatorAddress then return false end

    local activeOffset, animationOffset, animationIdOffset =
        findActiveAnimationsOffset(animatorAddress)

    if not activeOffset then return false end

    Layout.ActiveAnimations = activeOffset
    Layout.Animation = animationOffset
    Layout.AnimationId = animationIdOffset

    -- In the known AnimationTrack layout Speed/TimePosition sit immediately
    -- after the Animation pointer. Preserve that relationship when the
    -- Animation field shifts as a block.
    Layout.Speed = animationOffset + 0x14
    Layout.TimePosition = animationOffset + 0x18
    Layout.Calibrated = true

    print(string.format(
        "[AnimationTracker V2] calibrated | Active=0x%X Animation=0x%X AnimationId=0x%X Time=0x%X",
        Layout.ActiveAnimations,
        Layout.Animation,
        Layout.AnimationId,
        Layout.TimePosition
    ))

    return true
end

local function getPlayingTrackAddresses(character)
    local animatorAddress = getAnimatorAddress(character)
    if not animatorAddress then return {} end

    local function readList()
        local listHead = readPtr(animatorAddress + Layout.ActiveAnimations)
        if listHead == 0 then return nil end

        local firstNode = readPtr(listHead)
        if firstNode == 0 then return nil end
        if firstNode == listHead then return {} end

        local tracks = {}
        local currentNode = firstNode
        local visited = {}

        while currentNode ~= 0
            and currentNode ~= listHead
            and not visited[currentNode]
            and #tracks < 50 do

            visited[currentNode] = true

            local track = readPtr(currentNode + Layout.NodeTrack)
            if track ~= 0 then
                tracks[#tracks + 1] = track
            end

            local nextNode = readPtr(currentNode)
            if nextNode == 0 or nextNode == listHead then break end
            currentNode = nextNode
        end

        return tracks
    end

    local tracks = readList()

    if tracks == nil or (#tracks > 0 and not Layout.Calibrated) then
        if calibrate(character) then
            tracks = readList()
        end
    end

    return tracks or {}
end

local function extractTrackInfo(trackAddress)
    if not trackAddress or trackAddress == 0 then return nil end

    local animation = readPtr(trackAddress + Layout.Animation)
    if animation == 0 then return nil end

    local idPointer = readPtr(animation + Layout.AnimationId)
    if idPointer == 0 then return nil end

    local rawId = readString(idPointer)
    local animationId, numericId = normalizeAssetId(rawId)
    if not animationId then return nil end

    local timePosition = readFloat(trackAddress + Layout.TimePosition)
    if not timePosition or timePosition < -0.25 or timePosition > 120 then
        timePosition = 0
    end

    local speed = readFloat(trackAddress + Layout.Speed)
    if not speed or speed < -16 or speed > 16 then
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
    }
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _listeners = {} }, Signal)
end

function Signal:Connect(callback)
    self._listeners[#self._listeners + 1] = callback

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
        local callback = self._listeners[i]
        local ok, err = pcall(callback, ...)
        if not ok then
            print("[AnimationTracker V2] listener error: " .. tostring(err))
        end
    end
end

local AnimationTracker = {}
AnimationTracker.__index = AnimationTracker
AnimationTracker.Version = VERSION

function AnimationTracker.new(ignoreIds)
    local self = setmetatable({}, AnimationTracker)

    self.AnimationAdded = Signal.new()
    self.AnimationUpdated = Signal.new()
    self.AnimationRemoved = Signal.new()
    self.IgnoreIds = ignoreIds or {}
    self._cachedTracks = {}
    self._lastCalibrationAttempt = 0
    self._warnedNoTracks = false

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

function AnimationTracker:Update(character)
    local tracksPlaying = getPlayingTrackAddresses(character)

    if #tracksPlaying == 0 and not Layout.Calibrated then
        local now = os.clock()
        if now - self._lastCalibrationAttempt >= 1 then
            self._lastCalibrationAttempt = now
            calibrate(character)
        end
        return {}
    end

    local currentAddresses = {}
    local activeSnapshot = {}

    for i = 1, #tracksPlaying do
        local address = tracksPlaying[i]
        currentAddresses[address] = true

        local info = self._cachedTracks[address]
        local newlyExtracted = false

        if not info then
            info = extractTrackInfo(address)
            if info then
                self._cachedTracks[address] = info
                newlyExtracted = true
            end
        else
            local liveTime = readFloat(address + Layout.TimePosition)
            if liveTime and liveTime >= -0.25 and liveTime <= 120 then
                info.TimePosition = liveTime
            end

            local liveSpeed = readFloat(address + Layout.Speed)
            if liveSpeed and liveSpeed >= -16 and liveSpeed <= 16 then
                info.Speed = liveSpeed
            end
        end

        if info and not ignored(self.IgnoreIds, info.NumericAnimationId) then
            if newlyExtracted then
                self.AnimationAdded:Fire(info)
            end

            self.AnimationUpdated:Fire(info, info.TimePosition)
            activeSnapshot[#activeSnapshot + 1] = info
        end
    end

    for address, cachedInfo in pairs(self._cachedTracks) do
        if not currentAddresses[address] then
            self.AnimationRemoved:Fire(cachedInfo)
            self._cachedTracks[address] = nil
        end
    end

    return activeSnapshot
end

local ENV = (getgenv and getgenv()) or _G
ENV.AnimationTracker = AnimationTracker
_G.AnimationTracker = AnimationTracker
AnimationTracker = AnimationTracker

print("[AnimationTracker V2] loaded " .. VERSION .. " | no startup HTTP")
return AnimationTracker
