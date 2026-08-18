--[[
AnimationTracker V2.4 for Matcha
- No startup HTTP requests.
- Uses the embedded fallback layout from the user's current Gakuran build:
    AnimationId        = 0xC0
    Animation          = 0xB8
    Speed              = 0xD4
    TimePosition       = 0xD8
    ActiveAnimations   = 0xB80
- Read-only memory access.
- Exports AnimationTracker immediately.
]]

local VERSION = "2.4-current-gakuran-layout"

local OFF = {
    AnimationId = 0xC0,         -- 192
    Animation = 0xB8,           -- 184
    Speed = 0xD4,               -- 212
    TimePosition = 0xD8,        -- 216
    ActiveAnimations = 0xB80,   -- 2944
    NodeTrack = 0x10,
}

local function finite(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function readPtr(address)
    if not finite(address) or address <= 0 then return 0 end

    local ok, value = pcall(function()
        return memory_read("uintptr_t", address)
    end)

    if not ok or not finite(value) then
        return 0
    end

    return value
end

local function readFloat(address)
    if not finite(address) or address <= 0 then return nil end

    local ok, value = pcall(function()
        return memory_read("float", address)
    end)

    if not ok or not finite(value) then
        return nil
    end

    return value
end

local function readString(address)
    if not finite(address) or address <= 0 then return nil end

    local ok, value = pcall(function()
        return memory_read("string", address)
    end)

    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end

    return value
end

local function normalizeAnimationId(value)
    local text = tostring(value or "")
    local digits = string.match(text, "(%d%d%d%d%d%d+)")

    if not digits or #digits > 20 then
        return nil, nil
    end

    return "rbxassetid://" .. digits, tonumber(digits)
end

local function findAnimator(character)
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

    return animator
end

local function getAnimatorAddress(character)
    local animator = findAnimator(character)
    if not animator then return nil end

    local address

    pcall(function()
        address = animator.Address
    end)

    if not finite(address) or address == 0 then
        return nil
    end

    return address
end

local function getPlayingTrackAddresses(character)
    local animatorAddress = getAnimatorAddress(character)

    if not animatorAddress then
        return {}, "no_animator_address"
    end

    local listHead = readPtr(
        animatorAddress + OFF.ActiveAnimations
    )

    if listHead == 0 then
        return {}, "no_list_head"
    end

    local firstNode = readPtr(listHead)

    if firstNode == 0 then
        return {}, "no_first_node"
    end

    if firstNode == listHead then
        return {}, "empty"
    end

    local tracks = {}
    local visited = {}
    local currentNode = firstNode

    while currentNode ~= 0
        and currentNode ~= listHead
        and not visited[currentNode]
        and #tracks < 50 do

        visited[currentNode] = true

        local trackAddress =
            readPtr(currentNode + OFF.NodeTrack)

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

local function extractTrackInfo(trackAddress)
    if not finite(trackAddress) or trackAddress == 0 then
        return nil
    end

    local animation =
        readPtr(trackAddress + OFF.Animation)

    if animation == 0 then
        return nil
    end

    local idPointer =
        readPtr(animation + OFF.AnimationId)

    if idPointer == 0 then
        return nil
    end

    local rawAnimationId =
        readString(idPointer)

    local animationId, numericId =
        normalizeAnimationId(rawAnimationId)

    if not animationId then
        return nil
    end

    local timePosition =
        readFloat(trackAddress + OFF.TimePosition)

    if not timePosition
        or timePosition < -0.25
        or timePosition > 120 then
        timePosition = 0
    end

    local speed =
        readFloat(trackAddress + OFF.Speed)

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
        Source = "current-gakuran-layout",
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
                "[AnimationTracker V2.4] listener error: "
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

    self.AnimationAdded = Signal.new()
    self.AnimationUpdated = Signal.new()
    self.AnimationRemoved = Signal.new()

    self.IgnoreIds = ignoreIds or {}
    self.Debug = false

    self._cachedTracks = {}
    self._lastDiagAt = 0
    self._lastDiagText = nil

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

    local now = os.clock()

    if self._lastDiagText == text
        and now - self._lastDiagAt < 2 then
        return
    end

    self._lastDiagText = text
    self._lastDiagAt = now

    print(
        "[AnimationTracker V2.4] "
        .. characterName(character)
        .. " | "
        .. tostring(text)
    )
end

function AnimationTracker:Update(character)
    local trackAddresses, reason =
        getPlayingTrackAddresses(character)

    local currentAddresses = {}
    local activeSnapshot = {}

    for i = 1, #trackAddresses do
        local address =
            trackAddresses[i]

        currentAddresses[address] = true

        local info =
            self._cachedTracks[address]

        local newlyExtracted =
            info == nil

        if not info then
            info =
                extractTrackInfo(address)

            if info then
                self._cachedTracks[address] = info
            end
        else
            local liveTime =
                readFloat(
                    address + OFF.TimePosition
                )

            if liveTime
                and liveTime >= -0.25
                and liveTime <= 120 then
                info.TimePosition = liveTime
            end

            local liveSpeed =
                readFloat(
                    address + OFF.Speed
                )

            if liveSpeed
                and liveSpeed >= -16
                and liveSpeed <= 16 then
                info.Speed = liveSpeed
            end
        end

        if info
            and not ignored(
                self.IgnoreIds,
                info.NumericAnimationId
            ) then

            if newlyExtracted then
                self.AnimationAdded:Fire(info)
            end

            self.AnimationUpdated:Fire(
                info,
                info.TimePosition
            )

            activeSnapshot[#activeSnapshot + 1] =
                info
        end
    end

    for address, cachedInfo in pairs(self._cachedTracks) do
        if not currentAddresses[address] then
            self.AnimationRemoved:Fire(cachedInfo)
            self._cachedTracks[address] = nil
        end
    end

    if #activeSnapshot > 0 then
        self:_diag(
            character,
            string.format(
                "active=%d | first=%s | t=%.4f | speed=%.3f",
                #activeSnapshot,
                tostring(activeSnapshot[1].AnimationId),
                tonumber(activeSnapshot[1].TimePosition or 0),
                tonumber(activeSnapshot[1].Speed or 1)
            )
        )
    else
        self:_diag(
            character,
            "tracks=0 | reason=" .. tostring(reason)
        )
    end

    return activeSnapshot
end

local ENV =
    (getgenv and getgenv()) or _G

ENV.AnimationTracker = AnimationTracker
_G.AnimationTracker = AnimationTracker

print(
    "[AnimationTracker V2.4] loaded "
    .. VERSION
    .. " | Active=0xB80 Animation=0xB8 AnimationId=0xC0 Time=0xD8"
)

return AnimationTracker
