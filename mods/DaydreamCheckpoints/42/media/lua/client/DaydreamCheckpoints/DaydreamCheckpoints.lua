--=====================================================================--
-- Daydream Checkpoints — sleep sets a checkpoint, death rewinds the day
--
-- In-game half of the system. Detects waking from sleep, forces a game
-- save, then asks the companion watcher (a separate process outside the
-- Lua sandbox) to snapshot the save folder. The watcher and this mod
-- talk through small JSON files in Zomboid/Lua/ — the one directory
-- mod Lua may read and write.
--
-- Singleplayer only.
--=====================================================================--

local DEBUG = false                -- true = print progress to console.txt
local SAVE_DELAY_MS = 4000         -- let the wake-up fade settle first
local ACK_TIMEOUT_MS = 20000       -- give up waiting for the watcher
local RESTORE_ACK_TIMEOUT_MS = 240000 -- restore includes waiting for save unload
local MENU_MARKER_EVERY_MS = 2000  -- heartbeat that tells the watcher "game is at the menu"
local NIGHTMARE_DELAY_MS = 3500    -- pause after loading before the nightmare line
local REQUEST_FILE = "daydream_request.json"
local ACK_FILE = "daydream_ack.json"
local MENU_MARKER_FILE = "daydream_menu.txt"
-- The death memory lives OUTSIDE the save, because the restore rewinds
-- the save to before the death happened - the save itself can't remember
-- dying. This file in Zomboid/Lua/ carries it across the reload.
local NIGHTMARE_FILE = "daydream_nightmare.json"
-- Exiting to the main menu reloads the ENTIRE Lua environment (every mod's
-- files re-execute from scratch), which wipes plain Lua locals the instant
-- exitToMenu() is called - well before the watcher has even started the
-- restore. So the in-flight restore is tracked on disk, not in memory,
-- and picked back up once the reloaded Lua notices this file.
local PENDING_RESTORE_FILE = "daydream_pending_restore.json"
local MODDATA_KEY = "DaydreamCheckpoints"

local function dbg(msg)
    if DEBUG then print("[DaydreamCheckpoints] " .. msg) end
end

--=====================================================================--
-- Options (Options -> Mods -> Daydream Checkpoints)
--=====================================================================--

local optEnabled, optMinDays

if PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create then
    pcall(function()
        local opts = PZAPI.ModOptions:create("DaydreamCheckpoints", "Daydream Checkpoints")
        optEnabled = opts:addTickBox(
            "enabled",
            "Checkpoint when waking from sleep",
            true,
            "Waking up saves the game and snapshots the save folder as a checkpoint."
        )
        optMinDays = opts:addSlider(
            "minDays",
            "Minimum in-game days between checkpoints",
            0, 14, 1, 0,
            "0 = checkpoint on every sleep."
        )
    end)
end

local function optionValue(opt, default)
    if not opt or not opt.getValue then return default end
    local ok, v = pcall(opt.getValue, opt)
    if ok and v ~= nil then return v end
    return default
end

--=====================================================================--
-- Small helpers
--=====================================================================--

local function isSingleplayerInWorld()
    if isClient() or isServer() then return false end
    if not getWorld() then return false end
    return getPlayer() ~= nil
end

local function currentSaveSlot()
    local world = getWorld()
    if not world then return nil, nil end
    return world:getGameMode(), world:getWorld()
end

local function ingameDayNumber()
    local gt = getGameTime()
    if not gt then return 0 end
    local ok, hours = pcall(function() return gt:getWorldAgeHours() end)
    if not ok or not hours then return 0 end
    return math.floor(hours / 24) + 1
end

-- Escape a string for embedding in a JSON value.
local function jsonEscape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", " ")
    return s
end

-- Pull a string field out of a flat one-line JSON object. Good enough
-- for the fixed messages our watcher writes; not a general parser.
local function jsonField(raw, key)
    return raw:match('"' .. key .. '"%s*:%s*"(.-)"')
end

local function jsonBoolField(raw, key)
    local v = raw:match('"' .. key .. '"%s*:%s*(%a+)')
    if v == "true" then return true end
    if v == "false" then return false end
    return nil
end

local function readWholeFile(name)
    local reader = getFileReader(name, false)
    if not reader then return nil end
    local parts = {}
    while true do
        local line = reader:readLine()
        if line == nil then break end
        table.insert(parts, line)
    end
    reader:close()
    return table.concat(parts, "\n")
end

-- This build's HaloTextHelper only reliably exposes addText(character,
-- text) - the colored overloads changed signature in B42 unstable, so
-- keep it plain and fall back to speech if even that fails.
local function notify(msg)
    dbg("notify: " .. msg)
    local player = getPlayer()
    if not player then return end
    local shown = false
    if HaloTextHelper and HaloTextHelper.addText then
        shown = pcall(HaloTextHelper.addText, player, msg)
    end
    if not shown then
        pcall(function() player:Say(msg) end)
    end
end

-- Character speech bubble (in-world flavor, distinct from the halo notify).
local function say(line)
    local player = getPlayer()
    if not player or not line then return end
    pcall(function() player:Say(line) end)
end

local function pickRandom(pool)
    return pool[ZombRand(#pool) + 1]
end

--=====================================================================--
-- Flavor text
--=====================================================================--

-- Said on waking from sleep, when a checkpoint is taken. Lore-friendly:
-- the character marking the day in their mind, not "game saved".
local SLEEP_LINES = {
    "A new day. I'll remember waking up like this.",
    "Slept alright. This moment feels worth holding onto.",
    "Morning. If it all goes wrong, let me come back to here.",
    "Another dawn survived. I won't forget this one.",
    "Rested. Whatever happens today, this is where I start over.",
    "I could get used to waking up in one piece.",
    "New morning. Let this be the one I remember.",
}

-- Nightmare lines keyed by death cause, recounted on waking after a
-- rewind. Kept here (with the other flavor text) so the tick handler
-- that plays them can see the table.
local NIGHTMARE = {
    zombie = {
        "I dreamt they got me. Teeth at my throat, the cold... God. It felt so real.",
        "A nightmare - dragged down by dead hands, biting, tearing. I can still feel it.",
        "They swarmed me in the dream. I felt myself go under. Never again.",
    },
    bite = {
        "The dream again: the bite, the fever, feeling myself turn. I woke up screaming inside.",
        "I dreamt of the wound going bad. Watching my own hands grey over. Just a dream. Just a dream.",
    },
    infection = {
        "Fever dreams. I felt the sickness take me, felt myself slip away. It was so vivid.",
        "In the nightmare the infection won. I remember dying slow. I won't let that happen.",
    },
    fire = {
        "I dreamt of burning. The heat, the smoke, no way out. I can still smell it.",
        "Fire in the dream - I felt it eat through me. I jolted awake half expecting flames.",
    },
    cold = {
        "I dreamt of freezing to death, the cold creeping in until I couldn't move. Horrible.",
        "The nightmare was all ice - shivering, then nothing. I need to stay warm.",
    },
    hunger = {
        "I dreamt of starving, of my body just giving out. I have to eat.",
        "Hollow, wasting away in the dream until the dark took me. I won't ignore my stomach again.",
    },
    thirst = {
        "I dreamt my throat closed up, dying of thirst in the heat. I need water.",
        "The nightmare was all dust and dry lungs. I can't neglect water like that.",
    },
    wound = {
        "I dreamt I bled out, the world going soft and far away. I felt it happen.",
        "A dream of a wound that wouldn't close, of fading. It shook me awake.",
    },
    unknown = {
        "I had the worst nightmare - I dreamt I died out here. It felt real enough to taste.",
        "A terrible dream. I remember dying. I woke up glad to be breathing.",
        "I dreamt this was all over, that I didn't make it. Never want to feel that again.",
    },
}

--=====================================================================--
-- Watcher protocol: write one request, then poll for the matching ack.
--=====================================================================--

local pendingAck = nil -- { id = ..., deadlineAtMs = ... }

local function writeRequest(action, label)
    local gameMode, worldName = currentSaveSlot()
    if not gameMode or not worldName then return nil end

    local id = tostring(getTimestampMs())
    local line = string.format(
        '{"id":"%s","action":"%s","gameMode":"%s","worldName":"%s","label":"%s"}',
        jsonEscape(id), jsonEscape(action), jsonEscape(gameMode),
        jsonEscape(worldName), jsonEscape(label or "")
    )

    local writer = getFileWriter(REQUEST_FILE, true, false)
    if not writer then
        dbg("could not open request file for writing")
        return nil
    end
    writer:writeln(line)
    writer:close()
    dbg("request written: " .. line)
    return id
end

local function checkAck()
    if not pendingAck then return end

    local raw = readWholeFile(ACK_FILE)
    if raw and raw ~= "" and jsonField(raw, "id") == pendingAck.id then
        local ok = jsonBoolField(raw, "ok")
        local message = jsonField(raw, "message") or ""
        dbg("ack received: ok=" .. tostring(ok) .. " message=" .. message)
        if ok then
            say(pickRandom(SLEEP_LINES))
        else
            notify("Checkpoint failed: " .. message)
        end
        pendingAck = nil
        return
    end

    if getTimestampMs() > pendingAck.deadlineAtMs then
        dbg("ack timeout - watcher not running?")
        notify("Checkpoint watcher isn't responding - is it running?")
        pendingAck = nil
    end
end

--=====================================================================--
-- Checkpoint on wake
--=====================================================================--

local wasAsleep = {}
local pendingSaveAtMs = nil

local function doCheckpoint()
    if not optionValue(optEnabled, true) then return end
    if not isSingleplayerInWorld() then return end
    local player = getPlayer()
    if not player or player:isDead() then return end

    local day = ingameDayNumber()

    -- Cadence gate, persisted inside the save (and therefore inside
    -- every checkpoint too - restoring an old day restores its schedule).
    local minDays = tonumber(optionValue(optMinDays, 0)) or 0
    local store = ModData.getOrCreate(MODDATA_KEY)
    local lastDay = tonumber(store.lastCheckpointDay)
    if minDays > 0 and lastDay and (day - lastDay) < minDays then
        dbg("cadence gate: day=" .. day .. " lastDay=" .. tostring(lastDay) .. " minDays=" .. minDays)
        return
    end

    -- Set the markers BEFORE saving so they're stored inside the save,
    -- and therefore inside the snapshot the watcher is about to take.
    local prevLastDay, prevHas = store.lastCheckpointDay, store.hasCheckpoint
    store.lastCheckpointDay = day
    store.hasCheckpoint = true

    dbg("checkpoint: saving game (day " .. day .. ")")
    local saved = pcall(saveGame)
    if not saved then
        store.lastCheckpointDay, store.hasCheckpoint = prevLastDay, prevHas
        notify("Checkpoint failed: game save errored.")
        return
    end

    local id = writeRequest("backup", "Day " .. day)
    if id then
        pendingAck = { id = id, deadlineAtMs = getTimestampMs() + ACK_TIMEOUT_MS }
    end
end

local function onPlayerUpdate(player)
    if player:isDead() then return end
    local idx = player:getPlayerNum()
    local asleep = player:isAsleep()
    if wasAsleep[idx] and not asleep then
        dbg("wake-up detected, checkpoint in " .. SAVE_DELAY_MS .. "ms")
        pendingSaveAtMs = getTimestampMs() + SAVE_DELAY_MS
    end
    wasAsleep[idx] = asleep
end

local nightmareShownFor = nil
local nightmareDueAtMs = nil
local nightmarePendingCause = nil

-- Called once a world is loaded; if a nightmare memory is waiting,
-- schedule the character to recount it after a short beat.
local function pickupNightmare()
    local raw = readWholeFile(NIGHTMARE_FILE)
    if not raw or raw == "" then return end
    local cause = jsonField(raw, "cause") or "unknown"
    local ts = jsonField(raw, "ts") or ""
    if nightmareShownFor == ts then return end  -- already handled this one
    nightmareShownFor = ts
    nightmareDueAtMs = getTimestampMs() + NIGHTMARE_DELAY_MS
    nightmarePendingCause = cause
    -- empty the file so a later fresh load doesn't replay it
    local w = getFileWriter(NIGHTMARE_FILE, true, false)
    if w then w:writeln(""); w:close() end
    dbg("nightmare queued: " .. cause)
end

local function onTick()
    if pendingSaveAtMs and getTimestampMs() >= pendingSaveAtMs then
        pendingSaveAtMs = nil
        doCheckpoint()
    end
    if pendingAck then
        checkAck()
    end
    if nightmareDueAtMs and getTimestampMs() >= nightmareDueAtMs then
        nightmareDueAtMs = nil
        local pool = NIGHTMARE[nightmarePendingCause] or NIGHTMARE.unknown
        say(pickRandom(pool))
    end
end

-- On entering a world, check for a waiting nightmare (set if we just
-- rewound from a death).
local function onGameStart()
    nightmareShownFor = nil
    pickupNightmare()
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
Events.OnTick.Add(onTick)
Events.OnGameStart.Add(onGameStart)

--=====================================================================--
-- Death cause -> nightmare
--
-- Work out how the character died, so the survivor can "remember" it as
-- a nightmare after the rewind. The cause is written to a file OUTSIDE
-- the save (the restore rewinds the save to before death, so it can't
-- carry the memory itself) and read back after the checkpoint loads.
--=====================================================================--

-- Each probe is independently guarded, so an API mismatch on one signal
-- (common on B42 unstable) just skips that signal instead of aborting
-- the whole classification.
local function probe(fn, default)
    local ok, v = pcall(fn)
    if ok then return v end
    return default
end

-- Inspect body state at death to classify the cause. Ordered most- to
-- least-specific; returns a key into the NIGHTMARE table.
local function classifyDeath(player)
    local bd = probe(function() return player:getBodyDamage() end)
    if not bd then return "unknown" end

    if probe(function() return player:isOnFire() end, false) then return "fire" end
    if probe(function() return bd:isInfected() end, false) then return "infection" end

    -- scan body parts for the worst injury present
    local bitten, deepWound, bleeding = false, false, false
    probe(function()
        local parts = bd:getBodyParts()
        for i = 0, parts:size() - 1 do
            local p = parts:get(i)
            if p:bitten() then bitten = true end
            if p:deepWounded() or p:haveBullet() then deepWound = true end
            if (p:getBleedingTime() or 0) > 0 then bleeding = true end
        end
    end)
    if bitten then return "bite" end

    local temp = probe(function() return bd:getTemperature() end)
    if temp and temp < 36 then return "cold" end

    local hunger = probe(function() return player:getStats():getHunger() end, 0)
    if hunger and hunger >= 0.95 then return "hunger" end
    local thirst = probe(function() return player:getStats():getThirst() end, 0)
    if thirst and thirst >= 0.95 then return "thirst" end

    if deepWound or bleeding then return "wound" end

    return "zombie"  -- most open-world deaths are zombies
end

-- Cause captured at death; only committed to the nightmare file if the
-- player actually chooses to rewind (a respawn shouldn't spawn a dream).
local lastDeathCause = nil

local function writeNightmare(cause)
    local line = string.format('{"cause":"%s","ts":"%s"}',
        jsonEscape(cause), jsonEscape(tostring(getTimestampMs())))
    local writer = getFileWriter(NIGHTMARE_FILE, true, false)
    if not writer then return end
    writer:writeln(line)
    writer:close()
    dbg("nightmare recorded: " .. cause)
end

local function onPlayerDeath(player)
    if isClient() then return end
    if not player or player:getPlayerNum() ~= 0 then return end
    lastDeathCause = classifyDeath(player)
    dbg("death cause captured: " .. lastDeathCause)
end

Events.OnPlayerDeath.Add(onPlayerDeath)

--=====================================================================--
-- Restore on death
--
-- Death screen gains a "Wake up at last checkpoint" button. Clicking it
-- writes a restore request and exits to the main menu (mirroring the
-- vanilla Exit button). While the game sits at the menu, our front-end
-- tick writes a heartbeat file - that is how the watcher knows the save
-- is unloaded and it's safe to swap folders. When the watcher's ack
-- arrives, a dialog tells the player to load the save again.
--=====================================================================--

local WAKE_LABEL = "Wake up at last checkpoint"
local pendingRestoreId = nil
local restoreDeadlineAtMs = nil
local restoreStarted = false

local function hasCheckpoint()
    local ok, has = pcall(function()
        return ModData.getOrCreate(MODDATA_KEY).hasCheckpoint == true
    end)
    return ok and has
end

-- Remembered so the menu side can auto-load the exact save we restored.
-- Populated either fresh (same Lua session) or from disk after a reload.
local restoreGameMode, restoreWorldName = nil, nil

local function writePendingRestore(id, gameMode, worldName)
    local line = string.format('{"id":"%s","gameMode":"%s","worldName":"%s"}',
        jsonEscape(id), jsonEscape(gameMode), jsonEscape(worldName))
    local writer = getFileWriter(PENDING_RESTORE_FILE, true, false)
    if not writer then return false end
    writer:writeln(line)
    writer:close()
    return true
end

local function clearPendingRestore()
    local writer = getFileWriter(PENDING_RESTORE_FILE, true, false)
    if writer then writer:writeln(""); writer:close() end
end

-- Runs once per Lua load (including the reload exitToMenu() triggers) to
-- pick back up a restore that was in flight before the reload happened.
local function resumePendingRestore()
    local raw = readWholeFile(PENDING_RESTORE_FILE)
    if not raw or raw == "" then return end
    local id = jsonField(raw, "id")
    local gameMode = jsonField(raw, "gameMode")
    local worldName = jsonField(raw, "worldName")
    if not id or not gameMode or not worldName then return end

    pendingRestoreId = id
    restoreGameMode = gameMode
    restoreWorldName = worldName
    restoreDeadlineAtMs = getTimestampMs() + RESTORE_ACK_TIMEOUT_MS
    restoreStarted = true
    dbg("resumed pending restore from disk: id=" .. id .. " " .. gameMode .. "/" .. worldName)
end

local function startRestoreFlow(deathPanel)
    if restoreStarted then return end
    restoreStarted = true

    restoreGameMode, restoreWorldName = currentSaveSlot()
    -- Commit the death memory now that a rewind is actually happening.
    writeNightmare(lastDeathCause or "unknown")

    local id = writeRequest("restore", "latest")
    if not id then
        notify("Could not write the restore request.")
        restoreStarted = false
        return
    end
    pendingRestoreId = id
    restoreDeadlineAtMs = getTimestampMs() + RESTORE_ACK_TIMEOUT_MS
    writePendingRestore(id, restoreGameMode, restoreWorldName)
    dbg("restore requested, exiting to menu")

    -- mirror vanilla ISPostDeathUI:onExit
    pcall(function() setGameSpeed(1) end)
    pcall(function() deathPanel:removeFromUIManager() end)
    pcall(function() getCore():exitToMenu() end)
end

-- The exitToMenu() reload re-executes this whole file, so this call picks
-- back up any restore that was mid-flight when the reload happened.
resumePendingRestore()

if ISPostDeathUI then
    local origCreateChildren = ISPostDeathUI.createChildren
    function ISPostDeathUI:createChildren()
        origCreateChildren(self)
        if isClient() then return end
        if not (self.buttonRespawn and self.buttonExit and self.buttonQuit) then return end

        local gap = 10
        local buttonHgt = self.buttonRespawn:getHeight()
        local buttonWid = math.max(
            self:getWidth(),
            getTextManager():MeasureStringX(UIFont.Small, WAKE_LABEL) + gap * 2
        )

        for _, b in ipairs({ self.buttonRespawn, self.buttonExit, self.buttonQuit }) do
            b:setY(b:getY() + buttonHgt + gap)
            b:setWidth(buttonWid)
        end

        local button = ISButton:new(0, 0, buttonWid, buttonHgt, WAKE_LABEL, self, startRestoreFlow)
        self:configButton(button)
        self:addChild(button)
        self.buttonDaydreamWake = button

        self:setWidth(buttonWid)
        self:setHeight(self:getHeight() + buttonHgt + gap)
        self:setX(self.screenX + (self.screenWidth - buttonWid) / 2)
        self:setY(self.screenY + (self.screenHeight - 40 - self:getHeight()))
        dbg("death screen button added")
    end

    local origPrerender = ISPostDeathUI.prerender
    function ISPostDeathUI:prerender()
        origPrerender(self)
        local button = self.buttonDaydreamWake
        if not button then return end
        button:setVisible(self.waitOver == true and hasCheckpoint())
    end
end

--=====================================================================--
-- Front-end (main menu) side: heartbeat + restore ack handling.
-- Mod Lua stays loaded at the menu, and OnFETick fires there.
--=====================================================================--

local menuMarkerLastMs = 0

local function showMenuDialog(text)
    local shown = pcall(function()
        local w, h = 420, 140
        local x = (getCore():getScreenWidth() - w) / 2
        local y = (getCore():getScreenHeight() - h) / 2
        local modal = ISModalDialog:new(x, y, w, h, text, false, nil, nil)
        modal:initialise()
        modal:addToUIManager()
        modal:bringToTop()
    end)
    if not shown then dbg("menu dialog failed to show: " .. text) end
end

-- MainScreen may not have finished constructing its UI the instant
-- OnFETick starts firing after exitToMenu(), so auto-load is attempted
-- on a short retry loop rather than once immediately on ack.
local autoLoadRetryDeadlineMs = nil

local function attemptAutoLoad()
    if not (MainScreen and MainScreen.instance) then
        dbg("auto-load: MainScreen.instance not ready yet, waiting")
        return false
    end

    dbg("auto-load: attempting, gameMode=" .. tostring(restoreGameMode)
        .. " world=" .. tostring(restoreWorldName))

    local ok, err = pcall(function()
        if restoreGameMode and restoreWorldName and MainScreen.continueLatestSave then
            MainScreen.continueLatestSave(restoreGameMode, restoreWorldName)
        elseif MainScreen.latestSaveGameMode then
            MainScreen.continueLatestSave(MainScreen.latestSaveGameMode, MainScreen.latestSaveWorld)
        else
            error("no load entry point")
        end
    end)
    clearPendingRestore()
    if not ok then
        dbg("auto-load failed: " .. tostring(err))
        showMenuDialog("Checkpoint restored.\nClick Continue to wake up at the checkpoint.")
    else
        dbg("auto-load call completed without error")
    end
    return true
end

local function checkRestoreAck()
    local raw = readWholeFile(ACK_FILE)
    if raw and raw ~= "" and jsonField(raw, "id") == pendingRestoreId then
        local ok = jsonBoolField(raw, "ok")
        local message = jsonField(raw, "message") or ""
        dbg("restore ack: ok=" .. tostring(ok) .. " message=" .. message)
        pendingRestoreId = nil
        restoreStarted = false
        if ok then
            autoLoadRetryDeadlineMs = getTimestampMs() + 15000
        else
            clearPendingRestore()
            showMenuDialog("Checkpoint restore FAILED:\n" .. message .. "\nYour save was not touched.")
        end
        return
    end
    if restoreDeadlineAtMs and getTimestampMs() > restoreDeadlineAtMs then
        dbg("restore ack timeout")
        pendingRestoreId = nil
        restoreStarted = false
        clearPendingRestore()
        showMenuDialog("Checkpoint restore timed out - is the watcher running?\nYour save may not have been restored.")
    end
end

local function onFETick()
    local now = getTimestampMs()
    if now - menuMarkerLastMs >= MENU_MARKER_EVERY_MS then
        menuMarkerLastMs = now
        local writer = getFileWriter(MENU_MARKER_FILE, true, false)
        if writer then
            writer:writeln(tostring(now))
            writer:close()
        end
    end
    if pendingRestoreId then
        checkRestoreAck()
    end
    if autoLoadRetryDeadlineMs then
        if attemptAutoLoad() then
            autoLoadRetryDeadlineMs = nil
        elseif now > autoLoadRetryDeadlineMs then
            dbg("auto-load: gave up waiting for MainScreen.instance")
            autoLoadRetryDeadlineMs = nil
            clearPendingRestore()
            showMenuDialog("Checkpoint restored.\nClick Continue to wake up at the checkpoint.")
        end
    end
end

if Events.OnFETick then
    Events.OnFETick.Add(onFETick)
end

dbg("loaded; options=" .. tostring(optEnabled ~= nil)
    .. " ISPostDeathUI=" .. tostring(ISPostDeathUI ~= nil)
    .. " OnFETick=" .. tostring(Events.OnFETick ~= nil))
