--[[
    Bracket-style UI Library v3
    Drop-in upgrade of the original library (same CreateWindow / CreateTab /
    CreateGroupbox / CreateToggle ... API), plus fixes and new features.

    Quick start:
        local Library = loadstring(...)()
        local Window = Library:CreateWindow("My Window", Color3.fromRGB(19, 119, 255))
        local Tab = Window:CreateTab("Main")
        local Group = Tab:CreateGroupbox("Settings", "Left")

        local toggle = Group:CreateToggle("Enabled", function(state) print(state) end, "enabled")
        toggle:CreateKeyBind("E")
        Group:CreateSlider("Radius", 10, 500, 120, function(v) print(v) end, { Suffix = "px", Flag = "radius" })
        Group:CreateDropdown("Mode", { "A", "B", "C" }, print, { Default = "A", Flag = "mode" })
        Group:CreateColorPicker("Color", Color3.fromRGB(255, 0, 0), print, "color")
        Group:CreateButton("Hello", function() Window:Notify("Hi", "Button clicked") end)

    Optional last argument of every element is either a flag string or an
    options table ({ Flag = "name", Default = value, ... }). Flagged elements
    are stored in Window.Flags and saved/loaded by ExportConfig/ImportConfig.

    Changes vs the original:
      * Fixed Destroy() ("Destory" typo) - now disconnects everything
      * Fixed CratePlayerList typo (old name kept as an alias) and it now works
      * Every element returns an object (CreateButton returned nothing)
      * Dragging only starts from the title bar, not anywhere on the window
      * Dropdowns / color pickers render in an overlay (no clipping by scroll
        frames), close on outside click, tab change, scroll and window drag
      * Rewritten color picker (correct saturation/value math, hue bar)
      * Sliders: decimals, suffix, touch support, drag no longer fights the window
      * Accent color updates live everywhere via Window:SetAccent()
      * Callbacks are pcall-wrapped so one error doesn't kill the UI
      * Auto-sized groupboxes, first tab auto-selected, tabs auto-resize
      * New: labels, textboxes, keybinds, separators, notifications,
        config export/import/save/load, multi-select dropdowns
]]

local Library = {}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local DEFAULT_ACCENT = Color3.fromRGB(19, 119, 255)

local C = {
    Black = Color3.fromRGB(8, 8, 8),
    Outer = Color3.fromRGB(25, 25, 25),
    Body = Color3.fromRGB(17, 17, 17),
    Bar = Color3.fromRGB(24, 24, 24),
    Group = Color3.fromRGB(24, 24, 24),
    Control = Color3.fromRGB(60, 60, 60),
    ControlHover = Color3.fromRGB(78, 78, 78),
    List = Color3.fromRGB(30, 30, 30),
    Text = Color3.fromRGB(255, 255, 255),
    SubText = Color3.fromRGB(176, 176, 176),
}

local GRADIENT = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(167, 167, 167)),
})
local FONT = Enum.Font.SourceSans

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------

local function Create(class, props, children)
    local inst = Instance.new(class)
    local parent = nil
    for k, v in pairs(props or {}) do
        if k == "Parent" then
            parent = v
        else
            inst[k] = v
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

local function Stroke(inst, color, thickness)
    return Create("UIStroke", {
        Color = color or C.Black,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = inst,
    })
end

local function Gradient(inst)
    return Create("UIGradient", { Color = GRADIENT, Rotation = 90, Parent = inst })
end

local function NewLabel(parent, text, size, props)
    local label = Create("TextLabel", {
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = size or 15,
        TextColor3 = C.Text,
        TextStrokeTransparency = 0,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1, 0, 1, 0),
    })
    for k, v in pairs(props or {}) do
        label[k] = v
    end
    label.Parent = parent
    return label
end

local function Tween(inst, props, time)
    TweenService:Create(inst, TweenInfo.new(time or 0.12), props):Play()
end

local function Safe(fn, ...)
    if type(fn) ~= "function" then
        return
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        warn("[UI Library] callback error: " .. tostring(err))
    end
end

local function Opts(o)
    if type(o) == "string" then
        return { Flag = o }
    elseif type(o) == "table" then
        return o
    end
    return {}
end

local function IsPress(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function IsMove(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
end

local function Inside(gui, pos)
    local p, s = gui.AbsolutePosition, gui.AbsoluteSize
    return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

local function GetGuiParent()
    local ok, ui = pcall(function()
        return gethui and gethui()
    end)
    if ok and ui then
        return ui
    end
    local okCore, core = pcall(function()
        return game:GetService("CoreGui")
    end)
    if okCore and core then
        local probe = Instance.new("ScreenGui")
        local writable = pcall(function()
            probe.Parent = core
        end)
        probe:Destroy()
        if writable then
            return core
        end
    end
    return Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function EncodeValue(v)
    if typeof(v) == "Color3" then
        return { _color = { v.R, v.G, v.B } }
    end
    return v
end

local function DecodeValue(v)
    if type(v) == "table" and v._color then
        return Color3.new(v._color[1], v._color[2], v._color[3])
    end
    return v
end

-- Maid: tracks connections/instances so Destroy() cleans up everything
local Maid = {}
Maid.__index = Maid

function Maid.new()
    return setmetatable({ Tasks = {} }, Maid)
end

function Maid:Give(task)
    table.insert(self.Tasks, task)
    return task
end

function Maid:Clean()
    for _, t in ipairs(self.Tasks) do
        local kind = typeof(t)
        if kind == "RBXScriptConnection" then
            t:Disconnect()
        elseif kind == "Instance" then
            t:Destroy()
        elseif kind == "function" then
            pcall(t)
        end
    end
    self.Tasks = {}
end

----------------------------------------------------------------------
-- Public helpers (kept from the original)
----------------------------------------------------------------------

function Library:GetColor(color, asTable)
    if typeof(color) ~= "Color3" then
        return DEFAULT_ACCENT
    end

    local r = math.round(color.R * 255)
    local g = math.round(color.G * 255)
    local b = math.round(color.B * 255)

    if asTable then
        return { Red = r, Green = g, Blue = b }
    end
    return Color3.fromRGB(r, g, b)
end

function Library:GetSide(leftSize, rightSize)
    if leftSize > rightSize then
        return "Right"
    end
    return "Left"
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------

function Library:CreateWindow(title, color)
    title = title or "UI Library"

    local Window = { Flags = {}, Tabs = {} }
    local maid = Maid.new()
    local elements = {}
    local accentBinds = {}
    local tabsList = {}
    local activeTab = nil
    local binding = false
    local toggleKey = Enum.KeyCode.RightControl
    local accent = Library:GetColor(color)

    local gui = Create("ScreenGui", {
        Name = title,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 100,
    })
    gui.Parent = GetGuiParent()
    Window.Gui = gui

    local function BindAccent(fn)
        table.insert(accentBinds, fn)
        fn(accent)
    end

    local function SetFlag(flag, value)
        if flag then
            Window.Flags[flag] = value
        end
    end

    local function Register(flag, get, set)
        if flag then
            elements[flag] = { Get = get, Set = set }
        end
    end

    -- Overlay layer for dropdown lists / color pickers ------------------
    local popups = Create("Frame", {
        Name = "Popups",
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        ZIndex = 50,
        Parent = gui,
    })

    local currentPopup = nil

    local function ClosePopup()
        if currentPopup then
            local p = currentPopup
            currentPopup = nil
            p.close()
        end
    end

    local function ShowPopup(popup)
        if currentPopup then
            local p = currentPopup
            currentPopup = nil
            p.close()
        end
        currentPopup = popup
    end

    maid:Give(UserInputService.InputBegan:Connect(function(input)
        if currentPopup and IsPress(input) then
            local pos = input.Position
            local inPopup = Inside(currentPopup.frame, pos)
            local inAnchor = currentPopup.anchor and Inside(currentPopup.anchor, pos)
            if not inPopup and not inAnchor then
                ClosePopup()
            end
        end
    end))

    -- Notifications ------------------------------------------------------
    local notifications = Create("Frame", {
        Name = "Notifications",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -12, 1, -12),
        Size = UDim2.fromOffset(240, 400),
        BackgroundTransparency = 1,
        ZIndex = 60,
        Parent = gui,
    })
    Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Padding = UDim.new(0, 6),
        Parent = notifications,
    })

    -- Main frame ----------------------------------------------------------
    local main = Create("Frame", {
        Name = "Main",
        BackgroundColor3 = C.Outer,
        BorderSizePixel = 0,
        Position = UDim2.new(0.5, -270, 0.5, -265),
        Size = UDim2.fromOffset(540, 530),
        Parent = gui,
    })
    Stroke(main)

    local accentLine = Create("Frame", {
        Name = "AccentLine",
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 1),
        ZIndex = 2,
        Parent = main,
    })
    BindAccent(function(c)
        accentLine.BackgroundColor3 = c
    end)

    local titleBar = Create("Frame", {
        Name = "TitleBar",
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 24),
        Parent = main,
    })
    NewLabel(titleBar, title, 18, {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -20, 1, 0),
    })

    local body = Create("Frame", {
        Name = "Body",
        BackgroundColor3 = C.Body,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(7, 24),
        Size = UDim2.new(1, -14, 1, -31),
        Parent = main,
    })
    Stroke(body)

    local tabbar = Create("Frame", {
        Name = "TabBar",
        BackgroundColor3 = C.Bar,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 25),
        Parent = body,
    })
    Create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = tabbar,
    })

    local pages = Create("Frame", {
        Name = "Pages",
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, 25),
        Size = UDim2.new(1, 0, 1, -25),
        ClipsDescendants = true,
        Parent = body,
    })

    -- Dragging (title bar only) ------------------------------------------
    local dragging, dragStart, startPos = false, nil, nil

    titleBar.InputBegan:Connect(function(input)
        if IsPress(input) then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            ClosePopup()
        end
    end)

    maid:Give(UserInputService.InputChanged:Connect(function(input)
        if dragging and IsMove(input) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))

    maid:Give(UserInputService.InputEnded:Connect(function(input)
        if IsPress(input) then
            dragging = false
        end
    end))

    -- Toggle key ----------------------------------------------------------
    maid:Give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or binding then
            return
        end
        if toggleKey and input.KeyCode == toggleKey then
            gui.Enabled = not gui.Enabled
            ClosePopup()
        end
    end))

    ------------------------------------------------------------------
    -- Keybind button factory (used by toggles and standalone keybinds)
    ------------------------------------------------------------------
    local BIND_BLACKLIST = { W = true, A = true, S = true, D = true, Slash = true, Tab = true, Space = true, Unknown = true }

    local function MakeBind(parent, default, onPress, onChange)
        local key = default or "NONE"
        local listening = false

        local button = Create("TextButton", {
            Name = "Bind",
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, 0, 0, 0),
            Size = UDim2.fromOffset(80, 16),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Font = FONT,
            TextSize = 14,
            TextColor3 = C.SubText,
            TextStrokeTransparency = 0,
            TextXAlignment = Enum.TextXAlignment.Right,
            Text = "",
            Parent = parent,
        })

        local Bind = {}

        local function Render()
            button.Text = "[ " .. (listening and "..." or key) .. " ]"
        end
        Render()

        button.MouseButton1Click:Connect(function()
            listening = true
            binding = true
            Render()
        end)

        maid:Give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if listening then
                if input.UserInputType == Enum.UserInputType.Keyboard then
                    local name = input.KeyCode.Name
                    if name == "Escape" or name == "Backspace" or name == "Delete" or BIND_BLACKLIST[name] then
                        key = "NONE"
                    else
                        key = name
                    end
                    listening = false
                    Render()
                    if onChange then
                        Safe(onChange, key)
                    end
                    task.defer(function()
                        binding = false
                    end)
                end
                return
            end

            if gameProcessed or binding or key == "NONE" then
                return
            end
            if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode.Name == key then
                Safe(onPress, key)
            end
        end))

        function Bind:Set(newKey)
            key = newKey or "NONE"
            Render()
            if onChange then
                Safe(onChange, key)
            end
        end

        function Bind:Get()
            return key
        end

        Bind.SetBind = Bind.Set
        Bind.GetBind = Bind.Get

        return Bind
    end

    ------------------------------------------------------------------
    -- Window methods
    ------------------------------------------------------------------
    function Window:SetAccent(newColor)
        accent = Library:GetColor(newColor)
        for _, fn in ipairs(accentBinds) do
            Safe(fn, accent)
        end
    end
    Window.UpdateColor = Window.SetAccent

    function Window:GetAccent()
        return accent
    end

    function Window:SetToggleKey(key)
        if typeof(key) == "string" then
            key = Enum.KeyCode[key]
        end
        toggleKey = key
    end

    -- Original API: UpdateBind(bind, custombind)
    function Window:UpdateBind(bind, custom)
        if custom then
            Window:SetToggleKey(bind)
        else
            toggleKey = Enum.KeyCode.RightControl
        end
    end

    function Window:SetVisible(state)
        gui.Enabled = state and true or false
        ClosePopup()
    end

    function Window:Toggle()
        Window:SetVisible(not gui.Enabled)
    end

    function Window:Destroy()
        ClosePopup()
        maid:Clean()
        gui:Destroy()
    end

    function Window:Notify(heading, text, duration)
        duration = duration or 4
        local card = Create("Frame", {
            BackgroundColor3 = C.Bar,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Parent = notifications,
        })
        Stroke(card, accent)
        Create("UIPadding", {
            PaddingLeft = UDim.new(0, 8),
            PaddingRight = UDim.new(0, 8),
            PaddingTop = UDim.new(0, 5),
            PaddingBottom = UDim.new(0, 5),
            Parent = card,
        })
        Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = card })
        NewLabel(card, heading or "Notification", 16, {
            Size = UDim2.new(1, 0, 0, 18),
            LayoutOrder = 1,
        })
        if text and text ~= "" then
            NewLabel(card, text, 14, {
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                TextWrapped = true,
                TextColor3 = C.SubText,
                TextYAlignment = Enum.TextYAlignment.Top,
                LayoutOrder = 2,
            })
        end
        task.delay(duration, function()
            if card and card.Parent then
                card:Destroy()
            end
        end)
    end

    -- Config -------------------------------------------------------------
    function Window:ExportConfig()
        local out = {}
        for flag, el in pairs(elements) do
            out[flag] = EncodeValue(el.Get())
        end
        return HttpService:JSONEncode(out)
    end

    function Window:ImportConfig(json)
        local ok, data = pcall(function()
            return HttpService:JSONDecode(json)
        end)
        if not ok or type(data) ~= "table" then
            return false
        end
        for flag, value in pairs(data) do
            local el = elements[flag]
            if el then
                Safe(el.Set, DecodeValue(value))
            end
        end
        return true
    end

    function Window:SaveConfig(name)
        if not writefile then
            return false
        end
        return (pcall(writefile, (name or title) .. ".json", Window:ExportConfig()))
    end

    function Window:LoadConfig(name)
        if not (readfile and isfile) then
            return false
        end
        local path = (name or title) .. ".json"
        if not isfile(path) then
            return false
        end
        return Window:ImportConfig(readfile(path))
    end

    ------------------------------------------------------------------
    -- Tabs
    ------------------------------------------------------------------
    function Window:CreateTab(name, players)
        name = name or "Tab"

        local Tab = {}
        local weights = { Left = 0, Right = 0 }

        local button = Create("TextButton", {
            Name = "Tab_" .. name,
            Text = "",
            AutoButtonColor = false,
            BackgroundColor3 = C.Bar,
            BorderSizePixel = 0,
            LayoutOrder = #tabsList + 1,
            Size = UDim2.new(1, 0, 1, 0),
            Parent = tabbar,
        })
        local tabGradient = Gradient(button)
        tabGradient.Enabled = false
        NewLabel(button, name, 18, { TextXAlignment = Enum.TextXAlignment.Center })

        local page = Create("Frame", {
            Name = "Page_" .. name,
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),
            Visible = false,
            Parent = pages,
        })

        local function MakeColumn(colName, xScale)
            local col = Create("ScrollingFrame", {
                Name = colName,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Position = UDim2.new(xScale, 0, 0, 0),
                Size = UDim2.new(0.5, 0, 1, 0),
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                TopImage = "",
                BottomImage = "",
                Parent = page,
            })
            Create("UIPadding", {
                PaddingTop = UDim.new(0, 8),
                PaddingLeft = UDim.new(0, 6),
                PaddingRight = UDim.new(0, 6),
                PaddingBottom = UDim.new(0, 8),
                Parent = col,
            })
            Create("UIListLayout", {
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 10),
                Parent = col,
            })
            col:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
                ClosePopup()
            end)
            return col
        end

        local left = MakeColumn("Left", 0)
        local right = MakeColumn("Right", 0.5)

        local function Select()
            for _, t in ipairs(tabsList) do
                t.Page.Visible = false
                t.Button.BackgroundColor3 = C.Bar
                t.Gradient.Enabled = false
            end
            ClosePopup()
            page.Visible = true
            button.BackgroundColor3 = accent
            tabGradient.Enabled = true
            activeTab = Tab
        end

        BindAccent(function(c)
            if activeTab == Tab then
                button.BackgroundColor3 = c
            end
        end)

        button.MouseButton1Click:Connect(Select)

        Tab.Button = button
        Tab.Page = page
        Tab.Gradient = tabGradient
        Tab.Select = Select

        table.insert(tabsList, Tab)
        table.insert(Window.Tabs, Tab)
        for _, t in ipairs(tabsList) do
            t.Button.Size = UDim2.new(1 / #tabsList, 0, 1, 0)
        end
        if #tabsList == 1 then
            Select()
        end

        --------------------------------------------------------------
        -- Groupbox
        --------------------------------------------------------------
        function Tab:CreateGroupbox(boxName, side)
            boxName = boxName or "Groupbox"
            if side ~= "Left" and side ~= "Right" then
                side = Library:GetSide(weights.Left, weights.Right)
            end
            weights[side] = weights[side] + 30

            local column = (side == "Right") and right or left
            local Group = {}

            local box = Create("Frame", {
                Name = boxName,
                BackgroundColor3 = C.Group,
                BorderSizePixel = 0,
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                Parent = column,
            })
            Stroke(box)
            Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = box })

            NewLabel(box, boxName, 15, {
                Size = UDim2.new(1, 0, 0, 20),
                LayoutOrder = 0,
            })

            local content = Create("Frame", {
                Name = "Content",
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                LayoutOrder = 1,
                Parent = box,
            })
            Create("UIPadding", {
                PaddingLeft = UDim.new(0, 8),
                PaddingRight = UDim.new(0, 8),
                PaddingTop = UDim.new(0, 2),
                PaddingBottom = UDim.new(0, 8),
                Parent = content,
            })
            Create("UIListLayout", {
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 6),
                Parent = content,
            })

            local function Grow(h)
                weights[side] = weights[side] + h
            end

            ----------------------------------------------------------
            -- Label
            ----------------------------------------------------------
            function Group:CreateLabel(text)
                local Label = {}
                Grow(21)
                local label = NewLabel(content, text or "Label", 15, {
                    Size = UDim2.new(1, 0, 0, 15),
                    TextWrapped = true,
                })
                function Label:SetText(t)
                    label.Text = tostring(t)
                end
                function Label:GetText()
                    return label.Text
                end
                return Label
            end

            ----------------------------------------------------------
            -- Separator
            ----------------------------------------------------------
            function Group:CreateSeparator()
                Grow(7)
                Create("Frame", {
                    BackgroundColor3 = C.Black,
                    BorderSizePixel = 0,
                    Size = UDim2.new(1, 0, 0, 1),
                    Parent = content,
                })
            end

            ----------------------------------------------------------
            -- Toggle
            ----------------------------------------------------------
            function Group:CreateToggle(toggleName, callback, options)
                toggleName = toggleName or "Toggle"
                callback = callback or function() end
                options = Opts(options)
                Grow(22)

                local Toggle = {}
                local state = false

                local row = Create("Frame", {
                    Name = "Toggle",
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 0, 16),
                    Parent = content,
                })
                local checkbox = Create("Frame", {
                    Position = UDim2.fromOffset(0, 2),
                    Size = UDim2.fromOffset(12, 12),
                    BackgroundColor3 = C.Control,
                    BorderSizePixel = 0,
                    Parent = row,
                })
                Stroke(checkbox)
                Gradient(checkbox)
                NewLabel(row, toggleName, 15, {
                    Position = UDim2.fromOffset(20, 0),
                    Size = UDim2.new(1, -20, 1, 0),
                })
                local click = Create("TextButton", {
                    BackgroundTransparency = 1,
                    Text = "",
                    Size = UDim2.fromScale(1, 1),
                    Parent = row,
                })

                local function Render()
                    checkbox.BackgroundColor3 = state and accent or C.Control
                end
                BindAccent(Render)

                local function Set(value, silent)
                    state = value and true or false
                    Render()
                    SetFlag(options.Flag, state)
                    if not silent then
                        Safe(callback, state)
                    end
                end

                click.MouseButton1Click:Connect(function()
                    Set(not state)
                end)

                function Toggle:SetState(value)
                    Set(value)
                end
                function Toggle:GetState()
                    return state
                end
                Toggle.Set = Toggle.SetState
                Toggle.Get = Toggle.GetState

                -- keyBindCallback is optional and fires in addition to the
                -- toggle callback whenever the bound key flips the toggle
                function Toggle:CreateKeyBind(default, keyBindCallback)
                    local Bind = MakeBind(row, default, function(key)
                        Set(not state)
                        if keyBindCallback then
                            Safe(keyBindCallback, key, state)
                        end
                    end)
                    return Bind
                end

                Register(options.Flag, function()
                    return state
                end, function(v)
                    Set(v)
                end)
                if options.Default ~= nil then
                    Set(options.Default)
                end

                return Toggle
            end

            ----------------------------------------------------------
            -- Slider
            ----------------------------------------------------------
            function Group:CreateSlider(sliderName, min, max, def, callback, options)
                sliderName = sliderName or "Slider"
                min = min or 0
                max = max or 100
                def = def or min
                callback = callback or function() end
                options = Opts(options)
                local decimals = options.Decimals or 0
                local suffix = options.Suffix or ""
                Grow(42)

                local Slider = {}
                local value = min
                local dragging = false

                local row = Create("Frame", {
                    Name = "Slider",
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 0, 36),
                    Parent = content,
                })
                NewLabel(row, sliderName, 15, { Size = UDim2.new(1, 0, 0, 15) })

                local track = Create("Frame", {
                    Position = UDim2.fromOffset(0, 20),
                    Size = UDim2.new(1, 0, 0, 15),
                    BackgroundColor3 = C.Control,
                    BorderSizePixel = 0,
                    Parent = row,
                })
                Stroke(track)
                Gradient(track)

                local fill = Create("Frame", {
                    Size = UDim2.fromScale(0, 1),
                    BorderSizePixel = 0,
                    Parent = track,
                })
                Gradient(fill)
                BindAccent(function(c)
                    fill.BackgroundColor3 = c
                end)

                local valueLabel = NewLabel(track, "", 14, {
                    TextXAlignment = Enum.TextXAlignment.Center,
                    ZIndex = 2,
                })

                local function Round(n)
                    local m = 10 ^ decimals
                    return math.floor(n * m + 0.5) / m
                end

                local function Set(n, silent)
                    n = Round(math.clamp(tonumber(n) or min, min, max))
                    local changed = (n ~= value)
                    value = n
                    local alpha = (max == min) and 0 or (n - min) / (max - min)
                    fill.Size = UDim2.fromScale(alpha, 1)
                    valueLabel.Text = tostring(n) .. suffix
                    SetFlag(options.Flag, n)
                    if changed and not silent then
                        Safe(callback, n)
                    end
                end

                local function FromInput(input)
                    local alpha = math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
                    Set(min + (max - min) * alpha)
                end

                track.InputBegan:Connect(function(input)
                    if IsPress(input) then
                        dragging = true
                        ClosePopup()
                        FromInput(input)
                    end
                end)
                maid:Give(UserInputService.InputChanged:Connect(function(input)
                    if dragging and IsMove(input) then
                        FromInput(input)
                    end
                end))
                maid:Give(UserInputService.InputEnded:Connect(function(input)
                    if IsPress(input) then
                        dragging = false
                    end
                end))

                function Slider:SetValue(n)
                    Set(n)
                end
                function Slider:GetValue()
                    return value
                end
                Slider.Set = Slider.SetValue
                Slider.Get = Slider.GetValue

                Register(options.Flag, function()
                    return value
                end, function(v)
                    Set(v)
                end)

                Set(def, true)
                Safe(callback, value)
                return Slider
            end

            ----------------------------------------------------------
            -- Dropdown
            ----------------------------------------------------------
            function Group:CreateDropdown(dropName, list, callback, options)
                dropName = dropName or "Dropdown"
                list = list or {}
                callback = callback or function() end
                options = Opts(options)
                local multi = options.Multi and true or false
                Grow(46)

                local Dropdown = {}
                local selected = multi and {} or nil
                local items = {}

                local row = Create("Frame", {
                    Name = "Dropdown",
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 0, 40),
                    Parent = content,
                })
                NewLabel(row, dropName, 15, { Size = UDim2.new(1, 0, 0, 15) })

                local combo = Create("TextButton", {
                    Position = UDim2.fromOffset(0, 20),
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundColor3 = C.Control,
                    BorderSizePixel = 0,
                    AutoButtonColor = false,
                    Text = "",
                    Parent = row,
                })
                Stroke(combo)
                Gradient(combo)
                local comboText = NewLabel(combo, "...", 15, {
                    Position = UDim2.fromOffset(8, 0),
                    Size = UDim2.new(1, -24, 1, 0),
                    TextTruncate = Enum.TextTruncate.AtEnd,
                })
                NewLabel(combo, "v", 14, {
                    AnchorPoint = Vector2.new(1, 0),
                    Position = UDim2.new(1, -6, 0, 0),
                    Size = UDim2.fromOffset(12, 20),
                    TextColor3 = C.SubText,
                    TextXAlignment = Enum.TextXAlignment.Center,
                })

                local listFrame = Create("ScrollingFrame", {
                    Name = "DropdownList",
                    Visible = false,
                    BackgroundColor3 = C.List,
                    BorderSizePixel = 0,
                    ScrollBarThickness = 3,
                    CanvasSize = UDim2.new(),
                    AutomaticCanvasSize = Enum.AutomaticSize.Y,
                    TopImage = "",
                    BottomImage = "",
                    Parent = popups,
                })
                Stroke(listFrame)
                Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = listFrame })

                local function IsSelected(opt)
                    if multi then
                        return selected[opt] == true
                    end
                    return selected == opt
                end

                local function Display()
                    if multi then
                        local names = {}
                        for _, opt in ipairs(list) do
                            if selected[opt] then
                                table.insert(names, tostring(opt))
                            end
                        end
                        comboText.Text = (#names > 0) and table.concat(names, ", ") or "..."
                    else
                        comboText.Text = (selected ~= nil) and tostring(selected) or "..."
                    end
                end

                local function Refresh()
                    for _, it in ipairs(items) do
                        if IsSelected(it.Value) then
                            it.Button.BackgroundColor3 = accent
                        else
                            it.Button.BackgroundColor3 = C.List
                        end
                    end
                    Display()
                end
                BindAccent(Refresh)

                local function Emit()
                    if multi then
                        local out = {}
                        for _, opt in ipairs(list) do
                            if selected[opt] then
                                table.insert(out, opt)
                            end
                        end
                        SetFlag(options.Flag, out)
                        Safe(callback, out)
                    else
                        SetFlag(options.Flag, selected)
                        Safe(callback, selected)
                    end
                end

                local function Pick(opt)
                    if multi then
                        selected[opt] = not selected[opt] or nil
                    else
                        selected = opt
                    end
                    Refresh()
                    Emit()
                    if not multi then
                        ClosePopup()
                    end
                end

                local function Rebuild()
                    for _, it in ipairs(items) do
                        it.Button:Destroy()
                    end
                    items = {}
                    for i, opt in ipairs(list) do
                        local b = Create("TextButton", {
                            Size = UDim2.new(1, 0, 0, 19),
                            BackgroundColor3 = C.List,
                            BorderSizePixel = 0,
                            AutoButtonColor = false,
                            Text = tostring(opt),
                            Font = FONT,
                            TextSize = 14,
                            TextColor3 = C.Text,
                            TextStrokeTransparency = 0,
                            LayoutOrder = i,
                            Parent = listFrame,
                        })
                        b.MouseButton1Click:Connect(function()
                            Pick(opt)
                        end)
                        items[i] = { Button = b, Value = opt }
                    end
                    Refresh()
                end

                local function Close()
                    listFrame.Visible = false
                end

                combo.MouseButton1Click:Connect(function()
                    if listFrame.Visible then
                        ClosePopup()
                        return
                    end
                    local pos = combo.AbsolutePosition
                    local height = math.min(#list * 19, 152)
                    listFrame.Position = UDim2.fromOffset(pos.X, pos.Y + combo.AbsoluteSize.Y + 1)
                    listFrame.Size = UDim2.fromOffset(combo.AbsoluteSize.X, math.max(height, 19))
                    listFrame.Visible = true
                    ShowPopup({ frame = listFrame, anchor = combo, close = Close })
                end)

                function Dropdown:SetOption(opt, silent)
                    if multi then
                        selected = {}
                        if type(opt) == "table" then
                            for _, o in ipairs(opt) do
                                selected[o] = true
                            end
                        elseif opt ~= nil then
                            selected[opt] = true
                        end
                    else
                        selected = (opt == nil) and list[1] or opt
                    end
                    Refresh()
                    if not silent then
                        Emit()
                    end
                end

                function Dropdown:GetOption()
                    if multi then
                        local out = {}
                        for _, opt in ipairs(list) do
                            if selected[opt] then
                                table.insert(out, opt)
                            end
                        end
                        return out
                    end
                    return selected
                end

                function Dropdown:SetOptions(newList)
                    list = newList or {}
                    if multi then
                        local kept = {}
                        for _, opt in ipairs(list) do
                            if selected[opt] then
                                kept[opt] = true
                            end
                        end
                        selected = kept
                    elseif selected ~= nil and not table.find(list, selected) then
                        selected = nil
                    end
                    Rebuild()
                end
                Dropdown.Refresh = Dropdown.SetOptions

                Dropdown.Set = Dropdown.SetOption
                Dropdown.Get = Dropdown.GetOption

                Register(options.Flag, function()
                    return Dropdown:GetOption()
                end, function(v)
                    Dropdown:SetOption(v)
                end)

                Rebuild()
                if options.Default ~= nil then
                    Dropdown:SetOption(options.Default)
                end

                return Dropdown
            end

            ----------------------------------------------------------
            -- Button
            ----------------------------------------------------------
            function Group:CreateButton(buttonName, callback)
                buttonName = buttonName or "Button"
                callback = callback or function() end
                Grow(26)

                local Button = {}

                local btn = Create("TextButton", {
                    Name = "Button",
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundColor3 = C.Control,
                    BorderSizePixel = 0,
                    AutoButtonColor = false,
                    Text = "",
                    Parent = content,
                })
                Stroke(btn)
                Gradient(btn)
                local label = NewLabel(btn, buttonName, 15, { TextXAlignment = Enum.TextXAlignment.Center })

                btn.MouseEnter:Connect(function()
                    Tween(btn, { BackgroundColor3 = C.ControlHover })
                end)
                btn.MouseLeave:Connect(function()
                    Tween(btn, { BackgroundColor3 = C.Control })
                end)
                btn.MouseButton1Click:Connect(function()
                    Safe(callback)
                end)

                function Button:SetText(t)
                    label.Text = tostring(t)
                end
                function Button:Fire()
                    Safe(callback)
                end

                return Button
            end

            ----------------------------------------------------------
            -- TextBox
            ----------------------------------------------------------
            function Group:CreateTextBox(boxLabel, placeholder, callback, options)
                boxLabel = boxLabel or "TextBox"
                callback = callback or function() end
                options = Opts(options)
                Grow(46)

                local TextBox = {}
                local text = ""

                local row = Create("Frame", {
                    Name = "TextBox",
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 0, 40),
                    Parent = content,
                })
                NewLabel(row, boxLabel, 15, { Size = UDim2.new(1, 0, 0, 15) })

                local input = Create("TextBox", {
                    Position = UDim2.fromOffset(0, 20),
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundColor3 = C.Control,
                    BorderSizePixel = 0,
                    ClearTextOnFocus = false,
                    Font = FONT,
                    TextSize = 15,
                    Text = "",
                    PlaceholderText = placeholder or "",
                    PlaceholderColor3 = C.SubText,
                    TextColor3 = C.Text,
                    TextStrokeTransparency = 0,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    Parent = row,
                })
                Stroke(input)
                Gradient(input)
                Create("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = input })

                local function Set(t, silent, enterPressed)
                    text = tostring(t or "")
                    input.Text = text
                    SetFlag(options.Flag, text)
                    if not silent then
                        Safe(callback, text, enterPressed)
                    end
                end

                input.FocusLost:Connect(function(enterPressed)
                    Set(input.Text, false, enterPressed)
                end)

                function TextBox:SetText(t)
                    Set(t)
                end
                function TextBox:GetText()
                    return text
                end
                TextBox.Set = TextBox.SetText
                TextBox.Get = TextBox.GetText

                Register(options.Flag, function()
                    return text
                end, function(v)
                    Set(v)
                end)
                if options.Default ~= nil then
                    Set(options.Default, true)
                end

                return TextBox
            end

            ----------------------------------------------------------
            -- Standalone Keybind
            ----------------------------------------------------------
            function Group:CreateKeybind(bindName, default, callback, options)
                bindName = bindName or "Keybind"
                callback = callback or function() end
                options = Opts(options)
                Grow(22)

                local row = Create("Frame", {
                    Name = "Keybind",
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 0, 16),
                    Parent = content,
                })
                NewLabel(row, bindName, 15, { Size = UDim2.new(1, -90, 1, 0) })

                local Bind = MakeBind(row, default, function(key)
                    Safe(callback, key)
                end, function(key)
                    SetFlag(options.Flag, key)
                end)
                SetFlag(options.Flag, Bind:Get())

                Register(options.Flag, function()
                    return Bind:Get()
                end, function(v)
                    Bind:Set(v)
                end)

                return Bind
            end

            ----------------------------------------------------------
            -- ColorPicker
            ----------------------------------------------------------
            function Group:CreateColorPicker(pickerName, def, callback, options)
                pickerName = pickerName or "Color"
                callback = callback or function() end
                options = Opts(options)
                if typeof(def) ~= "Color3" then
                    def = Color3.fromRGB(255, 255, 255)
                end
                Grow(25)

                local ColorTypes = {}
                local h, s, v = Color3.toHSV(def)
                local currentColor = def

                local row = Create("Frame", {
                    Name = "ColorPicker",
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 0, 19),
                    Parent = content,
                })
                local swatch = Create("Frame", {
                    Size = UDim2.fromOffset(19, 19),
                    BackgroundColor3 = def,
                    BorderSizePixel = 0,
                    Parent = row,
                })
                Stroke(swatch)
                NewLabel(row, pickerName, 15, {
                    Position = UDim2.fromOffset(27, 0),
                    Size = UDim2.new(1, -27, 1, 0),
                })
                local click = Create("TextButton", {
                    BackgroundTransparency = 1,
                    Text = "",
                    Size = UDim2.fromScale(1, 1),
                    Parent = row,
                })

                local frame = Create("Frame", {
                    Name = "ColorPickerPopup",
                    Visible = false,
                    BackgroundColor3 = C.Outer,
                    BorderSizePixel = 0,
                    Size = UDim2.fromOffset(178, 152),
                    Parent = popups,
                })
                Stroke(frame)

                local sv = Create("ImageLabel", {
                    Position = UDim2.fromOffset(12, 12),
                    Size = UDim2.fromOffset(154, 104),
                    BackgroundColor3 = Color3.fromHSV(h, 1, 1),
                    BorderSizePixel = 0,
                    Image = "rbxassetid://4155801252",
                    Parent = frame,
                })
                Stroke(sv)
                local cursor = Create("Frame", {
                    AnchorPoint = Vector2.new(0.5, 0.5),
                    Size = UDim2.fromOffset(6, 6),
                    BackgroundColor3 = C.Text,
                    BorderSizePixel = 0,
                    ZIndex = 3,
                    Parent = sv,
                })
                Stroke(cursor)

                local hueBar = Create("Frame", {
                    Position = UDim2.fromOffset(12, 126),
                    Size = UDim2.fromOffset(154, 14),
                    BackgroundColor3 = C.Text,
                    BorderSizePixel = 0,
                    Parent = frame,
                })
                Stroke(hueBar)
                Create("UIGradient", {
                    Color = ColorSequence.new({
                        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
                        ColorSequenceKeypoint.new(1 / 6, Color3.fromRGB(255, 255, 0)),
                        ColorSequenceKeypoint.new(2 / 6, Color3.fromRGB(0, 255, 0)),
                        ColorSequenceKeypoint.new(3 / 6, Color3.fromRGB(0, 255, 255)),
                        ColorSequenceKeypoint.new(4 / 6, Color3.fromRGB(0, 0, 255)),
                        ColorSequenceKeypoint.new(5 / 6, Color3.fromRGB(255, 0, 255)),
                        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
                    }),
                    Parent = hueBar,
                })
                local hueMarker = Create("Frame", {
                    AnchorPoint = Vector2.new(0.5, 0),
                    Size = UDim2.new(0, 2, 1, 0),
                    BackgroundColor3 = C.Text,
                    BorderSizePixel = 0,
                    ZIndex = 3,
                    Parent = hueBar,
                })
                Stroke(hueMarker)

                local function Render()
                    currentColor = Color3.fromHSV(h, s, v)
                    swatch.BackgroundColor3 = currentColor
                    sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
                    cursor.Position = UDim2.fromScale(s, 1 - v)
                    hueMarker.Position = UDim2.fromScale(h, 0)
                end

                local function Commit(silent)
                    Render()
                    SetFlag(options.Flag, currentColor)
                    if not silent then
                        Safe(callback, currentColor)
                    end
                end

                local mode = nil

                local function Update(input)
                    if mode == "sv" then
                        s = math.clamp((input.Position.X - sv.AbsolutePosition.X) / sv.AbsoluteSize.X, 0, 1)
                        v = 1 - math.clamp((input.Position.Y - sv.AbsolutePosition.Y) / sv.AbsoluteSize.Y, 0, 1)
                    elseif mode == "hue" then
                        h = math.clamp((input.Position.X - hueBar.AbsolutePosition.X) / hueBar.AbsoluteSize.X, 0, 1)
                    else
                        return
                    end
                    Commit()
                end

                sv.InputBegan:Connect(function(input)
                    if IsPress(input) then
                        mode = "sv"
                        Update(input)
                    end
                end)
                hueBar.InputBegan:Connect(function(input)
                    if IsPress(input) then
                        mode = "hue"
                        Update(input)
                    end
                end)
                maid:Give(UserInputService.InputChanged:Connect(function(input)
                    if mode and IsMove(input) then
                        Update(input)
                    end
                end))
                maid:Give(UserInputService.InputEnded:Connect(function(input)
                    if IsPress(input) then
                        mode = nil
                    end
                end))

                local function Close()
                    frame.Visible = false
                    mode = nil
                end

                click.MouseButton1Click:Connect(function()
                    if frame.Visible then
                        ClosePopup()
                        return
                    end
                    local pos = swatch.AbsolutePosition
                    local viewport = workspace.CurrentCamera.ViewportSize
                    frame.Position = UDim2.fromOffset(
                        math.clamp(pos.X, 0, math.max(viewport.X - 180, 0)),
                        math.clamp(pos.Y + 23, 0, math.max(viewport.Y - 154, 0))
                    )
                    frame.Visible = true
                    ShowPopup({ frame = frame, anchor = row, close = Close })
                end)

                function ColorTypes:SetColor(newColor, silent)
                    if typeof(newColor) ~= "Color3" then
                        newColor = Color3.fromRGB(255, 255, 255)
                    end
                    h, s, v = Color3.toHSV(newColor)
                    Commit(silent)
                end
                function ColorTypes:GetColor()
                    return currentColor
                end
                ColorTypes.Set = ColorTypes.SetColor
                ColorTypes.Get = ColorTypes.GetColor

                Register(options.Flag, function()
                    return currentColor
                end, function(c)
                    ColorTypes:SetColor(c)
                end)

                Render()
                SetFlag(options.Flag, currentColor)
                Safe(callback, currentColor)
                return ColorTypes
            end

            return Group
        end

        --------------------------------------------------------------
        -- Player list
        --------------------------------------------------------------
        function Tab:CreatePlayerList(showButtons, events)
            events = events or {}
            local PlayerList = {}
            left.Visible = false
            right.Visible = false

            local box = Create("Frame", {
                Position = UDim2.fromOffset(6, 10),
                Size = UDim2.new(1, -12, 1, -16),
                BackgroundColor3 = C.Group,
                BorderSizePixel = 0,
                Parent = page,
            })
            Stroke(box)
            NewLabel(box, "Player List", 15, {
                Position = UDim2.fromOffset(8, 0),
                Size = UDim2.new(1, -16, 0, 18),
            })

            local scroll = Create("ScrollingFrame", {
                Position = UDim2.fromOffset(6, 22),
                Size = UDim2.new(1, -12, 1, -28),
                BackgroundColor3 = Color3.fromRGB(16, 16, 16),
                BorderSizePixel = 0,
                ScrollBarThickness = 3,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                TopImage = "",
                BottomImage = "",
                Parent = box,
            })
            Stroke(scroll)
            Create("UIListLayout", {
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 2),
                Parent = scroll,
            })

            local cards = {}

            local function Add(plr)
                if plr == Players.LocalPlayer or cards[plr.UserId] then
                    return
                end

                local card = Create("Frame", {
                    Name = "playercard",
                    Size = UDim2.new(1, 0, 0, showButtons and 60 or 38),
                    BackgroundColor3 = C.Control,
                    BorderSizePixel = 0,
                    Parent = scroll,
                })
                Gradient(card)

                local pfp = Create("ImageLabel", {
                    Position = UDim2.fromOffset(5, 5),
                    Size = UDim2.fromOffset(28, 28),
                    BackgroundTransparency = 1,
                    Parent = card,
                })
                if showButtons then
                    pfp.Size = UDim2.fromOffset(48, 48)
                end
                task.spawn(function()
                    local ok, img = pcall(function()
                        return Players:GetUserThumbnailAsync(plr.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
                    end)
                    if ok and pfp.Parent then
                        pfp.Image = img
                    end
                end)

                local xOffset = showButtons and 60 or 38
                NewLabel(card, "Username: " .. plr.Name .. " | UserId: " .. plr.UserId .. " | Membership: " .. plr.MembershipType.Name, 15, {
                    Position = UDim2.fromOffset(xOffset, 6),
                    Size = UDim2.new(1, -(xOffset + 6), 0, 18),
                    TextColor3 = plr.TeamColor.Color,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                })

                if showButtons then
                    local btnRow = Create("Frame", {
                        Position = UDim2.fromOffset(60, 33),
                        Size = UDim2.new(1, -66, 0, 20),
                        BackgroundTransparency = 1,
                        Parent = card,
                    })
                    Create("UIListLayout", {
                        FillDirection = Enum.FillDirection.Horizontal,
                        Padding = UDim.new(0, 4),
                        Parent = btnRow,
                    })
                    local defs = {
                        { "Whitelist", "onwhitelist" },
                        { "Blacklist", "onblacklist" },
                        { "Prioritize", "onprioritize" },
                        { "Unprioritize", "onunprioritize" },
                    }
                    for _, d in ipairs(defs) do
                        local b = Create("TextButton", {
                            Size = UDim2.fromOffset(100, 20),
                            BackgroundColor3 = C.Control,
                            BorderSizePixel = 0,
                            AutoButtonColor = false,
                            Text = "",
                            Parent = btnRow,
                        })
                        Stroke(b)
                        Gradient(b)
                        NewLabel(b, d[1], 14, { TextXAlignment = Enum.TextXAlignment.Center })
                        b.MouseButton1Click:Connect(function()
                            Safe(events[d[2]], plr.UserId, plr)
                        end)
                    end
                end

                cards[plr.UserId] = card
            end

            local function Remove(plr)
                local card = cards[plr.UserId]
                if card then
                    card:Destroy()
                    cards[plr.UserId] = nil
                end
            end

            for _, plr in ipairs(Players:GetPlayers()) do
                Add(plr)
            end
            maid:Give(Players.PlayerAdded:Connect(Add))
            maid:Give(Players.PlayerRemoving:Connect(Remove))

            function PlayerList:Refresh()
                for _, plr in ipairs(Players:GetPlayers()) do
                    Add(plr)
                end
            end

            return PlayerList
        end
        Tab.CratePlayerList = Tab.CreatePlayerList -- old misspelled name

        return Tab
    end

    return Window, gui
end

return Library
