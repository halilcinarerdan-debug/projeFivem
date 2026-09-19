Matrix = {}
Matrix.Bots = {}
Matrix.PlayerState = {}
Matrix.Inventory = {}
Matrix.NextBotId = 1

local QBCore = exports['qb-core']:GetCoreObject()
Matrix.QBCore = QBCore

function Matrix.Log(tag, fmt, ...)
    print(('[MATRIX:%s] %s'):format(tag, fmt:format(...)))
end

function Matrix.Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

function Matrix.Now()
    return os.time()
end

function Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    local item = exports.ox_inventory:GetSlot(inventoryId, slot)
    return (item and item.metadata) or {}
end

function Matrix.Inventory.MergeMetadata(inventoryId, slot, patch)
    local current = Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    for key, value in pairs(patch) do
        current[key] = value
    end
    exports.ox_inventory:SetMetadata(inventoryId, slot, current)
    return current
end

function Matrix.CreateBotRecord(profile)
    local id = Matrix.NextBotId
    Matrix.NextBotId = Matrix.NextBotId + 1

    local bot = {
        id = id,
        dna_id = profile.dna_id or ('DNA-%08d'):format(id),
        name = profile.name or ('Operative-%d'):format(id),
        role = profile.role or 'runner',
        status = 'active',
        psychology = {
            fear_factor = profile.fear_factor or 0.0,
            resilience = profile.resilience or 0.5,
            snitch_tendency = profile.snitch_tendency or 0.0,
            economic_pressure = profile.economic_pressure or 0.0,
            cognitive_shifter = profile.cognitive_shifter or 0.5,
            skill_chemistry = profile.skill_chemistry or 0.3
        },
        biology = {
            fatigue_level = 0.0,
            cortisol_level = 0.0,
            withdrawal_index = 0.0,
            addiction_level = profile.addiction_level or 0.0,
            base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
            fatigue_critical_since = nil,
            burned_this_episode = false
        },
        state = {
            activity = profile.activity or 'idle',
            trap_house_id = profile.trap_house_id,
            coords = profile.coords,
            spawned = false,
            net_id = nil,
            elapsed_seconds = 0
        }
    }

    Matrix.Bots[id] = bot
    Matrix.PersistBot(bot)
    Matrix.Log('CORE', 'Bot #%d matrise yazildi: %s (%s)', id, bot.name, bot.role)
    return bot
end

function Matrix.GetBot(id)
    return Matrix.Bots[id]
end

function Matrix.RemoveBot(id, reason)
    local bot = Matrix.Bots[id]
    if not bot then return end

    bot.status = reason or 'burned'
    Matrix.PersistBot(bot)
    Matrix.Log('CORE', 'Bot #%d aktif matristen kaldirildi: %s', id, bot.status)
    Matrix.Bots[id] = nil
end

function Matrix.ResolveActor(actorRef)
    if not actorRef then return nil end

    if actorRef.kind == 'bot' then
        return Matrix.Bots[actorRef.id]
    elseif actorRef.kind == 'player' then
        return Matrix.GetOrCreatePlayerState(actorRef.source)
    end

    return nil
end

function Matrix.GetOrCreatePlayerState(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return nil end

    local citizenid = player.PlayerData.citizenid
    local state = Matrix.PlayerState[citizenid]

    if not state then
        state = {
            id = citizenid,
            citizenid = citizenid,
            dna_id = ('DNA-PLR-%s'):format(citizenid),
            psychology = {
                skill_chemistry = Config.Player.DefaultSkillChemistry
            },
            biology = {
                fatigue_level = 0.0,
                cortisol_level = 0.0,
                resilience = Config.Player.DefaultResilience,
                base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
                last_update = Matrix.Now()
            },
            state = { activity = 'idle' }
        }

        Matrix.PlayerState[citizenid] = state

        MySQL.query.await([[
            INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
            VALUES (?, ?, ?, NOW())
            ON DUPLICATE KEY UPDATE citizenid = citizenid
        ]], { citizenid, 0.0, 0.0 })
    else
        Matrix.DecayPlayerCortisol(state)
    end

    return state
end

function Matrix.DecayPlayerCortisol(state)
    local now = Matrix.Now()
    local elapsedMinutes = math.floor((now - state.biology.last_update) / 60)
    if elapsedMinutes <= 0 then return end

    local recovery = state.biology.base_cortisol_recovery_rate * state.biology.resilience * elapsedMinutes
    state.biology.cortisol_level = Matrix.Clamp(state.biology.cortisol_level - recovery, 0.0, 1.0)
    state.biology.last_update = state.biology.last_update + (elapsedMinutes * 60)
end

function Matrix.PersistBot(bot)
    MySQL.query.await([[
        INSERT INTO matrix_bots (
            id, dna_id, name, role, status,
            fear_factor, resilience, snitch_tendency, economic_pressure, cognitive_shifter, skill_chemistry,
            fatigue_level, cortisol_level, withdrawal_index, addiction_level, base_cortisol_recovery_rate,
            trap_house_id, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            name = VALUES(name), role = VALUES(role), status = VALUES(status),
            fear_factor = VALUES(fear_factor), resilience = VALUES(resilience),
            snitch_tendency = VALUES(snitch_tendency), economic_pressure = VALUES(economic_pressure),
            cognitive_shifter = VALUES(cognitive_shifter), skill_chemistry = VALUES(skill_chemistry),
            fatigue_level = VALUES(fatigue_level), cortisol_level = VALUES(cortisol_level),
            withdrawal_index = VALUES(withdrawal_index), addiction_level = VALUES(addiction_level),
            base_cortisol_recovery_rate = VALUES(base_cortisol_recovery_rate),
            trap_house_id = VALUES(trap_house_id), updated_at = NOW()
    ]], {
        bot.id, bot.dna_id, bot.name, bot.role, bot.status,
        bot.psychology.fear_factor, bot.psychology.resilience, bot.psychology.snitch_tendency,
        bot.psychology.economic_pressure, bot.psychology.cognitive_shifter, bot.psychology.skill_chemistry,
        bot.biology.fatigue_level, bot.biology.cortisol_level, bot.biology.withdrawal_index,
        bot.biology.addiction_level, bot.biology.base_cortisol_recovery_rate,
        bot.state.trap_house_id
    })
end

local function LoadBotsFromDatabase()
    local rows = MySQL.query.await('SELECT * FROM matrix_bots WHERE status = ?', { 'active' })

    for _, row in ipairs(rows) do
        Matrix.Bots[row.id] = {
            id = row.id,
            dna_id = row.dna_id,
            name = row.name,
            role = row.role,
            status = row.status,
            psychology = {
                fear_factor = row.fear_factor,
                resilience = row.resilience,
                snitch_tendency = row.snitch_tendency,
                economic_pressure = row.economic_pressure,
                cognitive_shifter = row.cognitive_shifter,
                skill_chemistry = row.skill_chemistry
            },
            biology = {
                fatigue_level = row.fatigue_level,
                cortisol_level = row.cortisol_level,
                withdrawal_index = row.withdrawal_index,
                addiction_level = row.addiction_level,
                base_cortisol_recovery_rate = row.base_cortisol_recovery_rate,
                fatigue_critical_since = nil,
                burned_this_episode = false
            },
            state = {
                activity = 'idle',
                trap_house_id = row.trap_house_id,
                coords = nil,
                spawned = false,
                net_id = nil,
                elapsed_seconds = 0
            }
        }

        if row.id >= Matrix.NextBotId then
            Matrix.NextBotId = row.id + 1
        end
    end

    Matrix.Log('CORE', '%d bot matristen belleğe yüklendi.', #rows)
end

local MATRIX_DEALER_MODEL = 's_m_y_dealer_01'
local MATRIX_PED_INJECTION_MAX_TICKS = 50

function Matrix.SpawnBot(id, coords)
    local bot = Matrix.Bots[id]
    if not bot then
        Matrix.Log('CORE', '[HATA] Spawn reddedildi: Bot #%d matriste bulunamadı.', id)
        return false
    end

    if bot.state.spawned then
        Matrix.Log('CORE', '[HATA] Spawn reddedildi: Bot #%d zaten aktif.', id)
        return false
    end

    local modelHash = GetHashKey(MATRIX_DEALER_MODEL)
    local heading = coords.w or 0.0

    local ped = CreatePed(4, modelHash, coords.x, coords.y, coords.z, heading, true, false)

    local injectionTicks = 0
    while not DoesEntityExist(ped) and injectionTicks < MATRIX_PED_INJECTION_MAX_TICKS do
        Wait(0)
        injectionTicks = injectionTicks + 1
    end

    if not DoesEntityExist(ped) then
        Matrix.Log('CORE', '[HATA] Bot #%d için OneSync ped doğrulaması zaman aşımına uğradı.', id)
        return false
    end

    SetEntityAsMissionEntity(ped, true, true)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    bot.state.spawned = true
    bot.state.net_id = netId
    bot.state.coords = vector3(coords.x, coords.y, coords.z)

    TriggerClientEvent('matrix:client:injectBot', -1, id, bot.role, coords, bot.dna_id, netId)
    Matrix.Log('CORE', 'Bot #%d dünyaya enjekte edildi (%.1f, %.1f, %.1f) NetID:%d', id, coords.x, coords.y, coords.z, netId)
    return true, netId
end

function Matrix.DespawnBot(id)
    local bot = Matrix.Bots[id]
    if not bot then
        Matrix.Log('CORE', '[HATA] Despawn reddedildi: Bot #%d matriste bulunamadı.', id)
        return false
    end

    if not bot.state.spawned then
        Matrix.Log('CORE', '[HATA] Despawn reddedildi: Bot #%d zaten pasif.', id)
        return false
    end

    if bot.state.net_id then
        local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            DeleteEntity(ped)
        end
    end

    TriggerClientEvent('matrix:client:extractBot', -1, id)

    bot.state.spawned = false
    bot.state.net_id = nil

    Matrix.Log('CORE', 'Bot #%d dünyadan silindi ve saf veriye (arka plan cache matrisine) geri çekildi.', id)
    return true
end

local bureauAccumulator = 0

CreateThread(function()
    LoadBotsFromDatabase()

    while true do
        Wait(Config.Tick.IntervalMs)
        bureauAccumulator = bureauAccumulator + 1

        for _, bot in pairs(Matrix.Bots) do
            if bot.status == 'active' then
                bot.state.elapsed_seconds = bot.state.elapsed_seconds + 1

                if bot.state.elapsed_seconds % Config.Tick.SecondsPerMinute == 0 then
                    Matrix.Kitchen.ProcessMinuteCycle(bot)
                end

                if bot.state.elapsed_seconds % Config.Tick.SecondsPerHour == 0 then
                    Matrix.Kitchen.ProcessHourCycle(bot)
                end
            end
        end

        if bureauAccumulator >= Config.Bureau.AnalysisIntervalSeconds then
            bureauAccumulator = 0
            Matrix.Bureau.Tick()
            Matrix.Recruitment.ScanCustomerPool()
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, bot in pairs(Matrix.Bots) do
        Matrix.PersistBot(bot)
    end

    Matrix.Log('CORE', 'Tüm bot verileri kalıcı depoya yazıldı. Kaynak durduruluyor.')
end)

local function ForwardCoordsFromPlayer(source, distance)
    local ped = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(ped)
    local playerHeading = GetEntityHeading(ped)
    local rad = math.rad(playerHeading)

    return vector4(
        playerCoords.x - (math.sin(rad) * distance),
        playerCoords.y + (math.cos(rad) * distance),
        playerCoords.z,
        (playerHeading + 180.0) % 360.0
    )
end

QBCore.Commands.Add('botyarat', 'Yeni pasif bot matrisi olusturur (Katman 1: Core Matrix)', {
    { name = 'name', help = 'Bot adi (ornek: Ricky_Trap)' },
    { name = 'role', help = 'Rol: dealer/runner/lookout/cooking' }
}, true, function(source, args)
    local name = args[1]
    local role = args[2] or 'runner'

    local bot = Matrix.CreateBotRecord({ name = name, role = role })

    TriggerClientEvent('chat:addMessage', source, {
        args = { '[MATRIX]', ('Bot #%d matrise yazıldı: %s (%s)'):format(bot.id, bot.name, bot.role) }
    })
end)

QBCore.Commands.Add('botspawn', 'Belirtilen botu oyuncunun tam onune enjekte eder (Katman 1: Entity Injection)', {
    { name = 'id', help = 'Bot ID' }
}, true, function(source, args)
    local botId = tonumber(args[1])
    if not botId then
        TriggerClientEvent('chat:addMessage', source, { args = { '[MATRIX]', 'Geçersiz bot ID.' } })
        return
    end

    local spawnCoords = ForwardCoordsFromPlayer(source, 2.0)
    local success = Matrix.SpawnBot(botId, spawnCoords)

    TriggerClientEvent('chat:addMessage', source, {
        args = {
            '[MATRIX]',
            success and ('Bot #%d enjekte edildi.'):format(botId) or ('Bot #%d enjekte edilemedi.'):format(botId)
        }
    })
end)

QBCore.Commands.Add('botdespawn', 'Botu dunyadan tamamen siler ve hafiza matrisine geri ceker (0 Resmon hedefi)', {
    { name = 'id', help = 'Bot ID' }
}, true, function(source, args)
    local botId = tonumber(args[1])
    if not botId then
        TriggerClientEvent('chat:addMessage', source, { args = { '[MATRIX]', 'Geçersiz bot ID.' } })
        return
    end

    local success = Matrix.DespawnBot(botId)

    TriggerClientEvent('chat:addMessage', source, {
        args = {
            '[MATRIX]',
            success and ('Bot #%d hafıza matrisine geri çekildi.'):format(botId) or ('Bot #%d geri çekilemedi.'):format(botId)
        }
    })
end)

exports('CreateBot', function(profile) return Matrix.CreateBotRecord(profile) end)
exports('SpawnBot', function(id, coords) return Matrix.SpawnBot(id, coords) end)
exports('DespawnBot', function(id) return Matrix.DespawnBot(id) end)
exports('RemoveBot', function(id, reason) return Matrix.RemoveBot(id, reason) end)
exports('GetBot', function(id) return Matrix.GetBot(id) end)

exports('ReportWeaponDischarge', function(actorRef, weaponSerial, inventoryId, slot)
    return Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, inventoryId, slot)
end)
exports('StampTouch', function(actorRef, inventoryId, slot)
    return Matrix.Forensics.StampTouch(actorRef, inventoryId, slot)
end)
exports('AnalyzeEvidence', function(evidenceId)
    return Matrix.Forensics.AnalyzeEvidence(evidenceId)
end)

exports('ProcessCook', function(actorRef, trapHouseId, rawWeight, rawPurity, agentWeight)
    return Matrix.Kitchen.ProcessCook(actorRef, trapHouseId, rawWeight, rawPurity, agentWeight)
end)
exports('AdjustCortisol', function(actorRef, spikeType)
    return Matrix.Kitchen.AdjustCortisol(actorRef, spikeType)
end)
exports('OnBotCaptured', function(botId, trapHouseId)
    return Matrix.Kitchen.OnCaptured(botId, trapHouseId)
end)

exports('TriggerPropaganda', function(trapHouseId)
    return Matrix.Bureau.TriggerPropaganda(trapHouseId)
end)
exports('ReportUnencryptedComms', function(actorRef, coords)
    return Matrix.Bureau.OnUnencryptedComms(actorRef, coords)
end)
exports('ReportLogisticsRun', function(trapHouseId)
    return Matrix.Bureau.LogPatternEvent(trapHouseId)
end)

exports('ScanCustomerPool', function() return Matrix.Recruitment.ScanCustomerPool() end)
exports('BeginInterrogation', function(candidateId, src) return Matrix.Recruitment.BeginInterrogation(candidateId, src) end)
exports('ApplyInterrogationPressure', function(sessionId, amount) return Matrix.Recruitment.ApplyPressure(sessionId, amount) end)
exports('EvaluateInterrogation', function(sessionId) return Matrix.Recruitment.EvaluateOutcome(sessionId) end)
