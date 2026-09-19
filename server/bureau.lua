Matrix.Bureau = {}
Matrix.TrapHouses = {}

local propagandaMomentum = 0.0
local cyberLeakHeatmap = {}
local patternLog = {}

local function VectorDistance(a, b)
    return #(a - b)
end

function Matrix.Bureau.LoadTrapHouses()
    local rows = MySQL.query.await('SELECT * FROM matrix_trap_houses', {})

    for _, row in ipairs(rows) do
        Matrix.TrapHouses[row.id] = {
            id = row.id,
            label = row.label,
            coords = vector3(row.coord_x, row.coord_y, row.coord_z),
            decryption_confidence = row.decryption_confidence,
            raid_ordered = row.raid_ordered == 1
        }
        cyberLeakHeatmap[row.id] = row.cyber_leak_intensity or 0.0
        patternLog[row.id] = {}
    end

    Matrix.Log('BUREAU', '%d trap house yüklendi.', #rows)
end

local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math.huge

    for id, house in pairs(Matrix.TrapHouses) do
        local dist = VectorDistance(coords, house.coords)
        if dist < nearestDist then
            nearestId, nearestDist = id, dist
        end
    end

    return nearestId, nearestDist
end

function Matrix.Bureau.LogPatternEvent(trapHouseId)
    if not patternLog[trapHouseId] then patternLog[trapHouseId] = {} end

    local dt = os.date('*t')
    local bucketKey = ('%d_%d'):format(dt.wday, dt.hour)
    patternLog[trapHouseId][bucketKey] = (patternLog[trapHouseId][bucketKey] or 0) + 1

    MySQL.query.await([[
        INSERT INTO matrix_pattern_log (trap_house_id, day_of_week, hour_of_day, occurrence_count)
        VALUES (?, ?, ?, 1)
        ON DUPLICATE KEY UPDATE occurrence_count = occurrence_count + 1
    ]], { trapHouseId, dt.wday, dt.hour })
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

function Matrix.Bureau.AdvanceDecryption(trapHouseId, amount)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    house.decryption_confidence = Matrix.Clamp(house.decryption_confidence + amount, 0.0, 1.0)

    MySQL.query.await('UPDATE matrix_trap_houses SET decryption_confidence = ? WHERE id = ?', {
        house.decryption_confidence, trapHouseId
    })

    if house.decryption_confidence >= Config.Bureau.RaidDecryptionThreshold and not house.raid_ordered then
        Matrix.Bureau.IssueRaid(trapHouseId)
    end
end

function Matrix.Bureau.OnUnencryptedComms(actorRef, coords)
    local actor = Matrix.ResolveActor(actorRef)

    local hitTowers = {}
    for _, tower in ipairs(Config.Bureau.CellTowers) do
        if VectorDistance(coords, tower.coords) <= Config.Bureau.TowerRange then
            hitTowers[#hitTowers + 1] = tower
        end
    end

    if #hitTowers == 0 then
        return nil
    end

    local sumX, sumY, sumZ, sumWeight = 0.0, 0.0, 0.0, 0.0
    for _, tower in ipairs(hitTowers) do
        local dist = math.max(VectorDistance(coords, tower.coords), 1.0)
        local weight = 1.0 / dist
        sumX = sumX + (tower.coords.x * weight)
        sumY = sumY + (tower.coords.y * weight)
        sumZ = sumZ + (tower.coords.z * weight)
        sumWeight = sumWeight + weight
    end

    local estimate = vector3(sumX / sumWeight, sumY / sumWeight, sumZ / sumWeight)
    local narrowedRadius = Config.Bureau.BaseSearchRadius / #hitTowers

    local trapHouseId, distToTrap = FindNearestTrapHouse(estimate)
    if not trapHouseId or distToTrap > narrowedRadius then
        return { estimate = estimate, radius = narrowedRadius }
    end

    Matrix.Bureau.LogPatternEvent(trapHouseId)

    local heatmapIntensity = cyberLeakHeatmap[trapHouseId] or 0.0
    local normalizedRadius = math.max(narrowedRadius / Config.Bureau.BaseSearchRadius, 0.01)
    local gain = (Config.Bureau.TriangulationDecryptionGain / normalizedRadius) * (1.0 + heatmapIntensity) / #hitTowers

    Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)

    Matrix.Log(
        'BUREAU',
        'Sinyal üçgenlemesi (%s): %d istasyon kesişimi, yarıçap %.1fm, trap house #%d üzerinde %.4f kazanç',
        (actor and actor.dna_id) or 'UNKNOWN', #hitTowers, narrowedRadius, trapHouseId, gain
    )

    return { estimate = estimate, radius = narrowedRadius, trap_house_id = trapHouseId, gain = gain }
end

function Matrix.Bureau.TriggerPropaganda(trapHouseId)
    propagandaMomentum = math.min(
        (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor) + Config.Bureau.PropagandaMomentumIncrement,
        Config.Bureau.PropagandaMaxMomentum
    )

    local currentHeat = cyberLeakHeatmap[trapHouseId] or 0.0
    currentHeat = math.min(
        (currentHeat * Config.Bureau.CyberLeakGeometricFactor) + Config.Bureau.CyberLeakIncrement,
        Config.Bureau.CyberLeakMaxIntensity
    )
    cyberLeakHeatmap[trapHouseId] = currentHeat

    MySQL.query.await([[
        INSERT INTO matrix_bureau_intel (trap_house_id, category, intensity, updated_at)
        VALUES (?, 'cyber_leak', ?, NOW())
        ON DUPLICATE KEY UPDATE intensity = VALUES(intensity), updated_at = NOW()
    ]], { trapHouseId, currentHeat })

    Matrix.Log(
        'BUREAU',
        'Propaganda tetiklendi: recruitment momentum %.2f, trap house #%d siber sızıntı yoğunluğu %.2f',
        propagandaMomentum, trapHouseId, currentHeat
    )

    return propagandaMomentum, currentHeat
end

function Matrix.Bureau.GetPropagandaMomentum()
    return propagandaMomentum
end

function Matrix.Bureau.Tick()
    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        if not house.raid_ordered then
            local regularity = ComputePatternRegularity(trapHouseId)
            local heatmapIntensity = cyberLeakHeatmap[trapHouseId] or 0.0
            local gain = Config.Bureau.PatternAnalysisGain * regularity * (1.0 + heatmapIntensity)

            if gain > 0.0 then
                Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)
            end
        end
    end
end

function Matrix.Bureau.IssueRaid(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    house.raid_ordered = true
    house.decryption_confidence = Config.Bureau.PostRaidDecryptionReset
    cyberLeakHeatmap[trapHouseId] = (cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.PostRaidHeatmapDecay
    patternLog[trapHouseId] = {}

    MySQL.query.await([[
        UPDATE matrix_trap_houses
        SET raid_ordered = 1, last_raid_at = NOW(), decryption_confidence = ?, cyber_leak_intensity = ?
        WHERE id = ?
    ]], { Config.Bureau.PostRaidDecryptionReset, cyberLeakHeatmap[trapHouseId], trapHouseId })

    TriggerClientEvent('matrix:client:executeRaid', -1, trapHouseId, house.coords)
    Matrix.Log('BUREAU', '[ŞAFAK BASKINI EMRİ] Trap house #%d (%s) için dinamik baskın emri üretildi.', trapHouseId, house.label)
end

function Matrix.Bureau.ReceiveSnitchLeak(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    house.decryption_confidence = math.max(house.decryption_confidence, Config.Bureau.RaidDecryptionThreshold + 0.05)
    Matrix.Bureau.AdvanceDecryption(trapHouseId, 0.0)
end

CreateThread(function()
    Matrix.Bureau.LoadTrapHouses()
end)

RegisterNetEvent('matrix:server:reportUnencryptedComms', function(coords)
    local src = source
    Matrix.Bureau.OnUnencryptedComms({ kind = 'player', source = src }, coords)
end)

RegisterNetEvent('matrix:server:triggerPropaganda', function(trapHouseId)
    Matrix.Bureau.TriggerPropaganda(trapHouseId)
end)

RegisterNetEvent('matrix:server:reportLogisticsRun', function(trapHouseId)
    Matrix.Bureau.LogPatternEvent(trapHouseId)
end)
