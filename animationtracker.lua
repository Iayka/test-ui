--[[
AnimationTracker V2.2 Hybrid for Matcha
- No startup HTTP requests.
- Prefers Animator:GetPlayingAnimationTracks() when Matcha exposes it.
- Falls back to the validated memory layout when native track enumeration is unavailable.
- Uses FindFirstChildWhichIsA first, matching the original tracker.
- Emits throttled diagnostics when Debug=true.
]]

local VERSION = "2.2-hybrid"

local OFF = {
    ActiveAnimations = 0x868,
    NodeTrack = 0x10,
    Animation = 0xD0,
    AnimationId = 0xD0,
    Speed = 0xE4,
    TimePosition = 0xE8,
}

local function finite(n)
    return type(n) == "number"
        and n == n
        and n > -math.huge
        and n < math.huge
end

local function readPtr(address)
    if not finite(address) or address <= 0 then return 0 end

    local ok, value = pcall(function()
        return memory_read("uintptr_t", address)
    end)

    if not ok or not finite(value) then return 0 end
    return value
end

local function readFloat(address)
    if not finite(address) or address <= 0 then return nil end

    local ok, value = pcall(function()
        return memory_read("float", address)
    end)

    if not ok or not finite(value) then return nil end
    return value
end

local function readString(address)
    if not finite(address) or address <= 0 then return nil end

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

    local humanoid = nil

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

    local animator = nil

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

local function getAnimatorAddress(animator)
    if not animator then return nil end

    local address = nil
    pcall(function()
        address = animator.Address
    end)

    if not finite(address) or address == 0 then
        return nil
    end

    return address
end

local function extractNativeTrack(track)
    if not track then return nil end

    local rawAnimationId = nil

    local okId = pcall(function()
        local animation = track.Animation
        if animation then
            rawAnimationId = animation.AnimationId
        end
    end)

    if not okId or not rawAnimationId then
        return nil
    end

    local animationId, numericId = normalizeAssetId(rawAnimationId)
    if not animationId then return nil end

    local timePosition = 0
    pcall(function()
        local value = track.TimePosition
        if finite(value) and value >= -0.25 and value <= 120 then
            timePosition = value
        end
    end)

    local speed = 1
    pcall(function()
        local value = track.Speed
        if finite(value) and value >= -16 and value <= 16 then
            speed = value
        end
    end)

    local address = nil
    pcall(function()
        address = track.Address
    end)

    if not finite(address) or address == 0 then
        address = nil
    end

    return {
        Address = address,
        NativeTrack = track,
        Name = animationId,
        AnimationId = animationId,
        NumericAnimationId = numericId,
        TimePosition = timePosition,
        Speed = speed,
        IsPlaying = 1,
        Source = "native",
    }
end

local function getNativeTrackInfos(character)
    local animator = findAnimator(character)
    if not animator then
        return nil, "no_animator"
    end

    local tracks = nil

    local ok = pcall(function()
        tracks = animator:GetPlayingAnimationTracks()
    end)

    if not ok or type(tracks) ~= "table" then
        return nil, "native_unavailable"
    end

    local infos = {}

    for _, track in ipairs(tracks) do
        local info = extractNativeTrack(track)
        if info then
            infos[#infos + 1] = info
        end
    end

    return infos, "native"
end

local function getMemoryTrackAddresses(character)
    local animator = findAnimator(character)
    if not animator then return {}, "no_animator" end

    local animatorAddress = getAnimatorAddress(animator)
    if not animatorAddress then return {}, "no_animator_address" end

    local listHead = readPtr(animatorAddress + OFF.ActiveAnimations)
    if listHead == 0 then return {}, "no_list_head" end

    local firstNode = readPtr(listHead)

    if firstNode == 0 then
        return {}, "no_first_node"
    end

    if firstNode == listHead then
        return {}, "empty_list"
    end

    local tracks = {}
    local visited = {}
    local currentNode = firstNode

    while currentNode ~= 0
        and currentNode ~= listHead
        and not visited[currentNode]
        and #tracks < 50 do

        visited[currentNode] = true

        local trackAddress = readPtr(currentNode + OFF.NodeTrack)

        if trackAddress ~= 0 then
            tracks[#tracks + 1] = trackAddress
        end

        local nextNode = readPtr(currentNode)

        if nextNode == 0 or nextNode == listHead then
            break
        end

        currentNode = nextNode
    end

    return tracks, "memory"
end

local function extractMemoryTrack(trackAddress)
    if not finite(trackAddress) or trackAddress == 0 then return nil end

    local animation = readPtr(trackAddress + OFF.Animation)
    if animation == 0 then return nil end

    local idPointer = readPtr(animation + OFF.AnimationId)
    if idPointer == 0 then return nil end

    local rawId = readString(idPointer)
    local animationId, numericId = normalizeAssetId(rawId)

    if not animationId then return nil end

    local timePosition = readFloat(trackAddress + OFF.TimePosition)

    if not timePosition or timePosition < -0.25 or timePosition > 120 then
        timePosition = 0
    end

    local speed = readFloat(trackAddress + OFF.Speed)

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
        Source = "memory",
    }
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({_listeners = {}}, Signal)
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
        local ok, err = pcall(self._listeners[i], ...)

        if not ok then
            print("[AnimationTracker V2.2] listener error: " .. tostring(err))
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
    self.Debug = false

    self._cachedTracks = {}
    self._lastDiagAt = {}
    self._lastDiagText = {}

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

local function characterName(character)
    local name = "?"

    pcall(function()
        name = character.Name
    end)

    return tostring(name or "?")
end

function AnimationTracker:_diag(character, text)
    if not self.Debug then return end

    local key = characterName(character)
    local now = os.clock()

    if self._lastDiagText[key] == text
        and (now - (self._lastDiagAt[key] or 0)) < 2 then
        return
    end

    self._lastDiagText[key] = text
    self._lastDiagAt[key] = now

    print("[AnimationTracker V2.2] " .. key .. " | " .. text)
end

local function makeCacheKey(info)
    if info.Address then
        return info.Address
    end

    if info.NativeTrack then
        return info.NativeTrack
    end

    return info
end

function AnimationTracker:Update(character)
    local currentInfos = nil
    local source = nil

    local nativeInfos, nativeReason = getNativeTrackInfos(character)

    if nativeInfos and #nativeInfos > 0 then
        currentInfos = nativeInfos
        source = "native"
    else
        local addresses, memoryReason = getMemoryTrackAddresses(character)
        local memoryInfos = {}

        for i = 1, #addresses do
            local info = extractMemoryTrack(addresses[i])

            if info then
                memoryInfos[#memoryInfos + 1] = info
            end
        end

        currentInfos = memoryInfos
        source = "memory"

        if #currentInfos == 0 then
            self:_diag(
                character,
                string.format(
                    "tracks=0 | native=%s | memory=%s | animator=%s",
                    tostring(nativeReason),
                    tostring(memoryReason),
                    findAnimator(character) and "YES" or "NO"
                )
            )
        end
    end

    local currentKeys = {}
    local activeSnapshot = {}

    for i = 1, #currentInfos do
        local liveInfo = currentInfos[i]
        local key = makeCacheKey(liveInfo)

        currentKeys[key] = true

        local cached = self._cachedTracks[key]
        local newlyExtracted = cached == nil

        if not cached then
            cached = liveInfo
            self._cachedTracks[key] = cached
        else
            cached.AnimationId = liveInfo.AnimationId
            cached.NumericAnimationId = liveInfo.NumericAnimationId
            cached.TimePosition = liveInfo.TimePosition
            cached.Speed = liveInfo.Speed
            cached.Source = liveInfo.Source
            cached.NativeTrack = liveInfo.NativeTrack or cached.NativeTrack
        end

        if not ignored(self.IgnoreIds, cached.NumericAnimationId) then
            if newlyExtracted then
                self.AnimationAdded:Fire(cached)
            end

            self.AnimationUpdated:Fire(cached, cached.TimePosition)
            activeSnapshot[#activeSnapshot + 1] = cached
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
                "source=%s | active=%d | first=%s",
                tostring(source),
                #activeSnapshot,
                tostring(activeSnapshot[1].AnimationId)
            )
        )
    end

    return activeSnapshot
end

local ENV = (getgenv and getgenv()) or _G

ENV.AnimationTracker = AnimationTracker
_G.AnimationTracker = AnimationTracker

print("[AnimationTracker V2.2] loaded " .. VERSION .. " | native + memory fallback")
return AnimationTracker
