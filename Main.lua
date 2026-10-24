
local FLIP_BOARD = false
local SCAN_DELAY = 0.15
local API_URL = "https://rochess-gateway.vercel.app/api/analyze"
local API_KEY = ""
local ANALYSIS_DEPTH = 10
local STRENGTH = "high"
local PLAY_AS = "White" -- "White", "Black", or "Any"
local boardCenters = {}
local arrows = {}
local pendingFen = nil
local enteredFen = ""
local importStatus = "Waiting for a FEN position"
local newGameRequested = false
local promotionNames = {q="Queen", r="Rook", b="Bishop", n="Knight"}

local function removeArrow()
    for _, arrow in ipairs(arrows) do
        arrow.Line:Remove()
        arrow.Head:Remove()
    end
    arrows = {}
end

local function showArrow(fromSquare, toSquare, color)
    local fromPoint, toPoint = boardCenters[fromSquare], boardCenters[toSquare]
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
    arrowLine.Visible = true
    local arrowHead = Drawing.new("Triangle")
    arrowHead.PointA, arrowHead.PointB, arrowHead.PointC = tip, left, right
    arrowHead.Color = color
    arrowHead.Filled = true
    arrowHead.Visible = true
    arrows[#arrows + 1] = {Line = arrowLine, Head = arrowHead}
end

if UI and UI.AddTab then
    UI.AddTab("RoChess AI", function(tab)
        local settings = tab:Section("Game Settings", "Left")
        settings:Combo("chess_play_as", "Play as", {"White", "Black", "Any"}, 0, function(_, text)
            PLAY_AS = text
        end)
        settings:Combo("chess_strength", "Strength", {"Low", "Medium", "High"}, 2, function(_, text)
            STRENGTH = string.lower(text)
        end)
        settings:Text("Select your color before playing.")
        settings:Text("Best move: green arrow")
        settings:Button("New Game", function()
            newGameRequested = true
        end)
        local position = tab:Section("Position Import", "Right")
        local fenInput = position:InputText("chess_fen", "FEN position", "", function(text)
            enteredFen = text or ""
            pendingFen = text
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
    local fields = {}
    for field in fen:gmatch("[^%s]+") do fields[#fields + 1] = field end
    assert(#fields >= 2, "Invalid FEN")
    local result, rank = {}, 8
    for row in fields[1]:gmatch("[^/]+") do
        local file = 1
        for char in row:gmatch(".") do
            local count = tonumber(char)
            if count then
                file = file + count
            else
                local names = {p="Pawn", n="Knight", b="Bishop", r="Rook", q="Queen", k="King"}
                local color = char == char:upper() and "White" or "Black"
                result[string.char(96 + file) .. tostring(rank)] = color .. " " .. names[char:lower()]
                file = file + 1
            end
        end
        rank = rank - 1
    end
    return result, fields[2] == "w"
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

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

local function pieceCode(pieceType)
    local color, kind = pieceType:match("^(%a+) (.+)$")
    local codes = {Pawn="p", Knight="n", Bishop="b", Rook="r", Queen="q", King="k"}
    local code = codes[kind]
    return color == "White" and string.upper(code) or code
end

local function getBoard()
    local gui = child(player, "PlayerGui")
    local board = child(child(child(gui, "ChessUI"), "Root"), "Board")
    local squares, pieces = child(board, "Squares"), child(board, "Pieces")
    assert(squares and pieces, "Chess board not found. Open RoChess first.")
    return squares, pieces
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
            local p = square.AbsolutePosition
            squares[#squares + 1] = {index=index, x=p.X, y=p.Y}
            byIndex[index] = squares[#squares]
        end
    end
    assert(#squares == 64, "Expected 64 squares named S1 through S64.")
    local spacing = math.huge
    for i = 1, #squares do
        for j = i + 1, #squares do
            local dx, dy = squares[i].x - squares[j].x, squares[i].y - squares[j].y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1 and d < spacing then
                spacing = d
            end
        end
    end
    assert(spacing < math.huge and spacing >= 4, "Could not calculate board spacing.")
    boardCenters = {}
    for _, square in ipairs(squares) do
        local centerX = square.x + spacing / 2
        local centerY = square.y + spacing / 2
        boardCenters[squareName(square.index)] = Vector2.new(
            centerX,
            centerY
        )
    end
    local tokens, occupied = {}, {}
    for _, piece in ipairs(pieceFolder:GetChildren()) do
        if piece.ClassName == "ImageLabel" or piece.ClassName == "ImageButton" then
            local p, nearest, best = piece.AbsolutePosition, nil, math.huge
            for _, square in ipairs(squares) do
                local dx, dy = p.X - square.x, p.Y - square.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d < best then
                    nearest, best = square.index, d
                end
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

local function makeFen(snapshot, pieceTypes, whiteToMove, halfmove, fullmove)
    local board = {}
    for token, square in pairs(snapshot) do
        if pieceTypes[token] then board[square] = pieceCode(pieceTypes[token]) end
    end
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
    return table.concat(ranks, "/") .. " " .. (whiteToMove and "w" or "b") .. " - - " .. tostring(halfmove) .. " " .. tostring(fullmove)
end

local function askStockfish(fen)
    local body = HttpService:JSONEncode({fen=fen, strength=STRENGTH})
    local headers = nil
    if API_KEY ~= "" then
        headers = { ["X-API-Key"] = API_KEY }
    end
    local raw = httppost(API_URL, body, "application/json", headers)
    if raw == "" then return nil, "No response from the public Render API" end
    local ok, result = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(result) ~= "table" then return nil, "Invalid API response: " .. tostring(raw) end
    if not result.bestmove then return nil, result.detail or "API returned no best move" end
    return result
end

local ok, previous = pcall(scan)
if not ok then print("[Chess Detect] Initialization failed: " .. tostring(previous)); return end
local pieceTypes, known = {}, 0
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

local whiteToMove = startedAfterOpening and (PLAY_AS == "White") or (not startedAfterOpening)
local halfmove, fullmove = 0, startedAfterOpening and 2 or 1
local initialAnalysisPending = true

local function recommend(snapshot)
    local fen = makeFen(snapshot, pieceTypes, whiteToMove, halfmove, fullmove)
    local result = askStockfish(fen)
    if not result or not result.bestmove then return end
    local fromSquare, toSquare = result.bestmove:sub(1, 2), result.bestmove:sub(3, 4)
    local wantedPiece = "Unknown piece"
    for token, square in pairs(snapshot) do
        if square == fromSquare and pieceTypes[token] then
            wantedPiece = pieceTypes[token]
            break
        end
    end
    local promotion = result.bestmove:sub(5, 5):lower()
    local suffix = promotionNames[promotion] and " (promote to " .. promotionNames[promotion] .. ")" or ""
    local message = string.format("Move %s: %s -> %s%s", wantedPiece, fromSquare, toSquare, suffix)
    removeArrow()
    showArrow(fromSquare, toSquare, Color3.fromRGB(40, 220, 80))
    local backend = result.backend == "local" and "Local" or "Render"
    print("[Stockfish " .. backend .. "] " .. message)
end

while true do
    if UI and UI.GetValue then
        local selected = UI.GetValue("chess_play_as")
        if selected == 0 then
            PLAY_AS = "White"
        elseif selected == 1 then
            PLAY_AS = "Black"
        elseif selected == 2 then
            PLAY_AS = "Any"
        end
    end
    wait(SCAN_DELAY)
    local success, current = pcall(scan)
    if newGameRequested and success then
        pieceTypes = {}
        for token, square in pairs(current) do
            pieceTypes[token] = pieceAtStart(square)
        end
        previous = current
        whiteToMove = true
        halfmove, fullmove = 0, 1
        awaitingImport = false
        initialAnalysisPending = true
        pendingFen = nil
        importStatus = "New game ready"
        removeArrow()
        newGameRequested = false
        continue
    end
    if pendingFen and success then
        local imported, position, side = pcall(fenPieces, pendingFen)
        if imported then
            for token, square in pairs(current) do
                pieceTypes[token] = position[square]
            end
            previous = current
            whiteToMove = side
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
    if awaitingImport then
        continue
    end
    if initialAnalysisPending then
        local shouldAnalyze = PLAY_AS == "Any"
            or (PLAY_AS == "White" and whiteToMove)
            or (PLAY_AS == "Black" and not whiteToMove)
        if shouldAnalyze then recommend(previous) end
        initialAnalysisPending = false
    end
    if success and not sameSnapshot(previous, current) then
        wait(SCAN_DELAY)
        local stable, confirmed = pcall(scan)
        if stable and sameSnapshot(current, confirmed) then
            local moved, capture = {}, false
            for token, newSquare in pairs(confirmed) do
                local oldSquare = previous[token]
                if oldSquare and oldSquare ~= newSquare then moved[#moved + 1] = {token=token, from=oldSquare, to=newSquare, piece=pieceTypes[token]} end
            end
            for token in pairs(previous) do
                if not confirmed[token] then
                    capture = true
                    pieceTypes[token] = nil
                end
            end
            if #moved > 0 then
                local move = moved[1]
                if PLAY_AS == "White" or PLAY_AS == "Black" then
                    local wantedColor = PLAY_AS == "White" and "Black" or "White"
                    for _, candidate in ipairs(moved) do
                        if candidate.piece and candidate.piece:sub(1, 5) == wantedColor then
                            move = candidate
                            break
                        end
                    end
                    if not (move.piece and move.piece:sub(1, 5) == wantedColor) then
                        previous = confirmed
                        continue
                    end
                end
                local wasPawn = move.piece and move.piece:find("Pawn") ~= nil
                if wasPawn then
                    local destinationRank = tonumber(move.to:sub(2, 2))
                    if destinationRank == 1 or destinationRank == 8 then
                        local color = move.piece:sub(1, 5)
                        pieceTypes[move.token] = color .. " Queen"
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
                local yourTurn = PLAY_AS == "Any"
                    or (PLAY_AS == "White" and whiteToMove)
                    or (PLAY_AS == "Black" and not whiteToMove)
                if yourTurn then
                    local fen = makeFen(confirmed, pieceTypes, whiteToMove, halfmove, fullmove)
                    local result, errorMessage = askStockfish(fen)
                    if result then
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
                        showArrow(fromSquare, toSquare, Color3.fromRGB(40, 220, 80))
                        local backend = result.backend == "local" and "Local" or "Render"
                        print("[Stockfish " .. backend .. "] " .. message)
                    end
                end
            end
            previous = confirmed
        end
    end
end

