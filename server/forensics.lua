-- =====================================================================
-- MATRIX FORENSICS / server/forensics.lua
-- [K7-2/3] Real-Time Frisk / Çevirme Muhafızı - Büro polislerinin 8m adli
-- çemberi içinde `FriskDwellMs` boyunca kalan bot/oyuncu otomatik "Adli
-- Üst Araması"na tabi tutulur. Sahte plaka, BM- seri numaralı silah,
-- 2 dakikayı aşmış burner phone veya saflığı bozuk/tahrif edilmiş
-- uyuşturucu paketi bulunursa: delil indeksi anında sıçrar ve kalıcı el
-- koyma (SeizeVehicle / WipeBallisticRecord) otomatik tetiklenir.
--
-- Tek thread, Config.Forensics.TickIntervalMs'de bir uyanır (varsayılan
-- 1000ms) - polis yoksa hiçbir tarama yapılmaz. 0.00ms resmon doktrini.
-- =====================================================================

Matrix = Matrix or {}
Matrix.Bureau = Matrix.Bureau or {}
Matrix.Forensics = Matrix.Forensics or {}

local pairs, ipairs, type = pairs, ipairs, type
local math_min, math_max = math.min, math.max
local os_time = os.time
local GetPlayers = GetPlayers
local GetPlayerPed = GetPlayerPed
local GetEntityCoords = GetEntityCoords
local GetVehiclePedIsIn = GetVehiclePedIsIn
local GetVehicleNumberPlateText = GetVehicleNumberPlateText
local NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId

local Inventory = Config.Core.Inventory

local dwellTimers = {}   -- suspectKey -> accumulated ms in the circle
local searchCooldowns = {} -- suspectKey -> os_time() of last search

Matrix.Bureau.EvidenceIndex = Matrix.Bureau.EvidenceIndex or {}
Matrix.Forensics.ScratchedPlates = Matrix.Forensics.ScratchedPlates or {}
Matrix.Forensics.WipedSerials = Matrix.Forensics.WipedSerials or {}
Matrix.Forensics.SeizedVehicles = Matrix.Forensics.SeizedVehicles or {}

-- Bot peds registered by other modules (logistics / a future bot-AI
-- spawner) so the frisk sweep can reach them, not just real players.
-- entry: { netId, ownerId }
Matrix.Forensics.BotPeds = Matrix.Forensics.BotPeds or {}

function Matrix.Forensics.RegisterBotPed(botId, netId, ownerId)
    Matrix.Forensics.BotPeds[botId] = { netId = netId, ownerId = ownerId }
end

function Matrix.Forensics.MarkPlateScratched(plate)
    Matrix.Forensics.ScratchedPlates[plate] = true
end

-- ---------------------------------------------------------------------
-- Evidence index: a 0-100 confidence meter per target. "%20 zıplat"
-- moves it 20% of the remaining distance to 100 - guaranteed forward
-- movement even from 0, asymptotic towards the cap.
-- ---------------------------------------------------------------------
function Matrix.Bureau.BumpEvidenceIndex(targetId, pct)
    pct = pct or Config.Forensics.EvidenceIndexJumpPct
    local cur = Matrix.Bureau.EvidenceIndex[targetId] or 0
    local newVal = math_min(100, cur + (100 - cur) * pct)
    Matrix.Bureau.EvidenceIndex[targetId] = newVal
    Matrix.Log('FORENSICS', 'evidence index for %s: %.1f -> %.1f', tostring(targetId), cur, newVal)
    return newVal
end

function Matrix.Bureau.GetEvidenceIndex(targetId)
    return Matrix.Bureau.EvidenceIndex[targetId] or 0
end

-- ---------------------------------------------------------------------
-- Permanent seizure exports
-- ---------------------------------------------------------------------
function Matrix.Bureau.SeizeVehicle(plate, netId, reason)
    Matrix.Forensics.SeizedVehicles[plate] = { at = os_time(), reason = reason }

    if netId then
        local ok = pcall(function()
            local veh = NetworkGetEntityFromNetworkId(netId)
            if veh and veh ~= 0 then
                DeleteEntity(veh)
            end
        end)
        if not ok then
            Matrix.Log('FORENSICS', 'SeizeVehicle: could not resolve/delete entity for plate=%s (netId=%s)', tostring(plate), tostring(netId))
        end
    end

    -- If this was a logistics bot's assigned vehicle, unregister it too.
    if Matrix.Logistics and Matrix.Logistics.BotVehicles then
        for botId, bot in pairs(Matrix.Logistics.BotVehicles) do
            if bot.plate == plate then
                Matrix.Logistics.BotVehicles[botId] = nil
            end
        end
    end

    Matrix.Log('FORENSICS', 'SEIZED VEHICLE plate=%s reason=%s', tostring(plate), tostring(reason))
end

function Matrix.Bureau.WipeBallisticRecord(weaponSerial)
    Matrix.Forensics.WipedSerials[weaponSerial] = os_time()

    if Matrix.BlackMarket and Matrix.BlackMarket.InvalidateSerial then
        pcall(Matrix.BlackMarket.InvalidateSerial, weaponSerial)
    end

    Matrix.Log('FORENSICS', 'WIPED BALLISTIC RECORD serial=%s', tostring(weaponSerial))
end

-- ---------------------------------------------------------------------
-- On-duty police lookup (QBCore convention)
-- ---------------------------------------------------------------------
local function getOnDutyOfficers()
    local officers = {}
    local ok = pcall(function()
        local QBCore = exports[Config.Core.Resource]:GetCoreObject()
        for _, source in ipairs(GetPlayers()) do
            source = tonumber(source)
            local ply = QBCore.Functions.GetPlayer(source)
            if ply and ply.PlayerData and ply.PlayerData.job
                and ply.PlayerData.job.name == Config.Forensics.PoliceJob
                and ply.PlayerData.job.onduty then
                local coords = GetEntityCoords(GetPlayerPed(source))
                officers[#officers + 1] = { source = source, coords = coords }
            end
        end
    end)
    if not ok then return {} end
    return officers
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function nearestOfficerDistance(coords, officers)
    local best = math.huge
    local bestSource = nil
    for _, officer in ipairs(officers) do
        local d = distance(coords, officer.coords)
        if d < best then
            best = d
            bestSource = officer.source
        end
    end
    return best, bestSource
end

-- ---------------------------------------------------------------------
-- Inventory contraband inspection (defensive ox_inventory search)
-- ---------------------------------------------------------------------
local function searchAllSlots(inv)
    local ok, slots = pcall(function()
        return exports[Inventory]:Search(inv, 'slots')
    end)
    if not ok or not slots then return {} end
    if slots.name then slots = { slots } end
    return slots
end

local function removeFromInventory(inv, item, count, metadata)
    local ok, removed = pcall(function()
        return exports[Inventory]:RemoveItem(inv, item, count, metadata)
    end)
    return ok and removed
end

local function isPackagedItem(itemName)
    for _, name in pairs(Config.Kitchen.Packaging.PackagedItem) do
        if name == itemName then return true end
    end
    return false
end

-- Returns a list of contraband findings: { {kind, ...}, ... }
local function inspectInventory(inv)
    local findings = {}

    for _, slot in ipairs(searchAllSlots(inv)) do
        local metadata = slot.metadata or {}

        local serial = metadata.serial or metadata.weapon_serial
        if serial and tostring(serial):sub(1, #Config.Forensics.WeaponSerialContrabandPrefix) == Config.Forensics.WeaponSerialContrabandPrefix then
            findings[#findings + 1] = { kind = 'weapon', item = slot.name, serial = serial, slot = slot.slot }
        end

        if slot.name == 'burner_phone' and metadata.acquiredAt then
            local heldSeconds = os_time() - metadata.acquiredAt
            if heldSeconds > Config.Forensics.BurnerPhoneMaxHoldSeconds then
                findings[#findings + 1] = { kind = 'burner_phone', item = slot.name, heldSeconds = heldSeconds, metadata = metadata }
            end
        end

        if isPackagedItem(slot.name) then
            local purity = tonumber(metadata.purity) or 0
            local tampered = false
            if Matrix.Kitchen and Matrix.Kitchen.ComputeIntegrityHash and metadata.checksum then
                local ok, expected = pcall(Matrix.Kitchen.ComputeIntegrityHash, metadata.drugType, purity, metadata.packagedAt, metadata.batchId)
                tampered = ok and expected ~= metadata.checksum
            end
            if tampered or purity < Config.Market.GourmetMinPurity then
                findings[#findings + 1] = { kind = 'drugs', item = slot.name, purity = purity, tampered = tampered, metadata = metadata, count = slot.count }
            end
        end
    end

    return findings
end

-- ---------------------------------------------------------------------
-- Adli Üst Araması - runs against either a real player (source) or a
-- registered bot ped (botId + netId).
-- ---------------------------------------------------------------------
local function performForensicSearch(suspectKey, targetInv, ped, ownerId, isBot, officerSource)
    local findings = inspectInventory(targetInv)

    -- Vehicle plate check (independent of inventory contents).
    local veh = ped and GetVehiclePedIsIn(ped, false)
    if veh and veh ~= 0 then
        local plate = GetVehicleNumberPlateText(veh):gsub('%s+$', '')
        local scratched = Matrix.Forensics.ScratchedPlates[plate]
        if not scratched and Matrix.BlackMarket and Matrix.BlackMarket.IsScratchedPlate then
            local ok, result = pcall(Matrix.BlackMarket.IsScratchedPlate, plate)
            scratched = ok and result
        end
        if scratched then
            findings[#findings + 1] = { kind = 'vehicle', plate = plate, netId = NetworkGetNetworkIdFromEntity(veh) }
        end
    end

    if #findings == 0 then
        Matrix.Log('FORENSICS', 'frisk on %s: clean', tostring(suspectKey))
        if officerSource then
            TriggerClientEvent('matrix:client:hud:friskResult', officerSource, suspectKey, false, {})
        end
        return
    end

    Matrix.Bureau.BumpEvidenceIndex(ownerId or suspectKey)

    for _, finding in ipairs(findings) do
        if finding.kind == 'vehicle' then
            Matrix.Bureau.SeizeVehicle(finding.plate, finding.netId, 'scratched_plate')
        elseif finding.kind == 'weapon' then
            removeFromInventory(targetInv, finding.item, 1)
            Matrix.Bureau.WipeBallisticRecord(finding.serial)
        elseif finding.kind == 'burner_phone' then
            removeFromInventory(targetInv, finding.item, 1, finding.metadata)
        elseif finding.kind == 'drugs' then
            removeFromInventory(targetInv, finding.item, finding.count or 1, finding.metadata)
        end
    end

    if isBot and Matrix.Market and Matrix.Market.SeizeBotCash then
        pcall(Matrix.Market.SeizeBotCash, suspectKey)
    end

    Matrix.Log('FORENSICS', 'BUSTED %s: %d contraband item(s) found', tostring(suspectKey), #findings)

    if officerSource then
        TriggerClientEvent('matrix:client:hud:friskResult', officerSource, suspectKey, true, findings)
    end
    if not isBot and type(suspectKey) == 'number' then
        TriggerClientEvent('matrix:client:hud:searched', suspectKey, findings)
    end
end

-- ---------------------------------------------------------------------
-- Main sweep - dwell counters per suspect, cooldown after a search.
-- ---------------------------------------------------------------------
local function sweepOnce()
    local officers = getOnDutyOfficers()
    if #officers == 0 then return end

    local now = os_time()
    local seenThisTick = {}

    for _, source in ipairs(GetPlayers()) do
        source = tonumber(source)
        local isOfficer = false
        for _, officer in ipairs(officers) do
            if officer.source == source then isOfficer = true break end
        end

        if not isOfficer then
            local ped = GetPlayerPed(source)
            local coords = GetEntityCoords(ped)
            local dist, officerSource = nearestOfficerDistance(coords, officers)
            seenThisTick[source] = true

            if dist <= Config.Forensics.FriskRadius then
                dwellTimers[source] = (dwellTimers[source] or 0) + Config.Forensics.TickIntervalMs
                local onCooldown = searchCooldowns[source] and (now - searchCooldowns[source]) * 1000 < Config.Forensics.FriskCooldownMs
                if dwellTimers[source] >= Config.Forensics.FriskDwellMs and not onCooldown then
                    dwellTimers[source] = 0
                    searchCooldowns[source] = now
                    performForensicSearch(source, source, ped, tostring(source), false, officerSource)
                end
            else
                dwellTimers[source] = 0
            end
        end
    end

    for source in pairs(dwellTimers) do
        if not seenThisTick[source] then dwellTimers[source] = nil end
    end

    for botId, bot in pairs(Matrix.Forensics.BotPeds) do
        local ok, ped = pcall(NetworkGetEntityFromNetworkId, bot.netId)
        if ok and ped and ped ~= 0 then
            local coords = GetEntityCoords(ped)
            local dist, officerSource = nearestOfficerDistance(coords, officers)
            local key = 'bot:' .. tostring(botId)

            if dist <= Config.Forensics.FriskRadius then
                dwellTimers[key] = (dwellTimers[key] or 0) + Config.Forensics.TickIntervalMs
                local onCooldown = searchCooldowns[key] and (now - searchCooldowns[key]) * 1000 < Config.Forensics.FriskCooldownMs
                if dwellTimers[key] >= Config.Forensics.FriskDwellMs and not onCooldown then
                    dwellTimers[key] = 0
                    searchCooldowns[key] = now
                    local trunkInv = Matrix.Logistics and Matrix.Logistics.BotVehicles[botId]
                        and (Config.Logistics.Trunk.StashPrefix .. Matrix.Logistics.BotVehicles[botId].plate)
                    performForensicSearch(botId, trunkInv, ped, bot.ownerId, true, officerSource)
                end
            else
                dwellTimers[key] = 0
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Forensics.TickIntervalMs)
        local ok, err = pcall(sweepOnce)
        if not ok then
            Matrix.Log('FORENSICS', 'sweep error: %s', tostring(err))
        end
    end
end)

-- ---------------------------------------------------------------------
-- Manual trigger for admin/GM use or a client-side "target" interaction
-- (e.g. an officer manually frisking a nearby suspect on demand).
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:server:forensics:manualFrisk', function(targetServerId)
    local source = source
    local ok = pcall(function()
        local QBCore = exports[Config.Core.Resource]:GetCoreObject()
        local ply = QBCore.Functions.GetPlayer(source)
        return ply and ply.PlayerData.job.name == Config.Forensics.PoliceJob and ply.PlayerData.job.onduty
    end)
    if not ok then return end

    local ped = GetPlayerPed(targetServerId)
    if not ped or ped == 0 then return end
    performForensicSearch(targetServerId, targetServerId, ped, tostring(targetServerId), false, source)
end)

Matrix.Log('FORENSICS', 'server/forensics.lua loaded (Faz 2 - Frisk/Seizure)')
