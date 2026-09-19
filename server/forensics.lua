-- =====================================================================
-- MATRIX FORENSICS / forensics.lua
-- In-memory balistik cache, lokal ID allocator, async insert.
--
-- ★ KATMAN 5 REVİZYONU: EVRİLEN BALİSTİK (Gauss Çekirdeği Mutasyonu) ★
--   Silahın KENDİ canı (ox_inventory item durability, weaponInventoryId/
--   weaponSlot üzerinden okunur) artık namlu iz netliğini (Q_kovan)
--   ÇARPIMSAL olarak mutasyona uğratır: Q_kovan = Q_kovan_taban * durability.
--   durability [0,1]'e clamp'li olduğundan bu ASLA taban formülün üstüne
--   çıkmaz — sadece eskimiş silahlar daha da düşük netlik üretir. Silah canı
--   %50'nin altına düşünce eşleşme kesinliği (match_certainty) ÜSTEL olarak
--   baltalanır ("Adli Laboratuvar Körlüğü"); %20'nin altında deterministik
--   Jam_Chance formülü 0.65'in üzerine çıkar ve buna bağlı bir kalıcı-ölüm
--   riski değeri hesaplanır (asıl tutukluk/RNG çözümü — varsa — çatışma
--   sistemine aittir; burada sadece SAF, tekrar üretilebilir formül üretilir).
--   RNG YOK: aynı (weaponWear, cortisol, durability) üçlüsü HER ZAMAN aynı
--   çıktıyı üretir.
-- =====================================================================

Matrix.Forensics = Matrix.Forensics or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math       = tonumber, table, math
local math_max, math_min          = math.max, math.min
local GetGameTimer                = GetGameTimer

-- weaponSerial -> { ballistic_id, wear_level }
local BallisticCache = {}
-- ballistic_id -> pendingWear
local PendingWearUpdates = {}

-- Forensic evidence için lokal ID allocator (async INSERT'e izin verir)
local EvidenceNextId     = 1
local EvidenceIdSynced   = false

local function GetActorDnaId(actor)
    if not actor then return 'UNKNOWN' end
    return actor.dna_id or 'UNKNOWN'
end

local function GetActorCortisol(actor)
    if not actor or not actor.biology then return 0.0 end
    return Matrix.Clamp(actor.biology.cortisol_level or 0.0, 0.0, 1.0)
end

-- ★ KATMAN 5: silahın KENDİ canı (ox_inventory item durability, [0,100])
-- weaponInventoryId/weaponSlot üzerinden okunur ve [0,1]'e normalize edilir.
-- Metadata yoksa (silah hiç ateşlenmemiş/canı hiç ayarlanmamış) varsayılan
-- 1.0 (tam sağlam) - mutasyon formülü bu durumda taban formülü DEĞİŞTİRMEZ.
local function GetWeaponDurability(weaponInventoryId, weaponSlot)
    if not weaponInventoryId or type(weaponSlot) ~= 'number' then return 1.0 end
    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    local durability = tonumber(meta.durability)
    if not durability then return 1.0 end
    return Matrix.Clamp(durability / 100.0, 0.0, 1.0)
end

-- FORMÜL: Q_iz = clamp(1.0 - cortisol_level * FingerprintQualityCortisolWeight, 0, 1)
-- Yorum: el terlemesi (kortizol/panik) parmak izi netliğini DOĞRUSAL olarak
-- düşürür; ağırlık sabiti (0.4) tek bir çarpandır, RNG YOK. O(1) karmaşıklık -
-- her çağrıda tek bir clamp+çarpma; 0 Resmon açısından maliyetsizdir.
function Matrix.Forensics.ComputeFingerprintQuality(actor)
    local cortisol = GetActorCortisol(actor)
    return Matrix.Clamp(1.0 - (cortisol * Config.Forensics.FingerprintQualityCortisolWeight), 0.0, 1.0)
end

-- FORMÜL (Katman 5 — Tutukluk / Jam Chance):
--   durability >= WeaponJamChanceThreshold  -> 0.0 (risk yok)
--   durability <  WeaponJamChanceThreshold  -> WeaponJamBaseChance * (1 + deficitRatio)
--   deficitRatio = (threshold - durability) / threshold  ∈ (0,1]
-- Yorum: eşiğin hemen altında tabana (%65) sıçrar, sonra durability sıfıra
-- yaklaştıkça DOĞRUSAL büyümeye devam eder (deficitRatio→1 iken chance→2x
-- taban, clamp ile [0,1]'e sınırlanır). RNG YOK; asıl "tutukluk oldu mu"
-- kararı (ve buna bağlı gerçek zaman içi rulet) bu formülü TÜKETEN çatışma
-- sistemine aittir — burada sadece deterministik olasılık DEĞERİ üretilir.
function Matrix.Forensics.ComputeJamChance(weaponDurability)
    weaponDurability = Matrix.Clamp(tonumber(weaponDurability) or 1.0, 0.0, 1.0)
    local threshold = Config.Forensics.WeaponJamChanceThreshold
    if weaponDurability >= threshold then return 0.0 end

    local deficitRatio = (threshold - weaponDurability) / math_max(threshold, 0.0001)
    return Matrix.Clamp(Config.Forensics.WeaponJamBaseChance * (1.0 + deficitRatio), 0.0, 1.0)
end

-- Jam_Chance eşiğin (WeaponJamChanceThreshold) altındaki silahlar için sabit
-- bir kalıcı-ölüm risk DEĞERİ döner (WeaponJamHardDeleteRisk); eşiğin
-- üstündeyse 0.0. Bu da SAF bir formüldür — hangi sistemin bu riski nasıl
-- kullanacağı (RNG'li mi, eşik-tabanlı mı) bu dosyanın kapsamı DIŞINDADIR.
function Matrix.Forensics.GetHardDeleteRiskIfJammed(weaponDurability)
    if Matrix.Forensics.ComputeJamChance(weaponDurability) > 0.0 then
        return Config.Forensics.WeaponJamHardDeleteRisk
    end
    return 0.0
end

-- =====================================================================
-- LOAD CACHE
-- =====================================================================
function Matrix.Forensics.LoadCaches()
    -- Ballistic weapons
    local rows = MySQL.query.await('SELECT weapon_serial, ballistic_id, wear_level FROM matrix_ballistic_weapons', {}) or {}
    for _, row in ipairs(rows) do
        BallisticCache[row.weapon_serial] = {
            ballistic_id = row.ballistic_id,
            wear_level   = row.wear_level or 0.0
        }
    end
    Matrix.Log('FORENSICS', '%d balistik silah önbelleğe yüklendi.', #rows)

    -- Evidence id watermark
    local r = MySQL.query.await('SELECT COALESCE(MAX(id),0) AS mx FROM matrix_forensic_evidence', {}) or {}
    local mx = (r[1] and r[1].mx) or 0
    EvidenceNextId   = mx + 1
    EvidenceIdSynced = true
    Matrix.Log('FORENSICS', 'Kanıt ID watermark: %d', EvidenceNextId)
end

CreateThread(function()
    Matrix.Forensics.LoadCaches()
end)

local function NextEvidenceId()
    if not EvidenceIdSynced then return nil end
    local id = EvidenceNextId
    EvidenceNextId = id + 1
    return id
end

-- =====================================================================
-- BALLISTIC REGISTRATION (cache'ten, async upsert)
-- =====================================================================
function Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return nil end
    weaponWear = Matrix.Clamp(tonumber(weaponWear) or 0.0, 0.0, 1.0)

    local cached = BallisticCache[weaponSerial]
    if cached then
        if cached.wear_level ~= weaponWear then
            cached.wear_level = weaponWear
            PendingWearUpdates[cached.ballistic_id] = weaponWear
        end
        return cached.ballistic_id
    end

    local ballisticId = ('BAL-%s-%06X'):format(
        weaponSerial:sub(-4),
        (GetGameTimer() + #weaponSerial) % 0xFFFFFF
    )

    BallisticCache[weaponSerial] = {
        ballistic_id = ballisticId,
        wear_level   = weaponWear
    }

    MySQL.prepare([[
        INSERT INTO matrix_ballistic_weapons
            (ballistic_id, weapon_serial, wear_level, sealed_as_crime_weapon, first_registered)
        VALUES (?, ?, ?, 0, NOW())
        ON DUPLICATE KEY UPDATE wear_level = VALUES(wear_level)
    ]], { ballisticId, weaponSerial, weaponWear })

    Matrix.Log('FORENSICS', 'Yeni balistik imza: %s (Seri: %s)', ballisticId, weaponSerial)
    return ballisticId
end

-- =====================================================================
-- WEAPON FIRE SIMULATION
--
-- FORMÜL (Namlu Yiv-Set İmzası / kovan iz netliği):
--   Q_kovan_taban   = clamp(1.0 - weaponWear*CasingWearWeight - cortisol*CasingCortisolWeight, 0, 1)
--   Q_kovan         = clamp(Q_kovan_taban * weaponDurability, 0, 1)      [★ Katman 5 mutasyonu]
--   match_certainty = clamp(Q_kovan * BallisticStriationPrecision, 0, 1)
--   (match_certainty < LabBlindnessThreshold ise ★ üstel körlük uygulanır)
--   sealed_as_crime_weapon = match_certainty > MatchCertaintyThreshold
-- Yorum: iki bağımsız aşınma kaynağı (mekanik weaponWear, biyolojik cortisol)
-- doğrusal olarak Q_kovan_taban'dan çıkarılır; silahın KENDİ canı bunu
-- ÇARPIMSAL olarak mutasyona uğratır (weaponDurability=1.0 iken formül
-- ESKİSİYLE BİREBİR AYNIDIR — geriye dönük uyumlu). Tüm terimler [0,1]
-- aralığına clamp'lidir -> taşma/negatif olasılık riski yok. RNG YOK: aynı
-- (weaponWear, cortisol, weaponDurability) üçlüsü HER ZAMAN aynı
-- match_certainty'i üretir (tekrar edilebilirlik = test edilebilirlik).
-- KARMAŞIKLIK: O(1) - tek çağrıda sabit sayıda aritmetik işlem.
-- =====================================================================
function Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, evidenceType, weaponDurability)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end

    weaponWear       = Matrix.Clamp(tonumber(weaponWear) or 0.0, 0.0, 1.0)
    evidenceType     = evidenceType or 'casing'
    weaponDurability = Matrix.Clamp(tonumber(weaponDurability) or 1.0, 0.0, 1.0)

    local ballisticId = Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    if not ballisticId then return nil end

    local cortisol = GetActorCortisol(actor)
    local qKovanBase = Matrix.Clamp(
        1.0 - (weaponWear * Config.Forensics.CasingWearWeight)
            - (cortisol   * Config.Forensics.CasingCortisolWeight),
        0.0, 1.0
    )

    -- ★ GAUSS ÇEKİRDEĞİ MUTASYONU (bkz. dosya başı yorumu).
    local qKovan = Matrix.Clamp(qKovanBase * weaponDurability, 0.0, 1.0)

    local fingerprintQuality = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dnaId              = GetActorDnaId(actor)
    local matchCertainty     = Matrix.Clamp(qKovan * Config.BallisticStriationPrecision, 0.0, 1.0)

    -- ★ ADLİ LABORATUVAR KÖRLÜĞÜ: silah canı eşiğin altındaysa eşleşme
    -- kesinliği ÜSTEL olarak baltalanır (deficit büyüdükçe çöküş hızlanır).
    -- Eşiğin ÜSTÜNDEKİ silahlar için deficit<=0 -> çarpan=1 -> HİÇ etkisi yok.
    if weaponDurability < Config.Forensics.WeaponDurabilityLabBlindnessThreshold then
        local deficit = Config.Forensics.WeaponDurabilityLabBlindnessThreshold - weaponDurability
        matchCertainty = Matrix.Clamp(
            matchCertainty * math.exp(-Config.Forensics.WeaponDurabilityBlindnessDecayRate * deficit),
            0.0, 1.0
        )
    end

    local sealed = matchCertainty > Config.Forensics.MatchCertaintyThreshold

    local stateCoords = actor.state and actor.state.coords
    local cx, cy, cz  = 0.0, 0.0, 0.0
    if stateCoords then cx, cy, cz = stateCoords.x, stateCoords.y, stateCoords.z end

    -- Lokal ID tahsis (async insert)
    local evidenceId = NextEvidenceId()

    if evidenceId then
        MySQL.prepare([[
            INSERT INTO matrix_forensic_evidence
                (id, ballistic_id, evidence_type, striation_quality, fingerprint_id, fingerprint_quality,
                 match_certainty, sealed_as_crime_weapon, coords_x, coords_y, coords_z, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ]], {
            evidenceId, ballisticId, evidenceType, qKovan, dnaId, fingerprintQuality,
            matchCertainty, sealed and 1 or 0, cx, cy, cz
        })
    else
        -- watermark henüz hazır değilse fallback async insert (id olmadan)
        MySQL.prepare([[
            INSERT INTO matrix_forensic_evidence
                (ballistic_id, evidence_type, striation_quality, fingerprint_id, fingerprint_quality,
                 match_certainty, sealed_as_crime_weapon, coords_x, coords_y, coords_z, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ]], {
            ballisticId, evidenceType, qKovan, dnaId, fingerprintQuality,
            matchCertainty, sealed and 1 or 0, cx, cy, cz
        })
    end

    if sealed then
        MySQL.prepare([[
            UPDATE matrix_ballistic_weapons
            SET sealed_as_crime_weapon = 1, seal_certainty = ?
            WHERE ballistic_id = ?
        ]], { matchCertainty, ballisticId })
        Matrix.Log('FORENSICS', '[MÜHÜRLENDI] %s suç aleti (%.4f)', ballisticId, matchCertainty)
    end

    return {
        evidence_id         = evidenceId or -1,
        ballistic_id        = ballisticId,
        dna_id              = dnaId,
        weapon_wear         = weaponWear,
        weapon_durability   = weaponDurability,
        striation_quality   = qKovan,
        fingerprint_quality = fingerprintQuality,
        match_certainty     = matchCertainty,
        sealed              = sealed,
        jam_chance          = Matrix.Forensics.ComputeJamChance(weaponDurability),
        hard_delete_risk    = Matrix.Forensics.GetHardDeleteRiskIfJammed(weaponDurability)
    }
end

-- ★ KATMAN 5: market.lua'nın undercover ajan tetiği için — bir alıcının
-- gizli ajan olduğu teslimat anında ANLAŞILDIĞINDA (bkz. market.lua
-- Matrix.Market.EvaluateSale) ilgili balistik kaydı otomatik %100
-- kesinlikle mühürlenir. RNG yok, tek bir deterministik DB yazımı.
function Matrix.Forensics.ForceSeal(ballisticId)
    if type(ballisticId) ~= 'string' or ballisticId == '' then return false end

    MySQL.prepare([[
        UPDATE matrix_ballistic_weapons
        SET sealed_as_crime_weapon = 1, seal_certainty = 1.0
        WHERE ballistic_id = ?
    ]], { ballisticId })

    Matrix.Log('FORENSICS', '[UNDERCOVER TETİĞİ] %s otomatik %%100 kesinlikle mühürlendi.', ballisticId)
    return true
end

-- =====================================================================
-- ADLİ KRİMİNAL RAPORU (ASCII, askeri evrak formatı) - ox_inventory
-- item.metadata.description alanına basılır, tooltip'te gösterilir.
-- =====================================================================
local REPORT_WIDTH = 36
local REPORT_BORDER = ('='):rep(REPORT_WIDTH)
local REPORT_DIVIDER = ('-'):rep(REPORT_WIDTH)

local function ReportLine(label, value)
    return ('%-13s: %s'):format(label, tostring(value))
end

function Matrix.Forensics.BuildForensicReport(data)
    local lines = {
        REPORT_BORDER,
        '     ADLI KRIMINAL RAPORU',
        REPORT_DIVIDER,
        ReportLine('BALISTIK ID', data.ballistic_id or 'BILINMIYOR'),
        ReportLine('KANIT TIPI', data.evidence_type or 'casing'),
        ReportLine('STRIASYON', ('%.3f'):format(data.striation_quality or 0.0)),
        ReportLine('PARMAK IZI', data.fingerprint_id or 'BILINMIYOR'),
        ReportLine('IZ NETLIGI', ('%.3f'):format(data.fingerprint_quality or 0.0)),
        ReportLine('ESLESME', ('%.3f'):format(data.match_certainty or 0.0)),
        ReportLine('MUHUR', data.sealed and 'MUHURLENDI' or 'MUHURLENMEDI')
    }

    -- ★ Katman 5: sadece çağıran taraf weapon_durability sağladıysa eklenir
    -- (geriye dönük uyumluluk — eski/DB'den yeniden üretilen raporlar bu
    -- alanı hiç geçmez ve çıktı ESKİSİYLE BİREBİR AYNI kalır).
    if data.weapon_durability ~= nil then
        lines[#lines + 1] = ReportLine('SILAH CANI', ('%.1f%%'):format(data.weapon_durability * 100.0))
        lines[#lines + 1] = ReportLine('TUTUKLUK RISKI', ('%.3f'):format(data.jam_chance or 0.0))
    end

    lines[#lines + 1] = REPORT_DIVIDER
    lines[#lines + 1] = ReportLine('KAYIT', os.date('%Y-%m-%d %H:%M:%S'))
    lines[#lines + 1] = REPORT_BORDER

    return table.concat(lines, '\n')
end

function Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    if not casingInventoryId or type(casingSlot) ~= 'number' then return nil end

    local casingMeta = Matrix.Inventory.GetSlotMetadata(casingInventoryId, casingSlot)
    local durability = tonumber(casingMeta.durability) or 100.0
    durability = Matrix.Clamp(durability, 0.0, 100.0)
    local weaponWear = Matrix.Clamp(1.0 - (durability / 100.0), 0.0, 1.0)

    -- ★ Katman 5: bu, kovanın KENDİ aşınması (weaponWear) İLE AYNI ŞEY
    -- DEĞİLDİR — silahın (weaponInventoryId/weaponSlot) kendi canıdır.
    local weaponDurability = GetWeaponDurability(weaponInventoryId, weaponSlot)

    local result = Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, 'casing', weaponDurability)
    if not result then return nil end

    local report = Matrix.Forensics.BuildForensicReport({
        ballistic_id        = result.ballistic_id,
        evidence_type        = 'casing',
        striation_quality    = result.striation_quality,
        fingerprint_id        = result.dna_id,
        fingerprint_quality  = result.fingerprint_quality,
        match_certainty      = result.match_certainty,
        sealed                = result.sealed
    })

    Matrix.Inventory.MergeMetadata(casingInventoryId, casingSlot, {
        ballistic_id       = result.ballistic_id,
        striation_quality  = result.striation_quality,
        fingerprint_id     = result.dna_id,
        fingerprint_quality= result.fingerprint_quality,
        description        = report
    })

    -- Silahın kendisi de (kovan değil) incelendiğinde aynı adli özet görünsün.
    if weaponInventoryId and type(weaponSlot) == 'number' then
        Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, {
            ballistic_id      = result.ballistic_id,
            weapon_wear       = result.weapon_wear,
            weapon_durability = result.weapon_durability,
            jam_chance        = result.jam_chance,
            description       = Matrix.Forensics.BuildForensicReport({
                ballistic_id         = result.ballistic_id,
                evidence_type         = 'weapon',
                striation_quality     = result.striation_quality,
                fingerprint_id         = result.dna_id,
                fingerprint_quality   = result.fingerprint_quality,
                match_certainty       = result.match_certainty,
                sealed                 = result.sealed,
                weapon_durability     = result.weapon_durability,
                jam_chance             = result.jam_chance
            })
        })
    end

    return result.evidence_id, result.match_certainty, result.sealed, result.jam_chance, result.hard_delete_risk
end

-- =====================================================================
-- TOUCH STAMP
-- =====================================================================
function Matrix.Forensics.StampTouch(actorRef, inventoryId, slot)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end
    if not inventoryId or type(slot) ~= 'number' then return nil end

    local q  = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dna= GetActorDnaId(actor)

    Matrix.Inventory.MergeMetadata(inventoryId, slot, {
        fingerprint_id      = dna,
        fingerprint_quality = q
    })

    MySQL.prepare([[
        INSERT INTO matrix_touch_log
            (fingerprint_id, fingerprint_quality, inventory_id, slot_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { dna, q, tostring(inventoryId), slot })

    return q
end

-- =====================================================================
-- LAB ANALYSIS
-- =====================================================================
function Matrix.Forensics.AnalyzeEvidence(evidenceId)
    if type(evidenceId) ~= 'number' then return nil end

    local rows = MySQL.query.await('SELECT * FROM matrix_forensic_evidence WHERE id = ?', { evidenceId })
    local evidence = rows and rows[1]
    if not evidence then return nil end

    local q        = Matrix.Clamp(tonumber(evidence.striation_quality) or 0.0, 0.0, 1.0)
    local match    = Matrix.Clamp(q * Config.BallisticStriationPrecision, 0.0, 1.0)
    local sealed   = match > Config.Forensics.MatchCertaintyThreshold

    MySQL.prepare([[
        UPDATE matrix_forensic_evidence
        SET match_certainty = ?, sealed_as_crime_weapon = ?
        WHERE id = ?
    ]], { match, sealed and 1 or 0, evidenceId })

    if sealed then
        MySQL.prepare([[
            UPDATE matrix_ballistic_weapons
            SET sealed_as_crime_weapon = 1, seal_certainty = ?
            WHERE ballistic_id = ?
        ]], { match, evidence.ballistic_id })
        Matrix.Log('FORENSICS', 'Lab: kanıt #%d -> %s mühürlendi (%.4f)', evidenceId, evidence.ballistic_id, match)
    else
        Matrix.Log('FORENSICS', 'Lab: kanıt #%d yetersiz eşleşme (%.4f)', evidenceId, match)
    end

    return match, sealed
end

-- =====================================================================
-- WEAR FLUSH (ticker zamanlı, ana ticker'a yük olmasın diye ayrı thread)
-- =====================================================================
CreateThread(function()
    while true do
        Wait(20000)
        for bid, wear in pairs(PendingWearUpdates) do
            PendingWearUpdates[bid] = nil
            MySQL.prepare('UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE ballistic_id = ?', { wear, bid })
        end
    end
end)

-- =====================================================================
-- EVENT BRIDGE (guard'lı)
-- =====================================================================
RegisterNetEvent('matrix:server:reportWeaponDischarge', function(weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponSerial) ~= 'string' or #weaponSerial == 0 or #weaponSerial > 64 then return end
    if type(casingInventoryId) ~= 'string' or type(casingSlot) ~= 'number' then return end
    if weaponInventoryId ~= nil and type(weaponInventoryId) ~= 'string' then weaponInventoryId = nil end
    if type(weaponSlot) ~= 'number' then weaponSlot = nil end
    Matrix.Forensics.OnWeaponFired({ kind = 'player', source = src }, weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
end)

RegisterNetEvent('matrix:server:reportObjectTouch', function(inventoryId, slot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(inventoryId) ~= 'string' or type(slot) ~= 'number' then return end
    Matrix.Forensics.StampTouch({ kind = 'player', source = src }, inventoryId, slot)
end)

-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ (herkese açık test grubu, restricted=false)
-- Q_kovan = 1.0 - (weaponWear*0.3) - (cortisol*0.2), sonra silah canıyla
-- (durability) çarpılır; fingerprint = 1.0 - (cortisol*0.4). Bu komutlar
-- gerçek bir ateşleme olayı beklemeden formülleri manuel gözlemlemek/
-- manipüle etmek içindir. Hiçbir komut formüllerin KENDİSİNİ değiştirmez.
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', msg } })
    else
        print(('[MATRIX:FORENSICS:CONSOLE] %s'):format(msg))
    end
end

-- /forensicdump [ballisticId] - bir silahın kalıcı SQL kaydını ve ona bağlı
-- en yeni 10 kanıt satırını (matrix_forensic_evidence, asla silinmez) döker.
RegisterCommand('forensicdump', function(src, args)
    local ballisticId = args[1]
    if type(ballisticId) ~= 'string' then Reply(src, 'Kullanim: /forensicdump [ballisticId]'); return end

    local weaponRows = MySQL.query.await('SELECT * FROM matrix_ballistic_weapons WHERE ballistic_id = ?', { ballisticId }) or {}
    local weapon = weaponRows[1]
    if not weapon then Reply(src, 'Balistik ID bulunamadı.'); return end

    Reply(src, ('Silah: %s | Seri:%s | Aşınma:%.3f | Mühür:%s | Kesinlik:%s'):format(
        weapon.ballistic_id, weapon.weapon_serial, weapon.wear_level,
        tostring(weapon.sealed_as_crime_weapon == 1), tostring(weapon.seal_certainty)))

    local evidenceRows = MySQL.query.await(
        'SELECT * FROM matrix_forensic_evidence WHERE ballistic_id = ? ORDER BY id DESC LIMIT 10', { ballisticId }
    ) or {}
    Reply(src, ('--- %d kanıt satırı (en yeni 10) ---'):format(#evidenceRows))
    for _, ev in ipairs(evidenceRows) do
        Reply(src, ('  #%d [%s] Striasyon:%.3f Eşleşme:%.3f Mühür:%s'):format(
            ev.id, ev.evidence_type, ev.striation_quality, ev.match_certainty, tostring(ev.sealed_as_crime_weapon == 1)))
    end
end, false)

-- /forensicrapor [evidenceId] - kalıcı kanıt satırından ASCII "Adli Kriminal
-- Raporu"nu yeniden üretip konsola basar (BuildForensicReport'un gerçek DB
-- verisiyle tekrar üretilebilir/deterministik olduğunu doğrular).
RegisterCommand('forensicrapor', function(src, args)
    local evidenceId = tonumber(args[1])
    if not evidenceId then Reply(src, 'Kullanim: /forensicrapor [evidenceId]'); return end

    local rows = MySQL.query.await('SELECT * FROM matrix_forensic_evidence WHERE id = ?', { evidenceId })
    local evidence = rows and rows[1]
    if not evidence then Reply(src, 'Kanıt bulunamadı.'); return end

    local report = Matrix.Forensics.BuildForensicReport({
        ballistic_id         = evidence.ballistic_id,
        evidence_type        = evidence.evidence_type,
        striation_quality    = evidence.striation_quality,
        fingerprint_id       = evidence.fingerprint_id,
        fingerprint_quality  = evidence.fingerprint_quality,
        match_certainty      = evidence.match_certainty,
        sealed               = evidence.sealed_as_crime_weapon == 1
    })
    print(report)
    Reply(src, ('Kanıt #%d raporu konsola basıldı.'):format(evidenceId))
end, false)

-- /asinmaayarla [seri] [0.0-1.0] - weapon_wear'ı gerçek bir ateşleme
-- döngüsünü (RegisterOrGetBallisticId) beklemeden doğrudan yazar; Q_kovan
-- formülünün weaponWear ekseni boyunca davranışını test etmek içindir.
RegisterCommand('asinmaayarla', function(src, args)
    local serial = args[1]
    local wear = Matrix.Clamp(tonumber(args[2]) or 0.0, 0.0, 1.0)
    if type(serial) ~= 'string' then Reply(src, 'Kullanim: /asinmaayarla [seri] [0.0-1.0]'); return end

    local cached = BallisticCache[serial]
    if not cached then Reply(src, 'Bu seri henüz balistik olarak kayıtlı değil (önce ateşlenmeli).'); return end

    cached.wear_level = wear
    MySQL.prepare('UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE weapon_serial = ?', { wear, serial })
    Reply(src, ('%s aşınması %.3f olarak ayarlandı.'):format(serial, wear))
end, false)

-- ★ KATMAN 5 debug komutu: /silahasindir [slot] [miktar 0-100] - çağıran
-- oyuncunun KENDİ envanterindeki [slot]'taki silahın ox_inventory durability
-- metadata'sını doğrudan yazar (gerçek bir çatışma/aşınma döngüsü beklemeden
-- Gauss mutasyon formülünü test etmek içindir). Bir sonraki ateşlemede
-- OnWeaponFired bu değeri okuyup Q_kovan'ı mutasyona uğratır.
RegisterCommand('silahasindir', function(src, args)
    local slot = tonumber(args[1])
    local amount = Matrix.Clamp(tonumber(args[2]) or 100.0, 0.0, 100.0)
    if type(src) ~= 'number' or src <= 0 or not slot then
        Reply(src, 'Kullanim: /silahasindir [slot] [miktar 0-100]'); return
    end

    -- ox_inventory: oyuncu envanteri event köprüsündeki diğer inventoryId'ler
    -- gibi string olarak ele alınır (bkz. reportWeaponDischarge guard'ı).
    local inventoryId = tostring(src)
    Matrix.Inventory.MergeMetadata(inventoryId, slot, { durability = amount })

    Reply(src, ('Slot #%d silah canı %.1f olarak ayarlandı (Jam_Chance:%.3f). Bir sonraki ateşlemede Q_kovan mutasyona uğrayacak.'):format(
        slot, amount, Matrix.Forensics.ComputeJamChance(amount / 100.0)))
end, false)
