-- =====================================================================
-- MATRIX CORE / server/main.lua  (KATMAN 5 — ATMOSFERİK EVRİM SÜRÜMÜ)
--
-- ★ ÖNCEKİ SERTLEŞTİRME (v1, korunuyor):
--   [H8] BeginPhysicalDispatch HATA YOLLARINDA ENTITY SIZINTISI KAPATILDI:
--        CreatePed/CreateVehicle başarılı olup AwaitEntityCreation başarısız
--        olursa entity artık DeleteEntity ile DÜNYADAN SİLİNİR; task atama
--        (TaskGoStraightToCoord / TaskVehicleDriveToCoord) pcall ile
--        sarmalandı — başarısız olursa yarım kalan ped/araç temizlenip
--        'task_assignment_failed' döner.
--   [H9] CompleteDispatch içinde entity NetID'leri TABLO SIFIRLANMADAN ÖNCE
--        yakalanır ve pcall sınırları içinde tek tek temizlenir. Böylece
--        [H3]'teki iki-fazlı yapıda "bot silinmiş + dispatch düşmüş"
--        durumunda dahi entity'ler (RAM'deki ağ referansları ve dünyadaki
--        ped/araç) ORPHAN KALMAZ.
--   [H10] TickPhysicalDispatches Faz 2'de pcall(CompleteDispatch) başarısız
--        olursa Dispatches[botId] ZORLA nil'lenir (kalıcı RAM sızıntısı yok).
--
-- ★ KATMAN 5 EVRİM (bu sürüm):
--   [H11] MULTI-WAYPOINT TAKTİK ROTA MOTORU: BeginPhysicalDispatch'in
--        ped/araç doğum mantığı SpawnDispatchActors() içine çıkarılıp
--        ortaklaştırıldı (DRY, [H8] hardening korunarak). Yeni
--        Matrix.BeginRouteDispatch() botu N ara uğraktan geçirip en sonda
--        final hedefe (ana üs) sızdırır: bot bir uğrağa vardığı an
--        (dist <= DISPATCH_ARRIVAL_RADIUS_M) DURAKSAMADAN bir sonraki
--        uğrağa yeniden görevlendirilir (AdvanceRouteWaypoint). Işınlanma
--        koruması HER bacak (origin->wp1->wp2->wp3->final) için ayrı ayrı
--        uygulanır — tek bir bacak bile MinDispatchDistanceMeters'in
--        altındaysa zincir HİÇBİR entity dünyaya doğmadan tamamen reddedilir.
--   [H12] CO-OP MUTEX: bot.state.is_locked, bir dispatch (tekli veya
--        rotalı) aktifken o bota İKİNCİ bir sevk emri verilmesini
--        yapısal olarak engeller. BeginPhysicalDispatch/BeginRouteDispatch
--        başında kontrol edilir, CompleteDispatch/DespawnDispatchEntity'de
--        serbest bırakılır.
--   [H13] TAKTİK HUD VERİ KÖPRÜSÜ: Matrix.Hud.PushSnapshots yalnızca HUD'ı
--        AÇIK olan oyunculara (Matrix.HudViewers) veri gönderir; gönderilen
--        veri HAM float'tır ({ metric=..., value=... }) — edebi/askeri
--        bültene çevirme işi TAMAMEN client/hud.lua'da yapılır ("Sıfır Sayı
--        Standardı"). Sunucu konsolu (print/Matrix.Log) ve /matrixdump bu
--        köprüden ETKİLENMEZ, ham float dökmeye devam eder.
--   [H14] SUNUCU TARAFI PED SPAWN ANTI-CRASH GUARD: 'SetEntityAsMissionEntity'
--        SUNUCU LUA ORTAMINDA TANIMLI DEĞİLDİR (client-only native) — çağrılırsa
--        'attempt to call a nil value' hatasıyla script'i ve canlanma döngüsünü
--        kilitler. Bu sürümde TAMAMEN KALDIRILDI. Kalıcılık/ağ mühürleme artık
--        CreatePed/CreateVehicle/CreatePedInsideVehicle'ın kendi
--        (isNetwork=true, bScriptHostPed=true) bayrakları + doğrulama
--        sonrası 'SetEntityOrphanMode(entity, 2)' [KeepEntity — server'ın
--        entity'yi asla silmemesini garanti eden resmi CFX server-side
--        native'i] ile kurulur. Ayrıca tüm dealer/dispatch ped'leri artık
--        rol bazlı fallback zincirinden (Config.RoleModels/DefaultRoleModel)
--        TAMAMEN AYRIŞTIRILMIŞ, sabit DEALER_PED_MODEL_HASH ('g_m_y_famdnf_01'
--        — kapüşonlu sokak dealer skin'i) kullanır; hiçbir fallback modeline
--        izin verilmez.
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
local math_cos, math_abs        = math.cos, math.abs
local math_sqrt                 = math.sqrt

local CreateThread              = CreateThread
local Wait                      = Wait
local CreatePed                 = CreatePed
local CreatePedInsideVehicle    = CreatePedInsideVehicle
local CreateVehicle             = CreateVehicle
local DoesEntityExist           = DoesEntityExist
local DeleteEntity              = DeleteEntity
-- ★ [H14] SetEntityAsMissionEntity KASITLI OLARAK localize EDİLMEZ: bu
-- native sunucu Lua ortamında TANIMLI DEĞİLDİR (client-only) — burada bir
-- upvalue olarak tutulması bile "kullanılabilir" izlenimi verir. Yerine
-- SetEntityOrphanMode (server-safe, kalıcılık için resmi CFX native'i).
local SetEntityOrphanMode       = SetEntityOrphanMode
local SetEntityCoords           = SetEntityCoords
local SetEntityCoordsNoOffset   = SetEntityCoordsNoOffset
local GetHashKey                = GetHashKey
local GetGameTimer              = GetGameTimer
local NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local GetPlayerPed              = GetPlayerPed
local GetEntityCoords           = GetEntityCoords
local GetEntityHeading          = GetEntityHeading
local TaskVehicleDriveToCoord   = TaskVehicleDriveToCoord
local TaskGoStraightToCoord     = TaskGoStraightToCoord
local TriggerClientEvent        = TriggerClientEvent
local RegisterCommand           = RegisterCommand
local RegisterNetEvent          = RegisterNetEvent
local AddEventHandler           = AddEventHandler
local GetCurrentResourceName    = GetCurrentResourceName

-- ---------- Namespace ----------
Matrix       = Matrix       or {}
Matrix.Bots  = Matrix.Bots  or {}
Matrix.PlayerState = Matrix.PlayerState or {}
Matrix.Inventory   = Matrix.Inventory   or {}
Matrix.PlayerSourceIndex = Matrix.PlayerSourceIndex or {}
Matrix.NextBotId = Matrix.NextBotId or 1
Matrix.Dispatches = Matrix.Dispatches or {}

Matrix.QBX = exports.qbx_core

local PENDING_EVENTS_MAX = 64

-- =====================================================================
-- ★ [H14] KRİTİK ANTI-CRASH GUARD: SUNUCU TARAFI PED SPAWN KISITLAMASI
-- Tüm dealer/dispatch ped spawn'ları bu SABİT hash'i kullanır. Rol bazlı
-- Config.RoleModels/Config.DefaultRoleModel zincirine KASITLI olarak HİÇ
-- başvurulmaz — ciddiyetsiz/uygunsuz skin fallback'ini kökten engeller.
-- =====================================================================
local DEALER_PED_MODEL_NAME = 'g_m_y_famdnf_01' -- Street Dealer / Hooded Runner Skin
local DEALER_PED_MODEL_HASH = GetHashKey(DEALER_PED_MODEL_NAME)

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

function Matrix.Clamp(value, minV, maxV)
    if type(value) ~= 'number' or value ~= value or value == math_huge or value == -math_huge then
        return minV
    end
    if value < minV then return minV end
    if value > maxV then return maxV end
    return value
end

function Matrix.Now() return os.time() end

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
    for key, value in pairs(patch) do current[key] = value end
    pcall(exports['ox_inventory'].SetMetadata, exports['ox_inventory'], inventoryId, slot, current)
    return current
end

-- =====================================================================
-- TELSİZ KÖPRÜSÜ
-- =====================================================================
Matrix.Radio = Matrix.Radio or {}

function Matrix.Radio.ApplyStatic(targetSrc, intensity, reason)
    if type(targetSrc) ~= 'number' or targetSrc <= 0 then return false end
    intensity = Matrix.Clamp(tonumber(intensity) or 1.0, 0.0, 1.0)

    pcall(function() exports['pma-voice']:SetRadioStatic(targetSrc, intensity) end)
    pcall(function() exports['qb-radio']:SetRadioNoise(targetSrc, intensity) end)

    TriggerClientEvent('matrix:client:applyRadioStatic', targetSrc, intensity, reason or 'unknown')
    return true
end

-- =====================================================================
-- PERSISTENCE QUEUE
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
        params[idx] = b.id                                   ; idx = idx + 1
        params[idx] = b.dna_id                               ; idx = idx + 1
        params[idx] = b.name                                 ; idx = idx + 1
        params[idx] = b.role                                 ; idx = idx + 1
        params[idx] = b.status                               ; idx = idx + 1
        params[idx] = b.psychology.fear_factor               ; idx = idx + 1
        params[idx] = b.psychology.resilience                ; idx = idx + 1
        params[idx] = b.psychology.snitch_tendency           ; idx = idx + 1
        params[idx] = b.psychology.economic_pressure         ; idx = idx + 1
        params[idx] = b.psychology.cognitive_shifter         ; idx = idx + 1
        params[idx] = b.psychology.skill_chemistry           ; idx = idx + 1
        params[idx] = b.psychology.skill_cyber               ; idx = idx + 1
        params[idx] = b.psychology.skill_logistics           ; idx = idx + 1
        params[idx] = b.biology.fatigue_level                ; idx = idx + 1
        params[idx] = b.biology.cortisol_level               ; idx = idx + 1
        params[idx] = b.biology.withdrawal_index             ; idx = idx + 1
        params[idx] = b.biology.addiction_level              ; idx = idx + 1
        params[idx] = b.biology.base_cortisol_recovery_rate  ; idx = idx + 1
        params[idx] = b.state.trap_house_id                  ; idx = idx + 1
    end

    local query = BOT_UPSERT_HEAD .. table.concat(rows, ',') .. BOT_UPSERT_TAIL
    return query, params
end

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
        local ok, err = pcall(function() MySQL.prepare(query, params) end)
        if not ok then
            Matrix.Log('CORE', '[HATA] FlushDirtyBots basarisiz (yutuldu): %s', tostring(err))
        end
    end
    return count
end

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
            elapsed_seconds = 0,
            -- ★ [H12] Co-Op Mutex: aktif bir dispatch (tekli/rotalı) varken
            -- bu bota ikinci bir sevk emri verilmesini engeller.
            is_locked       = false,
            -- ★ [H13] Taktik HUD "Mekanik" bülteni için ham silah aşınması
            -- (1.0 = kusursuz, 0.0 = tamamen erimiş). Bkz. /botmekanik.
            weapon_wear_level = 1.0
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

    if Matrix.Dispatches[id] then
        Matrix.DespawnDispatchEntity(id, Matrix.Dispatches[id])
        Matrix.Dispatches[id] = nil
    end

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

    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return nil end
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

    pcall(function()
        MySQL.prepare([[
            INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
            VALUES (?, 0.0, 0.0, NOW())
            ON DUPLICATE KEY UPDATE citizenid = citizenid
        ]], { citizenid })
    end)

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
-- [H1] QBOX onPlayerLoaded — Warm Cache
-- =====================================================================
AddEventHandler('qbx_core:server:onPlayerLoaded', function(payload)
    local src
    if type(payload) == 'table' then
        src = tonumber(payload.source or payload.src or payload[1])
    else
        src = tonumber(payload)
    end
    if not src or src <= 0 then return end
    Matrix.GetOrCreatePlayerState(src)
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if type(player) ~= 'table' or not player.PlayerData then return end
    local src = tonumber(player.PlayerData.source)
    if src and src > 0 then Matrix.GetOrCreatePlayerState(src) end
end)

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
                elapsed_seconds = 0,
                is_locked       = false,
                weapon_wear_level = 1.0
            }
        }
        if row.id >= Matrix.NextBotId then Matrix.NextBotId = row.id + 1 end
    end
    Matrix.Log('CORE', '%d bot matristen belleğe yüklendi.', #rows)
end

-- =====================================================================
-- PED SPAWN / DESPAWN
-- =====================================================================
local MATRIX_PED_INJECTION_MAX_TICKS   = 50
local MATRIX_PED_INJECTION_POLL_MS     = 10

local function AwaitEntityCreation(entity, maxTicks)
    local ticks = 0
    maxTicks = maxTicks or MATRIX_PED_INJECTION_MAX_TICKS
    while not DoesEntityExist(entity) and ticks < maxTicks do
        Wait(MATRIX_PED_INJECTION_POLL_MS)
        ticks = ticks + 1
    end
    return DoesEntityExist(entity)
end
Matrix.AwaitEntityCreation = AwaitEntityCreation

--- ★ [H8] Entity güvenli imha yardımcısı — hem null hem 0 hem de zaten
--- yok olmuş handle'lara karşı dayanıklı.
local function SafeDeleteEntity(handle)
    if not handle or handle == 0 then return end
    local ok = pcall(function()
        if DoesEntityExist(handle) then
            DeleteEntity(handle)
        end
    end)
    return ok
end

function Matrix.SpawnBot(id, coords)
    local bot = Matrix.Bots[id]
    if not bot then return false, 'bot_missing' end
    if bot.state.spawned then return false, 'already_spawned' end
    if type(coords) ~= 'vector4' and type(coords) ~= 'vector3' then
        return false, 'bad_coords'
    end

    local modelHash = DEALER_PED_MODEL_HASH
    local x, y, z   = coords.x, coords.y, coords.z
    local heading   = coords.w or 0.0

    -- ★ [H14] ANTI-CRASH GUARD: SetEntityAsMissionEntity SUNUCUDA ÇAĞRILMAZ
    -- (client-only native → nil value → script kilitlenir). Kalıcılık/ağ
    -- mühürleme CreatePed'in kendi bayrakları + SetEntityOrphanMode ile kurulur.
    local ped = CreatePed(0, modelHash, x, y, z, heading, true, true)
    if not AwaitEntityCreation(ped) then
        SafeDeleteEntity(ped)
        Matrix.Log('CORE', '[HATA] Bot #%d OneSync ped doğrulaması zaman aşımı.', id)
        return false, 'timeout'
    end

    pcall(SetEntityOrphanMode, ped, 2) -- KeepEntity: server entity'yi asla silmez
    local netId = NetworkGetNetworkIdFromEntity(ped)

    bot.state.spawned = true
    bot.state.net_id  = netId
    bot.state.coords  = vector3(x, y, z)

    TriggerClientEvent('matrix:client:injectBot', -1, id, bot.role, coords, bot.dna_id, netId)
    Matrix.Log('CORE', 'Bot #%d enjekte edildi [%s] NetID:%d', id, DEALER_PED_MODEL_NAME, netId)
    return true, netId
end

function Matrix.DespawnBot(id)
    local bot = Matrix.Bots[id]
    if not bot then return false end
    if not bot.state.spawned then return false end

    if bot.state.net_id then
        local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end

    TriggerClientEvent('matrix:client:extractBot', -1, id)
    bot.state.spawned = false
    bot.state.net_id  = nil
    Matrix.Log('CORE', 'Bot #%d dünyadan çekildi.', id)
    return true
end

-- =====================================================================
-- PHYSICAL DISPATCH RUNTIME  ★ REVİZYON #1 + [H8] + KATMAN 5 [H11][H12] ★
-- =====================================================================

local DISPATCH_VEHICLE_MODELS = {
    car       = 'sultan',
    motorbike = 'bati',
}

local DISPATCH_ARRIVAL_RADIUS_M       = 6.0
local DISPATCH_POLICE_PROXIMITY_M     = 60.0
local DISPATCH_POLICE_DECRYPT_TICK    = 0.015
local DISPATCH_BUSTED_PROXIMITY_M     = 8.0
local DISPATCH_BUSTED_DWELL_TICKS     = 8
local DISPATCH_ALPR_RADIUS_M          = 250.0
local DISPATCH_TASK_REISSUE_TICKS     = 25

local DISPATCH_BASE_FOOT_SPEED_MS     = 1.4
local DISPATCH_BASE_VEHICLE_SPEED_MS  = 15.0
local DISPATCH_MIN_SPEED_FRACTION     = 0.25

local PoliceSources       = {}
local policeFailCount     = 0
local policeDisabledUntil = 0

local function RefreshPoliceCache()
    if Matrix.Now() < policeDisabledUntil then return end

    local ok, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
    if not ok or type(players) ~= 'table' then
        policeFailCount = policeFailCount + 1
        if policeFailCount >= 5 then
            policeDisabledUntil = Matrix.Now() + 60
            policeFailCount = 0
            Matrix.Log('CORE', '[UYARI] GetQBPlayers 5 kez ust uste basarisiz oldu; 60sn devre disi birakildi.')
        end
        return
    end
    policeFailCount = 0

    local fresh = {}
    for src, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.job then
            local job = player.PlayerData.job
            if job.onduty and (job.name == 'police' or job.name == 'sheriff' or job.type == 'leo') then
                fresh[src] = true
            end
        end
    end
    PoliceSources = fresh
end

CreateThread(function()
    while true do
        Wait(5000)
        RefreshPoliceCache()
    end
end)

local function LocalGetVehicleProfile(vehicleType)
    return Config.Logistics.VehicleTypes[vehicleType]
        or Config.Logistics.VehicleTypes[Config.Logistics.DefaultVehicleType]
end

local function LocalGetBotInventoryWeight(bot)
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

local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end

local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if #(coords - zone.coords) <= zone.radius then return zone end
    end
    return nil
end

local function FindActiveDeadDropAt(destination)
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if #(destination - drop.coords) <= drop.radius then return drop end
    end
    return nil
end

local function _SafeVec(v)
    return v and v.x == v.x and v.y == v.y and v.z == v.z
           and v.x ~= math_huge and v.x ~= -math_huge
           and v.y ~= math_huge and v.y ~= -math_huge
           and v.z ~= math_huge and v.z ~= -math_huge
end

--- ★ HATA DÜZELTMESİ: FiveM'in vector kütüphanesinde `#` (uzunluk/magnitude)
--- operatörü yalnızca vector3 için tanımlıdır — vector4 üzerinde (veya bir
--- vector4 içeren çıkarma işleminin sonucunda) ÇAĞRILIRSA "attempt to
--- perform unsupported operation on a vector value" hatasıyla script çöker.
--- origin (SafeForwardCoords'tan gelir) DAİMA vector4'tür (heading taşır);
--- ama spawn çağrılarında zaten yalnızca .x/.y/.z okunur, heading hiç
--- kullanılmaz — bu yüzden mesafe/depolama amaçlı TÜM vector'lar dispatch
--- fonksiyonlarına girer girmez burada saf vector3'e indirgenir.
local function _ToVec3(v)
    if type(v) == 'vector4' then return vector3(v.x, v.y, v.z) end
    return v
end

--- ★ [H11] Ortak ped/araç doğum yardımcısı. BeginPhysicalDispatch VE
--- BeginRouteDispatch tarafından paylaşılır; hata yollarında yarım kalan
--- entity'ler DÜNYADAN SİLİNİR (bkz. [H8]) — davranış tek-hedef sürümüyle
--- birebir aynıdır, yalnızca ortaklaştırılmıştır.
local function SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, firstDestination)
    -- ★ [H14] ANTI-CRASH GUARD: sabit model, rol bazlı fallback YOK.
    local pedHash = DEALER_PED_MODEL_HASH
    local isFoot  = (vehicleType == 'foot')

    local ped, vehicle
    local vehicleNetId = nil

    if isFoot then
        -- ★ [H14] SetEntityAsMissionEntity SUNUCUDA ÇAĞRILMAZ (client-only
        -- native → nil value → script kilitlenir).
        ped = CreatePed(0, pedHash, origin.x, origin.y, origin.z, 0.0, true, true)
        if not AwaitEntityCreation(ped) then
            SafeDeleteEntity(ped)
            return nil, nil, nil, nil, 'ped_spawn_timeout'
        end
        pcall(SetEntityOrphanMode, ped, 2) -- KeepEntity: server entity'yi asla silmez
        SetEntityCoords(ped, origin.x, origin.y, origin.z, false, false, false, false)

        local taskOk = pcall(TaskGoStraightToCoord,
            ped,
            firstDestination.x, firstDestination.y, firstDestination.z,
            cruiseSpeed, -1, 0.0, 0.5
        )
        if not taskOk then
            SafeDeleteEntity(ped)
            return nil, nil, nil, nil, 'task_assignment_failed'
        end
    else
        local vehModelName = DISPATCH_VEHICLE_MODELS[vehicleType] or DISPATCH_VEHICLE_MODELS.car
        local vehHash      = GetHashKey(vehModelName)

        -- ★ [H14] SetEntityAsMissionEntity SUNUCUDA ÇAĞRILMAZ; kalıcılık
        -- CreateVehicle'ın kendi (true, true) bayrakları + SetEntityOrphanMode
        -- ile kurulur.
        vehicle = CreateVehicle(vehHash, origin.x, origin.y, origin.z, 0.0, true, true)
        if not AwaitEntityCreation(vehicle) then
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'vehicle_spawn_timeout'
        end
        pcall(SetEntityOrphanMode, vehicle, 2) -- KeepEntity

        ped = CreatePedInsideVehicle(vehicle, 0, pedHash, -1, true, true)
        if not AwaitEntityCreation(ped) then
            SafeDeleteEntity(ped)
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'ped_in_vehicle_timeout'
        end
        pcall(SetEntityOrphanMode, ped, 2) -- KeepEntity

        local taskOk = pcall(TaskVehicleDriveToCoord,
            ped,
            vehicle,
            firstDestination.x, firstDestination.y, firstDestination.z,
            cruiseSpeed,
            0,
            vehHash,
            16777216,
            5.0,
            1
        )
        if not taskOk then
            SafeDeleteEntity(ped)
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'task_assignment_failed'
        end

        vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    end

    local pedNetId = NetworkGetNetworkIdFromEntity(ped)
    return ped, vehicle, pedNetId, vehicleNetId, nil
end

--- ★ [H8][H12] Fiziksel sevki başlatır (tek hedef). Hata yollarında yarım
--- kalan entity'ler DÜNYADAN SİLİNİR — hiçbir ped/araç orphan kalmaz.
--- Co-Op Mutex: bot.state.is_locked true ise sevk hiç başlamaz.
function Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, etaSeconds, dispatcherSrc, frictionDivisor)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    frictionDivisor = Matrix.Clamp(tonumber(frictionDivisor) or 1.0, 1.0, 1.0 / DISPATCH_MIN_SPEED_FRACTION)

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.state.is_locked then return false, 'bot_locked' end
    if Matrix.Dispatches[botId] then return false, 'already_dispatched' end
    if type(origin) ~= 'vector3' and type(origin) ~= 'vector4' then return false, 'bad_origin' end
    if type(destination) ~= 'vector3' and type(destination) ~= 'vector4' then return false, 'bad_destination' end

    -- ★ HATA DÜZELTMESİ: vector4 (heading taşıyan origin) ile vector3
    -- arasındaki `#(a - b)` mesafe hesapları "unsupported operation on a
    -- vector value" ile çöker. Buradan itibaren SAF vector3 kullanılır.
    origin      = _ToVec3(origin)
    destination = _ToVec3(destination)

    if not _SafeVec(origin) or not _SafeVec(destination) then
        return false, 'corrupt_vector'
    end

    -- ★ Işınlanma koruması: dünyada ped/araç DOĞMADAN ÖNCE mesafe kontrolü.
    if #(origin - destination) < Config.Logistics.MinDispatchDistanceMeters then
        return false, 'too_close'
    end

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
        Wait(50)
    end

    local isFoot      = (vehicleType == 'foot')
    local baseSpeed    = isFoot and DISPATCH_BASE_FOOT_SPEED_MS or DISPATCH_BASE_VEHICLE_SPEED_MS
    local cruiseSpeed  = math_max(baseSpeed / frictionDivisor, baseSpeed * DISPATCH_MIN_SPEED_FRACTION)

    local ped, vehicle, pedNetId, vehicleNetId, spawnErr =
        SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, destination)
    if spawnErr then return false, spawnErr end

    bot.state.spawned    = true
    bot.state.net_id     = pedNetId
    bot.state.is_locked  = true

    Matrix.Dispatches[botId] = {
        bot_id            = botId,
        entity_net_id     = pedNetId,
        vehicle_net_id    = vehicleNetId,
        plate             = plate,
        vehicle_type      = vehicleType,
        profile           = LocalGetVehicleProfile(vehicleType),
        origin            = origin,
        destination       = destination,
        route_queue       = nil,
        route_index       = nil,
        eta_estimate      = etaSeconds or 0.0,
        cruise_speed      = cruiseSpeed,
        elapsed           = 0.0,
        last_coords       = origin,
        weight_total      = LocalGetBotInventoryWeight(bot),
        dispatcher_src    = dispatcherSrc,
        comms_lost        = false,
        pending_events    = {},
        alpr_logged_traps = {},
        combat_damage     = 0.0,
        police_dwell      = 0,
        task_retry_ticks  = 0,
        started_at        = Matrix.Now()
    }

    bot.state.activity = 'distribution'

    TriggerClientEvent('matrix:client:injectBot', -1, botId, bot.role, origin, bot.dna_id, pedNetId)

    Matrix.Log('CORE',
        'Fiziksel sevk başlatıldı: Bot #%d [%s] Origin=(%.1f,%.1f,%.1f) → Hedef=(%.1f,%.1f,%.1f)',
        botId, vehicleType, origin.x, origin.y, origin.z, destination.x, destination.y, destination.z)

    return true
end

--- ★ [H11][H12] KATMAN 5: Multi-Waypoint Taktik Rota Motoru.
--- `waypointRefs` sırayla ziyaret edilecek ara nokta listesi (vector3'ler);
--- `finalRef` zincirin sonunda bota "sızma" (arrived) emri verecek ana
--- üs/final hedeftir. Bot bir uğrağa vardığı an (dist <= DISPATCH_ARRIVAL_
--- RADIUS_M) DURAKSAMADAN bir sonraki uğrağa yönlendirilir; zincirin son
--- halkası (finalRef) tamamlandığında dispatch normal şekilde 'arrived'
--- olarak kapanır.
---
--- Işınlanma koruması: HER bacak (origin->wp1->wp2->...->final) ayrı ayrı
--- MinDispatchDistanceMeters ile karşılaştırılır — TEK BİR bacak bile
--- eşiğin altındaysa zincir hiçbir entity dünyaya doğmadan reddedilir.
--- Co-Op Mutex: bot.state.is_locked true ise rota hiç başlamaz.
function Matrix.BeginRouteDispatch(botId, origin, waypointRefs, finalRef, plate, vehicleType, dispatcherSrc, frictionDivisor)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    frictionDivisor = Matrix.Clamp(tonumber(frictionDivisor) or 1.0, 1.0, 1.0 / DISPATCH_MIN_SPEED_FRACTION)

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.state.is_locked then return false, 'bot_locked' end
    if Matrix.Dispatches[botId] then return false, 'already_dispatched' end
    if type(origin) ~= 'vector3' and type(origin) ~= 'vector4' then return false, 'bad_origin' end
    if type(waypointRefs) ~= 'table' or #waypointRefs == 0 then return false, 'bad_waypoints' end
    if type(finalRef) ~= 'vector3' and type(finalRef) ~= 'vector4' then return false, 'bad_destination' end

    -- ★ HATA DÜZELTMESİ: vector4 (heading taşıyan origin) ile vector3
    -- arasındaki `#(a - b)` mesafe hesapları "unsupported operation on a
    -- vector value" ile çöker (bkz. _ToVec3). Buradan itibaren rota
    -- zincirindeki HER nokta SAF vector3'tür.
    origin   = _ToVec3(origin)
    finalRef = _ToVec3(finalRef)
    for i = 1, #waypointRefs do
        waypointRefs[i] = _ToVec3(waypointRefs[i])
    end

    if not _SafeVec(origin) or not _SafeVec(finalRef) then return false, 'corrupt_vector' end
    for i = 1, #waypointRefs do
        if not _SafeVec(waypointRefs[i]) then return false, 'corrupt_vector' end
    end

    local routeQueue = {}
    for i = 1, #waypointRefs do routeQueue[i] = waypointRefs[i] end
    routeQueue[#routeQueue + 1] = finalRef

    -- ★ Işınlanma koruması: HER bacak ayrı ayrı doğrulanır, hiçbir entity
    -- dünyaya doğmadan ÖNCE. Hangi bacağın çok kısa olduğunu çağırana
    -- bildirmek için leg index'i (i) ve ölçülen mesafeyi de döndürür.
    local legOrigin = origin
    for i = 1, #routeQueue do
        local legDest = routeQueue[i]
        local legDist = #(legOrigin - legDest)
        if legDist < Config.Logistics.MinDispatchDistanceMeters then
            return false, 'too_close', i, legDist
        end
        legOrigin = legDest
    end

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
        Wait(50)
    end

    local isFoot      = (vehicleType == 'foot')
    local baseSpeed    = isFoot and DISPATCH_BASE_FOOT_SPEED_MS or DISPATCH_BASE_VEHICLE_SPEED_MS
    local cruiseSpeed  = math_max(baseSpeed / frictionDivisor, baseSpeed * DISPATCH_MIN_SPEED_FRACTION)

    local ped, vehicle, pedNetId, vehicleNetId, spawnErr =
        SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, routeQueue[1])
    if spawnErr then return false, spawnErr end

    bot.state.spawned    = true
    bot.state.net_id     = pedNetId
    bot.state.is_locked  = true

    Matrix.Dispatches[botId] = {
        bot_id            = botId,
        entity_net_id     = pedNetId,
        vehicle_net_id    = vehicleNetId,
        plate             = plate,
        vehicle_type      = vehicleType,
        profile           = LocalGetVehicleProfile(vehicleType),
        origin            = origin,
        destination       = routeQueue[1],
        route_queue       = routeQueue,
        route_index       = 1,
        eta_estimate      = 0.0,
        cruise_speed      = cruiseSpeed,
        elapsed           = 0.0,
        last_coords       = origin,
        weight_total      = LocalGetBotInventoryWeight(bot),
        dispatcher_src    = dispatcherSrc,
        comms_lost        = false,
        pending_events    = {},
        alpr_logged_traps = {},
        combat_damage     = 0.0,
        police_dwell      = 0,
        task_retry_ticks  = 0,
        started_at        = Matrix.Now()
    }

    bot.state.activity = 'distribution'

    TriggerClientEvent('matrix:client:injectBot', -1, botId, bot.role, origin, bot.dna_id, pedNetId)

    Matrix.Log('CORE',
        'Multi-Waypoint rota başlatıldı: Bot #%d [%s] %d ara nokta + final hedef.',
        botId, vehicleType, #waypointRefs)

    return true
end

--- ★ [H9][H12] Aktif bir fiziksel sevki (tekli veya rotalı) sonlandırır ve
--- dünyadan çeker. Entity NetID'leri, Dispatches[botId] nil'lenmeden ÖNCE
--- yakalanır; böylece bot kaydı silinmiş olsa dahi ped/araç orphan KALMAZ.
--- Co-Op Mutex burada serbest bırakılır (is_locked = false).
function Matrix.CompleteDispatch(botId, reason)
    local dispatch = Matrix.Dispatches[botId]
    if not dispatch then return false end

    -- ★ [H9] Snapshot al — sonrasında Dispatches[botId]'yi nil'lesek bile
    -- bu referanslar elimizde kalır.
    local pedNetId     = dispatch.entity_net_id
    local vehicleNetId = dispatch.vehicle_net_id
    local plate        = dispatch.plate
    local destination  = dispatch.destination
    local lastCoords   = dispatch.last_coords

    Matrix.Dispatches[botId] = nil

    local bot = Matrix.Bots[botId]
    if bot then
        if reason == 'arrived' then
            bot.state.activity = 'idle'
            bot.state.coords   = destination

            local drop = FindActiveDeadDropAt(destination)
            if drop and Matrix.Supplier and Matrix.Supplier.OnPickup then
                pcall(Matrix.Supplier.OnPickup, { kind = 'bot', id = botId }, drop.id, nil)
            end
        elseif reason == 'busted' then
            local nearestId = FindNearestTrapHouse(lastCoords or destination)
            if nearestId then
                if Matrix.Kitchen and Matrix.Kitchen.OnCaptured then
                    pcall(Matrix.Kitchen.OnCaptured, botId, nearestId)
                end
            end
            if Matrix.Logistics and Matrix.Logistics.OnDealerEliminated then
                pcall(Matrix.Logistics.OnDealerEliminated, botId, 'police_busted')
            end
        end
    end

    if plate and Matrix.Logistics and Matrix.Logistics.ReleaseVehicleLock then
        pcall(Matrix.Logistics.ReleaseVehicleLock, plate)
    end

    -- ★ [H9] Entity'leri yakalanan NetID'ler üzerinden imha et.
    if pedNetId then
        local ped = NetworkGetEntityFromNetworkId(pedNetId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end
    if vehicleNetId then
        local veh = NetworkGetEntityFromNetworkId(vehicleNetId)
        if veh and veh ~= 0 and DoesEntityExist(veh) then SafeDeleteEntity(veh) end
    end

    if bot then
        bot.state.spawned   = false
        bot.state.net_id    = nil
        -- ★ [H12] Co-Op Mutex serbest bırakılır — bota yeniden sevk emri verilebilir.
        bot.state.is_locked = false
    end

    TriggerClientEvent('matrix:client:extractBot', -1, botId)
    Matrix.Log('CORE', '[SEVK SONLANDI] Bot #%d Sebep:%s', botId, tostring(reason or 'unknown'))
    return true
end

--- Dispatch entity'sini dünyadan siler. Opsiyonel `dispatch` argümanı
--- verilmezse Dispatches[botId] aranır (geriye dönük uyumlu). Co-Op Mutex
--- burada da güvenlik ağı olarak serbest bırakılır.
function Matrix.DespawnDispatchEntity(botId, dispatch)
    dispatch = dispatch or Matrix.Dispatches[botId]
    local bot = Matrix.Bots[botId]

    local pedNetId = dispatch and dispatch.entity_net_id or (bot and bot.state.net_id)

    if pedNetId then
        local ped = NetworkGetEntityFromNetworkId(pedNetId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end

    if dispatch and dispatch.vehicle_net_id then
        local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if veh and veh ~= 0 and DoesEntityExist(veh) then SafeDeleteEntity(veh) end
    end

    if bot then
        bot.state.spawned   = false
        bot.state.net_id    = nil
        bot.state.is_locked = false
    end

    TriggerClientEvent('matrix:client:extractBot', -1, botId)
end

local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end
    Matrix.Log('CORE', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('CORE', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end

local function QueueOrEmit(dispatch, message)
    if dispatch.comms_lost then
        local events = dispatch.pending_events
        if #events >= PENDING_EVENTS_MAX then
            table.remove(events, 1)
        end
        events[#events + 1] = message
    else
        Matrix.Log('CORE', message)
    end
end

--- ★ [H11] Bot bir ara uğrağa (route_queue[route_index]) vardığında,
--- DURAKSAMADAN bir sonraki uğrağa yeniden görevlendirilir. Dispatch
--- 'arrived' olarak KAPANMAZ — zincir devam eder.
local function AdvanceRouteWaypoint(ped, dispatch, botId)
    dispatch.route_index      = dispatch.route_index + 1
    dispatch.destination      = dispatch.route_queue[dispatch.route_index]
    dispatch.task_retry_ticks = 0

    local reissueSpeed = dispatch.cruise_speed or DISPATCH_BASE_VEHICLE_SPEED_MS
    if dispatch.vehicle_net_id then
        local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            pcall(TaskVehicleDriveToCoord,
                ped, veh,
                dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                reissueSpeed, 0, 0, 16777216, 5.0, 1
            )
        end
    else
        pcall(TaskGoStraightToCoord,
            ped,
            dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
            reissueSpeed, -1, 0.0, 0.5
        )
    end

    QueueOrEmit(dispatch, ('[ROTA ZİNCİRİ] Bot #%d %d/%d. uğrağa ulaştı — %d. noktaya anında yönlendirildi.'):format(
        botId, dispatch.route_index - 1, #dispatch.route_queue, dispatch.route_index))
end

function Matrix.TickPhysicalDispatches()
    local toComplete = {}

    for botId, dispatch in pairs(Matrix.Dispatches) do
        local bot = Matrix.Bots[botId]
        if not bot then
            toComplete[botId] = 'failed'
        else
            dispatch.elapsed = dispatch.elapsed + 1.0
            dispatch.task_retry_ticks = dispatch.task_retry_ticks + 1

            local ped = NetworkGetEntityFromNetworkId(dispatch.entity_net_id)
            if not ped or ped == 0 or not DoesEntityExist(ped) then
                Matrix.Log('CORE', '[SEVK KAYIP] Bot #%d fiziksel varlık bulunamadı, iptal.', botId)
                toComplete[botId] = 'failed'
            else
                local coordsRaw = GetEntityCoords(ped)
                local coords    = vector3(coordsRaw.x, coordsRaw.y, coordsRaw.z)
                dispatch.last_coords = coords
                bot.state.coords     = coords

                local distToDest = #(coords - dispatch.destination)
                if distToDest <= DISPATCH_ARRIVAL_RADIUS_M then
                    -- ★ [H11] Rota zinciri: son halkaya varana kadar HİÇ
                    -- duraksamadan bir sonraki uğrağa geç.
                    if dispatch.route_queue and dispatch.route_index < #dispatch.route_queue then
                        AdvanceRouteWaypoint(ped, dispatch, botId)
                    else
                        toComplete[botId] = 'arrived'
                    end
                else
                    local zone = FindDeadZone(coords)
                    if zone and not dispatch.comms_lost then
                        dispatch.comms_lost = true
                        Matrix.Log('CORE', '[BAĞLANTI KESİLDİ] Bot #%d (%s) kör bölgede: %s',
                            botId, bot.name, zone.label)
                        if type(dispatch.dispatcher_src) == 'number' and dispatch.dispatcher_src > 0 then
                            Matrix.Radio.ApplyStatic(dispatch.dispatcher_src, 1.0, 'dead_zone')
                        end
                    elseif (not zone) and dispatch.comms_lost then
                        dispatch.comms_lost = false
                        Matrix.Log('CORE', '[SİNYAL YENİDEN ALINDI] Bot #%d kör bölgeden çıktı.', botId)
                        SetTimeout(Config.Logistics.DeadZoneLogFlushDelayMs, function()
                            if Matrix.Dispatches[botId] == dispatch then
                                FlushPendingEvents(dispatch)
                            end
                        end)
                    end

                    local policeNearby = false
                    local veryClose    = false
                    for src in pairs(PoliceSources) do
                        local policePed = GetPlayerPed(src)
                        if policePed and policePed ~= 0 then
                            local pd = GetEntityCoords(policePed)
                            local d  = #(vector3(pd.x, pd.y, pd.z) - coords)
                            if d <= DISPATCH_POLICE_PROXIMITY_M then
                                policeNearby = true
                                if d <= DISPATCH_BUSTED_PROXIMITY_M then
                                    veryClose = true
                                end
                            end
                        end
                    end

                    if policeNearby then
                        local nearestId, nearestDist = FindNearestTrapHouse(coords)
                        if nearestId and nearestDist <= Config.Bureau.BaseSearchRadius then
                            Matrix.Bureau.AdvanceDecryption(
                                nearestId,
                                DISPATCH_POLICE_DECRYPT_TICK * (dispatch.profile.PoliceDecryptionMultiplier or 1.0)
                            )
                        end
                    end

                    if veryClose then
                        dispatch.police_dwell = dispatch.police_dwell + 1
                    else
                        dispatch.police_dwell = math_max(0, dispatch.police_dwell - 1)
                    end

                    if dispatch.police_dwell >= DISPATCH_BUSTED_DWELL_TICKS then
                        Matrix.Log('CORE', '[PUSU] Bot #%d polis tarafından kuşatıldı.', botId)
                        toComplete[botId] = 'busted'
                    else
                        if dispatch.plate then
                            for trapId, trapHouse in pairs(Matrix.TrapHouses or {}) do
                                if not dispatch.alpr_logged_traps[trapId] then
                                    if #(coords - trapHouse.coords) <= DISPATCH_ALPR_RADIUS_M then
                                        dispatch.alpr_logged_traps[trapId] = true
                                        local veh = Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(dispatch.plate)
                                        if veh then
                                            pcall(Matrix.Fleet.RecordAlprHit, dispatch.plate, bot.dna_id,
                                                veh.registered_by_citizenid, trapId)

                                            local vinMult = Config.Logistics.Fleet.VinDecryptionMultiplier[veh.vin_status] or 1.0
                                            Matrix.Bureau.AdvanceDecryption(
                                                trapId,
                                                DISPATCH_POLICE_DECRYPT_TICK
                                                    * (dispatch.profile.PoliceDecryptionMultiplier or 1.0)
                                                    * vinMult
                                            )
                                            QueueOrEmit(dispatch, ('[ALPR EŞLEŞMESİ] Plaka %s -> DNA %s -> Trap #%d'):format(
                                                dispatch.plate, bot.dna_id, trapId))
                                        end
                                    end
                                end
                            end
                        end

                        if dispatch.task_retry_ticks >= DISPATCH_TASK_REISSUE_TICKS then
                            dispatch.task_retry_ticks = 0
                            local reissueSpeed = dispatch.cruise_speed or DISPATCH_BASE_VEHICLE_SPEED_MS
                            if dispatch.vehicle_net_id then
                                local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
                                if veh and veh ~= 0 and DoesEntityExist(veh) then
                                    pcall(TaskVehicleDriveToCoord,
                                        ped, veh,
                                        dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                                        reissueSpeed, 0, 0, 16777216, 5.0, 1
                                    )
                                end
                            else
                                pcall(TaskGoStraightToCoord,
                                    ped,
                                    dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                                    reissueSpeed, -1, 0.0, 0.5
                                )
                            end
                        end

                        QueueOrEmit(dispatch, ('Bot #%d konum güncellendi: (%.1f, %.1f, %.1f) | Kalan mesafe:%.1fm'):format(
                            botId, coords.x, coords.y, coords.z, distToDest))
                    end
                end
            end
        end
    end

    -- ★ [H10] Faz 2: pcall başarısız olsa bile Dispatches[botId] ZORLA nil'lenir.
    for botId, reason in pairs(toComplete) do
        local ok, err = pcall(Matrix.CompleteDispatch, botId, reason)
        if not ok then
            Matrix.Log('CORE', '[HATA] CompleteDispatch (%s) basarisiz: %s', tostring(botId), tostring(err))
        end
        -- Güvenlik ağı: CompleteDispatch herhangi bir nedenle erken dönmüş/
        -- hata vermişse dispatches kaydı burada zorla düşürülür (RAM sızıntısı yok).
        if Matrix.Dispatches[botId] then
            Matrix.Dispatches[botId] = nil
        end
    end
end

-- =====================================================================
-- KATMAN 5 [H13]: TAKTİK HUD VERİ KÖPRÜSÜ (server ↔ client/hud.lua)
--
-- ★ SIFIR SAYI STANDARDI: Buradan çıkan satırlar HAM float taşır
-- ({ metric=..., value=... }). Edebi/askeri bültene çevirme işi TAMAMEN
-- client/hud.lua'da yapılır. Bu köprü yalnızca HUD'ı AÇIK olan
-- oyunculara (Matrix.HudViewers) veri gönderir — HUD kapalıyken sıfıra
-- yakın maliyet (0 Resmon bütçesi).
--
-- Geliştirici Kokpiti İstisnası: bu köprü sunucu konsoluna (print/
-- Matrix.Log) veya /matrixdump'a HİÇ dokunmaz — onlar zaten ham float
-- basmaya devam eder (bkz. RegisterCommand('matrixdump', ...) aşağıda).
-- =====================================================================
Matrix.Hud = Matrix.Hud or {}
Matrix.HudViewers = Matrix.HudViewers or {}

RegisterNetEvent('matrix:server:hudToggled', function(active)
    local src = source
    if active then
        Matrix.HudViewers[src] = true
    else
        Matrix.HudViewers[src] = nil
    end
end)

AddEventHandler('playerDropped', function()
    Matrix.HudViewers[source] = nil
end)

local HUD_MAX_BOT_LINES = 12  -- 0-resmon bütçesi: sınırsız bot dökümü yasak

function Matrix.Hud.BuildSnapshotLines(src)
    local lines = {}

    local citizenid   = Matrix.PlayerSourceIndex[src]
    local playerState = citizenid and Matrix.PlayerState[citizenid]
    if playerState and playerState.biology then
        lines[#lines + 1] = { header = true, text = '=== OPERATIF BIYO-TELEMETRI ===' }
        lines[#lines + 1] = { metric = 'cortisol_level', value = playerState.biology.cortisol_level }
        lines[#lines + 1] = { metric = 'fatigue_level',  value = playerState.biology.fatigue_level }
    end

    lines[#lines + 1] = { header = true, text = '=== SAHA EKIBI DURUMU ===' }
    local shown = 0
    for id, bot in pairs(Matrix.Bots) do
        if shown >= HUD_MAX_BOT_LINES then break end
        if bot.status == 'active' then
            lines[#lines + 1] = { header = true, text = ('-- Bot #%d [%s] --'):format(id, bot.name) }
            lines[#lines + 1] = { metric = 'cortisol_level', value = bot.biology.cortisol_level,      label = '  ' }
            lines[#lines + 1] = { metric = 'fatigue_level',  value = bot.biology.fatigue_level,       label = '  ' }
            lines[#lines + 1] = { metric = 'durability',     value = bot.state.weapon_wear_level or 1.0, label = '  ' }
            shown = shown + 1
        end
    end

    return lines
end

function Matrix.Hud.PushSnapshots()
    for src in pairs(Matrix.HudViewers) do
        local ok, lines = pcall(Matrix.Hud.BuildSnapshotLines, src)
        if ok then
            TriggerClientEvent('matrix:client:hudSnapshot', src, lines)
        else
            Matrix.Log('CORE', '[HATA] Hud.BuildSnapshotLines (src=%s) basarisiz: %s', tostring(src), tostring(lines))
        end
    end
end

-- =====================================================================
-- MASTER TICKER
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
                    local ok, err = pcall(Matrix.Kitchen.ProcessMinuteCycle, bot)
                    if not ok then Matrix.Log('CORE', '[HATA] ProcessMinuteCycle (Bot #%d) basarisiz: %s', bot.id, tostring(err)) end
                end
                if s % secPerHour == 0 then
                    local ok, err = pcall(Matrix.Kitchen.ProcessHourCycle, bot)
                    if not ok then Matrix.Log('CORE', '[HATA] ProcessHourCycle (Bot #%d) basarisiz: %s', bot.id, tostring(err)) end
                end
            end
        end

        for src, citizenid in pairs(Matrix.PlayerSourceIndex) do
            local state = Matrix.PlayerState[citizenid]
            if state and state.biology then
                Matrix.DecayPlayerCortisol(state)
                if state.biology.cortisol_level > Config.Kitchen.CortisolDeviationThreshold then
                    Matrix.Radio.ApplyStatic(src, state.biology.cortisol_level, 'panic')
                end
            end
        end

        local ok3, err3 = pcall(Matrix.TickPhysicalDispatches)
        if not ok3 then Matrix.Log('CORE', '[HATA] TickPhysicalDispatches basarisiz (yutuldu): %s', tostring(err3)) end

        if bureauAccumulator >= bureauInterval then
            bureauAccumulator = 0
            local ok4, err4 = pcall(Matrix.Bureau.Tick)
            if not ok4 then Matrix.Log('CORE', '[HATA] Bureau.Tick basarisiz (yutuldu): %s', tostring(err4)) end
            CreateThread(function()
                local okS, errS = pcall(Matrix.Recruitment.ScanCustomerPool)
                if not okS then Matrix.Log('CORE', '[HATA] ScanCustomerPool basarisiz (yutuldu): %s', tostring(errS)) end
            end)
        end

        if Matrix.Hud and Matrix.Hud.PushSnapshots then
            local ok5, err5 = pcall(Matrix.Hud.PushSnapshots)
            if not ok5 then Matrix.Log('CORE', '[HATA] Hud.PushSnapshots basarisiz (yutuldu): %s', tostring(err5)) end
        end
    end
end)

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
-- [H4] PLAYER DROP CLEANUP
-- =====================================================================
AddEventHandler('playerDropped', function()
    local src = source
    local citizenid = Matrix.PlayerSourceIndex[src]

    if citizenid then
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
    end
    Matrix.PlayerSourceIndex[src] = nil

    for _, dispatch in pairs(Matrix.Dispatches) do
        if dispatch.dispatcher_src == src then
            dispatch.dispatcher_src = nil
            dispatch.comms_lost = true
        end
    end
end)

-- =====================================================================
-- KOMUTLAR
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

RegisterCommand('coords', function(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped bulunamadi.'); return end
    local c  = GetEntityCoords(ped)
    local hd = GetEntityHeading(ped)
    Reply(src, ('KOMUTLAR ICIN (boslukla): %.3f %.3f %.3f  |Heading:%.1f'):format(c.x, c.y, c.z, hd))
    Reply(src, ('CONFIG ICIN (virgullu):  vector3(%.3f, %.3f, %.3f)'):format(c.x, c.y, c.z))
end, false)

RegisterCommand('botyarat', function(src, args)
    local name = args[1]
    local role = args[2] or 'runner'
    if type(name) ~= 'string' or name == '' then
        Reply(src, 'Kullanim: /botyarat [isim] [rol]'); return
    end
    if not Config.RoleModels[role] and role ~= Config.DefaultRoleModel then
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

-- =====================================================================
-- ★ KATMAN 5 [H11]: /rotaciz — MULTI-WAYPOINT TAKTİK ROTA MOTORU
--
-- Her waypoint argümanı ya salt tam sayı bir Trap House ID'si ya da
-- "x,y,z" biçiminde bir vector3'tür. Argümanlar client/hud.lua'nın F10
-- "Rota Çiz" diyaloğu tarafından ZATEN sanitize edilmiş şekilde gelir
-- (yalnızca rakam/nokta/virgül/eksi) — burada yalnızca FORMAT çözümlemesi
-- ve fiziksel/mesafe guard'ları uygulanır.
-- =====================================================================
local WAYPOINT_INTEGER_PATTERN = '^%d+$'
local WAYPOINT_COORD_PATTERN   = '^%-?%d+%.?%d*,%-?%d+%.?%d*,%-?%d+%.?%d*$'

local function ResolveWaypointRef(refString)
    if type(refString) ~= 'string' or refString == '' then return nil, 'empty_waypoint' end

    if refString:match(WAYPOINT_INTEGER_PATTERN) then
        local houseId = tonumber(refString)
        local house = Matrix.TrapHouses and Matrix.TrapHouses[houseId]
        if not house or not house.coords then return nil, 'trap_house_not_found' end
        return house.coords
    end

    if refString:match(WAYPOINT_COORD_PATTERN) then
        local xs, ys, zs = refString:match('^(%-?%d+%.?%d*),(%-?%d+%.?%d*),(%-?%d+%.?%d*)$')
        local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
        if not x or not y or not z then return nil, 'bad_coord_numbers' end
        if x ~= x or y ~= y or z ~= z then return nil, 'nan_coord' end
        return vector3(x, y, z)
    end

    return nil, 'unrecognized_waypoint_format'
end

RegisterCommand('rotaciz', function(src, args)
    local botId = tonumber(args[1])
    if not botId or not Matrix.Bots[botId] then
        Reply(src, 'Kullanim: /rotaciz [botId] [wp1] [wp2] [wp3] [finalHedef] [plaka] [aracTipi]')
        return
    end

    local waypoints = {}
    for i, rawIdx in ipairs({ 2, 3, 4 }) do
        local coords, err = ResolveWaypointRef(args[rawIdx])
        if not coords then
            Reply(src, ('Ugrak #%d cozumlenemedi: %s'):format(i, tostring(err)))
            return
        end
        waypoints[i] = coords
    end

    local finalCoords, finalErr = ResolveWaypointRef(args[5])
    if not finalCoords then
        Reply(src, ('Final hedef cozumlenemedi: %s'):format(tostring(finalErr)))
        return
    end

    local plate = args[6]
    if plate == nil or plate == '' or plate == 'nil' then plate = nil end

    local vehicleType = args[7]
    if not vehicleType or not Config.Logistics.VehicleTypes[vehicleType] then
        vehicleType = Config.Logistics.DefaultVehicleType
    end

    local origin = SafeForwardCoords(src, 2.0)
    if not origin then Reply(src, 'Rota baslatmak icin gecerli bir ped gerekli.'); return end

    local ok, err, legIndex, legDist = Matrix.BeginRouteDispatch(botId, origin, waypoints, finalCoords, plate, vehicleType, src)
    if ok then
        Reply(src, ('[ROTA CIZILDI] Bot #%d icin %d ugraklik taktik kacis rotasi baslatildi.'):format(botId, #waypoints + 1))
    elseif err == 'too_close' and legIndex then
        local totalLegs = #waypoints + 1
        local fromLabel = (legIndex == 1) and 'Oyuncu Konumu' or ('Ugrak #%d'):format(legIndex - 1)
        local toLabel   = (legIndex == totalLegs) and 'Final Hedef' or ('Ugrak #%d'):format(legIndex)
        Reply(src, ('Rota baslatilamadi: %s -> %s arasi cok yakin (%.1fm < %.1fm gerekli). Isinlanma korumasi engelledi.'):format(
            fromLabel, toLabel, legDist or 0.0, Config.Logistics.MinDispatchDistanceMeters))
    else
        Reply(src, ('Rota baslatilamadi: %s'):format(tostring(err)))
    end
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

exports('BeginPhysicalDispatch', function(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
    return Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
end)
exports('BeginRouteDispatch', function(botId, origin, waypoints, finalDest, plate, vehicleType, src, frictionDivisor)
    return Matrix.BeginRouteDispatch(botId, origin, waypoints, finalDest, plate, vehicleType, src, frictionDivisor)
end)
exports('CompleteDispatch', function(botId, reason)
    return Matrix.CompleteDispatch(botId, reason)
end)
exports('GetActiveDispatches', function()
    return Matrix.Dispatches
end)

exports('ReportWeaponDischarge', function(actorRef, weaponSerial, invId, slot)
    return Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, invId, slot)
end)
exports('SimulateWeaponFire', function(actorRef, weaponSerial, wear, evType, durability)
    return Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, wear, evType, durability)
end)
exports('StampTouch',     function(actorRef, invId, slot) return Matrix.Forensics.StampTouch(actorRef, invId, slot) end)
exports('AnalyzeEvidence',function(evId) return Matrix.Forensics.AnalyzeEvidence(evId) end)

exports('ProcessCook',  function(a, t, rw, rp, aw) return Matrix.Kitchen.ProcessCook(a, t, rw, rp, aw) end)
exports('AdjustCortisol',function(a, s) return Matrix.Kitchen.AdjustCortisol(a, s) end)
exports('OnBotCaptured', function(b, t) return Matrix.Kitchen.OnCaptured(b, t) end)

exports('TriggerPropaganda',     function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms',function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',    function(t) return Matrix.Bureau.LogPatternEvent(t) end)

exports('ScanCustomerPool',       function() return Matrix.Recruitment.ScanCustomerPool() end)
exports('BeginInterrogation',     function(c, s) return Matrix.Recruitment.BeginInterrogation(c, s) end)
exports('ApplyInterrogationPressure', function(s, a) return Matrix.Recruitment.ApplyPressure(s, a) end)
exports('EvaluateInterrogation',  function(s) return Matrix.Recruitment.EvaluateOutcome(s) end)

-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
local VALID_PSYCHOLOGY_FIELDS = {
    fear_factor = true, resilience = true, snitch_tendency = true,
    economic_pressure = true, cognitive_shifter = true,
    skill_chemistry = true, skill_cyber = true, skill_logistics = true
}
local VALID_BIOLOGY_FIELDS = {
    fatigue_level = true, cortisol_level = true, withdrawal_index = true,
    addiction_level = true, base_cortisol_recovery_rate = true
}

RegisterCommand('botskill', function(src, args)
    local botId = tonumber(args[1])
    local field = args[2]
    local value = tonumber(args[3])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not VALID_PSYCHOLOGY_FIELDS[field] or not value then
        Reply(src, 'Kullanim: /botskill [id] [fear_factor|resilience|snitch_tendency|economic_pressure|cognitive_shifter|skill_chemistry|skill_cyber|skill_logistics] [0.0-1.0]')
        return
    end
    bot.psychology[field] = Matrix.Clamp(value, 0.0, 1.0)
    Matrix.MarkBotDirty(botId)
    Reply(src, ('Bot #%d %s = %.3f olarak ayarlandı.'):format(botId, field, bot.psychology[field]))
end, false)

RegisterCommand('botbio', function(src, args)
    local botId = tonumber(args[1])
    local field = args[2]
    local value = tonumber(args[3])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not VALID_BIOLOGY_FIELDS[field] or not value then
        Reply(src, 'Kullanim: /botbio [id] [fatigue_level|cortisol_level|withdrawal_index|addiction_level|base_cortisol_recovery_rate] [deger]')
        return
    end
    local maxV = (field == 'addiction_level') and 100.0 or 1.0
    bot.biology[field] = Matrix.Clamp(value, 0.0, maxV)
    Matrix.MarkBotDirty(botId)
    Reply(src, ('Bot #%d %s = %.3f olarak ayarlandı.'):format(botId, field, bot.biology[field]))
end, false)

--- ★ KATMAN 5 [H13]: Bot'un HUD "Mekanik" bültenine (silah aşınması)
--- yansıyan ham durability/wear değerini ayarlar (debug/test amaçlı,
--- botskill/botbio ile aynı desen). Ham float BURADA basılır (dev cockpit
--- istisnası) — HUD'da her zaman edebi bültene çevrilmiş halde görünür.
RegisterCommand('botmekanik', function(src, args)
    local botId = tonumber(args[1])
    local value = tonumber(args[2])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not value then
        Reply(src, 'Kullanim: /botmekanik [id] [asinma 0.0-1.0] (1.0=kusursuz, 0.0=eriimis)')
        return
    end
    bot.state.weapon_wear_level = Matrix.Clamp(value, 0.0, 1.0)
    Reply(src, ('Bot #%d silah asinmasi (ham) = %.3f olarak ayarlandi.'):format(botId, bot.state.weapon_wear_level))
end, false)

RegisterCommand('radyoparazit', function(src, args)
    local targetSrc = tonumber(args[1]) or src
    local intensity = tonumber(args[2]) or 1.0
    Matrix.Radio.ApplyStatic(targetSrc, intensity, 'debug')
    Reply(src, ('Telsiz statiği src=%d yoğunluk=%.2f olarak tetiklendi.'):format(targetSrc, intensity))
end, false)

RegisterCommand('matrixdump', function(src)
    local count = 0
    for id, bot in pairs(Matrix.Bots) do
        count = count + 1
        Reply(src, ('#%d [%s|%s|%s] Fat:%.2f Cort:%.2f With:%.2f | Chem:%.2f Cyber:%.2f Log:%.2f | Res:%.2f Snitch:%.2f | Mekanik:%.2f'):format(
            id, bot.name, bot.role, bot.status,
            bot.biology.fatigue_level, bot.biology.cortisol_level, bot.biology.withdrawal_index,
            bot.psychology.skill_chemistry, bot.psychology.skill_cyber, bot.psychology.skill_logistics,
            bot.psychology.resilience, bot.psychology.snitch_tendency,
            bot.state.weapon_wear_level or 1.0))
    end
    Reply(src, ('--- Toplam %d bot ---'):format(count))
end, false)

RegisterCommand('fizikselsevk', function(src, args)
    local count = 0
    for botId, d in pairs(Matrix.Dispatches) do
        count = count + 1
        local lc = d.last_coords or d.origin
        local routeInfo = d.route_queue and (' Rota:%d/%d'):format(d.route_index, #d.route_queue) or ''
        Reply(src, ('Bot #%d [%s] Plaka:%s Konum:(%.1f,%.1f,%.1f) Hedef-Mesafe:%.1fm Hiz:%.2fm/s Sinyal:%s Polis-Dwell:%d Bekleyen:%d%s'):format(
            botId, d.vehicle_type, tostring(d.plate),
            lc.x, lc.y, lc.z,
            #(lc - d.destination),
            d.cruise_speed or 0.0,
            d.comms_lost and 'KESİK' or 'VAR',
            d.police_dwell,
            #d.pending_events,
            routeInfo))
    end
    Reply(src, ('--- Toplam %d fiziksel dispatch ---'):format(count))
end, false)
