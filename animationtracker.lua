--[[
AnimationTracker V2.1 for Matcha
- No startup HTTP requests.
- Uses the currently validated Roblox AnimationTrack layout directly.
- Avoids the V2.0 false-positive self-calibration that selected 0xA0/0xB0.
- Exports AnimationTracker immediately.
]]

local VERSION = "2.1-fixed-layout"

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
    if not digits or #digits > 20 then return nil end
    return "rbxassetid://" .. digits, tonumber(digits)
end

local function getAnimatorAddress(character)
    if not character or not character.Address or character.Address == 0 then
        return nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return nil end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator or not animator.Address or animator.Address == 0 then
        return nil
    end

    return animator.Address
end

local function getPlayingTrackAddresses(character)
    local animatorAddress = getAnimatorAddress(character)
    if not animatorAddress then return {} end

    local listHead = readPtr(animatorAddress + OFF.ActiveAnimations)
    if listHead == 0 then return {} end

    local firstNode = readPtr(listHead)
    if firstNode == 0 or firstNode == listHead then return {} end

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
        if nextNode == 0 or nextNode == listHead then break end
        currentNode = nextNode
    end

    return tracks
end

local function extractTrackInfo(trackAddress)
    if not trackAddress or trackAddress == 0 then return nil end

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
            print("[AnimationTracker V2.1] listener error: " .. tostring(err))
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
    self._validatedLogged = false
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

                if not self._validatedLogged then
                    self._validatedLogged = true
                    print(string.format(
                        "[AnimationTracker V2.1] layout validated | Active=0x%X Animation=0x%X AnimationId=0x%X Time=0x%X",
                        OFF.ActiveAnimations,
                        OFF.Animation,
                        OFF.AnimationId,
                        OFF.TimePosition
                    ))
                end
            end
        else
            local liveTime = readFloat(address + OFF.TimePosition)
            if liveTime and liveTime >= -0.25 and liveTime <= 120 then
                info.TimePosition = liveTime
            end

            local liveSpeed = readFloat(address + OFF.Speed)
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

print("[AnimationTracker V2.1] loaded " .. VERSION .. " | no startup HTTP")
return AnimationTracker
