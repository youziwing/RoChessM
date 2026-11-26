
local FLIP_BOARD = false
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local HttpService = game:GetService("HttpService")
local ROCHESS_SESSION = tostring(tick()) .. ":" .. tostring(math.random(1, 1000000000))
_G.__ROCHESS_SESSION = ROCHESS_SESSION
local DEVICE_ID = "anonymous"
pcall(function() DEVICE_ID = tostring(gethwid()) end)
if DEVICE_ID == "" or DEVICE_ID == "nil" then DEVICE_ID = "anonymous" end
local SCAN_DELAY = 0.08
local SETTLE_DELAY = 0.025
local SETTLE_STABLE_SCANS = 2
local API_URL = "https://rochess-gateway-seven.vercel.app/api/analyze"
local STATUS_URL = "https://rochess-gateway-seven.vercel.app/api/health"
local STATUS_INTERVAL = 10
local API_KEY = ""
local ANALYSIS_DEPTH = 10
local STRENGTH = "high"
local PLAY_STYLE = "standard"
local ENGINE = "stockfish"
local SECOND_MOVE_ENABLED = true
local TARGET_ELO = nil
local OPENING_NAME = "Automatic"
local openingActive = false
local moveHistory = {}
local positionCounts = {}
local lastPlayedUci = nil
local lastRepetitionWarningKey = nil
local lastRepetitionWarningCount = 0
local openingRefreshRequested = false
local openingLines = {
    ["Italian Game"] = {"e2e4", "e7e5", "g1f3", "b8c6", "f1c4"},
    ["Sicilian Defense"] = {"e2e4", "c7c5", "g1f3", "d7d6"},
    ["French Defense"] = {"e2e4", "e7e6", "d2d4", "d7d5"},
    ["Caro-Kann Defense"] = {"e2e4", "c7c6", "d2d4", "d7d5"},
    ["Alien Gambit"] = {"e2e4", "c7c6", "d2d4", "d7d5", "b1c3", "d5e4", "c3e4", "g8f6", "e4g5", "h7h6", "g5f7", "e8f7", "g1f3"},
    ["Queen's Gambit"] = {"ad2d4", "d7d5", "c2c4"},
    ["King's Indian Defense"] = {"d2d4", "g8f6", "c2c4", "g7g6"},
    ["English Opening"] = {"c2c4", "e7e5", "b1c3", "g8f6"},
}
local PLAY_AS = "White" -- "White" or "Black"
-- Auto-detect is the startup behavior; the UI intentionally exposes only
-- White and Black. Changing the combo switches to a manual override.
local AUTO_DETECT_COLOR = true
local lastPlayAsSelection = nil
local boardCenters = {}
local boardSquareObjects = {}
local arrows = {}
local applyPlayAs
local pendingFen = nil
local enteredFen = ""
local importStatus = "Waiting for a FEN position"
local newGameRequested = false
local promotionNames = {q="Queen", r="Rook", b="Bishop", n="Knight"}
local lastStatusCheck = 0
local lastAnnouncement = nil
local castlingRights = "KQkq"
local enPassantTarget = "-"
local pieceTypes = {}
local CUSTOM_UI_CHOICE_FILE = "rochess_ui_choice.json"
local useCustomUI = false
local customUI = nil
local CALIBRATION_FILE = "rochess_calibration.json"
local calibrationSignature = nil
local calibrationSaved = false
local calibrationOffsetX = 0
local calibrationOffsetY = 0
local calibrationSquareScale = 1
local calibrationActive = true
local calibrationConfirm = false
local calibrationPoints = {}
local calibrationDrawings = {}
pcall(function()
    if isfile(CALIBRATION_FILE) then
        local saved = HttpService:JSONDecode(readfile(CALIBRATION_FILE))
        calibrationOffsetX = tonumber(saved.offsetX) or 0
        calibrationOffsetY = tonumber(saved.offsetY) or 0
        calibrationActive = tonumber(saved.version) ~= 4
        calibrationSquareScale = tonumber(saved.squareScale) or 1
    end
end)

local function removeArrow()
    for _, arrow in ipairs(arrows) do
        arrow.Line:Remove()
        arrow.Head:Remove()
        if arrow.Label then arrow.Label:Remove() end
    end
    arrows = {}
end

local function showArrow(fromSquare, toSquare, color, labelText)
    local function liveCenter(name)
        local square = boardSquareObjects[name]
        if square then
            local ok, position, size = pcall(function()
                return square.AbsolutePosition, square.AbsoluteSize
            end)
            if ok and position and size and size.X >= 2 and size.Y >= 2 then
                return Vector2.new(position.X + size.X / 2, position.Y + size.Y / 2)
            end
        end
        return boardCenters[name]
    end
    local function adjusted(point)
        if not point then return nil end
        return Vector2.new(point.X + calibrationOffsetX, point.Y + calibrationOffsetY)
    end
    local fromPoint, toPoint = adjusted(liveCenter(fromSquare)), adjusted(liveCenter(toSquare))
    if not fromPoint or not toPoint or not Drawing then return end
    local dx, dy = toPoint.X - fromPoint.X, toPoint.Y - fromPoint.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then return end
    local ux, uy = dx / length, dy / length
    local px, py = -uy, ux
    local tip = toPoint
    local left = Vector2.new(toPoint.X - ux * 18 + px * 9, toPoint.Y - uy * 18 + py * 9)
    local right = Vector2.new(toPoint.X - ux * 18 - px * 9, toPoint.Y - uy * 18 - py * 9)
    local arrowLine = Drawing.new("Line")
    arrowLine.From = fromPoint
    arrowLine.To = Vector2.new(toPoint.X - ux * 8, toPoint.Y - uy * 8)
    arrowLine.Color = color
    arrowLine.Thickness = 4
    pcall(function() arrowLine.ZIndex = 900 end)
    arrowLine.Visible = true
    local arrowHead = Drawing.new("Triangle")
    arrowHead.PointA, arrowHead.PointB, arrowHead.PointC = tip, left, right
    arrowHead.Color = color
    arrowHead.Filled = true
    pcall(function() arrowHead.ZIndex = 901 end)
    arrowHead.Visible = true
    local label
    if labelText and labelText ~= "" then
        label = Drawing.new("Text")
        label.Text = labelText
        label.Position = Vector2.new(toPoint.X, toPoint.Y + 22)
        label.Size = 18
        label.Center = true
        label.Outline = true
        label.Color = Color3.fromRGB(255, 245, 80)
        pcall(function() label.Font = 2 end)
        pcall(function() label.ZIndex = 100 end)
        label.Visible = true
    end
    arrows[#arrows + 1] = {Line = arrowLine, Head = arrowHead, Label = label}
end

local function saveCalibration(signature)
    if calibrationSaved and calibrationSignature == signature then return end
    calibrationSignature = signature
    calibrationSaved = true
    pcall(function()
        writefile(CALIBRATION_FILE, HttpService:JSONEncode({
            signature=signature,
            version=4,
            offsetX=calibrationOffsetX,
            offsetY=calibrationOffsetY,
            squareScale=calibrationSquareScale,
        }))
    end)
    pcall(function()
        notify("RoChess", "Board alignment calibrated", 3)
    end)
end

local function clearCalibrationDrawings()
    for _, drawing in ipairs(calibrationDrawings) do pcall(function() drawing:Remove() end) end
    calibrationDrawings = {}
end

local function beginVisualCalibration()
    calibrationActive = true
    calibrationConfirm = false
    calibrationPoints = {}
    clearCalibrationDrawings()
    removeArrow()
    print("[Chess Detect] Drag the four calibration endpoints, then press Save visual calibration")
end

local function updateVisualCalibration()
    if not calibrationActive then return end
    local function center(square)
        local p = boardCenters[square]
        return p and Vector2.new(p.X + calibrationOffsetX, p.Y + calibrationOffsetY)
    end
    local definitions = {
        {from="e2", to="e4", color=Color3.fromRGB(40,220,80)},
        {from="g1", to="f3", color=Color3.fromRGB(70,140,255)},
    }
    for i, d in ipairs(definitions) do
        calibrationPoints[i] = calibrationPoints[i] or {from=center(d.from), to=center(d.to), held=nil}
        local point = calibrationPoints[i]
        local mouse = player:GetMouse()
        local mx, my = tonumber(mouse and mouse.X), tonumber(mouse and mouse.Y)
        if mx and my and ismouse1pressed() then
            if not point.held then
                local function near(p) return p and math.abs(p.X-mx) < 28 and math.abs(p.Y-my) < 28 end
                if near(point.from) then point.held = "from" elseif near(point.to) then point.held = "to" end
            end
            if point.held == "from" then point.from = Vector2.new(mx,my) end
            if point.held == "to" then point.to = Vector2.new(mx,my) end
        else
            point.held = nil
        end
        local line = calibrationDrawings[(i-1)*3+1]
        local head = calibrationDrawings[(i-1)*3+2]
        local text = calibrationDrawings[(i-1)*3+3]
        if not line then
            line, head, text = Drawing.new("Line"), Drawing.new("Triangle"), Drawing.new("Text")
            calibrationDrawings[(i-1)*3+1], calibrationDrawings[(i-1)*3+2], calibrationDrawings[(i-1)*3+3] = line, head, text
        end
        local dx, dy = point.to.X-point.from.X, point.to.Y-point.from.Y
        local length = math.max(1, math.sqrt(dx*dx+dy*dy)); local ux, uy = dx/length, dy/length; local px, py = -uy, ux
        line.From, line.To, line.Color, line.Thickness, line.Visible = point.from, Vector2.new(point.to.X-ux*8,point.to.Y-uy*8), d.color, 4, true
        head.PointA, head.PointB, head.PointC, head.Color, head.Filled, head.Visible = point.to, Vector2.new(point.to.X-ux*18+px*9,point.to.Y-uy*18+py*9), Vector2.new(point.to.X-ux*18-px*9,point.to.Y-uy*18-py*9), d.color, true, true
        text.Text, text.Position, text.Size, text.Center, text.Outline, text.Visible = i == 1 and "DRAG TO E2-E4" or "DRAG TO G1-F3", Vector2.new(point.to.X,point.to.Y+22), 16, true, true, true
    end
    if calibrationConfirm then
        local dx, dy, count = 0, 0, 0
        for i, d in ipairs(definitions) do
            local baseFrom, baseTo = boardCenters[d.from], boardCenters[d.to]
            local point = calibrationPoints[i]
            if baseFrom and baseTo and point then
                dx = dx + ((point.from.X-baseFrom.X)+(point.to.X-baseTo.X))/2
                dy = dy + ((point.from.Y-baseFrom.Y)+(point.to.Y-baseTo.Y))/2
                count = count + 1
            end
        end
        if count > 0 then calibrationOffsetX, calibrationOffsetY = dx/count, dy/count end
        calibrationSaved, calibrationSignature, calibrationConfirm = false, nil, false
        saveCalibration("manual")
        calibrationActive = false
        clearCalibrationDrawings()
        print(string.format("[Chess Detect] Visual calibration saved: X=%.1f Y=%.1f", calibrationOffsetX, calibrationOffsetY))
    end
end

local RoChessUI
local function setupInterfaceChoice()
    local savedChoice
    pcall(function()
        if isfile(CUSTOM_UI_CHOICE_FILE) then
            local saved = HttpService:JSONDecode(readfile(CUSTOM_UI_CHOICE_FILE))
            savedChoice = saved and saved.choice
        end
    end)
    if savedChoice == "matcha" then
        useCustomUI = false
        return false
    end
    local ok, jdui = pcall(function()
        local source = httpget("https://raw.githubusercontent.com/jdev-studio/jdui/refs/heads/main/JDUI")
        -- Matcha can stall when JDUI pre-scans every keyboard code on textbox focus.
        -- Text capture still receives newly pressed keys without this pre-scan.
        source = source:gsub('for k=8,254 do capture%.keys%[k%]=iskeypressed%(k%) end', '')
        source = source:gsub('for k=8,254 do cap%.keys%[k%]=iskeypressed%(k%) end', '')
        -- JDUI's stock sidebar always renders a player avatar. Remove only that
        -- profile block and frame rules; the rest of the library remains unchanged.
        source = source:gsub("if not avatar%(%s*26%.5%s*,%s*26%.5%s*,%s*32%s*%) then.-end", "if false then end")
        source = source:gsub('box%("brandBadge".-\n', "")
        source = source:gsub('box%("sidebarRule".-\n', "")
        source = source:gsub('box%("sidebar".-\n', "")
        source = source:gsub('box%("rim".-\n', "")
        source = source:gsub('label%("playerInitial".-\n', "")
        source = source:gsub('label%("playerName".-\n', "")
        source = source:gsub('label%("playerUsername".-\n', "")
        -- Keep the single RoChess page but remove JDUI's navigation rail.
        source = source:gsub('   box%("sidebar".-label%("keyhint".-\n', "")
        source = source:gsub('contentLeft=99', 'contentLeft=20')
        source = source:gsub('contentLeft=20%+108%*sidebarOpen', 'contentLeft=20')
        -- Skip JDUI's animated loading/title sequence.
        source = source:gsub('local introStart,introDone,introChimed,introSound=nil,false,false,nil', 'local introStart,introDone,introChimed,introSound=nil,true,true,nil')
        -- Prevent the hidden sidebar from expanding when the mouse crosses it.
        source = source:gsub('local expand=sidebarOver or %(sidebarOpen>%.01 and now%-sidebarLeaveTime<%.12%)', 'local expand=false')
        source = source:gsub('smallButton%("close".-requestClose%)', "")
        source = source:gsub('for i=1,math%.min%(%s*5,%s*#app%.Tabs%-tabOffset%) do.-   if #app%.Tabs>5 then', 'if #app.Tabs>5 then')
        source = source:gsub('   box%(tab%.Id%.%."nav".-\n', "")
        source = source:gsub('   box%(tab%.Id%.%."rail".-\n', "")
        source = source:gsub('   icon%(tab%.Id%.%."icon".-\n', "")
        source = source:gsub('   label%(tab%.Id%.%."name".-\n', "")
        source = source:gsub('   if over and click then click=false;tab:Select%(%) end\n', "")
        local loaded = loadstring(source)() or _G.JDUI
        pcall(function() loaded.Effects = false end)
        return loaded
    end)
    if not ok or type(jdui) ~= "table" then
        print("[RoChess UI] JDUI failed to load; using Matcha UI")
        return false
    end
    useCustomUI = true
    local main = jdui:AddTab({Title="RoChess", Icon="bolt"})
    local engine = main:AddIsland({Title="Engine", Description="Choose the analysis backend"})
    engine:AddDropdown({Title="Engine", Options={"Stockfish","Maia (Human Like)"}, Default=ENGINE=="maia" and "Maia (Human Like)" or "Stockfish", Callback=function(value)
        ENGINE = value == "Maia (Human Like)" and "maia" or "stockfish"
    end})
    engine:AddDropdown({Title="Strength", Options={"Low","Medium","High"}, Default=STRENGTH:gsub("^%l",string.upper), Callback=function(value) STRENGTH=string.lower(value) end})
    local targetEloText = TARGET_ELO and tostring(TARGET_ELO) or ""
    engine:AddTextbox({Title="Target Elo", Placeholder="800-3000 or blank", Default=TARGET_ELO and tostring(TARGET_ELO) or "", Callback=function(first, second)
        targetEloText = tostring(second or first or "")
    end})
    engine:AddButton({Title="Apply Target Elo", ButtonText="Apply", Callback=function()
        local text = tostring(targetEloText or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local number = tonumber(text)
        if text == "" then
            TARGET_ELO = nil
            print("[Chess] Target Elo cleared; using preset strength")
        elseif number and number >= 800 and number <= 3000 then
            TARGET_ELO = math.max(800, math.min(3000, math.floor(number + 0.5)))
            print("[Chess] Target Elo applied: " .. tostring(TARGET_ELO) .. " (next analysis)")
        else
            print("[Chess] Invalid Target Elo; enter 800-3000 or leave it blank")
        end
    end})
    local gameTab = main
    local game = gameTab:AddIsland({Title="Game settings", Description="Position and move preferences"})
    game:AddDropdown({Title="Play as", Options={"White","Black"}, Default=PLAY_AS, Callback=function(value) applyPlayAs(value) end})
    game:AddDropdown({Title="Playing style", Options={"Standard","Aggressive","Defensive"}, Default=PLAY_STYLE:gsub("^%l",string.upper), Callback=function(value) PLAY_STYLE=string.lower(value) end})
    game:AddDropdown({Title="Opening", Options={"Automatic","Italian Game","Sicilian Defense","French Defense","Caro-Kann Defense","Alien Gambit","Queen's Gambit","King's Indian Defense","English Opening"}, Default=OPENING_NAME, Callback=function(value)
        OPENING_NAME=value; openingActive=value~="Automatic"; moveHistory={}; openingRefreshRequested=true; newGameRequested=true; removeArrow()
    end})
    game:AddToggle({Title="Second best move", Default=SECOND_MOVE_ENABLED, Callback=function(value) SECOND_MOVE_ENABLED=value end})
    local actions = gameTab:AddIsland({Title="Actions", Description="Game and position controls"})
    actions:AddButton({Title="New Game", ButtonText="Reset", Callback=function()
        newGameRequested = true
        print("[Chess] New Game requested")
    end})
    actions:AddButton({Title="Visual Calibration", ButtonText="Open", Callback=function()
        beginVisualCalibration()
        print("[Chess] Visual calibration opened")
    end})
    actions:AddButton({Title="Use Matcha UI next launch", ButtonText="Switch", Callback=function()
        pcall(function() writefile(CUSTOM_UI_CHOICE_FILE, HttpService:JSONEncode({choice="matcha"})) end)
        pcall(function() jdui:Notify({Title="Saved", Content="Matcha UI will open next launch.", Type="success", Duration=4}) end)
    end})
    local position = gameTab:AddIsland({Title="Position Import", Description="Load a FEN position"})
    position:AddTextbox({Title="FEN", Placeholder="Paste a FEN position", Default="", Callback=function(value) enteredFen=value or "" end})
    position:AddButton({Title="Import position", ButtonText="Import", Callback=function()
        if enteredFen and enteredFen ~= "" then
            pendingFen = enteredFen
            newGameRequested = true
            print("[Chess] FEN import requested")
        else
            print("[Chess] FEN import failed: paste a FEN first")
        end
    end})
    jdui.Tabs = {main}
    pcall(function() jdui:SetConfig("rochess") end)
    pcall(function() jdui:SetKeybind(0xA1) end)
    pcall(function() jdui:SetTheme("Black") end)
    pcall(function() jdui:SetLayout("Compact") end)
    pcall(function() jdui:SetLayout({Height=28, Gap=4, Padding=6, IslandPadding=7, IslandBorder=0, IslandOpacity=0.58, IslandCorner=6, RowHeight=22, RowGap=2, BoxHeight=24, ButtonHeight=24}) end)
    pcall(function() jdui:SetOverflow("Scroll") end)
    pcall(function() jdui:SetOpacity(1) end)
    pcall(function() jdui:SetTitle("RoChess") end)
    pcall(function() jdui:SetSubtitle("Stockfish / Maia") end)
    pcall(function() jdui:SetEffects(false) end)
    main:Select()
    return true
end

RoChessUI = {}
do
    local WHITE = Color3.fromRGB(235,240,248)
    local MUTED = Color3.fromRGB(155,166,184)
    local PANEL = Color3.fromRGB(25,30,40)
    local CARD = Color3.fromRGB(35,42,55)
    local function add(list, kind, props)
        local object = Drawing.new(kind)
        for key, value in pairs(props) do pcall(function() object[key] = value end) end
        list[#list+1] = object
        return object
    end
    local function inside(mouse,x,y,w,h)
        return mouse and mouse.X >= x and mouse.X <= x+w and mouse.Y >= y and mouse.Y <= y+h
    end
    function RoChessUI.new(callbacks)
        local ui = {callbacks=callbacks or {}, objects={}, controls={}, popup=true, visible=true, pressed=false, selected=nil, dragging=false, dragX=0, dragY=0, rightShift=false, x=32, y=80, w=330}
        local function text(value,x,y,size,color)
            return add(ui.objects,"Text",{Text=value,Position=Vector2.new(x,y),Size=size or 14,Color=color or WHITE,Outline=true,Visible=true,ZIndex=200})
        end
        local function button(id,label,x,y,w,h)
            local box=add(ui.objects,"Square",{Position=Vector2.new(x,y),Size=Vector2.new(w,h),Color=CARD,Filled=true,Rounding=8,Visible=true,ZIndex=199})
            text(label,x+14,y+8,13,WHITE)
            ui.controls[#ui.controls+1]={id=id,x=x,y=y,w=w,h=h}
        end
        local function popup()
            add(ui.objects,"Square",{Position=Vector2.new(0,0),Size=Vector2.new(1920,1080),Color=Color3.fromRGB(8,11,17),Transparency=.35,Filled=true,Visible=true,ZIndex=190})
            add(ui.objects,"Square",{Position=Vector2.new(530,315),Size=Vector2.new(420,250),Color=PANEL,Filled=true,Visible=true,ZIndex=191})
            text("RoChess interface",570,350,22,WHITE); text("Choose which interface to use",570,385,14,MUTED)
            button("custom","Use RoChess UI",570,430,160,48); button("matcha","Use Matcha UI",750,430,160,48)
        end
        local function panel()
            ui.w=620
            add(ui.objects,"Square",{Position=Vector2.new(ui.x,ui.y),Size=Vector2.new(ui.w,520),Color=PANEL,Filled=true,Rounding=14,Visible=true,ZIndex=190})
            add(ui.objects,"Square",{Position=Vector2.new(ui.x,ui.y),Size=Vector2.new(64,520),Color=Color3.fromRGB(18,22,31),Filled=true,Rounding=14,Visible=true,ZIndex=191})
            text("R",ui.x+23,ui.y+24,22,WHITE)
            text("A",ui.x+24,ui.y+88,19,Color3.fromRGB(150,120,255))
            text("S",ui.x+24,ui.y+150,19,MUTED)
            text("M",ui.x+23,ui.y+212,19,MUTED)
            text("RoChess",ui.x+92,ui.y+24,24,WHITE)
            text("Chess assistant",ui.x+92,ui.y+56,13,MUTED)
            text("RIGHTSHIFT  •  HIDE / SHOW",ui.x+430,ui.y+31,10,MUTED)
            local function heading(value,x,y)
                text(value,x,y,11,Color3.fromRGB(170,155,255))
            end
            local function row(id,label,value,x,y,w)
                text(label,x,y,12,MUTED)
                button(id,value,x,y+17,w,32)
            end
            heading("ENGINE",ui.x+92,ui.y+100)
            heading("GAME SETTINGS",ui.x+330,ui.y+100)
            add(ui.objects,"Square",{Position=Vector2.new(ui.x+84,ui.y+120),Size=Vector2.new(220,210),Color=Color3.fromRGB(31,37,49),Filled=true,Rounding=10,Visible=true,ZIndex=192})
            add(ui.objects,"Square",{Position=Vector2.new(ui.x+320,ui.y+120),Size=Vector2.new(276,210),Color=Color3.fromRGB(31,37,49),Filled=true,Rounding=10,Visible=true,ZIndex=192})
            row("engine","Engine",ENGINE=="maia" and "Maia (Human)" or "Stockfish",ui.x+104,ui.y+143,180)
            row("strength","Strength",STRENGTH,ui.x+104,ui.y+198,180)
            row("elo","Target Elo",tostring(TARGET_ELO or "Off"),ui.x+104,ui.y+253,180)
            row("side","Play as",PLAY_AS,ui.x+340,ui.y+143,230)
            row("style","Style",PLAY_STYLE,ui.x+340,ui.y+198,230)
            row("opening","Opening",OPENING_NAME,ui.x+340,ui.y+253,230)
            heading("ACTIONS",ui.x+92,ui.y+360)
            add(ui.objects,"Square",{Position=Vector2.new(ui.x+84,ui.y+380),Size=Vector2.new(512,90),Color=Color3.fromRGB(31,37,49),Filled=true,Rounding=10,Visible=true,ZIndex=192})
            button("newgame","New Game",ui.x+104,ui.y+405,145,34)
            button("calibrate","Calibrate",ui.x+264,ui.y+405,145,34)
            button("hide","Minimize",ui.x+424,ui.y+405,145,34)
        end
        local function rebuild()
            for _, object in ipairs(ui.objects) do pcall(function() object:Remove() end) end
            ui.objects, ui.controls = {}, {}
            panel()
        end
        function ui:choose(kind)
            self.popup=false; self.selected=kind
            for _, object in ipairs(self.objects) do pcall(function() object:Remove() end) end
            self.objects={}; self.controls={}
            if kind=="custom" then panel(); if self.callbacks.onCustom then self.callbacks.onCustom() end
            elseif self.callbacks.onMatcha then self.visible=false; self.callbacks.onMatcha() end
        end
        function ui:step()
            if not self.visible then return end
            local mouse=player and player:GetMouse(); local down=ismouse1pressed()
            local shift = false
            pcall(function() shift = game:GetService("UserInputService"):IsKeyDown(Enum.KeyCode.RightShift) end)
            if shift and not self.rightShift then self.visible = not self.visible end
            self.rightShift = shift
            if not self.visible then return end
            if self.selected == "custom" and mouse then
                if down and not self.dragging and inside(mouse,self.x,self.y,self.w,70) then
                    self.dragging, self.dragX, self.dragY = true, mouse.X, mouse.Y
                elseif not down then
                    self.dragging = false
                end
                if self.dragging then
                    local dx,dy=mouse.X-self.dragX,mouse.Y-self.dragY
                    self.x,self.y=self.x+dx,self.y+dy; self.dragX,self.dragY=mouse.X,mouse.Y
                    for _, object in ipairs(self.objects) do pcall(function() object.Position=Vector2.new(object.Position.X+dx,object.Position.Y+dy) end) end
                    for _, control in ipairs(self.controls) do control.x,control.y=control.x+dx,control.y+dy end
                    return
                end
            end
            if down and not self.pressed then
                for _, control in ipairs(self.controls) do
                    if inside(mouse,control.x,control.y,control.w,control.h) then
                        if control.id=="custom" or control.id=="matcha" then self:choose(control.id)
                        elseif control.id=="hide" then self.visible=false
                        elseif self.callbacks[control.id] then self.callbacks[control.id](); rebuild() end
                        break
                    end
                end
            end
            self.pressed=down
        end
        popup()
        return ui
    end
end

setupInterfaceChoice()

if not useCustomUI and UI and UI.AddTab then
    UI.AddTab("RoChess AI", function(tab)
        local settings = tab:Section("Game Settings", "Left")
        settings:Combo("chess_play_as", "Play as", {"White", "Black"}, 0, function(_, text)
            -- The polling logic below handles changes. Do not treat the
            -- initial callback as a manual override.
        end)
        settings:Combo("chess_strength", "Strength", {"Low", "Medium", "High"}, 2, function(_, text)
            STRENGTH = string.lower(text)
        end)
        settings:Combo("chess_style", "Playing style", {"Standard", "Aggressive", "Defensive"}, 0, function(_, text)
            PLAY_STYLE = string.lower(text)
        end)
        settings:Combo("chess_engine", "Engine", {"Stockfish", "Maia (Human Like)"}, 0, function(_, text)
            ENGINE = text == "Maia (Human Like)" and "maia" or "stockfish"
        end)
        settings:Combo("chess_second_move", "Second best move", {"Off", "On"}, 1, function(_, text)
            SECOND_MOVE_ENABLED = text == "On"
        end)
        settings:Combo("chess_opening", "Opening", {"Automatic", "Italian Game", "Sicilian Defense", "French Defense", "Caro-Kann Defense", "Alien Gambit", "Queen's Gambit", "King's Indian Defense", "English Opening"}, 0, function(_, text)
            OPENING_NAME = text
            openingActive = OPENING_NAME ~= "Automatic"
            moveHistory = {}
            openingRefreshRequested = true
            newGameRequested = true
            removeArrow()
            print("[Chess] Opening selected: " .. OPENING_NAME)
        end)
        local eloInput = settings:InputText("chess_target_elo", "Target Elo (800-3000, optional)", "", function() end)
        settings:Button("Apply Target Elo", function()
            local text = ""
            local widgetOk, widgetText = pcall(function() return eloInput:GetValue() end)
            if widgetOk and widgetText then text = widgetText end
            local uiText = UI.GetValue("chess_target_elo")
            if uiText and uiText ~= "" then text = uiText end
            text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local value = tonumber(text)
            if text == "" then
                TARGET_ELO = nil
                print("[Chess] Target Elo cleared; using preset strength")
            elseif value and value >= 800 and value <= 3000 then
                TARGET_ELO = math.max(800, math.min(3000, math.floor(value + 0.5)))
                print("[Chess] Target Elo set to " .. tostring(TARGET_ELO) .. " (applies to the next analysis)")
            else
                print("[Chess] Invalid Target Elo; enter 800-3000 or leave it blank")
            end
        end)
        settings:Text("Target Elo overrides the preset strength.")
        settings:Text("Select your color before playing.")
        settings:Text("Best move: green arrow")
        settings:Button("Start visual calibration", function()
            beginVisualCalibration()
        end)
        settings:Button("Save visual calibration", function()
            calibrationConfirm = true
        end)
        settings:Button("Delete saved calibration", function()
            pcall(function()
                if isfile(CALIBRATION_FILE) then delfile(CALIBRATION_FILE) end
            end)
            calibrationOffsetX, calibrationOffsetY = 0, 0
            calibrationSaved, calibrationSignature = false, nil
            beginVisualCalibration()
            print("[Chess Detect] Saved calibration deleted")
        end)
        settings:Button("New Game", function()
            newGameRequested = true
        end)
        settings:Button("Use RoChess UI next launch", function()
            pcall(function() writefile(CUSTOM_UI_CHOICE_FILE, HttpService:JSONEncode({choice="custom"})) end)
            print("[Chess Detect] RoChess UI saved for next launch")
        end)
        local position = tab:Section("Position Import", "Right")
        local fenInput = position:InputText("chess_fen", "FEN position", "", function(text)
            enteredFen = text or ""
        end)
        position:Button("Import Position", function()
            local text = enteredFen
            local widgetOk, widgetText = pcall(function() return fenInput:GetValue() end)
            if widgetOk and widgetText and widgetText ~= "" then text = widgetText end
            local uiText = UI.GetValue("chess_fen")
            if uiText and uiText ~= "" then text = uiText end
            if text and text ~= "" then
                text = text:gsub("^%s+", ""):gsub("%s+$", "")
                enteredFen = text
                pendingFen = text
                importStatus = "Position queued"
            else
                importStatus = "Paste a FEN first"
            end
        end)
        position:Text(importStatus)
    end)
end

local function fenPieces(fen)
    assert(type(fen) == "string" and fen ~= "", "Invalid FEN: empty input")
    local fields = {}
    for field in fen:gmatch("[^%s]+") do fields[#fields + 1] = field end
    assert(#fields >= 2 and #fields <= 6, "Invalid FEN: expected 2 to 6 fields")
    assert(fields[2] == "w" or fields[2] == "b", "Invalid FEN: side to move must be w or b")
    local result, whiteKing, blackKing = {}, 0, 0
    local rank, ranks = 8, 0
    for row in fields[1]:gmatch("[^/]+") do
        ranks = ranks + 1
        assert(rank >= 1, "Invalid FEN: too many ranks")
        local file = 1
        for char in row:gmatch(".") do
            local count = tonumber(char)
            if count then
                assert(count >= 1 and count <= 8, "Invalid FEN: bad empty-square count")
                file = file + count
            else
                local lower = char:lower()
                local names = {p="Pawn", n="Knight", b="Bishop", r="Rook", q="Queen", k="King"}
                assert(names[lower] ~= nil and char:match("^[pnbrqkPNBRQK]$"), "Invalid FEN: unknown piece")
                assert(file <= 8, "Invalid FEN: rank has more than 8 files")
                local color = char == char:upper() and "White" or "Black"
                result[string.char(96 + file) .. tostring(rank)] = color .. " " .. names[lower]
                if lower == "k" then
                    if color == "White" then whiteKing = whiteKing + 1 else blackKing = blackKing + 1 end
                end
                file = file + 1
            end
        end
        assert(file == 9, "Invalid FEN: each rank must contain exactly 8 files")
        rank = rank - 1
    end
    assert(ranks == 8 and rank == 0, "Invalid FEN: expected exactly 8 ranks")
    assert(whiteKing == 1 and blackKing == 1, "Invalid FEN: position must contain one king per side")
    local rights = fields[3] or "-"
    assert(rights == "-" or rights:match("^[KQkq]+$"), "Invalid FEN: bad castling rights")
    local ep = fields[4] or "-"
    assert(ep == "-" or ep:match("^[a-h][36]$"), "Invalid FEN: bad en-passant square")
    local half, full = tonumber(fields[5] or "0"), tonumber(fields[6] or "1")
    assert(half and half >= 0 and half % 1 == 0, "Invalid FEN: bad halfmove clock")
    assert(full and full >= 1 and full % 1 == 0, "Invalid FEN: bad fullmove number")
    return result, fields[2] == "w", rights, ep, half, full
end

local function child(parent, name)
    return parent and parent:FindFirstChild(name) or nil
end

local function squareName(index)
    if FLIP_BOARD then
        index = 65 - index
    end
    return string.char(97 + (index - 1) % 8) .. tostring(math.floor((index - 1) / 8) + 1)
end

local function pieceAtStart(square)
    local file, rank = square:sub(1, 1), tonumber(square:sub(2, 2))
    local back = {a="Rook", b="Knight", c="Bishop", d="Queen", e="King", f="Bishop", g="Knight", h="Rook"}
    if rank == 1 then return "White " .. back[file] end
    if rank == 2 then return "White Pawn" end
    if rank == 7 then return "Black Pawn" end
    if rank == 8 then return "Black " .. back[file] end
end

local function inferMissingPiece(snapshot, types)
    local expected = {}
    local files = {"a", "b", "c", "d", "e", "f", "g", "h"}
    local back = {a="Rook", b="Knight", c="Bishop", d="Queen", e="King", f="Bishop", g="Knight", h="Rook"}
    for _, file in ipairs(files) do
        local kinds = {"White " .. back[file], "White Pawn", "Black Pawn", "Black " .. back[file]}
        for _, kind in ipairs(kinds) do expected[kind] = (expected[kind] or 0) + 1 end
    end
    local unknown
    for token in pairs(snapshot) do
        local kind = types[token]
        if kind then
            expected[kind] = expected[kind] - 1
        elseif unknown then
            return
        else
            unknown = token
        end
    end
    if unknown then
        for kind, count in pairs(expected) do
            if count == 1 then
                types[unknown] = kind
                return
            end
        end
    end
end

local function isStartingPosition(snapshot)
    local types, count = {}, 0
    for token, square in pairs(snapshot) do
        types[token] = pieceAtStart(square)
        if types[token] then count = count + 1 end
    end
    if count ~= 32 then return false, types end
    inferMissingPiece(snapshot, types)
    for token in pairs(snapshot) do
        if not types[token] then return false, types end
    end
    return true, types
end

local function pieceCode(pieceType)
    local color, kind = pieceType:match("^(%a+) (.+)$")
    local codes = {Pawn="p", Knight="n", Bishop="b", Rook="r", Queen="q", King="k"}
    local code = codes[kind]
    return color == "White" and string.upper(code) or code
end

local cachedSquareFolder, cachedPieceFolder
local function getBoard(forceRefresh)
    if not forceRefresh and cachedSquareFolder and cachedPieceFolder then
        return cachedSquareFolder, cachedPieceFolder
    end
    local gui = child(player, "PlayerGui")
    for _ = 1, 80 do
        local board = child(child(child(gui, "ChessUI"), "Root"), "Board")
        local squares, pieces = child(board, "Squares"), child(board, "Pieces")
        if squares and pieces then
            cachedSquareFolder, cachedPieceFolder = squares, pieces
            return squares, pieces
        end
        wait(0.1)
    end
    error("Chess board not found. Open RoChess first.")
end

local function detectPlayAs()
    local okBoard, squares = pcall(function()
        return select(1, getBoard(true))
    end)
    if not okBoard then return nil end
    -- RoChess currently stores the coordinate labels in an unnamed sibling
    -- Frame under Board; older builds used a named Coords Frame. Search the
    -- board subtree so both layouts work.
    local board = squares and squares.Parent
    local rank1, file1
    if board then
        for _, object in ipairs(board:GetDescendants()) do
            if object.Name == "Rank1" then rank1 = object end
            if object.Name == "File1" then file1 = object end
            if rank1 and file1 then break end
        end
    end
    if not rank1 or not file1 then return nil end
    local ok, rankText, fileText = pcall(function()
        return tostring(rank1.Text), tostring(file1.Text):lower()
    end)
    if not ok then return nil end
    if rankText == "8" and fileText == "a" then return "White" end
    if rankText == "1" and fileText == "h" then return "Black" end
    return nil
end

local function selectedPlayAs(value)
    if type(value) == "string" then
        local text = value:lower()
        if text == "white" then return "White" end
        if text == "black" then return "Black" end
    elseif type(value) == "number" then
        if value == 0 then return "White" end
        if value == 1 then return "Black" end
    end
    return nil
end

function applyPlayAs(color)
    if color ~= "White" and color ~= "Black" and color ~= "Any" then return end
    local oldColor = PLAY_AS
    PLAY_AS = color
    -- The RoChess square objects already move with the board orientation.
    -- Do not reverse their chess coordinates a second time.
    FLIP_BOARD = false
    if oldColor ~= PLAY_AS then
        newGameRequested = true
        boardCenters = {}
        removeArrow()
    end
end

local function getToken(piece)
    local ok, address = pcall(function() return piece.Address end)
    if ok and type(address) == "number" and address > 0 then
        return "address:" .. tostring(address)
    end
    return piece
end

local function scan()
    local squareFolder, pieceFolder = getBoard()
    local squares, byIndex = {}, {}
    for _, square in ipairs(squareFolder:GetChildren()) do
        local index = tonumber(square.Name:match("^S(%d+)$"))
        if index and index >= 1 and index <= 64 then
            local p, size = square.AbsolutePosition, square.AbsoluteSize
            squares[#squares + 1] = {index=index, x=p.X, y=p.Y, w=size.X, h=size.Y}
            byIndex[index] = squares[#squares]
        end
    end
    assert(#squares == 64, "Expected 64 squares named S1 through S64.")
    local first = byIndex[1]
    local spacing = first and math.min(first.w, first.h) or 0
    if spacing < 4 and byIndex[2] then
        spacing = math.abs(byIndex[2].x - byIndex[1].x)
    end
    if spacing < 4 and byIndex[9] then
        spacing = math.abs(byIndex[9].y - byIndex[1].y)
    end
    if spacing < 4 then
        local nearest = math.huge
        for i = 1, #squares do
            for j = i + 1, #squares do
                local dx, dy = squares[i].x - squares[j].x, squares[i].y - squares[j].y
                local distance = math.sqrt(dx * dx + dy * dy)
                if distance >= 4 and distance < nearest then nearest = distance end
            end
        end
        spacing = nearest
    end
    assert(spacing < math.huge and spacing >= 4, "Could not calculate board spacing.")
    boardCenters = {}
    boardSquareObjects = {}
    for _, square in ipairs(squares) do
        local width = square.w >= 4 and square.w or spacing
        local height = square.h >= 4 and square.h or spacing
        boardCenters[squareName(square.index)] = Vector2.new(square.x + width / 2, square.y + height / 2)
        boardSquareObjects[squareName(square.index)] = squareFolder:FindFirstChild("S" .. tostring(square.index))
    end
    local firstSquare = byIndex[1]
    local lastSquare = byIndex[64]
    local signature = string.format("%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", firstSquare.x, firstSquare.y, spacing, lastSquare.x, lastSquare.y, #squares)
    saveCalibration(signature)
    local tokens, occupied = {}, {}
    for _, piece in ipairs(pieceFolder:GetChildren()) do
        if piece.ClassName == "ImageLabel" or piece.ClassName == "ImageButton" then
            local p, nearest, best = piece.AbsolutePosition, nil, math.huge
            for _, square in ipairs(squares) do
                local dx, dy = p.X - square.x, p.Y - square.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < best then nearest, best = square.index, dist end
            end
            assert(nearest and best <= spacing * 0.4, "Piece is moving; wait for animation.")
            local name = squareName(nearest)
            assert(not occupied[name], "Overlapping pieces detected; wait for animation.")
            local token = getToken(piece)
            assert(tokens[token] == nil, "Duplicate piece identity; cannot track reliably.")
            occupied[name], tokens[token] = true, name
        end
    end
    return tokens
end
local function sameSnapshot(a, b)
    for token, square in pairs(a) do
        if b[token] ~= square then return false end
    end
    for token, square in pairs(b) do
        if a[token] ~= square then return false end
    end
    return true
end

local function updateMoveState(move, removed)
    enPassantTarget = "-"
    if not move or not move.piece then return end
    local color, kind, from, to = move.piece:sub(1, 5), move.piece:sub(7), move.from, move.to
    if kind == "King" then
        if color == "White" then castlingRights = castlingRights:gsub("K", ""):gsub("Q", "")
        else castlingRights = castlingRights:gsub("k", ""):gsub("q", "") end
    elseif kind == "Rook" then
        if from == "a1" then castlingRights = castlingRights:gsub("Q", "") end
        if from == "h1" then castlingRights = castlingRights:gsub("K", "") end
        if from == "a8" then castlingRights = castlingRights:gsub("q", "") end
        if from == "h8" then castlingRights = castlingRights:gsub("k", "") end
    end
    for _, gone in ipairs(removed or {}) do
        if gone.piece and gone.piece:sub(7) == "Rook" then
            if gone.from == "a1" then castlingRights = castlingRights:gsub("Q", "") end
            if gone.from == "h1" then castlingRights = castlingRights:gsub("K", "") end
            if gone.from == "a8" then castlingRights = castlingRights:gsub("q", "") end
            if gone.from == "h8" then castlingRights = castlingRights:gsub("k", "") end
        end
    end
    if castlingRights == "" then castlingRights = "-" end
    if kind == "Pawn" then
        local a, b = tonumber(from:sub(2, 2)), tonumber(to:sub(2, 2))
        if a and b and math.abs(b - a) == 2 then enPassantTarget = to:sub(1, 1) .. tostring((a + b) / 2) end
    end
end

local function makeFen(snapshot, pieceTypes, whiteToMove, halfmove, fullmove)
    local board = {}
    for token, square in pairs(snapshot) do if pieceTypes[token] then board[square] = pieceCode(pieceTypes[token]) end end
    local ranks = {}
    for rank = 8, 1, -1 do
        local row, empty = "", 0
        for file = 1, 8 do
            local piece = board[string.char(96 + file) .. tostring(rank)]
            if piece then
                if empty > 0 then row, empty = row .. tostring(empty), 0 end
                row = row .. piece
            else empty = empty + 1 end
        end
        if empty > 0 then row = row .. tostring(empty) end
        ranks[#ranks + 1] = row
    end
    local rights = castlingRights
    if board.e1 ~= "K" then rights = rights:gsub("K", ""):gsub("Q", "") end
    if board.e8 ~= "k" then rights = rights:gsub("k", ""):gsub("q", "") end
    if board.a1 ~= "R" then rights = rights:gsub("Q", "") end
    if board.h1 ~= "R" then rights = rights:gsub("K", "") end
    if board.a8 ~= "r" then rights = rights:gsub("q", "") end
    if board.h8 ~= "r" then rights = rights:gsub("k", "") end
    rights = rights == "" and "-" or rights
    local ep = enPassantTarget
    if ep ~= "-" then
        local epRank = tonumber(ep:sub(2, 2))
        if (whiteToMove and epRank ~= 6) or ((not whiteToMove) and epRank ~= 3) then ep = "-" end
    end
    return table.concat(ranks, "/") .. " " .. (whiteToMove and "w" or "b") .. " " .. rights .. " " .. ep .. " " .. tostring(halfmove) .. " " .. tostring(fullmove)
end

local function positionKey(fen)
    return tostring(fen):match("^(%S+ %S+ %S+ %S+)") or tostring(fen)
end

local function recordPosition(snapshot)
    local fen = makeFen(snapshot, pieceTypes, whiteToMove, halfmove, fullmove)
    local key = positionKey(fen)
    positionCounts[key] = (positionCounts[key] or 0) + 1
    return positionCounts[key], key
end

local function positionReady(snapshot)
    local whiteKing, blackKing, typed = 0, 0, 0
    for token, square in pairs(snapshot) do
        local piece = pieceTypes[token]
        if not piece then return false, "unclassified piece" end
        typed = typed + 1
        if piece == "White King" then whiteKing = whiteKing + 1 end
        if piece == "Black King" then blackKing = blackKing + 1 end
    end
    if typed < 2 then return false, "too few pieces" end
    if whiteKing ~= 1 or blackKing ~= 1 then return false, "invalid king count" end
    return true
end
local function askStockfish(fen, avoidMoves)
    local request = {fen=fen, strength=STRENGTH, style=PLAY_STYLE, engine=ENGINE}
    if SECOND_MOVE_ENABLED then request.include_alternative = true end
    if TARGET_ELO then request.target_elo = TARGET_ELO end
    if avoidMoves and #avoidMoves > 0 then request.avoid_moves = avoidMoves end
    local body = HttpService:JSONEncode(request)
    local headers = nil
    headers = { ["X-RoChess-Session"] = ROCHESS_SESSION, ["X-RoChess-Device"] = DEVICE_ID }
    if API_KEY ~= "" then headers["X-API-Key"] = API_KEY end
    local raw = httppost(API_URL, body, "application/json", headers)
    if raw == "" then return nil, "No response from the public Render API" end
    local ok, result = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(result) ~= "table" then return nil, "Invalid API response: " .. tostring(raw) end
    if not result.bestmove then return nil, result.detail or "API returned no best move" end
    return result
end

local function bestMove(fen, snapshot, avoidMoves)
    if openingActive and OPENING_NAME ~= "Automatic" then
        local line = openingLines[OPENING_NAME]
        local forced = line and line[#moveHistory + 1]
        if forced then
            return {bestmove=forced, backend="opening"}
        end
    end
    return askStockfish(fen, avoidMoves)
end

local function checkAnnouncement()
    local now = tick()
    if now - lastStatusCheck < STATUS_INTERVAL then return end
    lastStatusCheck = now
    local ok, raw = pcall(function() return httpget(STATUS_URL) end)
    if not ok or raw == "" then return end
    local decoded, result = pcall(function() return HttpService:JSONDecode(raw) end)
    if not decoded or type(result) ~= "table" then return end
    local announcement = tostring(result.announcement or "")
    if announcement ~= "" and announcement ~= lastAnnouncement then
        print("[RoChess Announcement] " .. announcement)
        pcall(function() notify("RoChess Announcement", announcement, 8) end)
    elseif announcement == "" and lastAnnouncement and lastAnnouncement ~= "" then
        print("[RoChess Announcement] Server update complete")
        pcall(function() notify("RoChess", "Server update complete", 5) end)
    end
    lastAnnouncement = announcement
end

local ok, previous = pcall(scan)
if not ok then print("[Chess Detect] Initialization failed: " .. tostring(previous)); return end
pieceTypes = {}
local known = 0
local unknownTokens = {}
local startedAfterOpening = false
for token, square in pairs(previous) do
    pieceTypes[token] = pieceAtStart(square)
    if pieceTypes[token] then
        known = known + 1
    else
        unknownTokens[#unknownTokens + 1] = token
    end
end

if known == 31 and #unknownTokens == 1 and PLAY_AS ~= "Any" then
    local expected = {}
    local files = {"a", "b", "c", "d", "e", "f", "g", "h"}
    local back = {a="Rook", b="Knight", c="Bishop", d="Queen", e="King", f="Bishop", g="Knight", h="Rook"}
    for _, file in ipairs(files) do
        local types = {"White " .. back[file], "White Pawn", "Black Pawn", "Black " .. back[file]}
        for _, kind in ipairs(types) do expected[kind] = (expected[kind] or 0) + 1 end
    end
    for _, kind in pairs(pieceTypes) do expected[kind] = expected[kind] - 1 end
    local missing
    for kind, count in pairs(expected) do
        if count == 1 then
            if missing then
                missing = nil
                break
            end
            missing = kind
        elseif count ~= 0 then
            missing = nil
            break
        end
    end
    if missing then
        pieceTypes[unknownTokens[1]] = missing
        known = 32
        startedAfterOpening = true
    end
end

local awaitingImport = known ~= 32

local mirrorVisible, mirrorKeyDown, mirrorNextDraw = true, false, 0
local mirrorObjects, mirrorLastKey = {}, nil
local mirrorX, mirrorY, mirrorSize = 70, 110, 420
local mirrorChars = {Pawn="P", Knight="N", Bishop="B", Rook="R", Queen="Q", King="K"}
local function mirrorClear()
    for _, object in ipairs(mirrorObjects) do pcall(function() object:Remove() end) end
    mirrorObjects = {}
end
local function mirrorAdd(kind, props)
    local object = Drawing.new(kind)
    for key, value in pairs(props) do pcall(function() object[key] = value end) end
    mirrorObjects[#mirrorObjects + 1] = object
end
local function mirrorDraw(snapshot)
    if not Drawing or not mirrorVisible then mirrorClear(); return end
    local state = {}
    for token, square in pairs(snapshot or {}) do state[#state+1] = tostring(square) .. tostring(pieceTypes[token] or "") end
    table.sort(state)
    local key = table.concat(state, "|") .. tostring(mirrorX) .. tostring(mirrorY) .. tostring(mirrorSize)
    if key == mirrorLastKey then return end
    mirrorLastKey = key
    mirrorClear()
    local cell = mirrorSize / 8
    mirrorAdd("Square", {Position=Vector2.new(mirrorX-4,mirrorY-38),Size=Vector2.new(mirrorSize+8,mirrorSize+44),Color=Color3.fromRGB(16,20,29),Filled=true,Visible=true,ZIndex=20})
    mirrorAdd("Text", {Text="Live Position Mirror",Position=Vector2.new(mirrorX+10,mirrorY-27),Size=16,Color=Color3.fromRGB(240,244,250),Outline=true,Visible=true,ZIndex=42})
    for rank=8,1,-1 do for file=1,8 do
        local square=string.char(96+file)..rank; local px=mirrorX+(file-1)*cell; local py=mirrorY+(8-rank)*cell
        mirrorAdd("Square",{Position=Vector2.new(px,py),Size=Vector2.new(cell,cell),Color=((file+rank)%2==0) and Color3.fromRGB(224,232,242) or Color3.fromRGB(91,123,153),Filled=true,Visible=true,ZIndex=30})
    end end
    for token,square in pairs(snapshot or {}) do
        local piece=pieceTypes[token]; local file,rank=square:match("^([a-h])([1-8])$")
        if piece and file and rank then
            local px=mirrorX+(string.byte(file)-97)*cell+cell/2; local py=mirrorY+(8-tonumber(rank))*cell+cell/2-14
            mirrorAdd("Text",{Text=mirrorChars[piece:sub(7)] or "?",Position=Vector2.new(px,py),Size=30,Center=true,Color=piece:sub(1,5)=="White" and Color3.fromRGB(250,250,250) or Color3.fromRGB(20,22,28),Outline=true,Visible=true,ZIndex=42})
        end
    end
    mirrorAdd("Text",{Text="F8 hide/show | live detector state",Position=Vector2.new(mirrorX,mirrorY+mirrorSize+8),Size=12,Color=Color3.fromRGB(205,215,230),Outline=true,Visible=true,ZIndex=42})
end
local function mirrorStep(snapshot)
    local down=false; pcall(function() down=game:GetService("UserInputService"):IsKeyDown(Enum.KeyCode.F8) end)
    if down and not mirrorKeyDown then mirrorVisible=not mirrorVisible; mirrorLastKey=nil end
    mirrorKeyDown=down
    local now=tick()
    if now >= mirrorNextDraw then
        mirrorNextDraw=now+0.15
        mirrorDraw(snapshot)
    end
end

local whiteToMove = startedAfterOpening and (PLAY_AS == "White") or (not startedAfterOpening)
local halfmove, fullmove = 0, startedAfterOpening and 2 or 1
local initialAnalysisPending = true
local pendingPromotion = nil
local analysisRetryAt = 0
local lastAnalysisFen = nil
local lastAnalysisAt = 0
local initialAnalysisEarliest = tick() + 0.75
local stockfishOnline = true
local previousWasStartingPosition = false
do
    local atStart, startTypes = isStartingPosition(previous)
    previousWasStartingPosition = atStart
end

local function resetForNewGame(snapshot, atStartingPosition, detectedTypes)
    pieceTypes = detectedTypes or {}
    if not detectedTypes then
        for token, square in pairs(snapshot) do pieceTypes[token] = pieceAtStart(square) end
        inferMissingPiece(snapshot, pieceTypes)
    end
    previous = snapshot
    whiteToMove = (PLAY_AS == "Black" and not atStartingPosition) and false or true
    halfmove, fullmove = 0, 1
    castlingRights, enPassantTarget = "KQkq", "-"
    awaitingImport = false
    initialAnalysisPending = true
    initialAnalysisEarliest = tick() + 0.75
    analysisRetryAt = tick()
    pendingFen = nil
    pendingPromotion = nil
    positionCounts = {}
    lastPlayedUci = nil
    lastRepetitionWarningKey = nil
    lastRepetitionWarningCount = 0
    removeArrow()
end

local describeAnalysisError

local function updateStockfishStatus(online, detail)
    if online == stockfishOnline then
        return
    end
    stockfishOnline = online
    if online then
        print("[Stockfish] service is back online")
        pcall(function() notify("Stockfish", "Service is back online", 5) end)
    else
        local message = describeAnalysisError(detail)
        if detail and tostring(detail) ~= "" then
            message = message .. " (" .. tostring(detail) .. ")"
        end
        print("[Stockfish] " .. message)
        pcall(function() notify("Stockfish", message, 8) end)
    end
end

describeAnalysisError = function(errorMessage)
    local message = tostring(errorMessage or "No best move returned")
    local lower = string.lower(message)
    if string.find(lower, "no legal moves") or string.find(lower, "no best move") then
        return "Game over: no legal moves"
    elseif string.find(lower, "illegal position") or string.find(lower, "invalid fen") then
        return "Invalid board position: the detected pieces do not form a legal chess position"
    elseif string.find(lower, "timed out") or string.find(lower, "timeout") then
        return "Analysis timed out: Stockfish did not respond in time"
    elseif string.find(lower, "api key") or string.find(lower, "401") then
        return "Authentication failed: the API key is invalid or missing"
    elseif string.find(lower, "no response") or string.find(lower, "service unavailable") or string.find(lower, "502") or string.find(lower, "503") then
        return "Stockfish service is offline or unreachable"
    end
    return "Analysis failed: " .. message
end

local function recommend(snapshot)
    local ready, reason = positionReady(snapshot)
    if not ready then
        analysisRetryAt = tick() + 0.35
        return false
    end
    local fen = makeFen(snapshot, pieceTypes, whiteToMove, halfmove, fullmove)
    local result, errorMessage = bestMove(fen, snapshot)
    if not result or not result.bestmove then
        print("[DBG] REJECT|fen=" .. tostring(fen) .. "|t=" .. (whiteToMove and "w" or "b") .. "|cr=" .. tostring(castlingRights) .. "|ep=" .. tostring(enPassantTarget) .. "|err=" .. tostring(errorMessage))
        updateStockfishStatus(false, errorMessage)
        print("[Chess Detect] " .. describeAnalysisError(errorMessage))
        analysisRetryAt = tick() + 2
        return false
    end
    updateStockfishStatus(true)
    local fromSquare, toSquare = result.bestmove:sub(1, 2), result.bestmove:sub(3, 4)
    local wantedPiece = "Unknown piece"
    for token, square in pairs(snapshot) do
        if square == fromSquare and pieceTypes[token] then
            wantedPiece = pieceTypes[token]
            break
        end
    end
    local promotion = result.bestmove:sub(5, 5):lower()
    pendingPromotion = nil
    if promotionNames[promotion] then
        pendingPromotion = {from=fromSquare, to=toSquare, kind=promotionNames[promotion]}
    end
    local suffix = promotionNames[promotion] and " (promote to " .. promotionNames[promotion] .. ")" or ""
    local message = string.format("Move %s: %s -> %s%s", wantedPiece, fromSquare, toSquare, suffix)
    removeArrow()
    local promotionLabel = promotionNames[promotion] and "PROMOTE TO " .. string.upper(promotionNames[promotion]) or nil
    showArrow(fromSquare, toSquare, Color3.fromRGB(40, 220, 80), promotionLabel)
    if SECOND_MOVE_ENABLED and result.alternative and result.alternative ~= result.bestmove then
        local altPromotion = promotionNames[result.alternative:sub(5, 5):lower()]
        local altLabel = altPromotion and "PROMOTE TO " .. string.upper(altPromotion) or nil
        showArrow(result.alternative:sub(1, 2), result.alternative:sub(3, 4), Color3.fromRGB(70, 140, 255), altLabel)
    end
    local engineName = ENGINE == "maia" and "Maia" or "Stockfish"
    local backend = result.backend == "opening" and "Opening" or (result.backend == "local" and "Local" or "Render")
    print("[" .. engineName .. " " .. backend .. "] " .. message)
    return true
end

local function settleSnapshot(firstSnapshot)
    local latest = firstSnapshot
    local stableScans = 0
    local deadline = tick() + 0.30
    while stableScans < SETTLE_STABLE_SCANS and tick() < deadline do
        wait(SETTLE_DELAY)
        local ok, nextSnapshot = pcall(scan)
        if not ok then return false, latest end
        if sameSnapshot(latest, nextSnapshot) then
            stableScans = stableScans + 1
        else
            latest = nextSnapshot
            stableScans = 0
        end
    end
    return stableScans >= SETTLE_STABLE_SCANS, latest
end

while _G.__ROCHESS_SESSION == ROCHESS_SESSION do
    checkAnnouncement()
    if customUI and useCustomUI then customUI:step() end
    if not useCustomUI and UI and UI.GetValue then
        local selected = selectedPlayAs(UI.GetValue("chess_play_as"))
        if selected and lastPlayAsSelection == nil then
            lastPlayAsSelection = selected
            -- White is the default UI value, so preserve automatic detection
            -- for it. Black on the initial screen is an explicit useful
            -- choice and must not be discarded before the first scan.
            if selected == "Black" then
                AUTO_DETECT_COLOR = false
                applyPlayAs(selected)
            end
        elseif selected and selected ~= lastPlayAsSelection then
            lastPlayAsSelection = selected
            AUTO_DETECT_COLOR = false
            applyPlayAs(selected)
        end
    end
    if AUTO_DETECT_COLOR then
        local detected = detectPlayAs()
        if detected and detected ~= PLAY_AS then
            applyPlayAs(detected)
            print("[Chess Detect] Automatically detected player color: " .. PLAY_AS)
        end
    end
    wait(SCAN_DELAY)
    local success, current = pcall(scan)
    if success and calibrationActive then
        updateVisualCalibration()
        continue
    end
    if openingRefreshRequested and success then
        local atStart, detectedTypes = isStartingPosition(current)
        if atStart then
            resetForNewGame(current, true, detectedTypes)
            initialAnalysisPending = true
            analysisRetryAt = tick()
        else
            openingActive = false
        end
        openingRefreshRequested = false
        newGameRequested = false
        continue
    end
    if success then
        local atStartingPosition, detectedTypes = isStartingPosition(current)
        if atStartingPosition and not previousWasStartingPosition and not newGameRequested then
            resetForNewGame(current, true, detectedTypes)
            previousWasStartingPosition = true
            continue
        end
        previousWasStartingPosition = atStartingPosition
    end
    if newGameRequested and success then
        moveHistory = {}
        openingActive = OPENING_NAME ~= "Automatic"
        pieceTypes = {}
        local atStartingPosition = true
        for token, square in pairs(current) do
            pieceTypes[token] = pieceAtStart(square)
            if not pieceTypes[token] then atStartingPosition = false end
        end
        inferMissingPiece(current, pieceTypes)
        if atStartingPosition then
            local count = 0
            for _ in pairs(pieceTypes) do count = count + 1 end
            atStartingPosition = count == 32
        end
        positionCounts = {}
        lastPlayedUci = nil
        previous = current
        if PLAY_AS == "Black" and not atStartingPosition then
            whiteToMove = false
        else
            whiteToMove = true
        end
        halfmove, fullmove = 0, 1
        castlingRights, enPassantTarget = "KQkq", "-"
        awaitingImport = false
        initialAnalysisPending = true
        pendingFen = nil
            moveHistory = {}
            openingActive = false
        importStatus = "New game ready"
        removeArrow()
        newGameRequested = false
        previousWasStartingPosition = atStartingPosition
        continue
    end
    if pendingFen and success then
        local imported, position, side, rights, ep, importedHalf, importedFull = pcall(fenPieces, pendingFen)
        if imported then
            pieceTypes = {}
            for token, square in pairs(current) do
                assert(position[square], "Imported FEN does not match the visible board")
                pieceTypes[token] = position[square]
            end
            castlingRights, enPassantTarget = rights, ep
            halfmove, fullmove = importedHalf, importedFull
            previous = current
            whiteToMove = side
            positionCounts = {}
            lastPlayedUci = nil
            recordPosition(current)
            awaitingImport = false
            initialAnalysisPending = true
            importStatus = "Position imported"
            print("[Chess] Position imported successfully")
            removeArrow()
        else
            importStatus = "Invalid FEN"
        end
        pendingFen = nil
        continue
    end
    if awaitingImport and success then
        local candidateTypes, completeStartingBoard = {}, true
        for token, square in pairs(current) do
            candidateTypes[token] = pieceAtStart(square)
            if not candidateTypes[token] then completeStartingBoard = false end
        end
        if completeStartingBoard then
            inferMissingPiece(current, candidateTypes)
            local count = 0
            for token in pairs(candidateTypes) do
                if candidateTypes[token] then count = count + 1 end
            end
            if count == 32 then
                pieceTypes = candidateTypes
                previous = current
                whiteToMove = true
                positionCounts = {}
                lastPlayedUci = nil
                recordPosition(current)
                halfmove, fullmove = 0, 1
                castlingRights, enPassantTarget = "KQkq", "-"
                awaitingImport = false
                initialAnalysisPending = true
                analysisRetryAt = tick()
                importStatus = "Starting position detected"
                print("[Chess Detect] Starting position detected")
            end
        end
        if awaitingImport then
            continue
        end
    elseif awaitingImport then
        continue
    end
    if initialAnalysisPending then
        local shouldAnalyze = PLAY_AS == "Any"
            or (PLAY_AS == "White" and whiteToMove)
            or (PLAY_AS == "Black" and not whiteToMove)
        if shouldAnalyze then
            if tick() >= initialAnalysisEarliest and tick() >= analysisRetryAt and recommend(previous) then
                initialAnalysisPending = false
            end
        else
            initialAnalysisPending = false
        end
    end
    if success and not sameSnapshot(previous, current) then
        local stable, confirmed = settleSnapshot(current)
        if stable then
            local moved, capture = {}, false
            local added, removed = {}, {}
            for token, newSquare in pairs(confirmed) do
                local oldSquare = previous[token]
                if oldSquare and oldSquare ~= newSquare then
                    moved[#moved + 1] = {token=token, from=oldSquare, to=newSquare, piece=pieceTypes[token]}
                elseif not oldSquare then
                    added[#added + 1] = {token=token, to=newSquare}
                end
            end
            for token in pairs(previous) do
                if not confirmed[token] then
                    capture = true
                    removed[#removed + 1] = {token=token, from=previous[token], piece=pieceTypes[token]}
                    pieceTypes[token] = nil
                end
            end
            if #moved > 1 then
                previous = confirmed
                if PLAY_AS == "White" then
                    whiteToMove = true
                elseif PLAY_AS == "Black" then
                    whiteToMove = false
                end
                initialAnalysisPending = true
                analysisRetryAt = 0
                moved = {}
            end
            local promotionWasDetected = false
            if #moved == 0 and #added == 1 then
                local promoted = added[1]
                local promotionFrom, promotionColor, promotionKind
                for _, gone in ipairs(removed) do
                    local rank = tonumber(promoted.to:sub(2, 2))
                    if gone.piece and gone.piece:find("Pawn")
                        and (rank == 1 or rank == 8)
                        and (not pendingPromotion or pendingPromotion.to == promoted.to) then
                        promotionFrom = gone.from
                        promotionColor = gone.piece:sub(1, 5)
                        promotionKind = pendingPromotion and pendingPromotion.kind or "Queen"
                        break
                    end
                end
                if promotionFrom then
                    pieceTypes[promoted.token] = promotionColor .. " " .. promotionKind
                    moved[1] = {
                        token=promoted.token,
                        from=promotionFrom,
                        to=promoted.to,
                        piece=promotionColor .. " " .. promotionKind
                    }
                    pendingPromotion = nil
                    promotionWasDetected = true
                end
            end
            if #moved > 0 then
                local move = moved[1]
                local castled = false
                if #moved > 1 then
                    local expectedColor = whiteToMove and "White" or "Black"
                    local matchedTurn = false
                    local kingMove, rookMove
                    for _, candidate in ipairs(moved) do
                        if candidate.piece and candidate.piece:sub(7) == "King" then kingMove = candidate end
                        if candidate.piece and candidate.piece:sub(7) == "Rook" then rookMove = candidate end
                    end
                    if kingMove and rookMove then
                        local validCastle = (kingMove.from == "e1" and (kingMove.to == "g1" or kingMove.to == "c1") and kingMove.piece == "White King")
                            or (kingMove.from == "e8" and (kingMove.to == "g8" or kingMove.to == "c8") and kingMove.piece == "Black King")
                        if validCastle then
                            move = kingMove
                            castled = true
                            matchedTurn = true
                        end
                    end
                    for _, candidate in ipairs(moved) do
                        if not matchedTurn and candidate.piece and candidate.piece:sub(1, 5) == expectedColor then
                            move = candidate
                            matchedTurn = true
                            break
                        end
                    end
                    if not matchedTurn then
                        for _, candidate in ipairs(moved) do
                            if candidate.piece and candidate.piece:sub(7) == "King" then
                                move = candidate
                                break
                            end
                        end
                    end
                end
                if move.piece == "White King" and move.from == "e1" and (move.to == "g1" or move.to == "c1") then
                    castled = true
                elseif move.piece == "Black King" and move.from == "e8" and (move.to == "g8" or move.to == "c8") then
                    castled = true
                end
                local wasPawn = move.piece and (move.piece:find("Pawn") ~= nil or promotionWasDetected)
                if wasPawn then
                    local destinationRank = tonumber(move.to:sub(2, 2))
                    if destinationRank == 1 or destinationRank == 8 then
                        local color = move.piece:sub(1, 5)
                        pieceTypes[move.token] = color .. " Queen"
                        pendingPromotion = nil
                    end
                end
                updateMoveState(move, removed)
                if castled then
                    if move.piece == "White King" then
                        castlingRights = castlingRights:gsub("K", ""):gsub("Q", "")
                    else
                        castlingRights = castlingRights:gsub("k", ""):gsub("q", "")
                    end
                    if castlingRights == "" then castlingRights = "-" end
                end
                local playedUci = move.from .. move.to
                if openingActive and OPENING_NAME ~= "Automatic" then
                    local line = openingLines[OPENING_NAME]
                    local expected = line and line[#moveHistory + 1]
                    if expected ~= playedUci then
                        openingActive = false
                        print("[Chess] Opening line ended: opponent deviated")
                    else
                        moveHistory[#moveHistory + 1] = playedUci
                    end
                end
                whiteToMove = not (move.piece and move.piece:sub(1, 5) == "White")
                if wasPawn or capture then
                    halfmove = 0
                else
                    halfmove = halfmove + 1
                end
                if whiteToMove then
                    fullmove = fullmove + 1
                end
                lastPlayedUci = playedUci
                local repetitionCount, repetitionKey = recordPosition(confirmed)
                if repetitionCount >= 2 and (repetitionKey ~= lastRepetitionWarningKey or repetitionCount ~= lastRepetitionWarningCount) then
                    lastRepetitionWarningKey = repetitionKey
                    lastRepetitionWarningCount = repetitionCount
                    if repetitionCount >= 3 then
                        print("[Chess] Threefold repetition detected; avoiding the previous move")
                    else
                        print("[Chess] Repetition detected; position seen twice")
                    end
                end
                local yourTurn = PLAY_AS == "Any"
                    or (PLAY_AS == "White" and whiteToMove)
                    or (PLAY_AS == "Black" and not whiteToMove)
                if yourTurn then
                    local ready = positionReady(confirmed)
                    local result, errorMessage
                    if ready then
                        local fen = makeFen(confirmed, pieceTypes, whiteToMove, halfmove, fullmove)
                        local avoidMoves = repetitionCount >= 2 and lastPlayedUci and {lastPlayedUci} or nil
                        if fen == lastAnalysisFen and tick() - lastAnalysisAt < 3 then
                            result = nil
                        else
                            lastAnalysisFen = fen
                            lastAnalysisAt = tick()
                            result, errorMessage = bestMove(fen, confirmed, avoidMoves)
                            if result and result.bestmove then
                            else
                            end
                        end
                    else
                    end
                    if result then
                        local fresh, latest = pcall(scan)
                        if not fresh or not sameSnapshot(confirmed, latest) then
                            result = nil
                            removeArrow()
                        end
                    end
                    if result then
                        updateStockfishStatus(true)
                        local fromSquare = result.bestmove:sub(1, 2)
                        local toSquare = result.bestmove:sub(3, 4)
                        local wantedPiece = "Unknown piece"
                        for token, square in pairs(confirmed) do
                            if square == fromSquare and pieceTypes[token] then
                                wantedPiece = pieceTypes[token]
                                break
                            end
                        end
                        local promotion = result.bestmove:sub(5, 5):lower()
                        local suffix = promotionNames[promotion] and " (promote to " .. promotionNames[promotion] .. ")" or ""
                        local message = string.format("Move %s: %s -> %s%s", wantedPiece, fromSquare, toSquare, suffix)
                        removeArrow()
                        local promotionLabel = promotionNames[promotion] and "PROMOTE TO " .. string.upper(promotionNames[promotion]) or nil
                        showArrow(fromSquare, toSquare, Color3.fromRGB(40, 220, 80), promotionLabel)
                        if SECOND_MOVE_ENABLED and result.alternative and result.alternative ~= result.bestmove then
                            local altPromotion = promotionNames[result.alternative:sub(5, 5):lower()]
                            local altLabel = altPromotion and "PROMOTE TO " .. string.upper(altPromotion) or nil
                            showArrow(result.alternative:sub(1, 2), result.alternative:sub(3, 4), Color3.fromRGB(70, 140, 255), altLabel)
                        end
                        local engineName = ENGINE == "maia" and "Maia" or "Stockfish"
                        local backend = result.backend == "opening" and "Opening" or (result.backend == "local" and "Local" or "Render")
                        print("[" .. engineName .. " " .. backend .. "] " .. message)
                    elseif errorMessage then
                        updateStockfishStatus(false, errorMessage)
                        print("[Chess Detect] " .. describeAnalysisError(errorMessage))
                    end
                end
            end
            previous = confirmed
            previousWasStartingPosition = false
        end
    end
end


