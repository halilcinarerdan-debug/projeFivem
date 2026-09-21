-- =====================================================================
-- MATRIX BUREAU / bureau.lua
-- Dirty-set persistence, ticker'da sıfır await, pattern cache,
-- ★ REVİZYON #2: BÜRO ↔ TOPTANCI İSTİHBARAT KÖPRÜSÜ ★
--
-- KONTRAТ (logistics.lua ile):
--   logistics.lua'nın OnPickup'ında forensic_trace_left == true ise:
--       Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
--   çağrılır. Bureau bu örneği SADECE BİRİKTİRİR (ANINDA trust'a dokunmaz!).
--
-- Bureau tarafı kendi tick'inde (Bureau.TickDropForensics):
--   1) Eski örnekleri unutur (zaman soğuması / üstel decay).
--   2) Match_Certainty hesaplar (aşağıdaki formül).
--   3) certainty >= BureauLeakCertaintyThreshold VE henüz leaked değilse:
--      → EmitSupplierIntelLeak → toptancıya deterministik kanalla sızdırır
--      → trust penalty uygulanır (logistics.lua ApplyBureauIntelLeak hook'u)
--      → leaked = true (tek seferlik; yeniden tetiklenmez).
--
-- MİMARİ GENİŞLETME NOTU (5/6/7/8. katman):
--   • 5. katman: DropForensics'e "witness_corroboration" alanı eklenebilir;
--     certainty formülüne ÇARPIMSAL terim olarak girer. ★ Bu katmanda AYRICA
--     aşağıdaki livestream tick'ine tek satırlık bir "telsiz sessizliği"
--     koruması eklendi (bkz. market.lua Matrix.RadioSilence) — Büro'nun
--     kendi mantığı (üçgenleme/baskın/desifre formülleri) HİÇ değişmedi,
--     sadece siber heatmap artışı market.lua'nın Matrix.RadioSilence.IsActive
--     guard'ıyla koşullandı. Hook yoksa (market.lua yüklü değilse) davranış
--     ESKİSİYLE BİREBİR AYNIDIR.
--   • 6. katman (BU SÜRÜM): ComputeRaidSquad artık server/door_reinforcement.lua
--     yüklüyse escapeWindow'a (kapı kırılma süresi) bir bonus ekler — bkz.
--     [K6] işaretli blok aşağıda. Hook yoksa davranış ESKİSİYLE BİREBİR
--     AYNIDIR. Ayrıca IssueRaid/ResolveRaidOutcome artık kendi server-içi
--     ('matrix:internal:raidIssued' / 'matrix:internal:raidResolved') Lua
--     event'lerini de fırlatır — bureau.lua'nın KENDİ üçgenleme/baskın/
--     deşifre formüllerine HİÇ dokunulmadı, bu yalnızca dış modüllerin
--     (door_reinforcement.lua) main.lua'ya veya bu dosyaya dokunmadan bir
--     baskının ne zaman başladığını/bittiğini öğrenmesini sağlayan pasif
--     bir yayın kanalıdır.
--   • 6. katman: EmitSupplierIntelLeak'in leak_channel parametresi
--     (siber / rüşvet / asılsız) yeni katsayı kanalları açar.
--   • 7. katman: BureauLeakCertaintyThreshold'u trap-house bazında
--     override eden bir "bölgesel federal baskı" vektörü eklenebilir.
--   • 8. katman: Uluslararası kartel diplomasi matrisi aynı kanaldan beslenir.
-- =====================================================================


Matrix.Bureau     = Matrix.Bureau     or {}
Matrix.TrapHouses = Matrix.TrapHouses or {}
Matrix.Supplier   = Matrix.Supplier   or {}
Matrix.Bureau.DropForensics = Matrix.Bureau.DropForensics or {}


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
local cyberLeakHeatmap   = {}
local patternLog         = {}


-- Dirty sets
local dirtyDecryption = {}
local dirtyIntel      = {}


-- Raid & livestream runtime
local RaidLogIdByTrapHouse = {}
local LivestreamSessions   = {}


-- ★ REVİZYON #2 runtime state
-- [dropId] = {
--     samples          = { { quality=N, at=epoch }, ... },   -- FIFO sınırı uygulanır
--     supplier_id      = N,
--     citizenid        = 'CID',
--     leaked           = false,     -- tek seferlik tetik guard'ı
--     last_activity_at = epoch
-- }
-- MATEMATİKSEL NOT: samples listesi zaman-serisi bir pencere (sliding window)
-- gibi davranır; MaxDropSamplesForLeak sınırını aşan örnekler FIFO olarak
-- atılır. Bu, belleği O(sabit) tutarken "son N kanıt günceldir" varsayımıyla
-- adli mantığa uyar (eski kanıtlar zaten kontaminasyon/aşınma ile geçersizdir).
local DropForensicsByDropId = Matrix.Bureau.DropForensics
local WARNED_MISSING_SUPPLIER_HOOK = false


-- =====================================================================
-- UTILITIES
-- =====================================================================
-- ★ DÜZELTME: FiveM'de vector3/vector4 değerlerinin type() sonucu
-- 'vector3'/'vector4' string'idir — 'table' DEĞİL, 'userdata' DEĞİL. Bu
-- kontrol eskiden yalnızca 'table'/'userdata' kabul ediyordu, yani GERÇEK
-- her vector3 GEÇERSİZ sayılıyor, mesafe her zaman math_huge dönüyordu
-- (FindNearestTrapHouse asla bir trap house bulamıyordu — üçgenleme/
-- deşifre kazancı SESSİZCE hiç işlemiyordu). Artık vector3/vector4 de
-- kabul ediliyor.
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    if type(a) ~= 'userdata' and type(a) ~= 'table' and type(a) ~= 'vector3' and type(a) ~= 'vector4' then return math_huge end
    if type(b) ~= 'userdata' and type(b) ~= 'table' and type(b) ~= 'vector3' and type(b) ~= 'vector4' then return math_huge end
    local ax, ay, az = a.x, a.y, a.z
    local bx, by, bz = b.x, b.y, b.z
    if type(ax) ~= 'number' or type(ay) ~= 'number' or type(az) ~= 'number' then return math_huge end
    if type(bx) ~= 'number' or type(by) ~= 'number' or type(bz) ~= 'number' then return math_huge end
    if ax ~= ax or ay ~= ay or az ~= az then return math_huge end
    if bx ~= bx or by ~= by or bz ~= bz then return math_huge end
    return #(a - b)
end


-- ★ AYNI DÜZELTME (bkz. VectorDistance yorumu): vector3/vector4 artık kabul
-- ediliyor. Bu satır düzelmeden ÖNCE /traphouseekle'a GEÇERLİ bir koordinat
-- bile versen "gecersiz koordinat" hatası ALIRDI — çünkü CreateTrapHouse
-- her zaman IsValidCoords(vector3(x,y,z))'yi false buluyordu.
local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
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
        cyberLeakHeatmap[row.id] = Matrix.Clamp(tonumber(row.cyber_leak_intensity) or 0.0, 0.0, 999.0)
        patternLog[row.id]       = {}
    end
    Matrix.Log('BUREAU', '%d trap house yüklendi.', #rows)
end


CreateThread(function()
    Matrix.Bureau.LoadTrapHouses()
end)


function Matrix.Bureau.CreateTrapHouse(label, coords)
    if not IsValidCoords(coords) then return false, 'bad_coords' end
    label = (type(label) == 'string' and label ~= '') and label or 'Yeni Trap'


    MySQL.insert([[
        INSERT INTO matrix_trap_houses (label, coord_x, coord_y, coord_z, decryption_confidence, cyber_leak_intensity, raid_ordered, created_at)
        VALUES (?, ?, ?, ?, 0.0, 0.0, 0, NOW())
    ]], { label, coords.x, coords.y, coords.z },
    function(insertId)
        if not insertId then return end
        Matrix.TrapHouses[insertId] = {
            id = insertId, label = label, coords = vector3(coords.x, coords.y, coords.z),
            decryption_confidence = 0.0, raid_ordered = false
        }
        cyberLeakHeatmap[insertId] = 0.0
        patternLog[insertId] = {}
        Matrix.Log('BUREAU', 'Yeni trap house #%d (%s) oluşturuldu.', insertId, label)
    end)


    return true
end


-- =====================================================================
-- FIND NEAREST
-- =====================================================================
local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
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
    if amount ~= amount then amount = 0.0 end


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
-- COMMS TRIANGULATION (IDW)
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

    -- ★ [T4] Her gerçek üçgenleme isabeti (telsiz ihlali) aynı zamanda
    -- Büro'nun kalıcı öğrenme hafızasına da işlenir. Bureau'nun KENDİ
    -- üçgenleme/deşifre formülüne (aşağıdaki satırlar) HİÇ dokunulmadı;
    -- bu tek satır yalnızca ek bir gözlemcidir (bkz. dosya sonu [T4] bloğu).
    if Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end


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
-- momentum' = min(momentum*GeometricFactor + Increment, MaxMomentum)
-- Doğrusal özyineleme x_(n+1) = a*x_n + b, a>1 → sabit nokta negatif
-- → tavan olmadan sınırsız büyür → MaxMomentum SERT tavanı.
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


-- ★ KATMAN 5: salt-okunur getter (market.lua'nın Taktik HUD'u için). Var
-- olan cyberLeakHeatmap'i okur — Büro'nun formüllerinin KENDİSİNE dokunmaz.
function Matrix.Bureau.GetHeat(trapHouseId)
    return cyberLeakHeatmap[trapHouseId] or 0.0
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
-- TICK (pasif örüntü analizi)
-- gain = PatternAnalysisGain * regularity * (1.0 + heat)
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
-- RAID (deterministik mürettebat/breach/kaçış matrisi)
-- =====================================================================
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


    -- ★ [K6] KAPI SÜRGÜ TAHKİMATI KÖPRÜSÜ (server/door_reinforcement.lua):
    -- sürgü/barikat seviyesi kapı kırılma süresine (escapeWindow) bir bonus
    -- ekler. Hook yoksa (modül yüklü değilse, ya da hata verirse) davranış
    -- BİREBİR ESKİSİ GİBİDİR — bu satırlar Büro'nun kendi mürettebat/breach
    -- formülüne HİÇ dokunmaz, yalnızca sonuca eklenen dışsal bir terimdir.
    if Matrix.DoorReinforcement and Matrix.DoorReinforcement.GetBreachDelaySeconds then
        local ok, bonus = pcall(Matrix.DoorReinforcement.GetBreachDelaySeconds, trapHouseId)
        if ok and type(bonus) == 'number' and bonus == bonus and bonus > 0.0 then
            escapeWindow = escapeWindow + bonus
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


    TriggerClientEvent('matrix:client:executeRaid', -1, trapHouseId, house.coords, {
        squad_size    = squadSize,
        breach_method = breachMethod,
        escape_window = escapeWindow
    })


    -- ★ [K6] Pasif server-içi yayın: door_reinforcement.lua (yüklüyse) bu
    -- event'i dinleyerek kapı kırılma geri sayımını kendi tarafında başlatır.
    -- Bureau'nun KENDİ mantığı bu event'in var olup olmamasından etkilenmez.
    TriggerEvent('matrix:internal:raidIssued', trapHouseId, escapeWindow, breachMethod, squadSize)

    -- ★ [T4] Bir baskın = Büro'nun eline geçen ürünün saflığı ölçülür. Bu,
    -- learning-core'un average_purity_intercepted'ini besler (bkz. dosya
    -- sonu [T4] bloğu). Kitchen batch verisi yoksa (o trap house hiç üretim
    -- yapmamışsa) sessizce atlanır -- sahte bir 0 örneği EKLENMEZ.
    if Matrix.Bureau.RecordPurityIntercepted then
        Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    end


    Matrix.Log('BUREAU', '[ŞAFAK BASKINI] Trap house #%d (%s): %d birim, breach=%s, kaçış=%ds.',
        trapHouseId, house.label, squadSize, breachMethod, escapeWindow)
end


local VALID_RAID_OUTCOMES = { captured = true, escaped = true, eliminated = true }


function Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
    if not VALID_RAID_OUTCOMES[outcome] then return false end
    local logId = RaidLogIdByTrapHouse[trapHouseId]
    if not logId then return false end


    MySQL.prepare('UPDATE matrix_raid_log SET outcome = ?, resolved_at = NOW() WHERE id = ?', { outcome, logId })


    -- ★ [K6] bkz. IssueRaid yorumu — geri sayımı sonlandırmak için simetrik yayın.
    TriggerEvent('matrix:internal:raidResolved', trapHouseId, outcome)


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
end


-- =====================================================================
-- FLUSH LOOP (dirty-set drene)
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
-- QB-PHONE CANLI YAYIN & SİBER PROPAGANDA
-- =====================================================================
function Matrix.Bureau.StartLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    if LivestreamSessions[src] then return false end


    local state = Matrix.GetOrCreatePlayerState(src)
    LivestreamSessions[src] = {
        started    = Matrix.Now(),
        citizenid  = state and state.citizenid,
        hype       = 1.0,
        heat_added = 0.0,
        trap_house_id = nil
    }
    Matrix.Log('BUREAU', '[CANLI YAYIN BAŞLADI] src=%d, IP çıkışı Büro siber taramasına açıldı.', src)
    return true
end


function Matrix.Bureau.StopLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local session = LivestreamSessions[src]
    if not session then return false end
    LivestreamSessions[src] = nil


    local duration = Matrix.Now() - session.started
    MySQL.prepare([[
        INSERT INTO matrix_livestream_events (citizenid, duration_seconds, hype_multiplier, heat_added, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { session.citizenid, duration, session.hype, session.heat_added, session.trap_house_id })


    Matrix.Log('BUREAU', '[CANLI YAYIN BİTTİ] src=%d, süre=%ds, son hype=%.2f, eklenen heat=%.2f',
        src, duration, session.hype, session.heat_added)
    return true
end


RegisterNetEvent('matrix:server:reportLivestreamStart', function()
    Matrix.Bureau.StartLivestream(source)
end)


RegisterNetEvent('matrix:server:reportLivestreamStop', function()
    Matrix.Bureau.StopLivestream(source)
end)


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


                    -- ★ KATMAN 5 KÖPRÜSÜ (market.lua): telsiz sessizliği aktifken
                    -- (/sessizlik) siber heatmap artışı ve buna bağlı deşifre
                    -- kazancı durur. Hook (Matrix.RadioSilence) yüklü değilse
                    -- davranış BİREBİR ESKİSİ GİBİDİR — üçgenleme/baskın/desifre
                    -- formüllerinin KENDİSİ bu revizyonda HİÇ değişmedi.
                    local silent = Matrix.RadioSilence and Matrix.RadioSilence.IsActive
                        and Matrix.RadioSilence.IsActive(session.citizenid)


                    if not silent then
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
    end
end)


-- =====================================================================
-- ★ REVİZYON #2: DEAD DROP ADLİ ÖRNEK TOPLAYICI ★
--
-- FORMÜL (Match_Certainty — deterministik birikim, RNG yok):
--   N           = samples listesindeki geçerli örnek sayısı
--   avgQ        = Σ(sample.quality) / N
--   volumeF     = min(1.0, N / RequiredSamplesForLeak)
--   heatF       = 1.0 + min(heat, CyberLeakMaxIntensity) * 0.15
--   recencyF    = exp(-elapsed_minutes * SampleDecayRate)
--   certainty   = clamp(avgQ * volumeF * heatF * recencyF, 0, 1)
--
-- Yorum: Kanıt KALİTESİ (avgQ), kanıt MİKTARI (volumeF — daha çok örnek
-- = daha kesin profil), yerel SİBER YOĞUNLUK (heatF — hedef bölgede
-- Büro gözetimi yoğunsa adli veri daha hızlı işlenir) ve tazelik
-- (recencyF — eski kanıt zamanla kontamine olur) ÇARPIMSAL etkileşir.
-- Çarpımsal zincir matematiksel olarak: certainty ∈ [0,1]; hiçbir terim
-- tek başına eşiği geçiremez, hepsi aynı yönde olmalıdır → gerçekçi
-- adli süreç simülasyonu.
-- =====================================================================


-- Config'te tanımlı olmayan sabitler için güvenli varsayılanlar.
-- (config.lua'ya Config.Bureau.BureauLeak* alanları eklenirse override edilir.)
local function CfgBureau(key, default)
    local v = Config.Bureau[key]
    if v == nil then return default end
    return v
end


local function NowEpoch()
    return os_time()
end


-- Yeni bir adli örnek kaydeder. logistics.lua OnPickup içinde
-- forensic_trace_left == true olduğunda çağrılır.
-- @param dropId      : number — dead drop ID
-- @param quality     : number [0,1] — bu örneğin adli kalitesi (parmak izi)
-- @param supplierId  : number — hangi toptancıya bağlı
-- @param citizenid   : string — teslim alımı kimin adına yapıldı
function Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    dropId     = tonumber(dropId)
    supplierId = tonumber(supplierId)
    quality    = tonumber(quality) or 0.0
    if not dropId or not supplierId then return false end
    if quality ~= quality then quality = 0.0 end
    quality = Matrix.Clamp(quality, 0.0, 1.0)


    local rec = DropForensicsByDropId[dropId]
    if not rec then
        rec = {
            samples          = {},
            supplier_id      = supplierId,
            citizenid        = citizenid or 'UNKNOWN',
            leaked           = false,
            last_activity_at = NowEpoch()
        }
        DropForensicsByDropId[dropId] = rec
    end


    -- FIFO pencere (bellek O(sabit))
    local maxSamples = CfgBureau('MaxDropSamplesForLeak', 8)
    rec.samples[#rec.samples + 1] = { quality = quality, at = NowEpoch() }
    while #rec.samples > maxSamples do
        table.remove(rec.samples, 1)
    end
    rec.last_activity_at = NowEpoch()
    -- supplier_id / citizenid zaman içinde değişmez varsayımı (drop→toptancı
    -- config eşlemesi sabittir).


    Matrix.Log('BUREAU',
        '[ADLİ ÖRNEK] Drop #%d, kalite=%.3f (toplam örnek: %d, toptancı #%d)',
        dropId, quality, #rec.samples, rec.supplier_id)
    return true
end


-- Bir drop için Match_Certainty hesabı (yukarıdaki formül).
-- Saf fonksiyon: yan etkisi yoktur, RNG yoktur; aynı girdi → aynı çıktı.
local function ComputeDropForensicCertainty(dropId, rec)
    rec = rec or DropForensicsByDropId[dropId]
    if not rec or #rec.samples == 0 then return 0.0, 0.0, 0 end


    -- Zaman soğuması: her örnek kendi yaşına göre ağırlıklandırılır.
    -- Bu, eski kanıtın "unutulmasını" tek bir skalerle çarpmak yerine
    -- ağırlıklı ortalama ile ifade eder → daha doğru adli davranış.
    local decayRate  = CfgBureau('SampleDecayRate', 0.002)  -- dakika başına
    local now        = NowEpoch()
    local wSum, qSum = 0.0, 0.0
    for _, s in ipairs(rec.samples) do
        local ageMin = math_max((now - s.at) / 60.0, 0.0)
        local w      = math.exp(-ageMin * decayRate)
        qSum = qSum + (s.quality * w)
        wSum = wSum + w
    end
    if wSum <= 0.0 then return 0.0, 0.0, #rec.samples end


    local avgQ        = qSum / wSum
    local required    = CfgBureau('RequiredSamplesForLeak', 3)
    local volumeF     = math_min(1.0, #rec.samples / math_max(required, 1))
    -- heat, en yakın trap house üzerinden okunur (drop konumu zaten config'te).
    local heat        = 0.0
    local dropCfg
    if Config.Supplier and Config.Supplier.DeadDrops then
        for _, d in ipairs(Config.Supplier.DeadDrops) do
            if d.id == dropId then dropCfg = d break end
        end
    end
    if dropCfg then
        local trapId, trapDist = FindNearestTrapHouse(dropCfg.coords)
        if trapId and trapDist <= Config.Bureau.BaseSearchRadius then
            heat = cyberLeakHeatmap[trapId] or 0.0
        end
    end
    local heatF       = 1.0 + math_min(heat, Config.Bureau.CyberLeakMaxIntensity) * 0.15
    local certainty   = Matrix.Clamp(avgQ * volumeF * heatF, 0.0, 1.0)
    return certainty, avgQ, #rec.samples
end


-- Toptancıya deterministik istihbarat sızıntısı emisyonu.
-- Bu, "sihirli RNG" yerine tamamen ölçülebilir bir kanaldır: Büro
-- laboratuvarının birikmiş kesinliği + drop heatmap'i.
local function EmitSupplierIntelLeak(citizenid, supplierId, certainty, dropId)
    -- Trust cezası: certainty - threshold aralığını [Base, Max] penalty'ye
    -- DOĞRUSAL haritalar. Bu, kesinlik arttıkça sızıntının "daha ağır"
    -- olduğunu ifade eder.
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local basePen    = CfgBureau('BureauLeakTrustPenaltyBase', 0.15)
    local maxPen     = CfgBureau('BureauLeakTrustPenaltyMax',  0.45)
    local span       = math_max(1.0 - threshold, 0.001)
    local norm       = Matrix.Clamp((certainty - threshold) / span, 0.0, 1.0)
    local penalty    = basePen + (maxPen - basePen) * norm


    -- ★ KÖPRÜ: logistics.lua ApplyBureauIntelLeak hook'unu dene.
    if Matrix.Supplier and Matrix.Supplier.ApplyBureauIntelLeak then
        pcall(Matrix.Supplier.ApplyBureauIntelLeak, citizenid, supplierId, penalty, dropId)
    else
        -- Fallback: hook yoksa, doğrudan DB'ye yaz. Trust = GREATEST(0, trust-penalty).
        -- forensic_leaks sayacını arttır ki toptancı geçmişi izlenebilir kalsın.
        MySQL.prepare([[
            INSERT INTO matrix_supplier_trust
                (citizenid, supplier_id, trust, late_payments, forensic_leaks, created_at, updated_at)
            VALUES (?, ?, 0.5, 0, 1, NOW(), NOW())
            ON DUPLICATE KEY UPDATE
                trust          = GREATEST(0.0, trust - ?),
                forensic_leaks = forensic_leaks + 1,
                updated_at     = NOW()
        ]], { citizenid, supplierId, penalty })


        if not WARNED_MISSING_SUPPLIER_HOOK then
            WARNED_MISSING_SUPPLIER_HOOK = true
            Matrix.Log('BUREAU',
                '[UYARI] Matrix.Supplier.ApplyBureauIntelLeak hooku tanimli degil; dogrudan DB yazimi kullanildi (logistics.lua guncellemesi onerilir).')
        end
    end


    Matrix.Log('BUREAU',
        '[İSTİHBARAT SIZINTISI] Drop #%d → Toptancı #%d | Kesinlik=%.3f | Penalty=%.3f | Mağdur=%s',
        dropId, supplierId, certainty, penalty, tostring(citizenid))


    -- İnfaz mangası / betrayal eşiği tetiklenmesi logistics.lua'nın
    -- ApplyBureauIntelLeak'i içinde kontrol edilir (o dosya BetrayalTrustThreshold
    -- ve TriggerBetrayal'a sahiptir). Hook yoksa fallback DB yazımı sonrası
    -- bir sonraki GetTrust çağrısında otomatik betrayal kontrolü olur.
end


-- Ticker: her N saniyede bir drop forensic kayıtlarını değerlendirir.
-- Bu fonksiyon ayrı bir CreateThread içinde çalışır (master ticker'ı kirletmez).
-- KARMAŞIKLIK: O(D * S) burada D = aktif drop kaydı, S = örnek sayısı (≤8).
function Matrix.Bureau.TickDropForensics()
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local staleAfter = CfgBureau('DropForensicsStaleSeconds', 3600)  -- 1 saat


    local now = NowEpoch()
    local toRemove = {}


    for dropId, rec in pairs(DropForensicsByDropId) do
        -- (1) Tamamen bayat kayıtları buda
        if (now - (rec.last_activity_at or now)) > staleAfter then
            toRemove[#toRemove + 1] = dropId
        else
            -- (2) Kesinlik hesapla
            local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)


            -- (3) Eşik aşıldı VE henüz sızdırılmadıysa → tek seferlik emisyon
            if not rec.leaked and certainty >= threshold then
                rec.leaked = true
                EmitSupplierIntelLeak(rec.citizenid, rec.supplier_id, certainty, dropId)
            end


            -- (4) Debug/log amaçlı: sadece anlamlı değişim olduğunda bas
            if N > 0 and N % 3 == 0 then
                Matrix.Log('BUREAU',
                    '[ADLİ TAKİP] Drop #%d | Örnek:%d | avgQ:%.3f | Kesinlik:%.3f (eşik:%.2f) | Sızdı:%s',
                    dropId, N, avgQ, certainty, threshold, tostring(rec.leaked))
            end
        end
    end


    for _, id in ipairs(toRemove) do
        DropForensicsByDropId[id] = nil
    end
end


CreateThread(function()
    local interval = CfgBureau('DropForensicsTickIntervalSeconds', 30) * 1000
    while true do
        Wait(interval)
        local ok, err = pcall(Matrix.Bureau.TickDropForensics)
        if not ok then
            Matrix.Log('BUREAU', '[HATA] TickDropForensics hata verdi (yutuldu): %s', tostring(err))
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


-- ★ REVİZYON #2: Dış katmanlardan (logistics.lua) manuel adli örnek beslemesi.
-- logistics.lua OnPickup içinden çağrılır VEYA doğrudan bu event tetiklenir.
RegisterNetEvent('matrix:server:reportDeadDropForensic', function(dropId, quality, supplierId, citizenid)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)


-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('TriggerPropaganda',      function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms', function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',     function(t) return Matrix.Bureau.LogPatternEvent(t) end)
exports('ReceiveSnitchLeak',      function(t) return Matrix.Bureau.ReceiveSnitchLeak(t) end)
exports('IssueRaid',              function(t) return Matrix.Bureau.IssueRaid(t) end)
exports('ResolveRaidOutcome',     function(t, o) return Matrix.Bureau.ResolveRaidOutcome(t, o) end)


-- ★ REVİZYON #2 dışa açılımı (logistics.lua bu export'u çağırır)
exports('OnDeadDropForensicPickup', function(dropId, quality, supplierId, citizenid)
    return Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)
exports('TickDropForensics', function()
    return Matrix.Bureau.TickDropForensics()
end)


-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[BUREAU]', msg } })
    else
        print(('[MATRIX:BUREAU:CONSOLE] %s'):format(msg))
    end
end


-- /coords'un ikinci satırı ("vector3(x, y, z)") config dosyalarına
-- yapıştırmak için virgüllüdür; oyuncular bunu (virgüllü haliyle) doğrudan
-- komutlara da yapıştırabiliyor. FiveM komut argümanlarını yalnızca
-- BOŞLUKTAN ayırdığı için "-1464.224," gibi trailing-comma'lı bir token
-- tonumber() ile hiç parse edilemez. Bu yüzden koordinat argümanlarındaki
-- virgüller tonumber'dan ÖNCE temizlenir (boşlukla ayrılmış doğru format
-- hâlâ çalışmaya devam eder — bu salt bir tolerans katmanıdır).
local function ParseCoordNumber(s)
    return tonumber((tostring(s or ''):gsub(',', '')))
end


-- ★ pcall'lı: MySQL.insert (veya IsValidCoords dışında herhangi bir şey)
-- beklenmedik şekilde hata verirse artık SESSİZCE yutulmuyor — chat'e
-- açık bir hata mesajı basılır VE server konsoluna loglanır. Önceki hâl
-- CreateTrapHouse'u pcall'sız çağırıyordu; bir DB hatası (örn. matrix.sql
-- hiç import edilmemişse tablo yok) komutun geri kalanını sessizce
-- durdurup oyuncuya HİÇBİR mesaj göstermeyebiliyordu.
RegisterCommand('traphouseekle', function(src, args)
    local label = args[1]
    local x, y, z = ParseCoordNumber(args[2]), ParseCoordNumber(args[3]), ParseCoordNumber(args[4])
    if not x or not y or not z then
        Reply(src, 'Kullanim: /traphouseekle [label] [x] [y] [z]  (boslukla ayirin, virgul KULLANMAYIN)'); return
    end


    local ok, errOrResult = pcall(Matrix.Bureau.CreateTrapHouse, label, vector3(x, y, z))
    if not ok then
        Reply(src, ('HATA: trap house olusturulamadi (%s). Server konsolunu kontrol edin.'):format(tostring(errOrResult)))
        Matrix.Log('BUREAU', '[HATA] /traphouseekle basarisiz: %s', tostring(errOrResult))
        return
    end
    if errOrResult == false then
        Reply(src, 'HATA: gecersiz koordinat.')
        return
    end


    Reply(src, 'Trap house olusturma istegi gonderildi (async). Birkac saniye sonra /traphousedurum ile dogrulayin.')
end, false)


RegisterCommand('traphousedurum', function(src, args)
    local id = tonumber(args[1])
    local house = id and Matrix.TrapHouses[id]
    if not house then Reply(src, 'Kullanim: /traphousedurum [id]'); return end


    Reply(src, ('#%d %s | Deşifre:%.4f/%.2f | Heat:%.3f | Düzenlilik:%.3f | Baskın:%s'):format(
        id, house.label, house.decryption_confidence, Config.Bureau.RaidDecryptionThreshold,
        cyberLeakHeatmap[id] or 0.0, ComputePatternRegularity(id), tostring(house.raid_ordered)))
end, false)


RegisterCommand('desifreekle', function(src, args)
    local id = tonumber(args[1])
    local amount = tonumber(args[2])
    if not id or not Matrix.TrapHouses[id] or not amount then
        Reply(src, 'Kullanim: /desifreekle [id] [miktar]'); return
    end
    Matrix.Bureau.AdvanceDecryption(id, amount)
    Reply(src, ('Trap #%d deşifre: %.4f'):format(id, Matrix.TrapHouses[id].decryption_confidence))
end, false)


RegisterCommand('propagandatetikle', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /propagandatetikle [id]'); return end
    local momentum, heat = Matrix.Bureau.TriggerPropaganda(id)
    Reply(src, ('Momentum:%.3f Heat:%.3f'):format(momentum, heat))
end, false)


RegisterCommand('baskinzorla', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /baskinzorla [id]'); return end
    Matrix.Bureau.IssueRaid(id)
    Reply(src, ('Trap #%d için baskın ZORLA tetiklendi (test modu).'):format(id))
end, false)


RegisterCommand('baskinsonuclandir', function(src, args)
    local id = tonumber(args[1])
    local outcome = args[2]
    if not id or not outcome then
        Reply(src, 'Kullanim: /baskinsonuclandir [id] [captured|escaped|eliminated]'); return
    end
    local ok = Matrix.Bureau.ResolveRaidOutcome(id, outcome)
    Reply(src, ok and 'Sonuç kaydedildi.' or 'Geçersiz sonuç veya aktif baskın kaydı yok.')
end, false)


RegisterCommand('yayinbaslat', function(src)
    local ok = Matrix.Bureau.StartLivestream(src)
    Reply(src, ok and 'Canlı yayın başlatıldı (test).' or 'Zaten yayında veya geçersiz src.')
end, false)


RegisterCommand('yayinbitir', function(src)
    local ok = Matrix.Bureau.StopLivestream(src)
    Reply(src, ok and 'Canlı yayın bitirildi (test).' or 'Aktif yayın bulunamadı.')
end, false)


RegisterCommand('momentumgoster', function(src)
    Reply(src, ('Propaganda momentum: %.4f'):format(propagandaMomentum))
end, false)


-- ★ REVİZYON #2 debug komutları
-- /dropsizintiekle [dropId] [kalite 0-1] [supplierId] [citizenid]
-- Belirtilen drop için manuel bir adli örnek ekler. Normalde logistics.lua
-- OnPickup içinden otomatik çağrılır; bu komut RNG beklemeden test sağlar.
RegisterCommand('dropsizintiekle', function(src, args)
    local dropId     = tonumber(args[1])
    local quality    = tonumber(args[2])
    local supplierId = tonumber(args[3])
    local citizenid  = args[4] or 'TEST-CID'
    if not dropId or not quality or not supplierId then
        Reply(src, 'Kullanim: /dropsizintiekle [dropId] [kalite 0-1] [supplierId] [citizenid]'); return
    end
    local ok = Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    Reply(src, ok and ('Örnek eklendi. Toplam: %d'):format(#(DropForensicsByDropId[dropId] and DropForensicsByDropId[dropId].samples or {}))
              or 'Geçersiz parametre.')
end, false)


-- /dropsizintidurum - TÜM drop adli toplayıcılarının anlık durumu:
-- örnek sayısı, ortalama kalite, kesinlik, sızıntı durumu.
RegisterCommand('dropsizintidurum', function(src)
    local count = 0
    for dropId, rec in pairs(DropForensicsByDropId) do
        count = count + 1
        local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)
        Reply(src, ('Drop #%d → Toptancı #%d | Örnek:%d avgQ:%.3f Kesinlik:%.3f | Sızdı:%s | Mağdur:%s'):format(
            dropId, rec.supplier_id, N, avgQ, certainty,
            tostring(rec.leaked), tostring(rec.citizenid)))
    end
    Reply(src, ('--- Toplam %d drop adli kaydi ---'):format(count))
    Reply(src, ('BureauLeakCertaintyThreshold: %.2f'):format(CfgBureau('BureauLeakCertaintyThreshold', 0.65)))
end, false)


-- /dropsizintisifirla [dropId] - Bir drop'un birikmiş adli örneklerini sıfırlar
-- (test amaçlı; yeni bir suç döngüsünü baştan gözlemlemek için).
RegisterCommand('dropsizintisifirla', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropsizintisifirla [dropId]'); return end
    if DropForensicsByDropId[dropId] then
        DropForensicsByDropId[dropId] = nil
        Reply(src, ('Drop #%d adli toplayicisi sifirlandi.'):format(dropId))
    else
        Reply(src, 'Bu drop için aktif adli kayit yok.')
    end
end, false)


-- =====================================================================
-- ★★★ KATMAN 7 [T4] FAZ 1: BÜRO KİLİDİ (NÜKLEER ABLUKA) ★★★
-- Aşağıdaki blok TAMAMEN YENİ bir EKLEMEDİR. Yukarıdaki hiçbir formül/
-- tablo/davranış DEĞİŞTİRİLMEDİ — yalnızca iki tek-satırlık gözlemci
-- (OnUnencryptedComms içinde RecordRadioBreach, IssueRaid içinde
-- RecordPurityIntercepted çağrıları) eklendi; onlar da bu bloktaki
-- fonksiyonlar tanımlı DEĞİLSE hiçbir şey yapmaz.
--
-- AMAÇ: decryption_confidence/IssueRaid (tek trap house, %90 baraj, HER
-- BASKINDA RESETLENİR) zaten var. Bu blok bunun ÜZERİNE, "bu trap house
-- artık yakılmış" diyen İKİNCİ, kalıcı bir eşik ekler: BİRİKMİŞ telsiz
-- ihlali sayısı + ele geçirilen ürünün ortalama saflığı (matrix_kitchen_
-- batches.output_purity, server/kitchen.lua — [0,1] ölçeğinde, YÜZDE
-- DEĞİL). Eşik (%75) aşılınca matrix_bureau_learning_core.lockdown_active=1
-- olur; server/district_hubs.lua (yüklüyse) o trap house'un Toplu Satış
-- Hub'larını dondurur, server/market.lua Matrix.CashDecay.Launder o trap
-- house için kirli nakit aklamayı reddeder. Tek seferlik baskınların
-- aksine lockdown KENDİLİĞİNDEN resetlenmez — yalnızca katsayı yeniden
-- eşiğin altına düşünce kalkar (IssueRaid bu sayaçları da PostRaidHeatmap
-- Decay ile soğutur, aşağıda).
--
-- SIFIR RNG: bu blokta da math.random YOK.
-- =====================================================================

local learningCore      = {}   -- [trapHouseId] = { frequent_zones, radio_breach_count, average_purity_intercepted, lockdown_active }
local dirtyLearningCore = {}


local function GetLearningState(trapHouseId)
    local state = learningCore[trapHouseId]
    if not state then
        state = {
            frequent_zones             = {},
            radio_breach_count         = 0,
            average_purity_intercepted = 0.0,
            lockdown_active            = false
        }
        learningCore[trapHouseId] = state
    end
    return state
end


-- ★ [T4] Sunucu her başladığında matrix_bureau_learning_core RAM'e
-- kilitlenir — LoadTrapHouses ile AYNI kalıp (bkz. dosya başı). Ayrı bir
-- tablo, çünkü matrix_bureau_intel (mevcut) yalnızca heat/triangulation/
-- pattern yoğunluğu taşır; radio_breach_count/average_purity_intercepted/
-- lockdown_active bambaşka, kalıcı bir sözleşmedir (raid'lerde SIFIRLANMAZ).
function Matrix.Bureau.LoadLearningCore()
    local rows = MySQL.query.await('SELECT * FROM matrix_bureau_learning_core', {}) or {}
    for _, row in ipairs(rows) do
        local zones = {}
        if row.frequent_zones and row.frequent_zones ~= '' then
            local ok, decoded = pcall(json.decode, row.frequent_zones)
            if ok and type(decoded) == 'table' then zones = decoded end
        end
        learningCore[row.trap_house_id] = {
            frequent_zones             = zones,
            radio_breach_count         = tonumber(row.radio_breach_count) or 0,
            average_purity_intercepted = tonumber(row.average_purity_intercepted) or 0.0,
            purity_sample_count        = tonumber(row.purity_sample_count) or 0,
            lockdown_active            = row.lockdown_active == 1
        }
    end
    Matrix.Log('BUREAU', '[T4] %d ogrenme hafizasi kaydi RAM onbellege kilitlendi.', #rows)
end


CreateThread(function()
    Matrix.Bureau.LoadLearningCore()
end)


local function FlushDirtyLearningCore()
    for trapHouseId in pairs(dirtyLearningCore) do
        local state = learningCore[trapHouseId]
        if state then
            MySQL.prepare([[
                INSERT INTO matrix_bureau_learning_core
                    (trap_house_id, frequent_zones, radio_breach_count, average_purity_intercepted, purity_sample_count, lockdown_active, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE
                    frequent_zones             = VALUES(frequent_zones),
                    radio_breach_count         = VALUES(radio_breach_count),
                    average_purity_intercepted = VALUES(average_purity_intercepted),
                    purity_sample_count        = VALUES(purity_sample_count),
                    lockdown_active            = VALUES(lockdown_active),
                    updated_at                 = NOW()
            ]], {
                trapHouseId,
                json.encode(state.frequent_zones),
                state.radio_breach_count,
                state.average_purity_intercepted,
                state.purity_sample_count or 0,
                state.lockdown_active and 1 or 0
            })
        end
        dirtyLearningCore[trapHouseId] = nil
    end
end


CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyLearningCore()
    end
end)


-- Deterministik kanıt katsayısı: breachRatio*BreachWeight + purityRatio*PurityWeight,
-- her ikisi de [0,1]'e kırpılır. average_purity_intercepted zaten [0,1]
-- ölçeğinde (bkz. matrix_kitchen_batches.output_purity), ayrı bir tavan
-- sabiti İCAT EDİLMEZ.
local function ComputeLockdownCoefficient(trapHouseId)
    local state = GetLearningState(trapHouseId)
    local breachRatio = math_min(state.radio_breach_count / Config.Bureau.LockdownBreachCeiling, 1.0)
    local purityRatio = math_min(state.average_purity_intercepted, 1.0)
    return (breachRatio * Config.Bureau.LockdownBreachWeight) + (purityRatio * Config.Bureau.LockdownPurityWeight)
end


local function EvaluateLockdown(trapHouseId)
    local state       = GetLearningState(trapHouseId)
    local coefficient = ComputeLockdownCoefficient(trapHouseId)

    if coefficient >= Config.Bureau.LockdownEvidenceThreshold and not state.lockdown_active then
        Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    elseif coefficient < Config.Bureau.LockdownEvidenceThreshold and state.lockdown_active then
        Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    end

    return coefficient
end


-- Her gerçek üçgenleme isabetinde Matrix.Bureau.OnUnencryptedComms
-- tarafından çağrılır (bkz. dosya başındaki tek satırlık hook).
function Matrix.Bureau.RecordRadioBreach(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local state = GetLearningState(trapHouseId)
    state.radio_breach_count = state.radio_breach_count + 1

    local zones = state.frequent_zones
    local known = false
    for i = 1, #zones do
        if zones[i] == house.label then known = true break end
    end
    if not known then zones[#zones + 1] = house.label end

    dirtyLearningCore[trapHouseId] = true
    EvaluateLockdown(trapHouseId)
end


-- Matrix.Bureau.IssueRaid tarafından çağrılır (bkz. dosya ortasındaki tek
-- satırlık hook). Trap house'un EN SON kitchen batch'inin output_purity'sini
-- (matrix_kitchen_batches, server/kitchen.lua) hareketli ortalamaya ekler.
-- Kendi bağımsız sayacı (purity_sample_count) kullanır — radio_breach_count
-- İLE KARIŞTIRILMAZ, ikisi farklı olay akışlarını sayar.
function Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    if not Matrix.TrapHouses[trapHouseId] then return end

    MySQL.query('SELECT output_purity FROM matrix_kitchen_batches WHERE trap_house_id = ? ORDER BY id DESC LIMIT 1',
        { trapHouseId },
        function(rows)
            local row = rows and rows[1]
            if not row or row.output_purity == nil then return end

            local state  = GetLearningState(trapHouseId)
            local sample = Matrix.Clamp(tonumber(row.output_purity) or 0.0, 0.0, 1.0)

            state.purity_sample_count = (state.purity_sample_count or 0) + 1
            local n = state.purity_sample_count
            state.average_purity_intercepted = state.average_purity_intercepted + ((sample - state.average_purity_intercepted) / n)

            dirtyLearningCore[trapHouseId] = true
            EvaluateLockdown(trapHouseId)
        end)
end


function Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = true
    dirtyLearningCore[trapHouseId] = true

    -- ★ Pasif server-içi yayın (raidIssued/raidResolved İLE AYNI desen) —
    -- server/district_hubs.lua (yüklüyse) bunu dinleyip kendi hub'larını
    -- dondurur/çözer. Bureau'nun KENDİ mantığı bu event'in var olup
    -- olmamasından etkilenmez.
    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, true)

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) icin NUKLEER ABLUKA DEVREDE (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end


function Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = false
    dirtyLearningCore[trapHouseId] = true

    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, false)

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) ablukasi kalkti (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end


function Matrix.Bureau.IsLockedDown(trapHouseId)
    local state = learningCore[trapHouseId]
    return state ~= nil and state.lockdown_active == true
end


-- ★ server/market.lua BuildSnapshot'un k6Lines bloğuna, Rendezvous/
-- DoorReinforcement İLE AYNI "hook-if-present" deseniyle takılması için
-- salt-okunur getter. Kilit yoksa nil döner (bulletin basılmaz).
function Matrix.Bureau.GetLockdownBulletin(trapHouseId)
    if not trapHouseId or not Matrix.Bureau.IsLockedDown(trapHouseId) then return nil end
    return '[ADLI ANOMALI: BURO KILIDI DEVREDE]', true
end


RegisterCommand('burokilitdurum', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitdurum [trapHouseId]'); return end

    local state       = GetLearningState(id)
    local coefficient = ComputeLockdownCoefficient(id)
    Reply(src, ('Trap #%d | Telsiz-Ihlali:%d Ort.Saflik:%.3f | Katsayi:%.3f/%.2f | Kilit:%s'):format(
        id, state.radio_breach_count, state.average_purity_intercepted,
        coefficient, Config.Bureau.LockdownEvidenceThreshold, tostring(state.lockdown_active)))
end, false)


-- /burokilitzorla [trapHouseId] - test amacli, esigi beklemeden kilidi
-- manuel tetikler (bkz. /baskinzorla ile AYNI disiplin/kapsam).
RegisterCommand('burokilitzorla', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitzorla [trapHouseId]'); return end
    Matrix.Bureau.TriggerLockdown(id, ComputeLockdownCoefficient(id))
    Reply(src, ('Trap #%d icin BURO KILIDI ZORLA tetiklendi (test modu).'):format(id))
end, false)


-- =====================================================================
-- ★ [T4-3] GELECEKTEKİ OPENAI / CHATGPT ANALİZ KÖPRÜSÜ
-- PASİF, varsayılan KAPALI. Kilit kararı (EvaluateLockdown, yukarıda) bu
-- köprüyü HİÇ beklemez — PerformHttpRequest saf danışma/log amaçlıdır.
-- Devre dışıyken bu thread'in TEK işi Wait() içinde beklemektir: 0 Resmon.
-- İnternet kesilirse veya apiKey yapılandırılmamışsa sistem otomatik
-- olarak deterministik motora (yukarıdaki EvaluateLockdown) düşer — o
-- zaten bu köprüden bağımsız çalışıyordu, "düşmek" için hiçbir ekstra
-- kod gerekmez.
-- =====================================================================
CreateThread(function()
    while true do
        Wait((Config.AI_Matrix_Brain.analysisIntervalMinutes or 60) * 60000)

        if Config.AI_Matrix_Brain.enabled then
            local ok, err = pcall(Matrix.Bureau.RunAIAdvisoryPass)
            if not ok then
                Matrix.Log('BUREAU', '[T4][AI] RunAIAdvisoryPass hata verdi (yutuldu): %s', tostring(err))
            end
        end
    end
end)


function Matrix.Bureau.RunAIAdvisoryPass()
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Matrix.Log('BUREAU', '[T4][AI] enabled=true fakat apiKey yapilandirilmamis, deterministik motor degismeden devam ediyor.')
        return
    end

    local payload = {}
    for trapHouseId, state in pairs(learningCore) do
        payload[#payload + 1] = {
            trap_house_id              = trapHouseId,
            frequent_zones             = state.frequent_zones,
            radio_breach_count         = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            lockdown_active            = state.lockdown_active
        }
    end

    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a deterministic police-heat auditor for a GTA roleplay server. Summarize risk trends only, never invent data, never suggest a course of action.' },
            { role = 'user', content = json.encode(payload) }
        }
    })

    PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
        if statusCode ~= 200 then
            Matrix.Log('BUREAU', '[T4][AI] OpenAI istegi basarisiz (HTTP %s); fallbackToDeterministic=%s, ogrenme motoru degismeden calismaya devam ediyor.',
                tostring(statusCode), tostring(Config.AI_Matrix_Brain.fallbackToDeterministic))
            return
        end

        local ok, decoded = pcall(json.decode, response)
        if not ok then
            Matrix.Log('BUREAU', '[T4][AI] OpenAI yaniti cozumlenemedi, deterministik motor etkilenmedi.')
            return
        end

        TriggerEvent('matrix:internal:aiAdvisoryReceived', decoded)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. Config.AI_Matrix_Brain.apiKey
    })
end