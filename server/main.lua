-- =====================================================================
-- MATRIX CORE / main.lua
-- Write-behind persistence, NaN-safe math, guard-clause hardening.
-- =====================================================================

-- ---------- Upvalue localization (perf) ----------
local pairs, ipairs, next       = pairs, ipairs, next
local type, tostring, tonumber  = type, tostring, tonumber
local table, string, math, os   = table, string, math, os
local setmetatable              = setmetatable
local tonumber, select          = tonumber, select
local math_floor, math_max      = math.floor, math.max
local math_min, math_huge       = math.min, math.huge
local math_rad, math_sin        = math.rad, math.sin
local math_cos                  = math.cos

local CreateThread              = CreateThread
local Wait                      = Wait
local CreatePed                 = CreatePed
local DoesEntityExist           = DoesEntityExist
local DeleteEntity              = DeleteEntity
local SetEntityAsMissionEntity  = SetEntityAsMissionEntity
local GetHashKey                = GetHashKey
local GetGameTimer              = GetGameTimer
local NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local GetPlayerPed              = GetPlayerPed
local GetEntityCoords           = GetEntityCoords
local GetEntityHeading          = GetEntityHeading
local TriggerClientEvent        = TriggerClientEvent
local RegisterCommand           = RegisterCommand
local RegisterNetEvent          = RegisterNetEvent
local AddEventHandler           = AddEventHandler
local GetCurrentResourceName    = GetCurrentResourceName
-- UYARI: `source` BİLİNÇLİ OLARAK localize edilmez. FiveM her event/komut
-- çağrısından hemen önce global `source`'u günceller; dosya yüklenirken bir
-- kez `local source = source` yapmak bu değeri yükleme anındaki bayat
-- değerde donduracağı ve her handler'da aynı (yanlış) src okunmasına yol
-- açacağı için KESİNLİKLE YAPILMAZ.

-- ---------- Namespace ----------
Matrix       = Matrix       or {}
Matrix.Bots  = Matrix.Bots  or {}
Matrix.PlayerState = Matrix.PlayerState or {}
Matrix.Inventory   = Matrix.Inventory   or {}
Matrix.PlayerSourceIndex = Matrix.PlayerSourceIndex or {} -- src -> citizenid
Matrix.NextBotId = Matrix.NextBotId or 1

local QBCore    = exports['qb-core']:GetCoreObject()
Matrix.QBCore   = QBCore

-- =====================================================================
-- CORE MATHEMATICS
-- =====================================================================
function Matrix.Log(tag, fmt, ...)
    if select('#', ...) > 0 then
        print(('[MATRIX:%s] %s'):format(tag, fmt:format(...)))
    else
        print(('[MATRIX:%s] %s'):format(tag, fmt))
    end
end

--- NaN/inf güvenli clamp.
function Matrix.Clamp(value, minV, maxV)
    if type(value) ~= 'number' or value ~= value or value == math_huge or value == -math_huge then
        return minV
    end
    if value < minV then return minV end
    if value > maxV then return maxV end
    return value
end

function Matrix.Now()
    return os.time()
end

-- =====================================================================
-- ENVANTER SARIMI
-- =====================================================================
function Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    if not inventoryId or not slot then return {} end
    local ok, item = pcall(exports['ox_inventory'].GetSlot, exports['ox_inventory'], inventoryId, slot)
    if not ok or not item or type(item) ~= 'table' then return {} end
    return item.metadata or {}
end

function Matrix.Inventory.MergeMetadata(inventoryId, slot, patch)
    local current = Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    if type(current) ~= 'table' then current = {} end
    if type(patch) ~= 'table' then return current end
    for key, value in pairs(patch) do
        current[key] = value
    end
    pcall(exports['ox_inventory'].SetMetadata, exports['ox_inventory'], inventoryId, slot, current)
    return current
end

-- =====================================================================
-- TELSİZ KÖPRÜSÜ (pma-voice / qb-radio)
-- pma-voice ve qb-radio'nun kesin export imzaları fork'tan fork'a değişir;
-- burada tahmini export adları pcall ile korumalı denenir (biri/ikisi de
-- yoksa sessizce yutulur). Asıl statik/parazit efekti nihayetinde client
-- event'i ('matrix:client:applyRadioStatic') dinleyen bir client script
-- tarafından uygulanmalıdır - bu dosya sadece server-taraflı kararı verir.
-- =====================================================================
Matrix.Radio = Matrix.Radio or {}

function Matrix.Radio.ApplyStatic(targetSrc, intensity, reason)
    if type(targetSrc) ~= 'number' or targetSrc <= 0 then return false end
    intensity = Matrix.Clamp(tonumber(intensity) or 1.0, 0.0, 1.0)

    pcall(function()
        exports['pma-voice']:SetRadioStatic(targetSrc, intensity)
    end)
    pcall(function()
        exports['qb-radio']:SetRadioNoise(targetSrc, intensity)
    end)

    TriggerClientEvent('matrix:client:applyRadioStatic', targetSrc, intensity, reason or 'unknown')
    return true
end

-- =====================================================================
-- PERSISTENCE QUEUE (write-behind, batch, async)
-- =====================================================================
Matrix.Persistence = {
    dirtyBots        = {},
    lastBotFlush     = 0,
    botFlushMs       = Config.Persistence.BotFlushIntervalMs,
    botFlushMaxBatch = Config.Persistence.BotFlushMaxBatch
}
local P = Matrix.Persistence

function Matrix.MarkBotDirty(botId)
    if botId then P.dirtyBots[botId] = true end
end

-- Tek UPSERT sorgusu için değer/parametre üret.
local BOT_ROW_SQL = '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())'
local BOT_UPSERT_HEAD =
    'INSERT INTO matrix_bots (id, dna_id, name, role, status, ' ..
    'fear_factor, resilience, snitch_tendency, economic_pressure, cognitive_shifter, skill_chemistry, ' ..
    'skill_cyber, skill_logistics, ' ..
    'fatigue_level, cortisol_level, withdrawal_index, addiction_level, base_cortisol_recovery_rate, ' ..
    'trap_house_id, updated_at) VALUES '
local BOT_UPSERT_TAIL =
    ' ON DUPLICATE KEY UPDATE ' ..
    'name=VALUES(name), role=VALUES(role), status=VALUES(status), ' ..
    'fear_factor=VALUES(fear_factor), resilience=VALUES(resilience), ' ..
    'snitch_tendency=VALUES(snitch_tendency), economic_pressure=VALUES(economic_pressure), ' ..
    'cognitive_shifter=VALUES(cognitive_shifter), skill_chemistry=VALUES(skill_chemistry), ' ..
    'skill_cyber=VALUES(skill_cyber), skill_logistics=VALUES(skill_logistics), ' ..
    'fatigue_level=VALUES(fatigue_level), cortisol_level=VALUES(cortisol_level), ' ..
    'withdrawal_index=VALUES(withdrawal_index), addiction_level=VALUES(addiction_level), ' ..
    'base_cortisol_recovery_rate=VALUES(base_cortisol_recovery_rate), ' ..
    'trap_house_id=VALUES(trap_house_id), updated_at=NOW()'

local function BuildBotUpsert(botList)
    local n = #botList
    if n == 0 then return nil, nil end

    local rows = {}
    for i = 1, n do rows[i] = BOT_ROW_SQL end

    local params = {}
    local idx = 1
    for i = 1, n do
        local b = botList[i]
        params[idx] = b.id                                       ; idx = idx + 1
        params[idx] = b.dna_id                                   ; idx = idx + 1
        params[idx] = b.name                                     ; idx = idx + 1
        params[idx] = b.role                                     ; idx = idx + 1
        params[idx] = b.status                                   ; idx = idx + 1
        params[idx] = b.psychology.fear_factor                   ; idx = idx + 1
        params[idx] = b.psychology.resilience                    ; idx = idx + 1
        params[idx] = b.psychology.snitch_tendency               ; idx = idx + 1
        params[idx] = b.psychology.economic_pressure             ; idx = idx + 1
        params[idx] = b.psychology.cognitive_shifter             ; idx = idx + 1
        params[idx] = b.psychology.skill_chemistry               ; idx = idx + 1
        params[idx] = b.psychology.skill_cyber                   ; idx = idx + 1
        params[idx] = b.psychology.skill_logistics               ; idx = idx + 1
        params[idx] = b.biology.fatigue_level                    ; idx = idx + 1
        params[idx] = b.biology.cortisol_level                   ; idx = idx + 1
        params[idx] = b.biology.withdrawal_index                 ; idx = idx + 1
        params[idx] = b.biology.addiction_level                  ; idx = idx + 1
        params[idx] = b.biology.base_cortisol_recovery_rate      ; idx = idx + 1
        params[idx] = b.state.trap_house_id                      ; idx = idx + 1
    end

    local query = BOT_UPSERT_HEAD .. table.concat(rows, ',') .. BOT_UPSERT_TAIL
    return query, params
end

--- Ticker tarafından periyodik çağrılır. Async fire-and-forget.
function Matrix.FlushDirtyBots()
    local dirty = P.dirtyBots
    if not next(dirty) then return 0 end

    local batch, count = {}, 0
    for id in pairs(dirty) do
        local bot = Matrix.Bots[id]
        if bot then
            count = count + 1
            batch[count] = bot
        end
        dirty[id] = nil
        if count >= P.botFlushMaxBatch then break end
    end
    if count == 0 then return 0 end

    local query, params = BuildBotUpsert(batch)
    if query then
        MySQL.prepare(query, params) -- async (promise), bloklamaz
    end
    return count
end

--- Sync varyantı sadece kapanışta kullanılır.
local function PersistAllBotsSync()
    local batch, count = {}, 0
    for _, bot in pairs(Matrix.Bots) do
        count = count + 1
        batch[count] = bot
    end
    if count == 0 then return end
    local query, params = BuildBotUpsert(batch)
    if query then
        pcall(function() MySQL.query.await(query, params) end)
    end
end

function Matrix.PersistBot(bot)
    if bot and bot.id then P.dirtyBots[bot.id] = true end
end

-- =====================================================================
-- BOT LIFECYCLE
-- =====================================================================
function Matrix.CreateBotRecord(profile)
    profile = profile or {}

    local id = Matrix.NextBotId
    Matrix.NextBotId = id + 1

    local bot = {
        id     = id,
        dna_id = profile.dna_id or ('DNA-%08d'):format(id),
        name   = profile.name   or ('Operative-%d'):format(id),
        role   = profile.role   or 'runner',
        status = 'active',
        psychology = {
            fear_factor       = Matrix.Clamp(profile.fear_factor or 0.0,       0.0, 1.0),
            resilience        = Matrix.Clamp(profile.resilience or 0.5,        0.0, 1.0),
            snitch_tendency   = Matrix.Clamp(profile.snitch_tendency or 0.0,   0.0, 1.0),
            economic_pressure = Matrix.Clamp(profile.economic_pressure or 0.0, 0.0, 1.0),
            cognitive_shifter = Matrix.Clamp(profile.cognitive_shifter or 0.5, 0.0, 1.0),
            skill_chemistry   = Matrix.Clamp(profile.skill_chemistry or 0.3,   0.0, 1.0),
            skill_cyber       = Matrix.Clamp(profile.skill_cyber or 0.0,       0.0, 1.0),
            skill_logistics   = Matrix.Clamp(profile.skill_logistics or 0.0,   0.0, 1.0)
        },
        biology = {
            fatigue_level             = 0.0,
            cortisol_level            = 0.0,
            withdrawal_index          = 0.0,
            addiction_level           = Matrix.Clamp(profile.addiction_level or 0.0, 0.0, 100.0),
            base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
            fatigue_critical_since    = nil,
            burned_this_episode       = false
        },
        state = {
            activity        = profile.activity or 'idle',
            trap_house_id   = profile.trap_house_id,
            coords          = profile.coords,
            spawned         = false,
            net_id          = nil,
            elapsed_seconds = 0
        }
    }

    Matrix.Bots[id] = bot
    Matrix.MarkBotDirty(id)
    Matrix.Log('CORE', 'Bot #%d matrise yazildi: %s (%s)', id, bot.name, bot.role)
    return bot
end

function Matrix.GetBot(id) return Matrix.Bots[id] end

function Matrix.RemoveBot(id, reason)
    local bot = Matrix.Bots[id]
    if not bot then return false end

    bot.status = reason or 'burned'

    local query, params = BuildBotUpsert({ bot })
    if query then MySQL.prepare(query, params) end

    P.dirtyBots[id] = nil
    Matrix.Bots[id] = nil
    Matrix.Log('CORE', 'Bot #%d aktif matristen kaldirildi: %s', id, bot.status)
    return true
end

-- =====================================================================
-- ACTOR RESOLUTION
-- =====================================================================
function Matrix.ResolveActor(actorRef)
    if type(actorRef) ~= 'table' then return nil end
    if actorRef.kind == 'bot' and actorRef.id then
        return Matrix.Bots[actorRef.id]
    end
    if actorRef.kind == 'player' and type(actorRef.source) == 'number' then
        return Matrix.GetOrCreatePlayerState(actorRef.source)
    end
    return nil
end

function Matrix.GetOrCreatePlayerState(src)
    if type(src) ~= 'number' or src <= 0 then return nil end

    local player = QBCore.Functions.GetPlayer(src)
    if not player or not player.PlayerData then return nil end

    local citizenid = player.PlayerData.citizenid
    if not citizenid then return nil end

    local state = Matrix.PlayerState[citizenid]
    if state then
        Matrix.DecayPlayerCortisol(state)
        Matrix.PlayerSourceIndex[src] = citizenid
        return state
    end

    state = {
        id         = citizenid,
        citizenid  = citizenid,
        dna_id     = ('DNA-PLR-%s'):format(citizenid),
        psychology = { skill_chemistry = Config.Player.DefaultSkillChemistry },
        biology    = {
            fatigue_level             = 0.0,
            cortisol_level            = 0.0,
            resilience                = Config.Player.DefaultResilience,
            base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
            last_update               = Matrix.Now()
        },
        state = { activity = 'idle' }
    }

    Matrix.PlayerState[citizenid]       = state
    Matrix.PlayerSourceIndex[src]       = citizenid

    -- Async upsert: yeni oyuncu bloğunu beklemeden başlat
    MySQL.prepare([[
        INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
        VALUES (?, 0.0, 0.0, NOW())
        ON DUPLICATE KEY UPDATE citizenid = citizenid
    ]], { citizenid })

    return state
end

function Matrix.DecayPlayerCortisol(state)
    if not state or not state.biology then return end
    local now = Matrix.Now()
    local last = state.biology.last_update or now
    local elapsedMinutes = math_floor((now - last) / 60)
    if elapsedMinutes <= 0 then return end

    local recovery = state.biology.base_cortisol_recovery_rate
                     * state.biology.resilience
                     * elapsedMinutes
    state.biology.cortisol_level = Matrix.Clamp(state.biology.cortisol_level - recovery, 0.0, 1.0)
    state.biology.last_update    = last + (elapsedMinutes * 60)
end

-- =====================================================================
-- DB LOAD
-- =====================================================================
local function LoadBotsFromDatabase()
    local rows = MySQL.query.await('SELECT * FROM matrix_bots WHERE status = ?', { 'active' }) or {}
    for _, row in ipairs(rows) do
        Matrix.Bots[row.id] = {
            id = row.id, dna_id = row.dna_id, name = row.name,
            role = row.role, status = row.status,
            psychology = {
                fear_factor       = row.fear_factor       or 0.0,
                resilience        = row.resilience        or 0.5,
                snitch_tendency   = row.snitch_tendency   or 0.0,
                economic_pressure = row.economic_pressure or 0.0,
                cognitive_shifter = row.cognitive_shifter or 0.5,
                skill_chemistry   = row.skill_chemistry   or 0.3,
                skill_cyber       = row.skill_cyber       or 0.0,
                skill_logistics   = row.skill_logistics   or 0.0
            },
            biology = {
                fatigue_level             = row.fatigue_level              or 0.0,
                cortisol_level            = row.cortisol_level             or 0.0,
                withdrawal_index          = row.withdrawal_index           or 0.0,
                addiction_level           = row.addiction_level            or 0.0,
                base_cortisol_recovery_rate = row.base_cortisol_recovery_rate or Config.BaseCortisolRecoveryRate,
                fatigue_critical_since    = nil,
                burned_this_episode       = false
            },
            state = {
                activity        = 'idle',
                trap_house_id   = row.trap_house_id,
                coords          = nil,
                spawned         = false,
                net_id          = nil,
                elapsed_seconds = 0
            }
        }
        if row.id >= Matrix.NextBotId then
            Matrix.NextBotId = row.id + 1
        end
    end
    Matrix.Log('CORE', '%d bot matristen belleğe yüklendi.', #rows)
end

-- =====================================================================
-- PED SPAWN / DESPAWN
-- =====================================================================
-- "0 Resmon" kısıtı: Wait(0) her yerde yasak. Ped ağ-kaydının onayını
-- 10ms'lik sınırlı bir bekleme ile poll'luyoruz (maks. 500ms).
local MATRIX_PED_INJECTION_MAX_TICKS   = 50
local MATRIX_PED_INJECTION_POLL_MS     = 10

function Matrix.SpawnBot(id, coords)
    local bot = Matrix.Bots[id]
    if not bot then return false, 'bot_missing' end
    if bot.state.spawned then return false, 'already_spawned' end
    if type(coords) ~= 'vector4' and type(coords) ~= 'vector3' then
        return false, 'bad_coords'
    end

    local modelName = Config.RoleModels[bot.role] or Config.DefaultRoleModel
    local modelHash = GetHashKey(modelName)
    local x, y, z   = coords.x, coords.y, coords.z
    local heading   = coords.w or 0.0

    local ped = CreatePed(4, modelHash, x, y, z, heading, true, false)

    local ticks = 0
    while not DoesEntityExist(ped) and ticks < MATRIX_PED_INJECTION_MAX_TICKS do
        Wait(MATRIX_PED_INJECTION_POLL_MS)
        ticks = ticks + 1
    end

    if not DoesEntityExist(ped) then
        Matrix.Log('CORE', '[HATA] Bot #%d OneSync ped doğrulaması zaman aşımı.', id)
        return false, 'timeout'
    end

    SetEntityAsMissionEntity(ped, true, true)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    bot.state.spawned = true
    bot.state.net_id  = netId
    bot.state.coords  = vector3(x, y, z)

    TriggerClientEvent('matrix:client:injectBot', -1, id, bot.role, coords, bot.dna_id, netId)
    Matrix.Log('CORE', 'Bot #%d enjekte edildi [%s] NetID:%d', id, modelName, netId)
    return true, netId
end

function Matrix.DespawnBot(id)
    local bot = Matrix.Bots[id]
    if not bot then return false end
    if not bot.state.spawned then return false end

    if bot.state.net_id then
        local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            DeleteEntity(ped)
        end
    end

    TriggerClientEvent('matrix:client:extractBot', -1, id)

    bot.state.spawned = false
    bot.state.net_id  = nil
    Matrix.Log('CORE', 'Bot #%d dünyadan çekildi.', id)
    return true
end

-- =====================================================================
-- TICKER (async-safe)
-- =====================================================================
local bureauAccumulator = 0

CreateThread(function()
    LoadBotsFromDatabase()

    local interval       = Config.Tick.IntervalMs
    local secPerMin      = Config.Tick.SecondsPerMinute
    local secPerHour     = Config.Tick.SecondsPerHour
    local bureauInterval = Config.Bureau.AnalysisIntervalSeconds

    while true do
        Wait(interval)
        bureauAccumulator = bureauAccumulator + 1

        for _, bot in pairs(Matrix.Bots) do
            if bot.status == 'active' then
                local s = bot.state.elapsed_seconds + 1
                bot.state.elapsed_seconds = s

                if s % secPerMin == 0 then
                    Matrix.Kitchen.ProcessMinuteCycle(bot)
                end
                if s % secPerHour == 0 then
                    Matrix.Kitchen.ProcessHourCycle(bot)
                end
            end
        end

        -- Oyuncu panik-telsiz kontrolü: kortizol eşiği geçildiğinde parazit
        -- uygula. DecayPlayerCortisol her çağrıda güvenlidir (I/O yok, sadece
        -- bellek), master ticker'ı kirletmez.
        for src, citizenid in pairs(Matrix.PlayerSourceIndex) do
            local state = Matrix.PlayerState[citizenid]
            if state and state.biology then
                Matrix.DecayPlayerCortisol(state)
                if state.biology.cortisol_level > Config.Kitchen.CortisolDeviationThreshold then
                    Matrix.Radio.ApplyStatic(src, state.biology.cortisol_level, 'panic')
                end
            end
        end

        if bureauAccumulator >= bureauInterval then
            bureauAccumulator = 0
            Matrix.Bureau.Tick()
            -- ScanCustomerPool senkron MySQL.query.await icerir; master ticker'i
            -- bloklamamak icin kendi coroutine'inde (async-safe) calistirilir.
            CreateThread(function()
                Matrix.Recruitment.ScanCustomerPool()
            end)
        end
    end
end)

-- Ayrı flush thread (ticker'ı kirletmez)
CreateThread(function()
    while true do
        Wait(Matrix.Persistence.botFlushMs)
        Matrix.FlushDirtyBots()
    end
end)

-- =====================================================================
-- SHUTDOWN
-- =====================================================================
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    PersistAllBotsSync()

    -- Oyuncu state'lerini de yaz
    for citizenid, state in pairs(Matrix.PlayerState) do
        pcall(function()
            MySQL.query.await([[
                INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE cortisol_level = VALUES(cortisol_level),
                    fatigue_level = VALUES(fatigue_level), updated_at = NOW()
            ]], { citizenid, state.biology.cortisol_level, state.biology.fatigue_level })
        end)
    end

    Matrix.Log('CORE', 'Tüm veri kalıcı depoya yazıldı. Kapanış tamamlandı.')
end)

-- =====================================================================
-- PLAYER DROP CLEANUP (memory leak önleme)
-- =====================================================================
AddEventHandler('playerDropped', function()
    local src = source
    local citizenid = Matrix.PlayerSourceIndex[src]
    if not citizenid then return end

    local state = Matrix.PlayerState[citizenid]
    if state then
        MySQL.prepare([[
            INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
            VALUES (?, ?, ?, NOW())
            ON DUPLICATE KEY UPDATE cortisol_level = VALUES(cortisol_level),
                fatigue_level = VALUES(fatigue_level), updated_at = NOW()
        ]], { citizenid, state.biology.cortisol_level, state.biology.fatigue_level })

        Matrix.PlayerState[citizenid] = nil
    end
    Matrix.PlayerSourceIndex[src] = nil
end)

-- =====================================================================
-- KOMUTLAR (guard-clause hardened)
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[MATRIX]', msg } })
    else
        print(('[MATRIX:CONSOLE] %s'):format(msg))
    end
end

local function SafeForwardCoords(src, distance)
    if type(src) ~= 'number' or src <= 0 then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c  = GetEntityCoords(ped)
    local hd = GetEntityHeading(ped)
    local rad = math_rad(hd)
    return vector4(
        c.x - (math_sin(rad) * distance),
        c.y + (math_cos(rad) * distance),
        c.z,
        (hd + 180.0) % 360.0
    )
end

RegisterCommand('botyarat', function(src, args)
    local name = args[1]
    local role = args[2] or 'runner'
    if type(name) ~= 'string' or name == '' then
        Reply(src, 'Kullanim: /botyarat [isim] [rol]'); return
    end
    if not Config.RoleModels[role] and role ~= Config.DefaultRoleModel then
        -- bilinmeyen rol → default
        role = 'runner'
    end

    local bot = Matrix.CreateBotRecord({ name = name, role = role })
    Reply(src, ('Bot #%d matrise yazıldı: %s (%s)'):format(bot.id, bot.name, bot.role))
end, false)

RegisterCommand('botspawn', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /botspawn [id]'); return end
    local coords = SafeForwardCoords(src, 2.0)
    if not coords then Reply(src, 'Spawn için geçerli bir ped gerekli.'); return end
    local ok = Matrix.SpawnBot(botId, coords)
    Reply(src, ok and ('Bot #%d enjekte edildi.'):format(botId)
              or  ('Bot #%d enjekte edilemedi.'):format(botId))
end, false)

RegisterCommand('botdespawn', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /botdespawn [id]'); return end
    local ok = Matrix.DespawnBot(botId)
    Reply(src, ok and ('Bot #%d hafıza matrisine geri çekildi.'):format(botId)
              or  ('Bot #%d geri çekilemedi.'):format(botId))
end, false)

RegisterCommand('balistiktest', function(src, args)
    local weaponSerial = tostring(args[1] or 'TEST-SERIAL-0001')
    local weaponWear   = Matrix.Clamp(tonumber(args[2]) or 0.0, 0.0, 1.0)

    local result = Matrix.Forensics.SimulateWeaponFire({ kind = 'player', source = src }, weaponSerial, weaponWear, 'test_fire')
    if not result then Reply(src, 'Test başarısız: oyuncu profili çözülemedi.'); return end

    Reply(src, ('BalistikID:%s | Q_kovan:%.3f | Parmak izi:%.3f | Eşleşme:%.3f | Mühür:%s'):format(
        result.ballistic_id, result.striation_quality, result.fingerprint_quality,
        result.match_certainty, tostring(result.sealed)))
end, false)

RegisterCommand('botbalistik', function(src, args)
    local botId = tonumber(args[1])
    if not botId or not Matrix.Bots[botId] then
        Reply(src, 'Kullanim: /botbalistik [id] [seri] [asinma 0-1]'); return
    end
    local weaponSerial = tostring(args[2] or ('TEST-SERIAL-BOT-%d'):format(botId))
    local weaponWear   = Matrix.Clamp(tonumber(args[3]) or 0.0, 0.0, 1.0)

    local result = Matrix.Forensics.SimulateWeaponFire({ kind = 'bot', id = botId }, weaponSerial, weaponWear, 'test_fire')
    if not result then Reply(src, 'Test başarısız.'); return end

    Reply(src, ('Bot #%d | BalistikID:%s | Q_kovan:%.3f | Eşleşme:%.3f | Mühür:%s'):format(
        botId, result.ballistic_id, result.striation_quality,
        result.match_certainty, tostring(result.sealed)))
end, false)

RegisterCommand('kortizolum', function(src)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state then Reply(src, 'Profil çözülemedi.'); return end

    Reply(src, ('Kortizol:%.2f | Yorgunluk:%.2f | Direnç:%.2f | Toparlanma:%.4f'):format(
        state.biology.cortisol_level, state.biology.fatigue_level,
        state.biology.resilience, state.biology.base_cortisol_recovery_rate))
end, false)

RegisterCommand('kortizoltetikle', function(src, args)
    local spikeType = args[1] or 'gunshot'
    if spikeType ~= 'gunshot' and spikeType ~= 'bureau_vehicle' then
        Reply(src, 'Kullanim: /kortizoltetikle [gunshot|bureau_vehicle]'); return
    end
    Matrix.Kitchen.AdjustCortisol({ kind = 'player', source = src }, spikeType)
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then
        Reply(src, ('Kortizol sıçraması (%s). Yeni seviye: %.2f'):format(spikeType, state.biology.cortisol_level))
    end
end, false)

RegisterCommand('botdurum', function(src, args)
    local botId = tonumber(args[1])
    local bot = botId and Matrix.Bots[botId]
    if not bot then Reply(src, 'Kullanim: /botdurum [id]'); return end
    Reply(src, ('Bot #%d [%s] Kortizol:%.2f Yorgunluk:%.2f Yoksunluk:%.2f Direnç:%.2f'):format(
        bot.id, bot.name, bot.biology.cortisol_level, bot.biology.fatigue_level,
        bot.biology.withdrawal_index, bot.psychology.resilience))
end, false)

-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('CreateBot',   function(p) return Matrix.CreateBotRecord(p) end)
exports('SpawnBot',    function(id, c) return Matrix.SpawnBot(id, c) end)
exports('DespawnBot',  function(id) return Matrix.DespawnBot(id) end)
exports('RemoveBot',   function(id, r) return Matrix.RemoveBot(id, r) end)
exports('GetBot',      function(id) return Matrix.GetBot(id) end)

exports('ReportWeaponDischarge', function(actorRef, weaponSerial, invId, slot)
    return Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, invId, slot)
end)
exports('SimulateWeaponFire', function(actorRef, weaponSerial, wear, evType)
    return Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, wear, evType)
end)
exports('StampTouch',     function(actorRef, invId, slot) return Matrix.Forensics.StampTouch(actorRef, invId, slot) end)
exports('AnalyzeEvidence',function(evId) return Matrix.Forensics.AnalyzeEvidence(evId) end)

exports('ProcessCook',  function(a, t, rw, rp, aw) return Matrix.Kitchen.ProcessCook(a, t, rw, rp, aw) end)
exports('AdjustCortisol',function(a, s) return Matrix.Kitchen.AdjustCortisol(a, s) end)
exports('OnBotCaptured', function(b, t) return Matrix.Kitchen.OnCaptured(b, t) end)

exports('TriggerPropaganda',    function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms',function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',   function(t) return Matrix.Bureau.LogPatternEvent(t) end)

exports('ScanCustomerPool',       function() return Matrix.Recruitment.ScanCustomerPool() end)
exports('BeginInterrogation',     function(c, s) return Matrix.Recruitment.BeginInterrogation(c, s) end)
exports('ApplyInterrogationPressure', function(s, a) return Matrix.Recruitment.ApplyPressure(s, a) end)
exports('EvaluateInterrogation',  function(s) return Matrix.Recruitment.EvaluateOutcome(s) end)
