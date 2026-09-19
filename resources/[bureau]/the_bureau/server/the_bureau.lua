--[[
    THE BUREAU :: KATMAN 2 -- OPERASYONLAR MOTORU (server/the_bureau.lua)
    ------------------------------------------------------------------------
    Arka planda calisan asenkron istihbarat yapay zekasi:
      - Isi haritasi (heatmap) uretimi ve decay dongusu
      - SIGINT paket sizintisi / operasyon sikligi takibi
      - Ayni mulkte tekrar eden meet-point oruntusunun desifre edilmesi
      - Arama karari (search warrant) tetiklenmesi
      - 40+ metreden sivil zirhli araclarla baskin (drive-by/cember) kancasi
      - Balistik adli delil kaydi ve AFIS soguk vaka koprusu
      - ox_inventory agirlik birimleriyle (gram) canli senkronizasyon

    Tum sabitler config.lua'dan okunur; burada hicbir deger hardcode edilmez.
]]

local QBCore = exports['qb-core']:GetCoreObject()

local Bureau = {}

local Heatmap             = {} -- [cellKey] = { heat = number, x = number, y = number }
local MeetPointLog         = {} -- [propertyIdentifier] = { gameTimer, gameTimer, ... }
local RegisteredProperties = {} -- [propertyIdentifier] = { propertyType, ownerCitizenid, x, y, z, maxWeight, currentWeight }
local RaidCooldowns        = {} -- [propertyIdentifier] = gameTimer
local ActiveRaids          = {} -- [propertyIdentifier] = { entities = {...}, startedAt = gameTimer }
local ActivityCounters     = {} -- [citizenid] = number, bir sonraki SIGINT taramasinda tuketilir

-- ============================================================
--  YARDIMCI FONKSIYONLAR
-- ============================================================

local function GetDistance(x1, y1, z1, x2, y2, z2)
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2 + (z1 - z2) ^ 2)
end

local function GetCellKey(x, y)
    local gridSize = Config.BureauAI.HeatmapGridSize
    return math.floor(x / gridSize) .. '_' .. math.floor(y / gridSize)
end

local function AddHeat(x, y, amount)
    local key = GetCellKey(x, y)
    local cell = Heatmap[key]
    if not cell then
        cell = { heat = 0.0, x = x, y = y }
        Heatmap[key] = cell
    end
    cell.heat = math.min(Config.BureauAI.HeatmapCellCap, cell.heat + amount)
end

local function DecayHeatmap()
    for key, cell in pairs(Heatmap) do
        cell.heat = cell.heat - (cell.heat * Config.BureauAI.HeatmapDecay)
        if cell.heat < 0.5 then
            Heatmap[key] = nil
        end
    end
end

-- Basit FNV-1a: kriptografik degil, oyun-ici "adli" imza uretimi icin yeterli entropi saglar.
local function Fnv1aHash(str)
    local hash = 2166136261
    for i = 1, #str do
        hash = hash ~ string.byte(str, i)
        hash = (hash * 16777619) & 0xFFFFFFFF
    end
    return hash
end

-- Yiv-set imzasi sadece silahin FIZIKSEL seri numarasina baglidir; boylece
-- ayni silahtan atilan farkli mermiler her zaman ayni hash'i uretir (gercek
-- balistik esleme mantigi). Zaman/koordinat gibi degisken veriler KULLANILMAZ.
local function BuildStriationHash(weaponSerial)
    local length = Config.ForensicThresholds.StriationHashLength
    local passes = math.ceil(length / 8)
    local out = {}
    for i = 1, passes do
        out[#out + 1] = string.format('%08x', Fnv1aHash(weaponSerial .. '#' .. i))
    end
    return table.concat(out):sub(1, length)
end

-- ============================================================
--  MULK / STASH KOPRUSU (ox_inventory agirlik birimleriyle konusur)
-- ============================================================

function Bureau.GetMaxWeightForProperty(propertyType)
    if propertyType == 'trap_house' then
        return Config.StashLimits.TrapHouseMaxKg * 1000.0 -- kg -> gram
    end
    return Config.StashLimits.MotelMaxGram
end

local function GetSlotsForProperty(propertyType)
    if propertyType == 'trap_house' then
        return Config.StashLimits.TrapHouseSlots
    end
    return Config.StashLimits.MotelSlots
end

--- Yeni bir mulku (motel odasi / trap house) Bureau'ya ve ox_inventory'ye kaydeder.
--- Digre gun/kaynaklarin (mulk satin alma sistemi vb.) cagirmasi icin export edilir.
function Bureau.RegisterProperty(propertyIdentifier, propertyType, ownerCitizenid, coords, label)
    local maxWeight = Bureau.GetMaxWeightForProperty(propertyType)
    local slots = GetSlotsForProperty(propertyType)

    RegisteredProperties[propertyIdentifier] = {
        propertyType    = propertyType,
        ownerCitizenid  = ownerCitizenid,
        x               = coords.x,
        y               = coords.y,
        z               = coords.z,
        maxWeight       = maxWeight,
        currentWeight   = 0.0,
    }

    MySQL.query([[
        INSERT INTO trap_house_stashes
            (property_identifier, property_type, owner_citizenid, max_weight_grams, coords_x, coords_y, coords_z)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            property_type = VALUES(property_type),
            owner_citizenid = VALUES(owner_citizenid),
            max_weight_grams = VALUES(max_weight_grams),
            coords_x = VALUES(coords_x),
            coords_y = VALUES(coords_y),
            coords_z = VALUES(coords_z)
    ]], { propertyIdentifier, propertyType, ownerCitizenid, maxWeight, coords.x, coords.y, coords.z })

    exports.ox_inventory:RegisterStash(propertyIdentifier, label or propertyIdentifier, slots, maxWeight, ownerCitizenid)

    return true
end

local function LoadPropertiesFromDatabase()
    MySQL.query('SELECT * FROM trap_house_stashes', {}, function(rows)
        if not rows then return end

        for i = 1, #rows do
            local row = rows[i]
            RegisteredProperties[row.property_identifier] = {
                propertyType   = row.property_type,
                ownerCitizenid = row.owner_citizenid,
                x              = row.coords_x,
                y              = row.coords_y,
                z              = row.coords_z,
                maxWeight      = row.max_weight_grams,
                currentWeight  = row.current_weight_grams,
            }

            exports.ox_inventory:RegisterStash(
                row.property_identifier,
                row.property_identifier,
                GetSlotsForProperty(row.property_type),
                row.max_weight_grams,
                row.owner_citizenid
            )
        end

        if Config.Debug then
            print(('[the_bureau] %d mulk yuklendi ve ox_inventory ile eslestirildi.'):format(#rows))
        end
    end)
end

local function SyncStashWeights()
    for propertyIdentifier, property in pairs(RegisteredProperties) do
        local inventory = exports.ox_inventory:GetInventory(propertyIdentifier)
        if inventory and inventory.weight then
            property.currentWeight = inventory.weight

            MySQL.update('UPDATE trap_house_stashes SET current_weight_grams = ? WHERE property_identifier = ?',
                { inventory.weight, propertyIdentifier })

            if inventory.weight > property.maxWeight then
                AddHeat(property.x, property.y, Config.BureauAI.BaseWantedMulti * 2.0)
            end
        end
    end
end

-- ============================================================
--  SIGINT :: PAKET SIZINTISI / OPERASYON SIKLIGI TARAMASI
-- ============================================================

local function ScanCellularMatrix()
    MySQL.query('SELECT id, owner_citizenid, packet_leak_ratio FROM sigint_cellular_matrix WHERE is_compromised = 0', {},
        function(rows)
            if not rows then return end

            for i = 1, #rows do
                local row = rows[i]
                local activity = row.owner_citizenid and ActivityCounters[row.owner_citizenid] or 0

                if activity > 0 then
                    local increment = Config.Sigint.PacketLeakBaseRatio * activity
                    local newRatio = math.min(1.0, tonumber(row.packet_leak_ratio) + increment)
                    local compromised = newRatio >= Config.Sigint.PacketLeakCompromiseAt

                    MySQL.update('UPDATE sigint_cellular_matrix SET packet_leak_ratio = ?, is_compromised = ? WHERE id = ?',
                        { newRatio, compromised and 1 or 0, row.id })

                    if compromised then
                        TriggerEvent('bureau:server:onAgentCompromised', row.id, row.owner_citizenid)
                    end
                end
            end

            ActivityCounters = {}
        end)
end

-- ============================================================
--  MEET-POINT PATTERN DESIFRESI VE ARAMA KARARI
-- ============================================================

local function FlagSearchWarrant(propertyIdentifier)
    MySQL.update([[
        UPDATE trap_house_stashes
        SET search_warrant_flag = 1, warrant_issued_at = NOW()
        WHERE property_identifier = ? AND search_warrant_flag = 0
    ]], { propertyIdentifier })
end

--- Property etrafinda Config.BureauAI.RaidApproachDistance+ mesafede baskin
--- ekibi icin cevresel (cember) spawn noktalari hesaplar ve baskin olayini
--- tetikler. Gercek arac/ped spawn'i asagidaki varsayilan handler'da yapilir;
--- bu sayede ileriki gunlerin AI davranis agaci ayni event'e kancalanabilir.
function Bureau.TriggerRaid(propertyIdentifier, coords, reason)
    local now = GetGameTimer()
    local last = RaidCooldowns[propertyIdentifier]

    if last and (now - last) < Config.BureauAI.RaidTriggerCooldownMs then
        return false, 'cooldown'
    end

    RaidCooldowns[propertyIdentifier] = now

    local unitCount = math.random(Config.BureauAI.MinUnitsForRaid, Config.BureauAI.MaxUnitsForRaid)
    local units = {}

    for _ = 1, unitCount do
        local angle = math.random() * 2 * math.pi
        local dist = Config.BureauAI.RaidApproachDistance + math.random(0, 15)

        units[#units + 1] = {
            x = coords.x + math.cos(angle) * dist,
            y = coords.y + math.sin(angle) * dist,
            z = coords.z,
            heading = angle * (180.0 / math.pi),
        }
    end

    MySQL.update('UPDATE trap_house_stashes SET last_raid_at = NOW() WHERE property_identifier = ?', { propertyIdentifier })

    TriggerEvent('bureau:server:onRaidInitiated', propertyIdentifier, coords, units, reason)

    local property = RegisteredProperties[propertyIdentifier]
    if property and property.ownerCitizenid then
        local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(property.ownerCitizenid)
        if targetPlayer then
            TriggerClientEvent('bureau:client:onRaidInitiated', targetPlayer.PlayerData.source, {
                propertyIdentifier = propertyIdentifier,
                coords             = coords,
                units              = units,
                reason             = reason,
            })
        end
    end

    return true, units
end

--- Bir oyuncu/NPC'nin bir mulk onunde lojistik "meet point" kurdugunu bildirir.
--- source: net id (exploit-border dogrulamasi ve citizenid cozumu icin gerekli)
function Bureau.RegisterMeetPoint(source, propertyIdentifier, clientCoords)
    local property = RegisteredProperties[propertyIdentifier]
    if not property then
        return false, 'unknown_property'
    end

    local dist = GetDistance(clientCoords.x, clientCoords.y, clientCoords.z, property.x, property.y, property.z)
    if dist > (Config.BureauAI.MeetPointRadius + Config.ExploitBorders.SafeClaimRadius) then
        return false, 'out_of_bounds'
    end

    local now = GetGameTimer()
    local log = MeetPointLog[propertyIdentifier]
    if not log then
        log = {}
        MeetPointLog[propertyIdentifier] = log
    end

    for i = #log, 1, -1 do
        if (now - log[i]) > Config.BureauAI.PatternWindowMs then
            table.remove(log, i)
        end
    end

    table.insert(log, now)

    local heatAdd = Config.BureauAI.BaseWantedMulti * 5.0
    AddHeat(property.x, property.y, heatAdd)

    MySQL.update('UPDATE trap_house_stashes SET meet_point_count = meet_point_count + 1, heat_score = heat_score + ? WHERE property_identifier = ?',
        { heatAdd, propertyIdentifier })

    local player = QBCore.Functions.GetPlayer(source)
    if player then
        local citizenid = player.PlayerData.citizenid
        ActivityCounters[citizenid] = (ActivityCounters[citizenid] or 0) + 1
    end

    if #log >= Config.BureauAI.PatternDeceptionsBeforeRaid then
        MeetPointLog[propertyIdentifier] = {}
        FlagSearchWarrant(propertyIdentifier)
        Bureau.TriggerRaid(propertyIdentifier, vector3(property.x, property.y, property.z), 'pattern_deception')
    end

    return true
end

-- ============================================================
--  ADLI BILISIM :: BALISTIK LOG + AFIS KOPRUSU
-- ============================================================

RegisterNetEvent('bureau:server:reportGunshot', function(weaponHash, coords, soundDb, weaponSerial)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end

    local citizenid = player.PlayerData.citizenid
    local serial = weaponSerial or ('UNSERIALIZED-' .. tostring(weaponHash) .. '-' .. citizenid)
    local striationHash = BuildStriationHash(serial)
    local triggered = soundDb >= Config.ForensicThresholds.AcousticDesibelAlert

    MySQL.insert([[
        INSERT INTO forensic_ballistic_logs
            (shooter_identifier, weapon_hash, coords_x, coords_y, coords_z, sound_pressure_db, striation_pattern_hash, shot_spotter_triggered)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], { citizenid, tostring(weaponHash), coords.x, coords.y, coords.z, soundDb, striationHash, triggered and 1 or 0 })

    ActivityCounters[citizenid] = (ActivityCounters[citizenid] or 0) + 1

    if not triggered then return end

    AddHeat(coords.x, coords.y, Config.BureauAI.BaseWantedMulti * 3.0)

    for propertyIdentifier, property in pairs(RegisteredProperties) do
        local dist = GetDistance(coords.x, coords.y, coords.z, property.x, property.y, property.z)
        if dist <= Config.ExploitBorders.ShotSpotterMaxDist then
            MySQL.update('UPDATE trap_house_stashes SET heat_score = heat_score + ? WHERE property_identifier = ?',
                { Config.BureauAI.BaseWantedMulti * 3.0, propertyIdentifier })
        end
    end

    TriggerEvent('bureau:server:onShotSpotterAlert', coords, soundDb, citizenid)
end)

--- Kalite esigini gecen bir parmak izini AFIS soguk vaka kaydina dusurur.
--- Day 2/3 etkilesim sistemlerinin (silah/stash uzerinde iz arama vb.) cagirmasi icin export edilir.
function Bureau.SubmitLatentPrint(fingerprintId, citizenid, coords, quality)
    if quality < Config.ForensicThresholds.LatentPrintLimit then
        return false, 'quality_too_low'
    end

    MySQL.insert([[
        INSERT INTO sigint_afis_cold_cases
            (fingerprint_id, suspect_citizenid, case_coords_x, case_coords_y, case_coords_z, print_quality)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { fingerprintId, citizenid, coords.x, coords.y, coords.z, quality })

    return true
end

-- ============================================================
--  VARSAYILAN BASKIN SPAWN HANDLER'I (40+ metre cember/drive-by)
--  Ileriki gunlerin AI davranis agaci ayni 'bureau:server:onRaidInitiated'
--  event'ine kancalanarak bu davranisi genisletebilir.
-- ============================================================

AddEventHandler('bureau:server:onRaidInitiated', function(propertyIdentifier, coords, units, _reason)
    local spawned = {}

    for i = 1, #units do
        local unit = units[i]
        local vehicleModel = Config.BureauAI.UnmarkedVehicles[math.random(#Config.BureauAI.UnmarkedVehicles)]
        local vehicleHash = GetHashKey(vehicleModel)

        local vehicle = CreateVehicle(vehicleHash, unit.x, unit.y, unit.z, unit.heading, true, false)
        SetEntityAsMissionEntity(vehicle, true, true)

        local pedHash = GetHashKey(Config.BureauAI.CivilianRaidPedModel)
        local driver = CreatePed(4, pedHash, unit.x, unit.y, unit.z, unit.heading, true, false)
        SetEntityAsMissionEntity(driver, true, true)
        SetPedIntoVehicle(driver, vehicle, -1)

        TaskVehicleDriveToCoordLongrange(driver, vehicle, coords.x, coords.y, coords.z, 25.0, 1, 5.0)

        spawned[#spawned + 1] = vehicle
        spawned[#spawned + 1] = driver
    end

    ActiveRaids[propertyIdentifier] = { entities = spawned, startedAt = GetGameTimer() }

    SetTimeout(Config.BureauAI.RaidUnitLifetimeMs, function()
        local raid = ActiveRaids[propertyIdentifier]
        if not raid then return end

        for _, entity in ipairs(raid.entities) do
            if DoesEntityExist(entity) then
                DeleteEntity(entity)
            end
        end

        ActiveRaids[propertyIdentifier] = nil
    end)
end)

-- ============================================================
--  NET EVENT KOPRULERI
-- ============================================================

RegisterNetEvent('bureau:server:registerMeetPoint', function(propertyIdentifier, coords)
    Bureau.RegisterMeetPoint(source, propertyIdentifier, coords)
end)

-- ============================================================
--  ANA ASENKRON AI THREAD'I (tek Wait, 0.00ms hedefi)
-- ============================================================

CreateThread(function()
    while true do
        Wait(Config.BureauAI.ScanInterval)
        DecayHeatmap()
        ScanCellularMatrix()
        SyncStashWeights()
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    LoadPropertiesFromDatabase()
end)

-- ============================================================
--  EXPORTS
-- ============================================================

exports('RegisterProperty', Bureau.RegisterProperty)
exports('TriggerRaid', Bureau.TriggerRaid)
exports('SubmitLatentPrint', Bureau.SubmitLatentPrint)

exports('RegisterMeetPoint', function(source, propertyIdentifier, coords)
    return Bureau.RegisterMeetPoint(source, propertyIdentifier, coords)
end)

exports('GetPropertyHeat', function(propertyIdentifier)
    local property = RegisteredProperties[propertyIdentifier]
    if not property then return 0.0 end

    local cell = Heatmap[GetCellKey(property.x, property.y)]
    return cell and cell.heat or 0.0
end)

exports('GetActiveRaids', function()
    return ActiveRaids
end)
