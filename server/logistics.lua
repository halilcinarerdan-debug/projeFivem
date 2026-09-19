-- =====================================================================
-- MATRIX LOGISTICS / logistics.lua
-- Katman 4: Programli Lojistik Sevk & Zaman-Mesafe Surtunme Motoru.
-- Sealed Katman 1-2-3 dosyalarina (main/forensics/recruitment/bureau/
-- kitchen) dokunmadan, onlarin dirty-set / async-prepare desenini
-- taklit ederek Matrix.* omurgasina kenetlenir. RNG yok, HUD yok;
-- her deger deterministik denklemlerden ve config sabitlerinden gelir.
-- =====================================================================

Matrix.Logistics = Matrix.Logistics or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local math_max, math_min, math_huge = math.max, math.min, math.huge

local CreateThread                  = CreateThread
local Wait                          = Wait
local SetTimeout                    = SetTimeout
local GetPlayerPed                  = GetPlayerPed
local GetEntityCoords               = GetEntityCoords
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local DoesEntityExist               = DoesEntityExist
local SetEntityCoords               = SetEntityCoords
local TriggerClientEvent            = TriggerClientEvent
local RegisterCommand               = RegisterCommand
local RegisterNetEvent              = RegisterNetEvent
local source                        = source

-- botId -> dispatch record
local ActiveDispatches = {}

-- =====================================================================
-- UTILITIES
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    return #(a - b)
end

local function LerpCoords(a, b, t)
    t = Matrix.Clamp(t, 0.0, 1.0)
    return vector3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t
    )
end

local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' then return false end
    return c.x ~= nil and c.y ~= nil and c.z ~= nil
end

local function GetVehicleProfile(vehicleType)
    return Config.Logistics.VehicleTypes[vehicleType]
        or Config.Logistics.VehicleTypes[Config.Logistics.DefaultVehicleType]
end

-- ox_inventory üzerinden dealer'ın taşıdığı toplam ağırlık (W_total, gram).
-- Konvansiyon: her dealer botu 'dealer_<id>' adlı bir ox_inventory envanteri kullanır.
local function GetBotInventoryWeight(bot)
    local inventoryId = ('dealer_%d'):format(bot.id)
    local ok, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return 0.0 end

    local total = 0.0
    for _, item in pairs(inv.items) do
        if type(item) == 'table' then
            total = total + ((tonumber(item.weight) or 0.0) * (tonumber(item.count) or 0.0))
        end
    end
    return total
end

-- Bureau.lua'daki en yakın trap house taramasının yerel eşdeğeri
-- (o dosya mühürlü olduğu için buradan çağrılamaz, aynı desen tekrarlanır).
local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then
            nearestId, nearestDist = id, d
        end
    end
    return nearestId, nearestDist
end

local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(coords, zone.coords) <= zone.radius then
            return zone
        end
    end
    return nil
end

-- =====================================================================
-- KÖR BÖLGE / GECİKMELİ LOG KUYRUĞU
-- =====================================================================
local function QueueOrEmit(dispatch, message)
    if dispatch.comms_lost then
        dispatch.pending_events[#dispatch.pending_events + 1] = message
    else
        Matrix.Log('LOGISTICS', message)
    end
end

local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end

    Matrix.Log('LOGISTICS', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('LOGISTICS', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end

-- =====================================================================
-- KALICI ÖLÜM (PERMADEATH & HARD-DELETE)
-- =====================================================================
function Matrix.Logistics.OnDealerEliminated(botId, cause)
    local bot = Matrix.Bots[botId]
    if not bot then return false end

    ActiveDispatches[botId] = nil

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
    end

    local deletedOk = pcall(function()
        MySQL.query.await('DELETE FROM matrix_bots WHERE id = ?', { botId })
    end)

    Matrix.Persistence.dirtyBots[botId] = nil
    Matrix.Bots[botId] = nil

    Matrix.Log('LOGISTICS', '[LOJİSTİK KAYIP: DEALER_ID %d KALICI OLARAK DE-REGİSTRE EDİLDİ] Sebep:%s | SQL Silindi:%s',
        botId, tostring(cause or 'unknown'), tostring(deletedOk))

    return true
end

-- =====================================================================
-- ÇATIŞMA DİRENCİ (deterministik hasar birikimi, RNG yok)
-- =====================================================================
function Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
    local bot = Matrix.Bots[botId]
    if not bot then return false end

    rawDamage = tonumber(rawDamage) or 1.0
    if rawDamage ~= rawDamage or rawDamage < 0.0 then rawDamage = 0.0 end

    local dispatch = ActiveDispatches[botId]
    local profile = GetVehicleProfile(dispatch and dispatch.vehicle_type or Config.Logistics.DefaultVehicleType)
    local effectiveDamage = rawDamage * (1.0 - profile.CombatResistance)

    if dispatch then
        dispatch.combat_damage = dispatch.combat_damage + effectiveDamage
        Matrix.Log('LOGISTICS', 'Bot #%d çatışma hasarı: ham=%.2f direnç=%.2f etkin=%.2f birikim=%.2f/%.2f',
            botId, rawDamage, profile.CombatResistance, effectiveDamage,
            dispatch.combat_damage, Config.Logistics.CombatEliminationThreshold)

        if dispatch.combat_damage >= Config.Logistics.CombatEliminationThreshold then
            Matrix.Logistics.OnDealerEliminated(botId, 'combat')
        end
    elseif effectiveDamage >= Config.Logistics.CombatEliminationThreshold then
        Matrix.Logistics.OnDealerEliminated(botId, 'combat')
    end

    return true
end

function Matrix.Logistics.OnPoliceCollision(botId)
    return Matrix.Logistics.OnDealerEliminated(botId, 'police_collision')
end

-- =====================================================================
-- DEALER SEVK (ETA hesaplayıcı)
-- =====================================================================
function Matrix.Logistics.DispatchDealer(botId, destination, vehicleType, dispatcherSrc)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.role ~= 'dealer' then return false, 'not_a_dealer' end
    if ActiveDispatches[botId] then return false, 'already_dispatched' end
    if not IsValidCoords(destination) then return false, 'bad_destination' end

    local origin = bot.state.coords
    if not IsValidCoords(origin) then return false, 'no_origin' end

    if type(vehicleType) ~= 'string' or not Config.Logistics.VehicleTypes[vehicleType] then
        vehicleType = Config.Logistics.DefaultVehicleType
    end
    local profile = GetVehicleProfile(vehicleType)

    local distance   = VectorDistance(origin, destination)
    local weightTotal = GetBotInventoryWeight(bot)
    local baseSpeed   = Config.Logistics.BaseSpeedUnitsPerSecond

    -- ETA = (Mesafe / (BaseSpeed * Hiz_Katsayisi)) * (1 + (W_total * k) * Surtunme_Carpani)
    local etaSeconds = (distance / (baseSpeed * profile.SpeedCoefficient))
        * (1.0 + (weightTotal * Config.Logistics.WeightFrictionCoefficient) * profile.FrictionMultiplier)
    etaSeconds = Matrix.Clamp(etaSeconds, 0.0, math_huge)

    ActiveDispatches[botId] = {
        bot_id         = botId,
        vehicle_type   = vehicleType,
        origin         = origin,
        destination    = destination,
        eta_total      = etaSeconds,
        eta_remaining  = etaSeconds,
        weight_total   = weightTotal,
        dispatcher_src = dispatcherSrc,
        comms_lost     = false,
        pending_events = {},
        combat_damage  = 0.0,
        started_at     = Matrix.Now()
    }

    bot.state.activity = 'distribution'

    Matrix.Log('LOGISTICS',
        'Sevkiyat başlatıldı: Bot #%d [%s] Araç:%s Mesafe:%.1fm Ağırlık:%.1fg ETA:%.1fsn',
        botId, bot.name, vehicleType, distance, weightTotal, etaSeconds)

    return true, etaSeconds
end

-- =====================================================================
-- TICK (1000ms, sıfır await — main.lua'nın ticker'ından bağımsız)
-- =====================================================================
function Matrix.Logistics.Tick()
    for botId, dispatch in pairs(ActiveDispatches) do
        local bot = Matrix.Bots[botId]
        if not bot then
            ActiveDispatches[botId] = nil
        else
            dispatch.eta_remaining = math_max(dispatch.eta_remaining - 1.0, 0.0)

            local progress = 1.0
            if dispatch.eta_total > 0.0 then
                progress = 1.0 - (dispatch.eta_remaining / dispatch.eta_total)
            end

            local currentCoords = LerpCoords(dispatch.origin, dispatch.destination, progress)
            bot.state.coords = currentCoords

            local zone = FindDeadZone(currentCoords)
            local nowInDeadZone = zone ~= nil

            if nowInDeadZone and not dispatch.comms_lost then
                dispatch.comms_lost = true
                Matrix.Log('LOGISTICS', '[BAĞLANTI KESİLDİ - SİNYAL YOK] Bot #%d (%s) kör bölgeye girdi: %s',
                    botId, bot.name, zone.label)
            elseif (not nowInDeadZone) and dispatch.comms_lost then
                dispatch.comms_lost = false
                Matrix.Log('LOGISTICS', '[SİNYAL YENİDEN ALINDI] Bot #%d (%s) kör bölgeden çıktı, gecikmeli veri akışı %.1fsn içinde gelecek.',
                    botId, bot.name, Config.Logistics.DeadZoneLogFlushDelayMs / 1000.0)
                SetTimeout(Config.Logistics.DeadZoneLogFlushDelayMs, function()
                    FlushPendingEvents(dispatch)
                end)
            end

            -- Sinyal varken (kör bölge dışında) sevkiyat en yakın trap house'a
            -- araç tipine bağlı "Polis Deşifre Çarpanı" oranında istihbarat sızdırır.
            local profile = GetVehicleProfile(dispatch.vehicle_type)
            if not dispatch.comms_lost and profile.PoliceDecryptionMultiplier > 0.0 then
                local trapHouseId, trapDist = FindNearestTrapHouse(currentCoords)
                if trapHouseId and trapDist <= Config.Bureau.BaseSearchRadius then
                    Matrix.Bureau.AdvanceDecryption(
                        trapHouseId,
                        Config.Logistics.PoliceDecryptionGainPerTick * profile.PoliceDecryptionMultiplier
                    )
                end
            end

            QueueOrEmit(dispatch, ('Bot #%d konum güncellendi: (%.1f, %.1f, %.1f) | Kalan ETA:%.1fsn'):format(
                botId, currentCoords.x, currentCoords.y, currentCoords.z, dispatch.eta_remaining))

            if dispatch.eta_remaining <= 0.0 then
                bot.state.coords    = dispatch.destination
                bot.state.activity  = 'idle'

                QueueOrEmit(dispatch, ('[VARIŞ NOKTASINDA / AT MEET-POINT] Bot #%d (%s) hedefe ulaştı.'):format(botId, bot.name))

                if bot.state.spawned and bot.state.net_id then
                    local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
                    if ped and ped ~= 0 and DoesEntityExist(ped) then
                        SetEntityCoords(ped, dispatch.destination.x, dispatch.destination.y, dispatch.destination.z, false, false, false, false)
                    end
                end

                ActiveDispatches[botId] = nil
            end
        end
    end
end

CreateThread(function()
    local interval = Config.Logistics.DispatchTickIntervalMs or Config.Tick.IntervalMs
    while true do
        Wait(interval)
        Matrix.Logistics.Tick()
    end
end)

-- =====================================================================
-- KOMUTLAR (guard-clause hardened, Taktik Komuta Paneli)
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[LOJİSTİK]', msg } })
    else
        print(('[MATRIX:LOGISTICS:CONSOLE] %s'):format(msg))
    end
end

RegisterCommand('sevket', function(src, args)
    local botId = tonumber(args[1])
    local vehicleType = args[2] or Config.Logistics.DefaultVehicleType

    if not botId then
        Reply(src, 'Kullanim: /sevket [botId] [foot|motorbike|car]'); return
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        Reply(src, 'Meet-point için geçerli bir ped gerekli.'); return
    end
    local destination = GetEntityCoords(ped)

    local ok, etaOrReason = Matrix.Logistics.DispatchDealer(botId, destination, vehicleType, src)
    if ok then
        Reply(src, ('Bot #%d sevk edildi [%s]. Tahmini varış: %.1f sn'):format(botId, vehicleType, etaOrReason))
    else
        Reply(src, ('Sevkiyat başarısız: %s'):format(tostring(etaOrReason)))
    end
end, false)

-- =====================================================================
-- EVENT BRIDGE (guard'lı — polis çakışması / çatışma bildirimi)
-- =====================================================================
RegisterNetEvent('matrix:server:reportDealerEliminated', function(botId, cause)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnDealerEliminated(botId, type(cause) == 'string' and cause or 'unknown')
end)

RegisterNetEvent('matrix:server:reportDealerPoliceCollision', function(botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnPoliceCollision(botId)
end)

RegisterNetEvent('matrix:server:reportDealerCombatDamage', function(botId, rawDamage)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
end)

-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('DispatchDealer', function(botId, dest, vType, dispatcherSrc)
    return Matrix.Logistics.DispatchDealer(botId, dest, vType, dispatcherSrc)
end)
exports('ApplyCombatDamageToDealer', function(botId, dmg)
    return Matrix.Logistics.ApplyCombatDamage(botId, dmg)
end)
exports('EliminateDealer', function(botId, cause)
    return Matrix.Logistics.OnDealerEliminated(botId, cause)
end)
exports('ReportDealerPoliceCollision', function(botId)
    return Matrix.Logistics.OnPoliceCollision(botId)
end)
