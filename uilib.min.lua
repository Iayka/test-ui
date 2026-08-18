--[[
INS-compatible Matcha Drawing UI replacement
File name: uilib.min.lua
Purpose: standalone UI library for Matcha without Roblox ScreenGui/Instance.new.
Implements the subset used by the Gakuran admin/staff script:
CreateWindow, Tab, Section, Toggle, Slider, Dropdown, Label, Info,
Button, Divider, Notify, LoadConfig, SaveConfig, Get/Set/SetText/AddKeybind.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local Library = {}
Library.__index = Library
Library.Version = "Matcha-INS-Compat-1.0"

local C = {
    BG = Color3.fromRGB(8, 8, 10),
    PANEL = Color3.fromRGB(15, 15, 18),
    PANEL2 = Color3.fromRGB(23, 23, 27),
    BORDER = Color3.fromRGB(52, 52, 60),
    RED = Color3.fromRGB(220, 25, 38),
    RED_DARK = Color3.fromRGB(82, 10, 18),
    TEXT = Color3.fromRGB(245, 245, 248),
    MUTED = Color3.fromRGB(165, 165, 172),
    DIM = Color3.fromRGB(105, 105, 112),
    GREEN = Color3.fromRGB(70, 210, 120),
}

local function safe(fn, fallback)
    local ok, out = pcall(fn)
    if ok then return out end
    return fallback
end

local function mouseXY()
    return safe(function()
        return Mouse.X, Mouse.Y
    end, 0), safe(function()
        return Mouse.Y
    end, 0)
end

local function mouseDown()
    return safe(function()
        return ismouse1pressed() == true
    end, false)
end

local function keyDown(code)
    if type(iskeypressed) ~= "function" then return false end
    return safe(function()
        return iskeypressed(code) == true
    end, false)
end

local function pointIn(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function dnew(kind, props, bucket)
    local obj = Drawing.new(kind)
    for k, v in pairs(props or {}) do
        pcall(function() obj[k] = v end)
    end
    if bucket then
        table.insert(bucket, obj)
    end
    return obj
end

local function setVisible(obj, on)
    if obj then
        pcall(function() obj.Visible = on end)
    end
end

local function remove(obj)
    if obj then
        pcall(function() obj:Remove() end)
    end
end

local function setText(obj, text)
    if obj then
        pcall(function() obj.Text = tostring(text or "") end)
    end
end

local function setPos(obj, x, y)
    if obj then
        pcall(function() obj.Position = Vector2.new(x, y) end)
    end
end

local function setSize(obj, w, h)
    if obj then
        pcall(function() obj.Size = Vector2.new(w, h) end)
    end
end

local function setColor(obj, color)
    if obj then
        pcall(function() obj.Color = color end)
    end
end

local function font()
    return safe(function()
        return Drawing.Fonts.UI
    end, 0)
end

local windows = {}
local notifications = {}

local function makeText(bucket, text, size, x, y, color, z)
    return dnew("Text", {
        Text = tostring(text or ""),
        FontSize = size or 13,
        Font = font(),
        Color = color or C.TEXT,
        Position = Vector2.new(x or 0, y or 0),
        Visible = true,
        Outline = false,
        ZIndex = z or 4,
    }, bucket)
end

local function makeSquare(bucket, x, y, w, h, color, filled, z)
    return dnew("Square", {
        Position = Vector2.new(x or 0, y or 0),
        Size = Vector2.new(w or 1, h or 1),
        Color = color or C.PANEL,
        Filled = filled ~= false,
        Visible = true,
        ZIndex = z or 2,
    }, bucket)
end

local function controlBase(section, kind, name, height)
    local control = {
        Type = kind,
        Name = tostring(name or kind),
        Height = height or 30,
        Section = section,
        Draw = {},
        Visible = false,
        X = 0, Y = 0, W = 0, H = height or 30,
        Keybind = nil,
        LastKeyDown = false,
    }
    table.insert(section.Controls, control)
    return control
end

local function invoke(cb, ...)
    if type(cb) ~= "function" then return end
    local ok, err = pcall(cb, ...)
    if not ok then
        warn("[INS Compat UI] callback error: " .. tostring(err))
    end
end

local ControlMethods = {}

function ControlMethods:Get()
    return self.Value
end

function ControlMethods:Set(value)
    if self.Type == "Dropdown" then
        if type(value) == "table" then
            self.Value = value
        else
            self.Value = {value}
        end
    else
        self.Value = value
    end
    invoke(self.Callback, self.Value)
    return self
end

function ControlMethods:SetText(text)
    self.Value = tostring(text or "")
    self.Name = self.Value
    return self
end

local keyCodes = {
    space = 32,
    [" "] = 32,
    a = string.byte("A"), b = string.byte("B"), c = string.byte("C"),
    d = string.byte("D"), e = string.byte("E"), f = string.byte("F"),
    g = string.byte("G"), h = string.byte("H"), i = string.byte("I"),
    j = string.byte("J"), k = string.byte("K"), l = string.byte("L"),
    m = string.byte("M"), n = string.byte("N"), o = string.byte("O"),
    p = string.byte("P"), q = string.byte("Q"), r = string.byte("R"),
    s = string.byte("S"), t = string.byte("T"), u = string.byte("U"),
    v = string.byte("V"), w = string.byte("W"), x = string.byte("X"),
    y = string.byte("Y"), z = string.byte("Z"),
}

function ControlMethods:AddKeybind(key, mode)
    local normalized = string.lower(tostring(key or ""))
    self.Keybind = {
        Code = keyCodes[normalized],
        Mode = tostring(mode or "Toggle"),
    }
    return self
end

local SectionMethods = {}

function SectionMethods:Label(text)
    local c = controlBase(self, "Label", text, 24)
    c.Value = tostring(text or "")
    c.Draw.Text = makeText(self.Window.Objects, c.Value, 13, 0, 0, C.TEXT, 6)
    return setmetatable(c, {__index = ControlMethods})
end

function SectionMethods:Info(text)
    local c = controlBase(self, "Info", text, 40)
    c.Value = tostring(text or "")
    c.Draw.Box = makeSquare(self.Window.Objects, 0, 0, 10, 10, C.PANEL2, true, 4)
    c.Draw.Text = makeText(self.Window.Objects, c.Value, 12, 0, 0, C.MUTED, 6)
    return setmetatable(c, {__index = ControlMethods})
end

function SectionMethods:Divider(text)
    local c = controlBase(self, "Divider", text, 28)
    c.Value = tostring(text or "")
    c.Draw.Line = makeSquare(self.Window.Objects, 0, 0, 10, 1, C.RED_DARK, true, 5)
    c.Draw.Text = makeText(self.Window.Objects, c.Value, 12, 0, 0, C.RED, 6)
    return setmetatable(c, {__index = ControlMethods})
end

function SectionMethods:Button(name, callback)
    local c = controlBase(self, "Button", name, 32)
    c.Callback = callback
    c.Draw.Box = makeSquare(self.Window.Objects, 0, 0, 10, 10, C.PANEL2, true, 4)
    c.Draw.Text = makeText(self.Window.Objects, c.Name, 13, 0, 0, C.TEXT, 6)
    return setmetatable(c, {__index = ControlMethods})
end

function SectionMethods:Toggle(name, default, callback)
    if type(default) == "function" and callback == nil then
        callback = default
        default = false
    end
    local c = controlBase(self, "Toggle", name, 31)
    c.Value = default == true
    c.Callback = callback
    c.Draw.Text = makeText(self.Window.Objects, c.Name, 13, 0, 0, C.TEXT, 6)
    c.Draw.Track = makeSquare(self.Window.Objects, 0, 0, 34, 16, C.PANEL2, true, 5)
    c.Draw.Knob = makeSquare(self.Window.Objects, 0, 0, 12, 12, C.DIM, true, 6)
    return setmetatable(c, {__index = ControlMethods})
end

function SectionMethods:Slider(name, default, step, minValue, maxValue, suffix, callback)
    local c = controlBase(self, "Slider", name, 43)
    c.Value = tonumber(default) or 0
    c.Step = tonumber(step) or 1
    c.Min = tonumber(minValue) or 0
    c.Max = tonumber(maxValue) or 100
    if c.Max <= c.Min then c.Max = c.Min + 1 end
    c.Suffix = tostring(suffix or "")
    c.Callback = callback
    c.Dragging = false
    c.Draw.Text = makeText(self.Window.Objects, c.Name, 12, 0, 0, C.TEXT, 6)
    c.Draw.Value = makeText(self.Window.Objects, "", 12, 0, 0, C.MUTED, 6)
    c.Draw.Bar = makeSquare(self.Window.Objects, 0, 0, 10, 4, C.BORDER, true, 5)
    c.Draw.Fill = makeSquare(self.Window.Objects, 0, 0, 1, 4, C.RED, true, 6)
    return setmetatable(c, {__index = ControlMethods})
end

function SectionMethods:Dropdown(name, default, options, multi, callback)
    local c = controlBase(self, "Dropdown", name, 38)
    c.Options = options or {}
    c.Multi = multi == true
    c.Callback = callback
    c.Value = {}
    if default ~= nil then
        if type(default) == "table" then
            c.Value = default
        else
            c.Value = {default}
        end
    end
    c.Index = 0
    c.Draw.Text = makeText(self.Window.Objects, c.Name, 12, 0, 0, C.TEXT, 6)
    c.Draw.Box = makeSquare(self.Window.Objects, 0, 0, 10, 19, C.PANEL2, true, 4)
    c.Draw.Value = makeText(self.Window.Objects, "None", 12, 0, 0, C.MUTED, 6)
    return setmetatable(c, {__index = ControlMethods})
end

local TabMethods = {}

function TabMethods:Section(name, side)
    local s = {
        Name = tostring(name or "Section"),
        Side = tostring(side or "Left"),
        Controls = {},
        Tab = self,
        Window = self.Window,
        Draw = {},
        X = 0, Y = 0, W = 0, H = 0,
    }
    s.Draw.Box = makeSquare(self.Window.Objects, 0, 0, 10, 10, C.PANEL, true, 2)
    s.Draw.Border = makeSquare(self.Window.Objects, 0, 0, 10, 1, C.RED_DARK, true, 3)
    s.Draw.Title = makeText(self.Window.Objects, s.Name, 13, 0, 0, C.RED, 5)
    table.insert(self.Sections, s)
    return setmetatable(s, {__index = SectionMethods})
end

local WindowMethods = {}

function WindowMethods:Tab(name, icon)
    local t = {
        Name = tostring(name or "Tab"),
        Icon = icon,
        Sections = {},
        Window = self,
        Draw = {},
    }
    t.Draw.Button = makeSquare(self.Objects, 0, 0, 10, 10, C.PANEL2, true, 3)
    t.Draw.Text = makeText(self.Objects, t.Name, 13, 0, 0, C.MUTED, 6)
    table.insert(self.Tabs, t)
    if not self.ActiveTab then self.ActiveTab = t end
    return setmetatable(t, {__index = TabMethods})
end

function WindowMethods:SelectTab(tab)
    if type(tab) == "string" then
        for _, t in ipairs(self.Tabs) do
            if t.Name == tab then
                self.ActiveTab = t
                return
            end
        end
    elseif type(tab) == "table" then
        self.ActiveTab = tab
    end
end

function WindowMethods:LoadConfig(name)
    print("[INS Compat UI] LoadConfig requested: " .. tostring(name))
end

function WindowMethods:SaveConfig(name)
    print("[INS Compat UI] SaveConfig requested: " .. tostring(name))
end

function Library:CreateWindow(opts)
    opts = opts or {}
    local size = opts.size or Vector2.new(700, 580)

    local w = {
        Title = tostring(opts.title or "Window"),
        Width = safe(function() return size.X end, 700),
        Height = safe(function() return size.Y end, 580),
        X = 70,
        Y = 100,
        Objects = {},
        Tabs = {},
        ActiveTab = nil,
        Dragging = false,
        DragDX = 0,
        DragDY = 0,
        LastMouseDown = false,
        Closed = false,
    }

    w.Draw = {}
    w.Draw.Shadow = makeSquare(w.Objects, w.X + 5, w.Y + 5, w.Width, w.Height, Color3.fromRGB(0,0,0), true, 1)
    w.Draw.BG = makeSquare(w.Objects, w.X, w.Y, w.Width, w.Height, C.BG, true, 2)
    w.Draw.Header = makeSquare(w.Objects, w.X, w.Y, w.Width, 38, C.PANEL, true, 3)
    w.Draw.RedLine = makeSquare(w.Objects, w.X, w.Y + 37, w.Width, 1, C.RED, true, 5)
    w.Draw.Title = makeText(w.Objects, w.Title, 14, w.X + 12, w.Y + 12, C.TEXT, 7)
    w.Draw.Version = makeText(w.Objects, "INS Compat / Matcha Drawing", 11, w.X + 300, w.Y + 13, C.MUTED, 7)
    w.Draw.Close = makeSquare(w.Objects, w.X + w.Width - 30, w.Y + 8, 20, 20, C.RED_DARK, true, 6)
    w.Draw.CloseText = makeText(w.Objects, "X", 12, w.X + w.Width - 24, w.Y + 12, C.TEXT, 8)
    w.Draw.Sidebar = makeSquare(w.Objects, w.X + 8, w.Y + 48, 132, w.Height - 58, C.PANEL, true, 3)

    table.insert(windows, w)
    return setmetatable(w, {__index = WindowMethods})
end

function Library:Notify(title, text)
    local n = {
        Title = tostring(title or "Notice"),
        Text = tostring(text or ""),
        Created = os.clock(),
        Draw = {},
    }
    table.insert(notifications, n)
    print(string.format("[UI Notify] %s | %s", n.Title, n.Text))
end

function Library:LoadConfig(name)
    print("[INS Compat UI] LoadConfig requested: " .. tostring(name))
end

function Library:SaveConfig(name)
    print("[INS Compat UI] SaveConfig requested: " .. tostring(name))
end

local function hideControl(c)
    for _, d in pairs(c.Draw or {}) do setVisible(d, false) end
end

local function showControl(c)
    for _, d in pairs(c.Draw or {}) do setVisible(d, true) end
end

local function layoutControl(c, x, y, w)
    c.X, c.Y, c.W, c.H = x, y, w, c.Height

    if c.Type == "Label" then
        setPos(c.Draw.Text, x + 8, y + 6)
        setText(c.Draw.Text, c.Value)

    elseif c.Type == "Info" then
        setPos(c.Draw.Box, x + 4, y + 2)
        setSize(c.Draw.Box, w - 8, c.Height - 4)
        setPos(c.Draw.Text, x + 10, y + 10)
        setText(c.Draw.Text, c.Value)

    elseif c.Type == "Divider" then
        setPos(c.Draw.Text, x + 8, y + 5)
        setText(c.Draw.Text, c.Value)
        setPos(c.Draw.Line, x + 8, y + 23)
        setSize(c.Draw.Line, w - 16, 1)

    elseif c.Type == "Button" then
        setPos(c.Draw.Box, x + 5, y + 3)
        setSize(c.Draw.Box, w - 10, c.Height - 6)
        setPos(c.Draw.Text, x + 12, y + 9)

    elseif c.Type == "Toggle" then
        setPos(c.Draw.Text, x + 8, y + 8)
        setPos(c.Draw.Track, x + w - 45, y + 8)
        setColor(c.Draw.Track, c.Value and C.RED_DARK or C.PANEL2)
        setPos(c.Draw.Knob, x + w - (c.Value and 26 or 42), y + 10)
        setColor(c.Draw.Knob, c.Value and C.RED or C.DIM)

    elseif c.Type == "Slider" then
        local range = c.Max - c.Min
        local ratio = (tonumber(c.Value) - c.Min) / range
        if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
        setPos(c.Draw.Text, x + 8, y + 5)
        setPos(c.Draw.Value, x + w - 88, y + 5)
        setText(c.Draw.Value, string.format("%.3g%s", tonumber(c.Value) or 0, c.Suffix))
        setPos(c.Draw.Bar, x + 8, y + 31)
        setSize(c.Draw.Bar, w - 16, 4)
        setPos(c.Draw.Fill, x + 8, y + 31)
        setSize(c.Draw.Fill, math.max(1, (w - 16) * ratio), 4)

    elseif c.Type == "Dropdown" then
        local display = "None"
        if type(c.Value) == "table" and #c.Value > 0 then
            display = table.concat(c.Value, ", ")
        end
        setPos(c.Draw.Text, x + 8, y + 3)
        setPos(c.Draw.Box, x + 8, y + 18)
        setSize(c.Draw.Box, w - 16, 17)
        setPos(c.Draw.Value, x + 13, y + 20)
        setText(c.Draw.Value, display)
    end
end

local function layoutSection(s, x, y, w)
    local total = 34
    for _, c in ipairs(s.Controls) do
        total = total + c.Height + 3
    end
    total = total + 5

    s.X, s.Y, s.W, s.H = x, y, w, total
    setVisible(s.Draw.Box, true)
    setVisible(s.Draw.Border, true)
    setVisible(s.Draw.Title, true)
    setPos(s.Draw.Box, x, y)
    setSize(s.Draw.Box, w, total)
    setPos(s.Draw.Border, x, y)
    setSize(s.Draw.Border, w, 1)
    setPos(s.Draw.Title, x + 9, y + 9)

    local cy = y + 29
    for _, c in ipairs(s.Controls) do
        showControl(c)
        layoutControl(c, x + 4, cy, w - 8)
        cy = cy + c.Height + 3
    end
    return total
end

local function hideSection(s)
    setVisible(s.Draw.Box, false)
    setVisible(s.Draw.Border, false)
    setVisible(s.Draw.Title, false)
    for _, c in ipairs(s.Controls) do hideControl(c) end
end

local function updateKeybind(c)
    if not c.Keybind or not c.Keybind.Code then return end
    if c.Type ~= "Toggle" then return end

    local down = keyDown(c.Keybind.Code)
    local mode = string.lower(c.Keybind.Mode or "toggle")

    if mode == "hold" then
        if c.Value ~= down then
            c.Value = down
            invoke(c.Callback, c.Value)
        end
    elseif down and not c.LastKeyDown then
        c.Value = not c.Value
        invoke(c.Callback, c.Value)
    end

    c.LastKeyDown = down
end

local function interactControl(c, mx, my, pressed, down)
    if not c.Visible then return end

    updateKeybind(c)

    if c.Type == "Button" then
        if pressed and pointIn(mx, my, c.X + 5, c.Y + 3, c.W - 10, c.H - 6) then
            invoke(c.Callback)
        end

    elseif c.Type == "Toggle" then
        if pressed and pointIn(mx, my, c.X, c.Y, c.W, c.H) then
            c.Value = not c.Value
            invoke(c.Callback, c.Value, c)
        end

    elseif c.Type == "Slider" then
        local barX, barY, barW = c.X + 8, c.Y + 24, c.W - 16
        if pressed and pointIn(mx, my, barX, barY, barW, 18) then
            c.Dragging = true
        end
        if not down then c.Dragging = false end
        if c.Dragging then
            local ratio = (mx - barX) / barW
            if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
            local raw = c.Min + (c.Max - c.Min) * ratio
            local step = c.Step > 0 and c.Step or 1
            local value = math.floor((raw / step) + 0.5) * step
            if value < c.Min then value = c.Min end
            if value > c.Max then value = c.Max end
            if c.Value ~= value then
                c.Value = value
                invoke(c.Callback, c.Value)
            end
        end

    elseif c.Type == "Dropdown" then
        if pressed and pointIn(mx, my, c.X + 8, c.Y + 15, c.W - 16, 22) then
            if #c.Options > 0 then
                c.Index = c.Index + 1
                if c.Index > #c.Options then c.Index = 1 end
                c.Value = {c.Options[c.Index]}
                invoke(c.Callback, c.Value)
            end
        end
    end
end

local function updateWindow(w)
    if w.Closed then return end

    local mx, my = mouseXY()
    local down = mouseDown()
    local pressed = down and not w.LastMouseDown
    local released = (not down) and w.LastMouseDown

    if pressed and pointIn(mx, my, w.X + w.Width - 34, w.Y + 5, 29, 29) then
        w.Closed = true
        for _, o in ipairs(w.Objects) do remove(o) end
        return
    end

    if pressed and pointIn(mx, my, w.X, w.Y, w.Width - 40, 38) then
        w.Dragging = true
        w.DragDX = mx - w.X
        w.DragDY = my - w.Y
    end
    if released then w.Dragging = false end
    if w.Dragging and down then
        w.X = mx - w.DragDX
        w.Y = my - w.DragDY
    end

    setPos(w.Draw.Shadow, w.X + 5, w.Y + 5)
    setSize(w.Draw.Shadow, w.Width, w.Height)
    setPos(w.Draw.BG, w.X, w.Y)
    setSize(w.Draw.BG, w.Width, w.Height)
    setPos(w.Draw.Header, w.X, w.Y)
    setSize(w.Draw.Header, w.Width, 38)
    setPos(w.Draw.RedLine, w.X, w.Y + 37)
    setSize(w.Draw.RedLine, w.Width, 1)
    setPos(w.Draw.Title, w.X + 12, w.Y + 12)
    setPos(w.Draw.Version, w.X + math.max(220, w.Width - 270), w.Y + 13)
    setPos(w.Draw.Close, w.X + w.Width - 30, w.Y + 8)
    setPos(w.Draw.CloseText, w.X + w.Width - 24, w.Y + 12)
    setPos(w.Draw.Sidebar, w.X + 8, w.Y + 48)
    setSize(w.Draw.Sidebar, 132, w.Height - 58)

    local ty = w.Y + 58
    for _, t in ipairs(w.Tabs) do
        local active = w.ActiveTab == t
        setVisible(t.Draw.Button, true)
        setVisible(t.Draw.Text, true)
        setPos(t.Draw.Button, w.X + 15, ty)
        setSize(t.Draw.Button, 118, 30)
        setColor(t.Draw.Button, active and C.RED_DARK or C.PANEL2)
        setPos(t.Draw.Text, w.X + 25, ty + 8)
        setColor(t.Draw.Text, active and C.TEXT or C.MUTED)

        if pressed and pointIn(mx, my, w.X + 15, ty, 118, 30) then
            w.ActiveTab = t
        end
        ty = ty + 35
    end

    for _, t in ipairs(w.Tabs) do
        if t ~= w.ActiveTab then
            for _, s in ipairs(t.Sections) do hideSection(s) end
        end
    end

    local active = w.ActiveTab
    if active then
        local contentX = w.X + 150
        local contentY = w.Y + 48
        local contentW = w.Width - 160
        local gap = 10
        local colW = math.floor((contentW - gap) / 2)
        local leftY = contentY
        local rightY = contentY

        for _, s in ipairs(active.Sections) do
            local side = string.lower(s.Side)
            if side == "right" then
                local h = layoutSection(s, contentX + colW + gap, rightY, colW)
                rightY = rightY + h + 8
            else
                local h = layoutSection(s, contentX, leftY, colW)
                leftY = leftY + h + 8
            end
        end

        for _, s in ipairs(active.Sections) do
            for _, c in ipairs(s.Controls) do
                c.Visible = true
                interactControl(c, mx, my, pressed, down)
            end
        end
    end

    w.LastMouseDown = down
end

local function updateNotifications()
    local baseX = 25
    local baseY = 25

    for i = #notifications, 1, -1 do
        local n = notifications[i]
        if os.clock() - n.Created > 3.5 then
            for _, d in pairs(n.Draw) do remove(d) end
            table.remove(notifications, i)
        else
            if not n.Draw.Box then
                n.Draw.Box = makeSquare(nil, baseX, baseY, 310, 54, C.PANEL, true, 20)
                n.Draw.Line = makeSquare(nil, baseX, baseY, 3, 54, C.RED, true, 21)
                n.Draw.Title = makeText(nil, n.Title, 13, baseX + 12, baseY + 10, C.TEXT, 22)
                n.Draw.Text = makeText(nil, n.Text, 11, baseX + 12, baseY + 31, C.MUTED, 22)
            end
            local y = baseY + (i - 1) * 60
            setPos(n.Draw.Box, baseX, y)
            setPos(n.Draw.Line, baseX, y)
            setPos(n.Draw.Title, baseX + 12, y + 10)
            setPos(n.Draw.Text, baseX + 12, y + 31)
        end
    end
end

RunService.RenderStepped:Connect(function()
    for _, w in ipairs(windows) do
        pcall(updateWindow, w)
    end
    pcall(updateNotifications)
end)

INSui = Library
print("[INS Compat UI] Loaded " .. Library.Version)
return Library
