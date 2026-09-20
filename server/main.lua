-- =====================================================================
-- MATRIX CORE / main.lua
-- Write-behind persistence, NaN-safe math, guard-clause hardening,
-- FİZİKSEL SEVK MOTORU (görünmez/ışınlanan sevk iptal edildi).
--
-- ★ KATMAN 5 REVİZYONU: QBOX (qbx_core) MİGRASYONU ★
--   qb-core'un tekil "GetCoreObject()" nesnesi Qbox'ta YOKTUR; Qbox
--   doğrudan export tabanlıdır (`exports.qbx_core:GetPlayer(src)`,
--   `exports.qbx_core:GetQBPlayers()`). Aşağıdaki iki temas noktası
--   (Matrix.GetOrCreatePlayerState, RefreshPoliceCache) bu yeni export
--   yüzeyine taşındı; PlayerData.citizenid ve PlayerData.job.{name,onduty,
--   type} alan adları Qbox'ta qb-core ile AYNIDIR (Qbox kasıtlı olarak
--   geriye dönük uyumludur), bu yüzden geri kalan TÜM iş mantığı
--   (write-behind kuyruk, dirty-flag, fiziksel sevk state machine'i)
--   TEK SATIR BİLE DEĞİŞMEDEN korundu.
--
-- ★ KATMAN 5 SERTLEŞTİRME REVİZYONU (bu turda eklendi):
--   [H1] qbx_core:server:onPlayerLoaded (+ QBCore:Server:PlayerLoaded
--        uyumluluk event'i) hook'u → PlayerState cache'i oyuncu bağlanır
--        bağlanmaz ısıtılır (ilk komut çağrısındaki GetPlayer gecikmesi
--        sıfırlanır). GetOrCreatePlayerState zaten idempotent olduğundan
--        bu salt bir "warm-cache" etkisidir, yeni bir kontrat AÇMAZ.
--   [H2] dispatch.pending_events için FIFO cap (PENDING_EVENTS_MAX=64):
--        bot uzun süre kör bölgede kalırsa kuyruk sınırsız büyümez, en
--        eski mesaj düşürülür.
--   [H3] TickPhysicalDispatches iki fazlı hale getirildi: Faz 1 salt-okunur
--        gezinir ve tamamlanacak dispatch'leri bir tabloya toplar; Faz 2
--        (iterasyon bittikten SONRA) bu tamamlamaları uygular. NOT: Lua'da
--        `pairs()` sırasında MEVCUT bir anahtarı nil'e ayarlamak zaten
--        tanımlı/güvenli davranıştır (Lua 5.4 manual §3.3.5); yani tek-fazlı
--        eski hâl teknik olarak "kırık" değildi. Bu değişikliğin gerçek
--        değeri OKUNABİLİRLİK ve ekstra güvenlik payıdır — "ne yapılacağı"
--        ile "ne zaman yapılacağı" ayrıştırılır.
--   [H4] playerDropped: dispatcher_src bu oyuncuya ait TÜM aktif dispatch
--        kayıtlarından temizlenir (dispatcher_src=nil, comms_lost=true).
--        Bu GERÇEK bir düzeltmedir — eskiden bağlantısı kopan bir
--        dispatcher'ın src'si dispatch üzerinde askıda kalıyordu; FiveM
--        sunucu ID'leri yeniden kullanılabildiğinden, sonraki bir oyuncu
--        AYNI ID'yi alırsa Matrix.Radio.ApplyStatic YANLIŞ oyuncuya telsiz
--        statiği gönderebilirdi. Bot sevkiyatı KESİNTİSİZ devam eder,
--        sadece telsiz bağı koptu sayılır.
--   [H5] RefreshPoliceCache: pcall + devre kesici (5 üst üste hata → 60sn
--        devre dışı). Qbox export'u geçici olarak hata verse bile master
--        ticker'a bağlı 5sn'lik thread çökmez/spam basmaz.
--   [H6] Ticker'daki kritik adımlar (bot biyoloji döngüleri, fiziksel sevk
--        takibi, Büro tick'i, dirty-bot flush) pcall ile sarmalandı: TEK
--        bir bot/adımdaki beklenmeyen hata artık MASTER TICKER THREAD'İNİ
--        BÜTÜNÜYLE DÜŞÜRMEZ (eskiden yakalanmayan bir hata bu thread'i
--        sessizce öldürüp TÜM bot biyolojisini/sevk takibini durdurabilirdi
--        — bu GERÇEK ve önemli bir dayanıklılık kazanımıdır).
--   [H7] Master ticker'a (5). adım eklendi: Matrix.Hud.PushSnapshots
--        (market.lua) — SADECE HUD açık oyunculara, AYNI 1000ms saatten,
--        ayrı bir thread AÇMADAN. Hook yoksa (market.lua yüklü değilse)
--        no-op.
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
local SetEntityAsMissionEntity  = SetEntityAsMissionEntity
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
-- UYARI: `source` BİLİNÇLİ OLARAK localize edilmez. FiveM her event/komut
-- çağrısından hemen önce global `source`'u günceller; dosya yüklenirken bir
-- kez `local source = source` yapmak bu değeri bayat değerde dondurur.

-- ---------- Namespace ----------
Matrix       = Matrix       or {}
Matrix.Bots  = Matrix.Bots  or {}
Matrix.PlayerState = Matrix.PlayerState or {}
Matrix.Inventory   = Matrix.Inventory   or {}
Matrix.PlayerSourceIndex = Matrix.PlayerSourceIndex or {}
Matrix.NextBotId = Matrix.NextBotId or 1
Matrix.Dispatches = Matrix.Dispatches or {} -- [botId] = dispatch record (fiziksel sevk)

-- ★ Qbox: tekil "core object" yok — doğrudan export referansı tutulur.
-- Matrix.QBX:GetPlayer(src) / Matrix.QBX:GetPlayerByCitizenId(cid) /
-- Matrix.QBX:GetQBPlayers() bundan sonra kullanılacak tüm yüzeydir.
Matrix.QBX = exports.qbx_core

-- [H2] pending_events FIFO cap (kör bölgede sınırsız RAM büyümesi önlenir).
local PENDING_EVENTS_MAX = 64

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
-- Yorum: değer bir Lua number değilse VEYA NaN/inf ise güvenli tabana düşülür.
-- Sıfıra bölme guard'ı bu fonksiyonun dışında ayrıca uygulanır (aşağıda
-- inverse distance weighting'de).
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
-- TELSİZ KÖPRÜSÜ (pma-voice / qb-radio) — aynen korundu
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
        -- [H6] pcall: batch UPSERT hata verirse flush thread'i düşmez.
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

    -- Fiziksel sevkte ise önce dünyadan çek
    if Matrix.Dispatches[id] then
        Matrix.DespawnDispatchEntity(id)
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

-- ★ Qbox: exports.qbx_core:GetPlayer(source) — qb-core'daki
-- QBCore.Functions.GetPlayer(source) ile birebir aynı sözleşme (Player
-- bulunamazsa nil döner). PlayerData.citizenid alan adı DEĞİŞMEDİ.
-- [H6] pcall: Qbox export'u beklenmedik şekilde hata fırlatırsa (örn.
-- resource henüz tam başlamamışken) bu ÇAĞIRANLARIN TAMAMINI (ticker,
-- event bridge'ler, komutlar) düşürmez.
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
--
-- Qbox `qbx_core:server:onPlayerLoaded` event'i, PlayerData'nın sunucuya
-- tamamen yüklendiği anı bildirir. Burada state'i ısıtmak:
--   (1) İlk komut çağrısındaki GetPlayer gecikmesini sıfırlar.
--   (2) matrix_player_state satırını erkenden yazar (crash anında bile
--       oyuncu kalıcı satırına sahip olur).
-- NOT: matrix_hierarchy (co-op rütbe) bu hook'a İHTİYAÇ DUYMAZ — rütbeler
-- citizenid bazlı ve resource açılışında TÜMÜ RAM'e yüklenir (bkz.
-- market.lua Matrix.Hierarchy.LoadHierarchy); oyuncu online olsun ya da
-- olmasın rütbe ataması zaten RAM+DB'de kalıcıdır. Bu hook SADECE
-- Matrix.PlayerState (kortizol/yorgunluk) ısıtması içindir.
-- Event payload'ı Qbox sürümüne göre değişebilir; defansif olarak birkaç
-- olası alan adı denenir.
-- =====================================================================
AddEventHandler('qbx_core:server:onPlayerLoaded', function(payload)
    local src
    if type(payload) == 'table' then
        src = tonumber(payload.source or payload.src or payload[1])
    else
        src = tonumber(payload)
    end
    if not src or src <= 0 then return end

    -- GetOrCreatePlayerState zaten idempotent; ısıtma etkisi yaratır.
    Matrix.GetOrCreatePlayerState(src)
end)

-- Qbox bazı sürümlerde `QBCore:Server:PlayerLoaded` da yayar (uyumluluk).
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
                elapsed_seconds = 0
            }
        }
        if row.id >= Matrix.NextBotId then Matrix.NextBotId = row.id + 1 end
    end
    Matrix.Log('CORE', '%d bot matristen belleğe yüklendi.', #rows)
end

-- =====================================================================
-- PED SPAWN / DESPAWN (genel API — sevk dışı kullanım için)
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
    if not AwaitEntityCreation(ped) then
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
        if ped and ped ~= 0 and DoesEntityExist(ped) then DeleteEntity(ped) end
    end

    TriggerClientEvent('matrix:client:extractBot', -1, id)
    bot.state.spawned = false
    bot.state.net_id  = nil
    Matrix.Log('CORE', 'Bot #%d dünyadan çekildi.', id)
    return true
end

-- =====================================================================
-- PHYSICAL DISPATCH RUNTIME  ★ REVİZYON #1 ★
--
-- Eski mimaride DispatchDealer, sadece bir ETA sayacı kurup süre bitince
-- botu hedefte "ışınlıyordu" (SpawnBot). Yolda fiziksel bir ped/araç
-- olmadığı için polisler veya ALPR radarları onu göremiyordu.
--
-- Yeni mimari:
--   1) BeginPhysicalDispatch → pedi/aracı ORIGIN'de gerçekten yaratır.
--      Araca TaskVehicleDriveToCoord (server-side OneSync uyumlu), yaya
--      bota TaskGoStraightToCoord verir.
--   2) TickPhysicalDispatches (1000 ms master ticker):
--      • GetEntityCoords(entity) ile GERÇEK dünya pozisyonu okunur.
--      • Kör bölge / polis yakınlığı / ALPR radarları bu gerçek konuma göre
--        değerlendirilir; decryption kazancı dinamik uygulanır.
--      • Varış (mesafe <= ARRIVAL_RADIUS) veya pusu (polis dwell >= eşiği)
--        tespit edildiğinde CompleteDispatch çağrılır → Despawn.
--   3) CompleteDispatch → dead drop otomatik teslim alımı + despawn.
--
-- KARMAŞIKLIK: O(D) per master tick; D = aktif dispatch sayısı (tipik < 30).
-- =====================================================================

-- Varsayılan araç modelleri (Config.Logistics.Fleet.DefaultModel gelene kadar
-- fallback). Yeni katman config'e model alanı ekleyip buradan override edebilir.
local DISPATCH_VEHICLE_MODELS = {
    car       = 'sultan',
    motorbike = 'bati',
}

-- Fiziksel sevk sabitleri (deterministik; RNG yok).
local DISPATCH_ARRIVAL_RADIUS_M       = 6.0    -- bu mesafede "vardı" sayılır
local DISPATCH_POLICE_PROXIMITY_M     = 60.0   -- polis bu menzile girince deşifre hızlanır
local DISPATCH_POLICE_DECRYPT_TICK    = 0.015  -- her tik'te polis görüşü başına deşifre kazancı
local DISPATCH_BUSTED_PROXIMITY_M     = 8.0    -- polis BU kadar yakınsa "dwell" sayacı işler
local DISPATCH_BUSTED_DWELL_TICKS     = 8      -- 8 sn boyunca polis dibinde kalırsa pusu
local DISPATCH_ALPR_RADIUS_M          = 250.0  -- ALPR/trap house gözlem menzili
local DISPATCH_TASK_REISSUE_TICKS     = 25     -- 25 sn'de bir rota yeniden atanır (AI takılma önleyici)

-- ★ KATMAN 5: Zaman-Mesafe Sürtünme Denklemi'nin GERÇEK sürüş hızına bağlanması.
-- Eskiden TaskVehicleDriveToCoord/TaskGoStraightToCoord'a SABİT KODLANMIŞ
-- 15.0 / 1.4 m/s veriliyordu; logistics.lua'nın hesapladığı frictionDivisor
-- (ağırlık × WeightFrictionCoefficient × araç-tipi-sürtünmesi × aşınma)
-- yalnızca chat'e basılan ETA metnini etkiliyordu, gerçek sürüş HİÇ
-- yavaşlamıyordu ("kozmetik sürtünme"). Artık BeginPhysicalDispatch bu
-- taban hızları frictionDivisor'e böler — aynı katsayı hem tahminde hem
-- gerçek simülasyonda kullanılır. Taban hızların KENDİSİ değişmedi (boş
-- envanter + sıfır aşınmış araçta davranış eskisiyle BİREBİR AYNI, çünkü
-- frictionDivisor=1.0 durumunda bölme etkisizdir); yalnızca YÜK/AŞINMA
-- ARTIK gerçekten yavaşlatıyor.
local DISPATCH_BASE_FOOT_SPEED_MS     = 1.4
local DISPATCH_BASE_VEHICLE_SPEED_MS  = 15.0
-- frictionDivisor ne kadar büyürse büyüsün hız bu oranın (taban hızın
-- %25'i) altına düşmez — aşırı yük/aşınma botu sonsuza kadar süründürmez,
-- sadece belirgin şekilde yavaşlatır.
local DISPATCH_MIN_SPEED_FRACTION     = 0.25

-- Polis oyuncuları cache'i. Her master tick'te QB job sorgusu yapmak yerine
-- 5 sn'de bir yeniden inşa edilir → 0 Resmon hedefiyle uyumlu.
-- ★ Qbox: exports.qbx_core:GetQBPlayers() zaten <source, Player> tablosu
-- döndürdüğü için GetPlayers()+GetPlayer(src) çiftini tek çağrıya indirger.
-- [H5] pcall + devre kesici: Qbox export'u 5 kez üst üste hata verirse
-- 60sn devre dışı bırakılır (5sn'lik thread ne çöker ne log spam'ler).
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
    -- Drop aktifliği logistics.lua tarafında tutulur; burada sadece statik
    -- config koordinatına göre yakınlık kontrolü yapılır. OnPickup zaten
    -- "no_active_drop" dönerse sessizce yutulur.
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if #(destination - drop.coords) <= drop.radius then return drop end
    end
    return nil
end

--- Fiziksel sevki başlatır. Pedi/aracı ORIGIN'de gerçekten yaratır,
--- OneSync routing görevini atar, Matrix.Dispatches tablosuna kaydeder.
--- @return boolean, string|nil reason
function Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, etaSeconds, dispatcherSrc, frictionDivisor)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    -- ★ frictionDivisor >= 1.0 (logistics.lua'nın ETA formülüyle AYNI değer);
    -- verilmezse (örn. export'u doğrudan çağıran eski bir kod yolu) 1.0
    -- varsayılır -> taban hızlar DEĞİŞMEZ, geriye dönük tam uyumlu.
    frictionDivisor = Matrix.Clamp(tonumber(frictionDivisor) or 1.0, 1.0, 1.0 / DISPATCH_MIN_SPEED_FRACTION)

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if Matrix.Dispatches[botId] then return false, 'already_dispatched' end
    if type(origin) ~= 'vector3' and type(origin) ~= 'vector4' then return false, 'bad_origin' end
    if type(destination) ~= 'vector3' and type(destination) ~= 'vector4' then return false, 'bad_destination' end

    -- Origin/destination NaN/inf guard
    local function _safeVec(v)
        return v and v.x == v.x and v.y == v.y and v.z == v.z
               and v.x ~= math_huge and v.x ~= -math_huge
               and v.y ~= math_huge and v.y ~= -math_huge
               and v.z ~= math_huge and v.z ~= -math_huge
    end
    if not _safeVec(origin) or not _safeVec(destination) then
        return false, 'corrupt_vector'
    end

    -- ★ IŞINLANMA GUARD'I (ikinci katman): logistics.lua'nın ValidateDestination'ı
    -- zaten bu kontrolü DispatchDealer akışında yapar, ama bu fonksiyon export
    -- edilmiş olduğundan başka bir kod yolu doğrudan çağırabilir — bu yüzden
    -- kural burada da AYNEN tekrarlanır: hedef nil/bozuksa (yukarıda zaten
    -- reddedildi) veya origin-destination mesafesi min eşiğin altındaysa sevk
    -- tamamen iptal edilir, oyuncunun dibine ASLA araç/bot ışınlanmaz.
    if #(origin - destination) < Config.Logistics.MinDispatchDistanceMeters then
        return false, 'too_close'
    end

    -- Eğer bot zaten bir şekilde spawn'lıysa, önce temizle
    if bot.state.spawned then
        Matrix.DespawnBot(botId)
        Wait(50)
    end

    local pedModelName = Config.RoleModels[bot.role] or Config.DefaultRoleModel
    local pedHash      = GetHashKey(pedModelName)

    local isFoot = (vehicleType == 'foot')
    local ped, vehicle
    local vehicleNetId = nil

    -- ★ Gerçek sürüş hızı = taban hız / frictionDivisor (taban hızın
    -- DISPATCH_MIN_SPEED_FRACTION'ının altına asla düşmez). frictionDivisor=1.0
    -- iken (boş envanter, sıfır aşınmış/foot) sonuç TAM olarak eski sabit
    -- değerdir (1.4 / 15.0) — davranış değişikliği yalnızca yük/aşınma
    -- gerçekten mevcutken ortaya çıkar.
    local baseSpeed   = isFoot and DISPATCH_BASE_FOOT_SPEED_MS or DISPATCH_BASE_VEHICLE_SPEED_MS
    local cruiseSpeed = math_max(baseSpeed / frictionDivisor, baseSpeed * DISPATCH_MIN_SPEED_FRACTION)

    if isFoot then
        ped = CreatePed(4, pedHash, origin.x, origin.y, origin.z, 0.0, true, false)
        if not AwaitEntityCreation(ped) then return false, 'ped_spawn_timeout' end
        SetEntityAsMissionEntity(ped, true, true)
        SetEntityCoords(ped, origin.x, origin.y, origin.z, false, false, false, false)

        -- Server-side routing: yürüme görevi. (OneSync uyumlu.)
        -- Hız = cruiseSpeed (taban 1.4 m/s, sürtünmeyle yavaşlar), timeout=-1 (süresiz).
        TaskGoStraightToCoord(
            ped,
            destination.x, destination.y, destination.z,
            cruiseSpeed, -- speed
            -1,    -- timeout
            0.0,   -- targetHeading
            0.5    -- distanceToSlide
        )
    else
        local vehModelName = DISPATCH_VEHICLE_MODELS[vehicleType] or DISPATCH_VEHICLE_MODELS.car
        local vehHash      = GetHashKey(vehModelName)

        vehicle = CreateVehicle(vehHash, origin.x, origin.y, origin.z, 0.0, true, true)
        if not AwaitEntityCreation(vehicle) then return false, 'vehicle_spawn_timeout' end
        SetEntityAsMissionEntity(vehicle, true, true)

        ped = CreatePedInsideVehicle(vehicle, 4, pedHash, -1, true, false)
        if not AwaitEntityCreation(ped) then
            DeleteEntity(vehicle)
            return false, 'ped_in_vehicle_timeout'
        end
        SetEntityAsMissionEntity(ped, true, true)

        -- Server-side routing: sürüş görevi. drivingStyle bitmask:
        --   0        = normal (trafik kurallarına uyumlu)
        --   16777216 = "stop for vehicles/peds"
        --   Diğer bit seçenekleri: 262144 = dikkatli sürüş.
        TaskVehicleDriveToCoord(
            ped,
            vehicle,
            destination.x, destination.y, destination.z,
            cruiseSpeed, -- cruise speed m/s (taban 15.0, sürtünmeyle yavaşlar)
            0,        -- vehicleModel (0 = mevcut)
            vehHash,  -- drivingStyle model argümanı
            16777216, -- drivingStyle bitmask
            5.0,      -- targetReached distance
            1         -- straightLine (0 = rota planlamalı)
        )

        vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    end

    local pedNetId = NetworkGetNetworkIdFromEntity(ped)

    bot.state.spawned = true
    bot.state.net_id  = pedNetId

    Matrix.Dispatches[botId] = {
        bot_id            = botId,
        entity_net_id     = pedNetId,
        vehicle_net_id    = vehicleNetId,
        plate             = plate,
        vehicle_type      = vehicleType,
        profile           = LocalGetVehicleProfile(vehicleType),
        origin            = origin,
        destination       = destination,
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

    -- Client tarafı sadece ped görselini çizer (karar server tarafındadır).
    TriggerClientEvent('matrix:client:injectBot', -1, botId, bot.role, origin, bot.dna_id, pedNetId)

    Matrix.Log('CORE',
        'Fiziksel sevk başlatıldı: Bot #%d [%s] Origin=(%.1f,%.1f,%.1f) → Hedef=(%.1f,%.1f,%.1f)',
        botId, vehicleType, origin.x, origin.y, origin.z, destination.x, destination.y, destination.z)

    return true
end

--- Aktif bir fiziksel sevki sonlandırır ve dünyadan çeker.
--- @param reason 'arrived' | 'busted' | 'aborted' | 'failed'
function Matrix.CompleteDispatch(botId, reason)
    local dispatch = Matrix.Dispatches[botId]
    if not dispatch then return false end

    local bot = Matrix.Bots[botId]
    Matrix.Dispatches[botId] = nil

    if bot then
        if reason == 'arrived' then
            bot.state.activity = 'idle'
            bot.state.coords   = dispatch.destination

            -- Hedefte açık bir dead drop var mı? Varsa otomatik teslim alımı.
            local drop = FindActiveDeadDropAt(dispatch.destination)
            if drop and Matrix.Supplier and Matrix.Supplier.OnPickup then
                pcall(Matrix.Supplier.OnPickup, { kind = 'bot', id = botId }, drop.id, nil)
            end

        elseif reason == 'busted' then
            -- Pusu: en yakın trap house üzerinden Büro'ya yakalandı.
            local nearestId = FindNearestTrapHouse(dispatch.last_coords or dispatch.destination)
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

    -- Aktif araç kilidini serbest bırak
    if dispatch.plate and Matrix.Logistics and Matrix.Logistics.ReleaseVehicleLock then
        pcall(Matrix.Logistics.ReleaseVehicleLock, dispatch.plate)
    end

    Matrix.DespawnDispatchEntity(botId)
    Matrix.Log('CORE', '[SEVK SONLANDI] Bot #%d Sebep:%s', botId, tostring(reason or 'unknown'))
    return true
end

--- Dispatch entity'sini (ped + varsa araç) dünyadan siler.
function Matrix.DespawnDispatchEntity(botId)
    local dispatch = Matrix.Dispatches[botId]
    local bot = Matrix.Bots[botId]

    -- Entity referanslarına dispatch üzerinden eriş (bot.state.net_id hâlâ geçerli olabilir).
    local pedNetId = dispatch and dispatch.entity_net_id or (bot and bot.state.net_id)

    if pedNetId then
        local ped = NetworkGetEntityFromNetworkId(pedNetId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then DeleteEntity(ped) end
    end

    if dispatch and dispatch.vehicle_net_id then
        local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if veh and veh ~= 0 and DoesEntityExist(veh) then DeleteEntity(veh) end
    end

    if bot then
        bot.state.spawned = false
        bot.state.net_id  = nil
    end

    TriggerClientEvent('matrix:client:extractBot', -1, botId)
end

-- Kuyruktaki log mesajlarını kör bölgeden çıkınca toplu iletir.
local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end
    Matrix.Log('CORE', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('CORE', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end

-- [H2] FIFO cap: pending_events PENDING_EVENTS_MAX'ı aşarsa en eski mesaj
-- atılır (kör bölgede sınırsız RAM büyümesi engellenir).
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

--- Master ticker tarafından 1.000 ms'de bir çağrılır.
--- Yoldaki her fiziksel dispatch'ın GERÇEK dünya pozisyonunu okur ve
--- polis / ALPR / kör bölge etkileşimlerini dinamik olarak işler.
--- [H3] İKİ FAZLI: Faz 1 salt-okunur gezinir ve tamamlanacakları toplar;
--- Faz 2 (iterasyon bittikten SONRA) bu tamamlamaları uygular. Bu, "ne
--- yapılacağına karar verme" ile "yapma" adımlarını ayrıştırarak okunurluğu
--- ve ek güvenlik payını artırır (Lua'da pairs() sırasında MEVCUT bir
--- anahtarı nil'e ayarlamak zaten tanımlı/güvenli davranıştır, dolayısıyla
--- bu bir "kırık davranış düzeltmesi" değil, bilinçli bir sağlamlaştırmadır).
function Matrix.TickPhysicalDispatches()
    local toComplete = {}   -- [botId] = reason (Faz 2'de uygulanır)

    for botId, dispatch in pairs(Matrix.Dispatches) do
        local bot = Matrix.Bots[botId]
        if not bot then
            toComplete[botId] = 'failed'
        else
            dispatch.elapsed = dispatch.elapsed + 1.0
            dispatch.task_retry_ticks = dispatch.task_retry_ticks + 1

            local ped = NetworkGetEntityFromNetworkId(dispatch.entity_net_id)
            if not ped or ped == 0 or not DoesEntityExist(ped) then
                -- Fiziksel varlık kayıp (sunucu restart, crash) → iptal
                Matrix.Log('CORE', '[SEVK KAYIP] Bot #%d fiziksel varlık bulunamadı, iptal.', botId)
                toComplete[botId] = 'failed'
            else
                local coordsRaw = GetEntityCoords(ped)
                local coords    = vector3(coordsRaw.x, coordsRaw.y, coordsRaw.z)
                dispatch.last_coords = coords
                bot.state.coords     = coords

                -- =====================================================
                -- VARİŞ KONTROLÜ (deterministik mesafe eşiği)
                -- =====================================================
                local distToDest = #(coords - dispatch.destination)
                if distToDest <= DISPATCH_ARRIVAL_RADIUS_M then
                    toComplete[botId] = 'arrived'
                else
                    -- ================================================
                    -- KÖR BÖLGE (yalnızca telemetri gecikir; gözetim sürer)
                    -- ================================================
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
                            -- Dispatch bu arada tamamlanmış olabilir → guard.
                            if Matrix.Dispatches[botId] == dispatch then
                                FlushPendingEvents(dispatch)
                            end
                        end)
                    end

                    -- ================================================
                    -- POLİS YAKINLIK TARAMASI (dinamik risk)
                    -- ================================================
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

                    -- Polis görüşü: en yakın trap house'a deşifre kazancı
                    if policeNearby then
                        local nearestId, nearestDist = FindNearestTrapHouse(coords)
                        if nearestId and nearestDist <= Config.Bureau.BaseSearchRadius then
                            Matrix.Bureau.AdvanceDecryption(
                                nearestId,
                                DISPATCH_POLICE_DECRYPT_TICK * (dispatch.profile.PoliceDecryptionMultiplier or 1.0)
                            )
                        end
                    end

                    -- "Dwell" sayacı: çok yakın polis teması birikirse pusu
                    if veryClose then
                        dispatch.police_dwell = dispatch.police_dwell + 1
                    else
                        dispatch.police_dwell = math_max(0, dispatch.police_dwell - 1)
                    end

                    if dispatch.police_dwell >= DISPATCH_BUSTED_DWELL_TICKS then
                        Matrix.Log('CORE', '[PUSU] Bot #%d polis tarafından kuşatıldı.', botId)
                        toComplete[botId] = 'busted'
                    else
                        -- ============================================
                        -- ALPR / EŞKAL LOGLAMA (trap house başına bir kez)
                        -- ============================================
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

                        -- ============================================
                        -- ROTA YENİDEN ATAMA (AI takılma önleyici)
                        -- ============================================
                        if dispatch.task_retry_ticks >= DISPATCH_TASK_REISSUE_TICKS then
                            dispatch.task_retry_ticks = 0
                            -- ★ Yeniden atanan görev de dispatch.cruise_speed'i kullanır
                            -- (sürtünme yavaşlaması yolun ortasında sıfırlanmasın diye —
                            -- eskiden burası da sabit 15.0/1.4'e dönüyordu).
                            local reissueSpeed = dispatch.cruise_speed or DISPATCH_BASE_VEHICLE_SPEED_MS
                            if dispatch.vehicle_net_id then
                                local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
                                if veh and veh ~= 0 and DoesEntityExist(veh) then
                                    TaskVehicleDriveToCoord(
                                        ped, veh,
                                        dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                                        reissueSpeed, 0, 0, 16777216, 5.0, 1
                                    )
                                end
                            else
                                TaskGoStraightToCoord(
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

    -- Faz 2: iterasyon BİTTİ, şimdi tamamlamaları uygula.
    for botId, reason in pairs(toComplete) do
        pcall(Matrix.CompleteDispatch, botId, reason)
    end
end

-- =====================================================================
-- MASTER TICKER (async-safe)
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

        -- (1) Bot biyolojik döngüler
        -- [H6] pcall: TEK bir botun formülünde beklenmedik hata olsa bile
        -- diğer botlar ve ticker'ın kendisi etkilenmez.
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

        -- (2) Oyuncu panik-telsiz kontrolü
        for src, citizenid in pairs(Matrix.PlayerSourceIndex) do
            local state = Matrix.PlayerState[citizenid]
            if state and state.biology then
                Matrix.DecayPlayerCortisol(state)
                if state.biology.cortisol_level > Config.Kitchen.CortisolDeviationThreshold then
                    Matrix.Radio.ApplyStatic(src, state.biology.cortisol_level, 'panic')
                end
            end
        end

        -- (3) FİZİKSEL SEVK TAKİBİ
        local ok3, err3 = pcall(Matrix.TickPhysicalDispatches)
        if not ok3 then Matrix.Log('CORE', '[HATA] TickPhysicalDispatches basarisiz (yutuldu): %s', tostring(err3)) end

        -- (4) Büro örüntü analizi
        if bureauAccumulator >= bureauInterval then
            bureauAccumulator = 0
            local ok4, err4 = pcall(Matrix.Bureau.Tick)
            if not ok4 then Matrix.Log('CORE', '[HATA] Bureau.Tick basarisiz (yutuldu): %s', tostring(err4)) end
            CreateThread(function()
                local okS, errS = pcall(Matrix.Recruitment.ScanCustomerPool)
                if not okS then Matrix.Log('CORE', '[HATA] ScanCustomerPool basarisiz (yutuldu): %s', tostring(errS)) end
            end)
        end

        -- (5) ★ KATMAN 5: Taktik HUD anlık görüntü push — SADECE HUD açık
        -- oyunculara, AYNI 1000ms saatten (ayrı bir thread AÇILMAZ). Hook
        -- yoksa (market.lua yüklü değilse) tamamen no-op.
        if Matrix.Hud and Matrix.Hud.PushSnapshots then
            local ok5, err5 = pcall(Matrix.Hud.PushSnapshots)
            if not ok5 then Matrix.Log('CORE', '[HATA] Hud.PushSnapshots basarisiz (yutuldu): %s', tostring(err5)) end
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
-- [H4] PLAYER DROP CLEANUP (genişletilmiş süpürme)
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

    -- Bu oyuncunun dispatcher_src olarak atandığı TÜM aktif dispatch'ler:
    -- bot KOŞMAYA DEVAM EDER (sunucu-tarafında tick'leniyor), sadece
    -- telsiz bağı kopar → dispatcher_src=nil, comms_lost=true. Böylece
    -- (a) FiveM'in yeniden kullandığı src ID'leri ile yanlış oyuncuya
    -- telsiz statiği gitmesi engellenir, (b) dispatch orphaned bir
    -- dispatcher referansı tutmaz.
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

-- /coords - anlık konum + heading'i chat'e basar, /traphouseekle [label]
-- [x] [y] [z], /korbolgetest [x] [y] [z] gibi komutlara veya Config.Market.
-- Zones / Config.Supplier.DeadDrops içine yapıştırılabilir formatta.
RegisterCommand('coords', function(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped bulunamadi.'); return end
    local c  = GetEntityCoords(ped)
    local hd = GetEntityHeading(ped)
    -- ★ İKİ FORMAT, İKİ AMAÇ — birbirine KARIŞTIRILMAMALI:
    --   (1) KOMUTLAR için (örn. /traphouseekle, /korbolgetest): boşlukla
    --       ayrılmış, VİRGÜLSÜZ. FiveM komut argümanları sadece boşluktan
    --       böler; virgüllü bir sayı tonumber() ile parse edilemez.
    --   (2) CONFIG DOSYALARI için (shared/config.lua içine Lua kodu olarak
    --       yapıştırılacak): virgüllü "vector3(x, y, z)" Lua sözdizimi.
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

-- ★ Fiziksel sevk dışa açılımı (logistics.lua DispatchDealer buradan çağırır)
exports('BeginPhysicalDispatch', function(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
    return Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
end)
exports('CompleteDispatch', function(botId, reason)
    return Matrix.CompleteDispatch(botId, reason)
end)
exports('GetActiveDispatches', function()
    -- Dış katmanlar için salt-okunur kopya döndür (deep copy değil, referans).
    -- 5. katman (örn. hava lojistiği) bu tabloyu kendi tick'inde okuyabilir.
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
        Reply(src, ('#%d [%s|%s|%s] Fat:%.2f Cort:%.2f With:%.2f | Chem:%.2f Cyber:%.2f Log:%.2f | Res:%.2f Snitch:%.2f'):format(
            id, bot.name, bot.role, bot.status,
            bot.biology.fatigue_level, bot.biology.cortisol_level, bot.biology.withdrawal_index,
            bot.psychology.skill_chemistry, bot.psychology.skill_cyber, bot.psychology.skill_logistics,
            bot.psychology.resilience, bot.psychology.snitch_tendency))
    end
    Reply(src, ('--- Toplam %d bot ---'):format(count))
end, false)

-- ★ Fiziksel sevk durum komutu
RegisterCommand('fizikselsevk', function(src, args)
    local count = 0
    for botId, d in pairs(Matrix.Dispatches) do
        count = count + 1
        local lc = d.last_coords or d.origin
        Reply(src, ('Bot #%d [%s] Plaka:%s Konum:(%.1f,%.1f,%.1f) Hedef-Mesafe:%.1fm Hiz:%.2fm/s Sinyal:%s Polis-Dwell:%d Bekleyen:%d'):format(
            botId, d.vehicle_type, tostring(d.plate),
            lc.x, lc.y, lc.z,
            #(lc - d.destination),
            d.cruise_speed or 0.0,
            d.comms_lost and 'KESİK' or 'VAR',
            d.police_dwell,
            #d.pending_events))
    end
    Reply(src, ('--- Toplam %d fiziksel dispatch ---'):format(count))
end, false)
