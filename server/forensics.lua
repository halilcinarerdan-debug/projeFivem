-- =====================================================================
-- MATRIX FORENSICS / forensics.lua
-- In-memory balistik cache, lokal ID allocator, async insert.
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

function Matrix.Forensics.ComputeFingerprintQuality(actor)
    local cortisol = GetActorCortisol(actor)
    return Matrix.Clamp(1.0 - (cortisol * Config.Forensics.FingerprintQualityCortisolWeight), 0.0, 1.0)
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
-- =====================================================================
function Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, evidenceType)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end

    weaponWear   = Matrix.Clamp(tonumber(weaponWear) or 0.0, 0.0, 1.0)
    evidenceType = evidenceType or 'casing'

    local ballisticId = Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    if not ballisticId then return nil end

    local cortisol = GetActorCortisol(actor)
    local qKovan = Matrix.Clamp(
        1.0 - (weaponWear * Config.Forensics.CasingWearWeight)
            - (cortisol   * Config.Forensics.CasingCortisolWeight),
        0.0, 1.0
    )

    local fingerprintQuality = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dnaId              = GetActorDnaId(actor)
    local matchCertainty     = Matrix.Clamp(qKovan * Config.BallisticStriationPrecision, 0.0, 1.0)
    local sealed             = matchCertainty > Config.Forensics.MatchCertaintyThreshold

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
        evidence_id       = evidenceId or -1,
        ballistic_id      = ballisticId,
        dna_id            = dnaId,
        weapon_wear       = weaponWear,
        striation_quality = qKovan,
        fingerprint_quality = fingerprintQuality,
        match_certainty   = matchCertainty,
        sealed            = sealed
    }
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
        ReportLine('MUHUR', data.sealed and 'MUHURLENDI' or 'MUHURLENMEDI'),
        REPORT_DIVIDER,
        ReportLine('KAYIT', os.date('%Y-%m-%d %H:%M:%S')),
        REPORT_BORDER
    }
    return table.concat(lines, '\n')
end

function Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    if not casingInventoryId or type(casingSlot) ~= 'number' then return nil end

    local casingMeta = Matrix.Inventory.GetSlotMetadata(casingInventoryId, casingSlot)
    local durability = tonumber(casingMeta.durability) or 100.0
    durability = Matrix.Clamp(durability, 0.0, 100.0)
    local weaponWear = Matrix.Clamp(1.0 - (durability / 100.0), 0.0, 1.0)

    local result = Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, 'casing')
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
            ballistic_id = result.ballistic_id,
            weapon_wear  = result.weapon_wear,
            description  = Matrix.Forensics.BuildForensicReport({
                ballistic_id     = result.ballistic_id,
                evidence_type     = 'weapon',
                striation_quality = result.striation_quality,
                fingerprint_id     = result.dna_id,
                fingerprint_quality = result.fingerprint_quality,
                match_certainty   = result.match_certainty,
                sealed             = result.sealed
            })
        })
    end

    return result.evidence_id, result.match_certainty, result.sealed
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
