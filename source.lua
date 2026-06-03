local CONFIG = {
    Player = {
        TrackJoins = true,
        TrackLeaves = true,
        TrackAdminActions = true,
        MaxNameLength = 20,
    },
    Character = {
        TrackSpawns = true,
        TrackDespawns = true,
        TrackRespawns = true,
    },
    Humanoid = {
        TrackWalkSpeed = {Enabled = true, Threshold = 0.5},
        TrackJumpPower = {Enabled = true, Threshold = 0.5},
        TrackHealth = {Enabled = true, Threshold = 5, TrackDamageSources = true},
        TrackStates = {
            Moving = true,
            Jumping = true,
            Falling = true,
            Swimming = true,
            Seated = true,
            Ragdoll = true,
        },
    },
    Advanced = {
        TrackTeleports = true,
        TrackTools = true,
        TrackChat = true,
        TrackPrivateServers = true,
    },
    Security = {
        ObfuscatePlayerNames = false,
        FilterSensitiveData = true,
    },
    Logging = {
        OutputToConsole = true,
        MaxMessageHistory = 100,
        Cooldown = 0.1,
        TimestampFormat = "%H:%M:%S",
        ColorOutput = true,
    },
}

local Logger = {
    lastLog = {},
    history = {},
}

function Logger:timestamp()
    return os.date(CONFIG.Logging.TimestampFormat)
end

function Logger:canLog(key)
    local now = tick()
    local last = self.lastLog[key] or 0
    if now - last >= CONFIG.Logging.Cooldown then
        self.lastLog[key] = now
        return true
    end
    return false
end

function Logger:formatPlayerName(name)
    if not CONFIG.Security.ObfuscatePlayerNames then return name end
    local maxLen = CONFIG.Player.MaxNameLength
    if #name > maxLen then
        name = name:sub(1, maxLen)
    end
    return name
end

function Logger:filterData(data)
    if not CONFIG.Security.FilterSensitiveData then return data end
    if type(data) == "string" then
        data = data:gsub("%a+%.%a+%.%a+", "[HIDDEN]")
        data = data:gsub("%d+%.%d+%.%d+%.%d+", "[IP]")
        data = data:gsub("[%w%-]+@[%w%-]+%.[%w]+", "[EMAIL]")
    end
    return data
end

function Logger:log(msg, playerName)
    if not CONFIG.Logging.OutputToConsole then return end
    local timestamp = self:timestamp()
    local formatted = string.format("[%s] %s", timestamp, msg)
    if playerName then
        local obfuscated = self:formatPlayerName(playerName)
        formatted = formatted:gsub(playerName, obfuscated)
    end
    formatted = self:filterData(formatted)
    table.insert(self.history, formatted)
    if #self.history > CONFIG.Logging.MaxMessageHistory then
        table.remove(self.history, 1)
    end
    if CONFIG.Logging.ColorOutput then
        print("\27[36m" .. formatted .. "\27[37m")
    end
end

local function checkPrivateServer()
    if not CONFIG.Advanced.TrackPrivateServers then return end
    local jobId = game.JobId
    if jobId and jobId ~= "" then
        if jobId:match("^%d+$") then
            Logger:log("[SERVER] Public server detected")
        else
            Logger:log(string.format("[SERVER] Private server detected (JobId: %s)", jobId))
        end
    else
        Logger:log("[SERVER] Local or Private server context")
    end
end

local Cache = {
    players = {},
    walkSpeed = {},
    jumpPower = {},
    health = {},
    dead = {},
    lastState = {},
    moving = {},
    lastPosition = {},
}

local function setupAdminTracking(player)
    if not CONFIG.Player.TrackAdminActions then return end
    player.Chatted:Connect(function(msg)
        local lowerMsg = msg:lower()
        if lowerMsg:match("kick") or lowerMsg:match("ban") or lowerMsg:match("teleport") or lowerMsg:match("goto") or lowerMsg:match("mgiht") then
            Logger:log(string.format("[ADMIN] %s: %s", player.Name, msg), player.Name)
        end
    end)
end

local function setupMovementTracking(player, hum, root)
    if not CONFIG.Humanoid.TrackStates.Moving then return end
    Cache.moving[player.UserId] = false
    Cache.lastPosition[player.UserId] = root.Position
    
    game:GetService("RunService").Heartbeat:Connect(function()
        if not root or not root.Parent or not hum or hum.Health <= 0 then return end
        local currentPos = root.Position
        local lastPos = Cache.lastPosition[player.UserId]
        if lastPos then
            local dist = (currentPos - lastPos).Magnitude
            local isMoving = dist > 0.2
            if isMoving ~= Cache.moving[player.UserId] then
                if isMoving then
                    Logger:log(string.format("%s started moving", player.Name), player.Name)
                else
                    Logger:log(string.format("%s stopped moving", player.Name), player.Name)
                end
                Cache.moving[player.UserId] = isMoving
            end
        end
        Cache.lastPosition[player.UserId] = currentPos
    end)
end

local function setupHumanoidStates(player, hum)
    Cache.lastState[player.UserId] = {
        Falling = false,
        Swimming = false,
        Seated = false,
    }
    
    game:GetService("RunService").Heartbeat:Connect(function()
        if not hum or hum.Health <= 0 then return end
        
        if CONFIG.Humanoid.TrackStates.Falling then
            local isFalling = hum:GetState() == Enum.HumanoidStateType.Freefall
            if isFalling ~= Cache.lastState[player.UserId].Falling then
                Logger:log(string.format("%s Falling = %s", player.Name, tostring(isFalling)), player.Name)
                Cache.lastState[player.UserId].Falling = isFalling
            end
        end
        
        if CONFIG.Humanoid.TrackStates.Swimming then
            local isSwimming = hum:GetState() == Enum.HumanoidStateType.Swimming
            if isSwimming ~= Cache.lastState[player.UserId].Swimming then
                Logger:log(string.format("%s Swimming = %s", player.Name, tostring(isSwimming)), player.Name)
                Cache.lastState[player.UserId].Swimming = isSwimming
            end
        end
        
        if CONFIG.Humanoid.TrackStates.Seated then
            local isSeated = hum:GetState() == Enum.HumanoidStateType.Seated
            if isSeated ~= Cache.lastState[player.UserId].Seated then
                Logger:log(string.format("%s Seated = %s", player.Name, tostring(isSeated)), player.Name)
                Cache.lastState[player.UserId].Seated = isSeated
            end
        end
    end)
end

local function setupJumpTracking(player, hum, root)
    if not CONFIG.Humanoid.TrackStates.Jumping then return end
    local wasOnGround = true
    
    game:GetService("RunService").Heartbeat:Connect(function()
        if not hum or hum.Health <= 0 or not root then return end
        local yVel = root.AssemblyLinearVelocity.Y
        local isOnGround = hum.FloorMaterial ~= Enum.Material.Air
        if wasOnGround and not isOnGround and yVel > 5 then
            if Logger:canLog("jump_" .. player.UserId) then
                Logger:log(string.format("%s jumped (velocity: %.1f)", player.Name, yVel), player.Name)
            end
        end
        wasOnGround = isOnGround
    end)
end

local function setupDeathTracking(player, char)
    local hum = char:WaitForChild("Humanoid", 5)
    if not hum then return end
    
    hum.Died:Connect(function()
        if not Cache.dead[player.UserId] then
            Cache.dead[player.UserId] = true
            if CONFIG.Character.TrackDespawns then
                Logger:log(string.format("%s DIED", player.Name), player.Name)
            end
        end
    end)
end

local function setupCharacterTracking(player, char)
    setupDeathTracking(player, char)
    local hum = char:WaitForChild("Humanoid", 10)
    local root = char:WaitForChild("HumanoidRootPart", 10)
    
    if hum then
        Cache.dead[player.UserId] = false
        if CONFIG.Humanoid.TrackWalkSpeed.Enabled then
            Cache.walkSpeed[player.UserId] = hum.WalkSpeed
            hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
                local old = Cache.walkSpeed[player.UserId] or 16
                local new = hum.WalkSpeed
                if math.abs(old - new) >= CONFIG.Humanoid.TrackWalkSpeed.Threshold then
                    Logger:log(string.format("%s speed: %.1f -> %.1f", player.Name, old, new), player.Name)
                    Cache.walkSpeed[player.UserId] = new
                end
            end)
        end
        
        if CONFIG.Humanoid.TrackJumpPower.Enabled then
            Cache.jumpPower[player.UserId] = hum.JumpPower
            hum:GetPropertyChangedSignal("JumpPower"):Connect(function()
                local old = Cache.jumpPower[player.UserId] or 50
                local new = hum.JumpPower
                if math.abs(old - new) >= CONFIG.Humanoid.TrackJumpPower.Threshold then
                    Logger:log(string.format("%s jump power: %.1f -> %.1f", player.Name, old, new), player.Name)
                    Cache.jumpPower[player.UserId] = new
                end
            end)
        end
        
        if CONFIG.Humanoid.TrackHealth.Enabled then
            Cache.health[player.UserId] = hum.Health
            hum:GetPropertyChangedSignal("Health"):Connect(function()
                local old = Cache.health[player.UserId] or hum.MaxHealth
                local new = hum.Health
                if math.abs(old - new) >= CONFIG.Humanoid.TrackHealth.Threshold and new > 0 then
                    local diff = new - old
                    local sign = diff > 0 and "+" or ""
                    Logger:log(string.format("%s hp: %.1f -> %.1f (%s%.1f)", player.Name, old, new, sign, diff), player.Name)
                    Cache.health[player.UserId] = new
                end
            end)
        end
        
        setupHumanoidStates(player, hum)
        if root then
            setupJumpTracking(player, hum, root)
            setupMovementTracking(player, hum, root)
        end
    end
    
    if root and CONFIG.Advanced.TrackTeleports then
        local lastPos = root.Position
        game:GetService("RunService").Heartbeat:Connect(function()
            if root and root.Parent then
                local newPos = root.Position
                local dist = (newPos - lastPos).Magnitude
                if dist > 40 and hum.Health > 0 then
                    if Logger:canLog("tp_" .. player.UserId) then
                        Logger:log(string.format("%s teleported %.1f studs", player.Name, dist), player.Name)
                    end
                end
                lastPos = newPos
            end
        end)
    end
    
    if CONFIG.Advanced.TrackTools then
        char.ChildAdded:Connect(function(tool)
            if tool:IsA("Tool") then
                Logger:log(string.format("%s equipped %s", player.Name, tool.Name), player.Name)
            end
        end)
        char.ChildRemoved:Connect(function(tool)
            if tool:IsA("Tool") then
                Logger:log(string.format("%s unequipped %s", player.Name, tool.Name), player.Name)
            end
        end)
    end
end

local function initializePlayer(player)
    if player == game:GetService("Players").LocalPlayer and not CONFIG.Logging.OutputToConsole then return end
    
    Cache.players[player.UserId] = {
        name = player.Name,
        joinTime = tick(),
    }
    Cache.dead[player.UserId] = false
    
    setupAdminTracking(player)
    
    if CONFIG.Advanced.TrackChat then
        player.Chatted:Connect(function(msg)
            msg = Logger:filterData(msg)
            Logger:log(string.format("[CHAT] %s: %s", player.Name, msg), player.Name)
        end)
    end
    
    if player.Character then
        task.spawn(setupCharacterTracking, player, player.Character)
    end
    
    player.CharacterAdded:Connect(function(char)
        if CONFIG.Character.TrackSpawns then
            Logger:log(string.format("%s spawned", player.Name), player.Name)
        end
        setupCharacterTracking(player, char)
    end)
    
    player.CharacterRemoving:Connect(function()
        if CONFIG.Character.TrackDespawns then
            Logger:log(string.format("%s character removed", player.Name), player.Name)
        end
    end)
end

local function trackPlayers()
    local players = game:GetService("Players")
    
    for _, player in ipairs(players:GetPlayers()) do
        task.spawn(initializePlayer, player)
    end
    
    players.PlayerAdded:Connect(function(player)
        if CONFIG.Player.TrackJoins then
            Logger:log(string.format("+ %s (%s) joined", player.Name, player.UserId), player.Name)
        end
        initializePlayer(player)
    end)
    
    players.PlayerRemoving:Connect(function(player)
        if CONFIG.Player.TrackLeaves then
            local data = Cache.players[player.UserId]
            if data and data.joinTime then
                local timePlayed = tick() - data.joinTime
                local minutes = math.floor(timePlayed / 60)
                local seconds = math.floor(timePlayed % 60)
                Logger:log(string.format("- %s left (played: %dm %ds)", player.Name, minutes, seconds), player.Name)
            else
                Logger:log(string.format("- %s left", player.Name), player.Name)
            end
        end
        Cache.players[player.UserId] = nil
        Cache.dead[player.UserId] = nil
    end)
end

local function main()
    Logger:log("Simple Server Logger v2 loaded")
    checkPrivateServer()
    trackPlayers()
    Logger:log("[OK] Tracking initialized for all active instances")
end

local success, err = pcall(main)
if not success then
    warn("Logger fatal error: " .. tostring(err))
end
