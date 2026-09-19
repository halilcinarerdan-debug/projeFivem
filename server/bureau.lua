-- =====================================================================
-- MATRIX BUREAU / bureau.lua
-- Dirty-set persistence, ticker'da sıfır await, pattern cache.
-- =====================================================================

Matrix.Bureau     = Matrix.Bureau     or {}
Matrix.TrapHouses = Matrix.TrapHouses or {}

local pairs, ipairs, next        = pairs, ipairs, next
local type, tostring, tonumber   = type, tostring, tonumber
local math, table                = math, table
local math_max, math_min         = math.max, math.min
local math_huge                  = math.huge
local math_floor                 = math.floor
local os_date                    = os.date
local os_time                    = os.time
local GetPlayerPed                = GetPlayerPed
local GetEntityCoords             = GetEntityCoords

local propagandaMomentum = 0.0
local cyberLeakHeatmap   = {}  -- [trapHouseId] = intensity
local patternLog         = {}  -- [trapHouseId][bucketKey] = count

-- Dirty sets
local dirtyDecryption = {}
local dirtyIntel      = {}

-- Raid & canlı yayın çalışma zamanı durumları (kalıcı değil, tek oturumluk)
local RaidLogIdByTrapHouse = {} -- trapHouseId -> matrix_raid_log.id
local LivestreamSessions   = {} -- src -> { started, citizenid, hype, heat_added, trap_house_id }

-- =====================================================================
-- UTILITIES
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    return #(a - b)
end

local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' then return false end
    return c.x ~= nil and c.y ~= nil and c.z ~= nil
end

-- =====================================================================
-- LOAD
-- =====================================================================
function Matrix.Bureau.LoadTrapHouses()
    local rows = MySQL.query.await('SELECT * FROM matrix_trap_houses', {}) or {}
    for _, row in ipairs(rows) do
        Matrix.TrapHouses[row.id] = {
            id                   = row.id,
            label                = row.label or ('Trap #' .. row.id),
            coords               = vector3(row.coord_x or 0.0, row.coord_y or 0.0, row.coord_z or 0.0),
            decryption_confidence= Matrix.Clamp(tonumber(row.decryption_confidence) or 0.0, 0.0, 1.0),
            raid_ordered         = row.raid_ordered == 1
        }
        cyberLeakHeatmap[row.id] = tonumber(row.cyber_leak_intensity) or 0.0
        patternLog[row.id]       = {}
    end
    Matrix.Log('BUREAU', '%d trap house yüklendi.', #rows)
end

CreateThread(function()
    Matrix.Bureau.LoadTrapHouses()
end)

-- =====================================================================
-- FIND NEAREST
-- =====================================================================
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

-- =====================================================================
-- PATTERN LOG (cache + async upsert)
-- =====================================================================
function Matrix.Bureau.LogPatternEvent(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return false end

    if not patternLog[trapHouseId] then patternLog[trapHouseId] = {} end

    local dt = os_date('*t')
    local key = ('%d_%d'):format(dt.wday, dt.hour)
    patternLog[trapHouseId][key] = (patternLog[trapHouseId][key] or 0) + 1

    MySQL.prepare([[
        INSERT INTO matrix_pattern_log (trap_house_id, day_of_week, hour_of_day, occurrence_count)
        VALUES (?, ?, ?, 1)
        ON DUPLICATE KEY UPDATE occurrence_count = occurrence_count + 1
    ]], { trapHouseId, dt.wday, dt.hour })

    return true
end

local function ComputePatternRegularity(trapHouseId)
    local buckets = patternLog[trapHouseId]
    if not buckets then return 0.0 end

    local total, maxBucket = 0, 0
    for _, count in pairs(buckets) do
        total = total + count
        if count > maxBucket then maxBucket = count end
    end
    if total == 0 then return 0.0 end
    return maxBucket / total
end

-- =====================================================================
-- DECRYPTION (dirty-set)
-- =====================================================================
function Matrix.Bureau.AdvanceDecryption(trapHouseId, amount)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    amount = tonumber(amount) or 0.0
    if amount ~= amount then amount = 0.0 end -- NaN guard

    house.decryption_confidence = Matrix.Clamp(house.decryption_confidence + amount, 0.0, 1.0)
    dirtyDecryption[trapHouseId] = true

    if house.decryption_confidence >= Config.Bureau.RaidDecryptionThreshold and not house.raid_ordered then
        Matrix.Bureau.IssueRaid(trapHouseId)
    end
end

local function FlushDirtyDecryption()
    for id in pairs(dirtyDecryption) do
        local h = Matrix.TrapHouses[id]
        if h then
            MySQL.prepare(
                'UPDATE matrix_trap_houses SET decryption_confidence = ? WHERE id = ?',
                { h.decryption_confidence, id }
            )
        end
        dirtyDecryption[id] = nil
    end
end

-- =====================================================================
-- COMMS TRIANGULATION
-- =====================================================================
function Matrix.Bureau.OnUnencryptedComms(actorRef, coords)
    if not IsValidCoords(coords) then return nil end

    local actor = Matrix.ResolveActor(actorRef)

    local hitTowers = {}
    for _, tower in ipairs(Config.Bureau.CellTowers) do
        if VectorDistance(coords, tower.coords) <= Config.Bureau.TowerRange then
            hitTowers[#hitTowers + 1] = tower
        end
    end
    if #hitTowers == 0 then return nil end

    local sumX, sumY, sumZ, sumWeight = 0.0, 0.0, 0.0, 0.0
    for _, tower in ipairs(hitTowers) do
        local d = math_max(VectorDistance(coords, tower.coords), 1.0)
        local w = 1.0 / d
        sumX = sumX + (tower.coords.x * w)
        sumY = sumY + (tower.coords.y * w)
        sumZ = sumZ + (tower.coords.z * w)
        sumWeight = sumWeight + w
    end

    if sumWeight <= 0.0 then return nil end

    local estimate = vector3(sumX / sumWeight, sumY / sumWeight, sumZ / sumWeight)
    local narrowedRadius = Config.Bureau.BaseSearchRadius / #hitTowers

    local trapHouseId, distToTrap = FindNearestTrapHouse(estimate)
    if not trapHouseId or distToTrap > narrowedRadius then
        return { estimate = estimate, radius = narrowedRadius }
    end

    Matrix.Bureau.LogPatternEvent(trapHouseId)

    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local normRadius = math_max(narrowedRadius / Config.Bureau.BaseSearchRadius, 0.01)
    local gain = (Config.Bureau.TriangulationDecryptionGain / normRadius)
                 * (1.0 + heat)
                 / #hitTowers
    gain = Matrix.Clamp(gain, 0.0, 0.5)

    Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)

    Matrix.Log('BUREAU', 'Üçgenleme (%s): %d istasyon, r=%.1fm, trap #%d kazanç=%.4f',
        (actor and actor.dna_id) or 'UNKNOWN', #hitTowers, narrowedRadius, trapHouseId, gain)

    return { estimate = estimate, radius = narrowedRadius, trap_house_id = trapHouseId, gain = gain }
end

-- =====================================================================
-- PROPAGANDA
-- =====================================================================
function Matrix.Bureau.TriggerPropaganda(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return 0.0, 0.0 end

    propagandaMomentum = math_min(
        (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor)
            + Config.Bureau.PropagandaMomentumIncrement,
        Config.Bureau.PropagandaMaxMomentum
    )

    local currentHeat = cyberLeakHeatmap[trapHouseId] or 0.0
    currentHeat = math_min(
        (currentHeat * Config.Bureau.CyberLeakGeometricFactor)
            + Config.Bureau.CyberLeakIncrement,
        Config.Bureau.CyberLeakMaxIntensity
    )
    cyberLeakHeatmap[trapHouseId] = currentHeat
    dirtyIntel[trapHouseId]       = true

    Matrix.Log('BUREAU', 'Propaganda: momentum=%.2f, trap #%d heat=%.2f',
        propagandaMomentum, trapHouseId, currentHeat)

    return propagandaMomentum, currentHeat
end

function Matrix.Bureau.GetPropagandaMomentum()
    return propagandaMomentum
end

local function FlushDirtyIntel()
    for id in pairs(dirtyIntel) do
        local heat = cyberLeakHeatmap[id] or 0.0
        MySQL.prepare([[
            INSERT INTO matrix_bureau_intel (trap_house_id, category, intensity, updated_at)
            VALUES (?, 'cyber_leak', ?, NOW())
            ON DUPLICATE KEY UPDATE intensity = VALUES(intensity), updated_at = NOW()
        ]], { id, heat })
        dirtyIntel[id] = nil
    end
end

-- =====================================================================
-- TICK (ticker çağırır → await yok)
-- =====================================================================
function Matrix.Bureau.Tick()
    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        if not house.raid_ordered then
            local regularity = ComputePatternRegularity(trapHouseId)
            local heat       = cyberLeakHeatmap[trapHouseId] or 0.0
            local gain       = Config.Bureau.PatternAnalysisGain * regularity * (1.0 + heat)

            if gain > 0.0 then
                Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)
            end
        end
    end
end

-- =====================================================================
-- RAID (fiziksel Şafak Baskını: deterministik mürettebat/breach/kaçış matrisi)
-- =====================================================================

-- Mürettebat büyüklüğü siber yoğunluğa (heat) bağlı, tavanlı; breach yöntemi
-- deşifre kesinliğine bağlı (>= eşik: explosive, altı: ram); kaçış penceresi
-- trap house bir telekom kör noktasına yakınsa (Büro telsizi de bozulur) uzar.
-- Hepsi deterministik config sabitlerinden gelir, RNG yok.
local function ComputeRaidSquad(trapHouseId, house)
    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local squadSize = math_floor(Config.Bureau.RaidBaseSquadSize + (heat * Config.Bureau.RaidHeatSquadFactor) + 0.5)
    squadSize = math_max(Config.Bureau.RaidBaseSquadSize, math_min(squadSize, Config.Bureau.RaidMaxSquadSize))

    local breachMethod = (house.decryption_confidence >= Config.Bureau.RaidExplosiveBreachThreshold)
        and 'explosive' or 'ram'

    local escapeWindow = Config.Bureau.RaidBaseEscapeWindowSeconds
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(house.coords, zone.coords) <= zone.radius then
            escapeWindow = escapeWindow + Config.Bureau.RaidDeadZoneEscapeBonusSeconds
            break
        end
    end

    return squadSize, breachMethod, escapeWindow
end

function Matrix.Bureau.IssueRaid(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end
    if house.raid_ordered then return end

    local decryptionAtRaid = house.decryption_confidence
    local squadSize, breachMethod, escapeWindow = ComputeRaidSquad(trapHouseId, house)

    house.raid_ordered          = true
    house.decryption_confidence = Config.Bureau.PostRaidDecryptionReset
    cyberLeakHeatmap[trapHouseId] = (cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.PostRaidHeatmapDecay
    patternLog[trapHouseId]     = {}

    MySQL.prepare([[
        UPDATE matrix_trap_houses
        SET raid_ordered = 1, last_raid_at = NOW(),
            decryption_confidence = ?, cyber_leak_intensity = ?
        WHERE id = ?
    ]], {
        Config.Bureau.PostRaidDecryptionReset,
        cyberLeakHeatmap[trapHouseId],
        trapHouseId
    })

    MySQL.insert([[
        INSERT INTO matrix_raid_log (
            trap_house_id, squad_size, breach_method, decryption_confidence_at_raid,
            escape_window_seconds, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, 'pending', NOW())
    ]], { trapHouseId, squadSize, breachMethod, decryptionAtRaid, escapeWindow },
    function(insertId)
        if insertId then RaidLogIdByTrapHouse[trapHouseId] = insertId end
    end)

    -- Fiziksel kapı kırma/enjeksiyon animasyonu client-taraflıdır (bu repo'da
    -- client.lua yok); burada sadece deterministik karar kontratı iletilir.
    TriggerClientEvent('matrix:client:executeRaid', -1, trapHouseId, house.coords, {
        squad_size    = squadSize,
        breach_method = breachMethod,
        escape_window = escapeWindow
    })

    Matrix.Log('BUREAU', '[ŞAFAK BASKINI] Trap house #%d (%s) emri üretildi: %d birim, breach=%s, kaçış penceresi=%ds.',
        trapHouseId, house.label, squadSize, breachMethod, escapeWindow)
end

local VALID_RAID_OUTCOMES = { captured = true, escaped = true, eliminated = true }

function Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
    if not VALID_RAID_OUTCOMES[outcome] then return false end
    local logId = RaidLogIdByTrapHouse[trapHouseId]
    if not logId then return false end

    MySQL.prepare('UPDATE matrix_raid_log SET outcome = ?, resolved_at = NOW() WHERE id = ?', { outcome, logId })
    Matrix.Log('BUREAU', 'Baskın (kayıt #%d, trap #%d) sonuçlandı: %s', logId, trapHouseId, outcome)
    return true
end

function Matrix.Bureau.ReceiveSnitchLeak(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local target = Config.Bureau.RaidDecryptionThreshold + 0.05
    if house.decryption_confidence < target then
        house.decryption_confidence = target
    end
    dirtyDecryption[trapHouseId] = true
    -- AdvanceDecryption çağırmak IssueRaid tetikleyebilir; bilinçli atlıyoruz.
end

-- =====================================================================
-- FLUSH LOOP
-- =====================================================================
CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyDecryption()
        FlushDirtyIntel()
    end
end)

-- =====================================================================
-- QB-PHONE CANLI YAYIN KANCASI & SİBER PROPAGANDA
-- qb-phone fork'ları event adlarını farklı isimlendirebilir; bu yüzden bu
-- dosya kendi sabit event adını kullanır ('matrix:server:reportLivestream*')
-- ve qb-phone tarafında bu event'i tetikleyen tek satırlık bir köprü
-- eklenmesi gerekir (qb-phone'un kendi Live/livestream event handler'ından
-- TriggerServerEvent('matrix:server:reportLivestreamStart') çağrılır).
-- =====================================================================
RegisterNetEvent('matrix:server:reportLivestreamStart', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if LivestreamSessions[src] then return end

    local state = Matrix.GetOrCreatePlayerState(src)
    LivestreamSessions[src] = {
        started    = Matrix.Now(),
        citizenid  = state and state.citizenid,
        hype       = 1.0,
        heat_added = 0.0,
        trap_house_id = nil
    }
    Matrix.Log('BUREAU', '[CANLI YAYIN BAŞLADI] src=%d, IP çıkışı Büro siber taramasına açıldı.', src)
end)

RegisterNetEvent('matrix:server:reportLivestreamStop', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local session = LivestreamSessions[src]
    if not session then return end
    LivestreamSessions[src] = nil

    local duration = Matrix.Now() - session.started
    MySQL.prepare([[
        INSERT INTO matrix_livestream_events (citizenid, duration_seconds, hype_multiplier, heat_added, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { session.citizenid, duration, session.hype, session.heat_added, session.trap_house_id })

    Matrix.Log('BUREAU', '[CANLI YAYIN BİTTİ] src=%d, süre=%ds, son hype=%.2f, eklenen heat=%.2f',
        src, duration, session.hype, session.heat_added)
end)

-- Hype tick'i (1000ms, kendi bağımsız thread'i — master ticker'ı kirletmez).
-- İtibar Çarpanı (R_hype) geometrik büyür ve doğrudan propagandaMomentum'u da
-- besler (Recruit_chance zaten momentum'a bağlı, ayrı bir kanal icat edilmedi).
-- Bedel: en yakın trap house'un cyber-leak heatmap'i botun skill_cyber'iyle
-- çarpılarak yükselir ve Şafak Baskını sayacı (deşifre kazancı) öne çekilir.
CreateThread(function()
    while true do
        Wait(1000)
        for src, session in pairs(LivestreamSessions) do
            local ped = GetPlayerPed(src)
            if not ped or ped == 0 then
                LivestreamSessions[src] = nil
            else
                session.hype = math_min(
                    (session.hype * Config.Bureau.LivestreamHypeGeometricFactor) + Config.Bureau.LivestreamHypeIncrementPerTick,
                    Config.Bureau.PropagandaMaxMomentum
                )

                propagandaMomentum = math_min(
                    (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor) + Config.Bureau.PropagandaMomentumIncrement,
                    Config.Bureau.PropagandaMaxMomentum
                )

                local coords = GetEntityCoords(ped)
                local trapHouseId, dist = FindNearestTrapHouse(coords)
                if trapHouseId and dist <= Config.Bureau.BaseSearchRadius then
                    session.trap_house_id = trapHouseId

                    local cyberSkill = 1.0
                    for _, bot in pairs(Matrix.Bots) do
                        if bot.state.trap_house_id == trapHouseId then
                            cyberSkill = Matrix.Kitchen.GetEffectiveSkill(bot, 'skill_cyber')
                            break
                        end
                    end
                    cyberSkill = math_max(cyberSkill, 0.1)

                    local heatGain = Config.Bureau.LivestreamHeatIncrementPerTick * cyberSkill
                    cyberLeakHeatmap[trapHouseId] = math_min(
                        ((cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.CyberLeakGeometricFactor) + heatGain,
                        Config.Bureau.CyberLeakMaxIntensity
                    )
                    dirtyIntel[trapHouseId] = true
                    session.heat_added = session.heat_added + heatGain

                    Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Bureau.LivestreamDecryptionGainPerTick * cyberSkill)
                end
            end
        end
    end
end)

-- =====================================================================
-- EVENT BRIDGE (guard'lı)
-- =====================================================================
RegisterNetEvent('matrix:server:reportUnencryptedComms', function(coords)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not IsValidCoords(coords) then return end
    Matrix.Bureau.OnUnencryptedComms({ kind = 'player', source = src }, coords)
end)

RegisterNetEvent('matrix:server:triggerPropaganda', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.TriggerPropaganda(trapHouseId)
end)

RegisterNetEvent('matrix:server:reportLogisticsRun', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.LogPatternEvent(trapHouseId)
end)

RegisterNetEvent('matrix:server:reportRaidOutcome', function(trapHouseId, outcome)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
end)
