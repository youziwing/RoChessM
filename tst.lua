
local FLIP_BOARD = false
local ROCHESS_SESSION = tostring(tick()) .. ":" .. tostring(math.random(1, 1000000000))
_G.__ROCHESS_SESSION = ROCHESS_SESSION
local SCAN_DELAY = 0.15
local API_URL = "https://vercel-gateway-two-orpin.vercel.app/api/analyze"
local STATUS_URL = "https://vercel-gateway-two-orpin.vercel.app/api/status"
local STATUS_INTERVAL = 10
local API_KEY = ""
local ANALYSIS_DEPTH = 10
local STRENGTH = "high"
local SECOND_MOVE_ENABLED = true
local TARGET_ELO = nil
local OPENING_NAME = "Automatic"
local openingActive = false
local moveHistory = {}
local openingRefreshRequested = false
local openingLines = {
    ["Italian Game"] = {"e2e4", "e7e5", "g1f3", "b8c6", "f1c4"},
    ["Sicilian Defense"] = {"e2e4", "c7c5", "g1f3", "d7d6"},
    ["French Defense"] = {"e2e4", "e7e6", "d2d4", "d7d5"},
    ["Caro-Kann Defense"] = {"e2e4", "c7c6", "d2d4", "d7d5"},
    ["Queen's Gambit"] = {"d2d4", "d7d5", "c2c4"},
    ["King's Indian Defense"] = {"d2d4", "g8f6", "c2c4", "g7g6"},
    ["English Opening"] = {"c2c4", "e7e5", "b1c3", "g8f6"},
}
local PLAY_AS = "White" -- "White", "Black", or "Any"
local AUTO_DETECT_COLOR = true
local orientationChanged = false
local boardCenters = {}
local boardSquareObjects = {}
local arrows = {}
local pendingFen = nil
local enteredFen = ""
local importStatus = "Waiting for a FEN position"
local newGameRequested = false
local promotionNames = {q="Queen", r="Rook", b="Bishop", n="Knight"}
local lastStatusCheck = 0
local lastAnnouncement = nil
local castlingRights = "KQkq"
local enPassantTarget = "-"

local function removeArrow()
    for _, arrow in ipairs(arrows) do
        arrow.Line:Remove()
        arrow.Head:Remove()
    end
    arrows = {}
end

local function showArrow(fromSquare, toSquare, color)
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
    local fromPoint, toPoint = liveCenter(fromSquare), liveCenter(toSquare)
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
            applyPlayAs(text)
        end)
        settings:Combo("chess_strength", "Strength", {"Low", "Medium", "High"}, 2, function(_, text)
            STRENGTH = string.lower(text)
        end)
        settings:Combo("chess_second_move", "Second best move", {"Off", "On"}, 1, function(_, text)
            SECOND_MOVE_ENABLED = text == "On"
        end)
        settings:Combo("chess_opening", "Opening", {"Automatic", "Italian Game", "Sicilian Defense", "French Defense", "Caro-Kann Defense", "Queen's Gambit", "King's Indian Defense", "English Opening"}, 0, function(_, text)
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
            local value = tonumber(text)
            if value then
                TARGET_ELO = math.max(800, math.min(3000, math.floor(value + 0.5)))
                print("[Chess] Target Elo set to " .. tostring(TARGET_ELO) .. " (applies to the next analysis)")
            else
                TARGET_ELO = nil
                print("[Chess] Target Elo cleared; using preset strength")
            end
        end)
        settings:Text("Target Elo overrides the preset strength.")
        settings:Text("Select your color before playing.")
        settings:Text("Best move: green arrow")
        settings:Button("New Game", function()
            newGameRequested = true
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
local function getBoard()
    if cachedSquareFolder and cachedPieceFolder then return cachedSquareFolder, cachedPieceFolder end
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
    local squares = cachedSquareFolder
    local coords = squares and squares.Parent and squares.Parent:FindFirstChild("Coords")
    local rank1 = coords and coords:FindFirstChild("Rank1")
    local file1 = coords and coords:FindFirstChild("File1")
    if not rank1 or not file1 then return nil end
    local ok, rankText, fileText = pcall(function()
        return tostring(rank1.Text), tostring(file1.Text):lower()
    end)
    if not ok then return nil end
    if rankText == "8" and fileText == "a" then return "White" end
    if rankText == "1" and fileText == "h" then return "Black" end
    return nil
end

local function applyPlayAs(color)
    if color ~= "White" and color ~= "Black" and color ~= "Any" then return end
    local oldColor = PLAY_AS
    PLAY_AS = color
    -- The RoChess square objects already move with the board orientation.
    -- Do not reverse their chess coordinates a second time.
    FLIP_BOARD = false
    if oldColor ~= PLAY_AS then
        orientationChanged = true
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
    local rights = castlingRights == "" and "-" or castlingRights
    return table.concat(ranks, "/") .. " " .. (whiteToMove and "w" or "b") .. " " .. rights .. " " .. enPassantTarget .. " " .. tostring(halfmove) .. " " .. tostring(fullmove)
end
local function askStockfish(fen, avoidMoves)
    local request = {fen=fen, strength=STRENGTH}
    if SECOND_MOVE_ENABLED then request.include_alternative = true end
    if TARGET_ELO then request.target_elo = TARGET_ELO end
    if avoidMoves and #avoidMoves > 0 then request.avoid_moves = avoidMoves end
    local body = HttpService:JSONEncode(request)
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

local function openingMove(snapshot)
    if not openingActive or OPENING_NAME == "Automatic" then return nil end
    local line = openingLines[OPENING_NAME]
    local expected = line and line[#moveHistory + 1]
    if not expected then return nil end
    local fromSquare, toSquare = expected:sub(1, 2), expected:sub(3, 4)
    local hasSource = false
    for _, square in pairs(snapshot) do
        if square == fromSquare then hasSource = true break end
    end
    if not hasSource then
        openingActive = false
        print("[Chess] Opening line ended: move is not legal in the current position")
        return nil
    end
    return expected
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
local pendingPromotion = nil
local analysisRetryAt = 0
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
    removeArrow()
end

local function updateStockfishStatus(online, detail)
    if online == stockfishOnline then
        return
    end
    stockfishOnline = online
    if online then
        print("[Stockfish] service is back online")
        pcall(function() notify("Stockfish", "Service is back online", 5) end)
    else
        local message = "Script is currently down: Stockfish service unavailable"
        if detail and tostring(detail) ~= "" then
            message = message .. " (" .. tostring(detail) .. ")"
        end
        print("[Stockfish] " .. message)
        pcall(function() notify("Stockfish", message, 8) end)
    end
end

local function recommend(snapshot)
    local fen = makeFen(snapshot, pieceTypes, whiteToMove, halfmove, fullmove)
    local result, errorMessage = bestMove(fen, snapshot)
    if not result or not result.bestmove then
        updateStockfishStatus(false, errorMessage)
        print("[Chess Detect] Script is currently down: Stockfish unavailable - " .. tostring(errorMessage or "No best move returned"))
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
    showArrow(fromSquare, toSquare, Color3.fromRGB(40, 220, 80))
    if SECOND_MOVE_ENABLED and result.alternative then
        showArrow(result.alternative:sub(1, 2), result.alternative:sub(3, 4), Color3.fromRGB(70, 140, 255))
    end
    local backend = result.backend == "opening" and "Opening" or (result.backend == "local" and "Local" or "Render")
    print("[Stockfish " .. backend .. "] " .. message)
    return true
end

while _G.__ROCHESS_SESSION == ROCHESS_SESSION do
    checkAnnouncement()
    if AUTO_DETECT_COLOR then
        local detected = detectPlayAs()
        if detected and detected ~= PLAY_AS then
            applyPlayAs(detected)
            print("[Chess Detect] Automatically detected player color: " .. PLAY_AS)
        end
    elseif UI and UI.GetValue then
        local selected = UI.GetValue("chess_play_as")
        if selected == 0 then
            applyPlayAs("White")
        elseif selected == 1 then
            applyPlayAs("Black")
        elseif selected == 2 then
            applyPlayAs("Any")
        end
    end
    wait(SCAN_DELAY)
    local success, current = pcall(scan)
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
        wait(SCAN_DELAY)
        local stable, confirmed = pcall(scan)
        if stable and sameSnapshot(current, confirmed) then
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
                if #moved > 1 then
                    for _, candidate in ipairs(moved) do
                        if candidate.piece and candidate.piece:sub(7) == "King" then
                            move = candidate
                            break
                        end
                    end
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
                local yourTurn = PLAY_AS == "Any"
                    or (PLAY_AS == "White" and whiteToMove)
                    or (PLAY_AS == "Black" and not whiteToMove)
                if yourTurn then
                    local fen = makeFen(confirmed, pieceTypes, whiteToMove, halfmove, fullmove)
                    local result, errorMessage = bestMove(fen, confirmed)
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
                        showArrow(fromSquare, toSquare, Color3.fromRGB(40, 220, 80))
                        if SECOND_MOVE_ENABLED and result.alternative then
                            showArrow(result.alternative:sub(1, 2), result.alternative:sub(3, 4), Color3.fromRGB(70, 140, 255))
                        end
                        local backend = result.backend == "opening" and "Opening" or (result.backend == "local" and "Local" or "Render")
                        print("[Stockfish " .. backend .. "] " .. message)
                    elseif errorMessage then
                        updateStockfishStatus(false, errorMessage)
                        print("[Chess Detect] Script is currently down: Stockfish unavailable - " .. tostring(errorMessage))
                    end
                end
            end
            previous = confirmed
            previousWasStartingPosition = false
        end
    end
end

