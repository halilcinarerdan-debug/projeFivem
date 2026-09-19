Matrix.Forensics = {}

local function GetActorDnaId(actor)
    if not actor then return 'UNKNOWN' end
    return actor.dna_id
end

local function GetActorCortisol(actor)
    if not actor or not actor.biology then return 0.0 end
    return actor.biology.cortisol_level or 0.0
end

function Matrix.Forensics.ComputeFingerprintQuality(actor)
    local cortisol = GetActorCortisol(actor)
    return Matrix.Clamp(1.0 - (cortisol * Config.Forensics.FingerprintQualityCortisolWeight), 0.0, 1.0)
end

function Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    local existing = MySQL.query.await('SELECT ballistic_id FROM matrix_ballistic_weapons WHERE weapon_serial = ?', { weaponSerial })

    if existing[1] then
        MySQL.query.await('UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE weapon_serial = ?', { weaponWear, weaponSerial })
        return existing[1].ballistic_id
    end

    local ballisticId = ('BAL-%s-%06X'):format(weaponSerial:sub(-4), (GetGameTimer() + #weaponSerial) % 0xFFFFFF)

    MySQL.query.await([[
        INSERT INTO matrix_ballistic_weapons (ballistic_id, weapon_serial, wear_level, sealed_as_crime_weapon, first_registered)
        VALUES (?, ?, ?, 0, NOW())
    ]], { ballisticId, weaponSerial, weaponWear })

    Matrix.Log('FORENSICS', 'Yeni balistik yiv-set imzasi kaydedildi: %s (Seri: %s)', ballisticId, weaponSerial)
    return ballisticId
end

function Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, casingInventoryId, casingSlot)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end

    local casingMeta = Matrix.Inventory.GetSlotMetadata(casingInventoryId, casingSlot)
    local durability = tonumber(casingMeta.durability) or 100.0
    local weaponWear = Matrix.Clamp(1.0 - (durability / 100.0), 0.0, 1.0)

    local ballisticId = Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)

    local qKovan = Matrix.Clamp(
        1.0 - (weaponWear * Config.Forensics.CasingWearWeight) - (GetActorCortisol(actor) * Config.Forensics.CasingCortisolWeight),
        0.0, 1.0
    )
    local fingerprintQuality = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dnaId = GetActorDnaId(actor)

    Matrix.Inventory.MergeMetadata(casingInventoryId, casingSlot, {
        ballistic_id = ballisticId,
        striation_quality = qKovan,
        fingerprint_id = dnaId,
        fingerprint_quality = fingerprintQuality
    })

    local matchCertainty = qKovan * Config.BallisticStriationPrecision
    local sealed = matchCertainty > Config.Forensics.MatchCertaintyThreshold

    local actorCoords = actor.state and actor.state.coords

    local evidenceId = MySQL.insert.await([[
        INSERT INTO matrix_forensic_evidence (
            ballistic_id, evidence_type, striation_quality, fingerprint_id, fingerprint_quality,
            match_certainty, sealed_as_crime_weapon, coords_x, coords_y, coords_z, created_at
        ) VALUES (?, 'casing', ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        ballisticId, qKovan, dnaId, fingerprintQuality, matchCertainty, sealed and 1 or 0,
        actorCoords and actorCoords.x or 0.0,
        actorCoords and actorCoords.y or 0.0,
        actorCoords and actorCoords.z or 0.0
    })

    if sealed then
        MySQL.query.await('UPDATE matrix_ballistic_weapons SET sealed_as_crime_weapon = 1, seal_certainty = ? WHERE ballistic_id = ?', {
            matchCertainty, ballisticId
        })
        Matrix.Log('FORENSICS', '[MÜHÜRLENDI] %s "Suç Aleti" olarak sınıflandırıldı. Eşleşme: %.4f', ballisticId, matchCertainty)
    end

    return evidenceId, matchCertainty, sealed
end

function Matrix.Forensics.StampTouch(actorRef, inventoryId, slot)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end

    local fingerprintQuality = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dnaId = GetActorDnaId(actor)

    Matrix.Inventory.MergeMetadata(inventoryId, slot, {
        fingerprint_id = dnaId,
        fingerprint_quality = fingerprintQuality
    })

    MySQL.query.await([[
        INSERT INTO matrix_touch_log (fingerprint_id, fingerprint_quality, inventory_id, slot_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { dnaId, fingerprintQuality, tostring(inventoryId), slot })

    return fingerprintQuality
end

function Matrix.Forensics.AnalyzeEvidence(evidenceId)
    local rows = MySQL.query.await('SELECT * FROM matrix_forensic_evidence WHERE id = ?', { evidenceId })
    local evidence = rows[1]
    if not evidence then return nil end

    local matchCertainty = evidence.striation_quality * Config.BallisticStriationPrecision
    local sealed = matchCertainty > Config.Forensics.MatchCertaintyThreshold

    MySQL.query.await('UPDATE matrix_forensic_evidence SET match_certainty = ?, sealed_as_crime_weapon = ? WHERE id = ?', {
        matchCertainty, sealed and 1 or 0, evidenceId
    })

    if sealed then
        MySQL.query.await('UPDATE matrix_ballistic_weapons SET sealed_as_crime_weapon = 1, seal_certainty = ? WHERE ballistic_id = ?', {
            matchCertainty, evidence.ballistic_id
        })
        Matrix.Log('FORENSICS', 'Laboratuvar analizi: Kanıt #%d -> %s mühürlendi (%.4f)', evidenceId, evidence.ballistic_id, matchCertainty)
    else
        Matrix.Log('FORENSICS', 'Laboratuvar analizi: Kanıt #%d yetersiz eşleşme (%.4f)', evidenceId, matchCertainty)
    end

    return matchCertainty, sealed
end

RegisterNetEvent('matrix:server:reportWeaponDischarge', function(weaponSerial, casingInventoryId, casingSlot)
    local src = source
    Matrix.Forensics.OnWeaponFired({ kind = 'player', source = src }, weaponSerial, casingInventoryId, casingSlot)
end)

RegisterNetEvent('matrix:server:reportObjectTouch', function(inventoryId, slot)
    local src = source
    Matrix.Forensics.StampTouch({ kind = 'player', source = src }, inventoryId, slot)
end)
