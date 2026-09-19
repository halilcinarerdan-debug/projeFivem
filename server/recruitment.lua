-- =====================================================================
-- MATRIX RECRUITMENT / recruitment.lua
-- Batch UPDATE, async insert, sıfır await ticker.
-- =====================================================================

Matrix.Recruitment = Matrix.Recruitment or {}
Matrix.Candidates  = Matrix.Candidates  or {}
Matrix.Sessions    = Matrix.Sessions    or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table               = tonumber, table
local math_max                      = math.max

local nextCandidateId = 1
local nextSessionId   = 1

local BIO_FIELDS = {
    'fear_factor', 'resilience', 'snitch_tendency',
    'economic_pressure', 'cognitive_shifter', 'skill_chemistry'
}

-- =====================================================================
-- TRAIT DERIVATION
-- =====================================================================
local function DeriveTraitsFromCustomer(stats)
    if type(stats) ~= 'table' then stats = {} end
    return {
        fear_factor       = Matrix.Clamp((stats.police_encounters_nearby or 0) * 0.10, 0.0, 1.0),
        resilience        = Matrix.Clamp(0.30 + ((stats.completed_deals or 0) * 0.02), 0.0, 1.0),
        snitch_tendency   = Matrix.Clamp((stats.times_reported or 0) * 0.15, 0.0, 1.0),
        economic_pressure = Matrix.Clamp((stats.failed_payments or 0) * 0.12, 0.0, 1.0),
        cognitive_shifter = Matrix.Clamp(0.20 + ((stats.completed_deals or 0) * 0.015), 0.0, 1.0),
        skill_chemistry   = Matrix.Clamp((stats.chemistry_hints or 0) * 0.10, 0.0, 1.0)
    }
end

-- =====================================================================
-- SCAN CUSTOMER POOL (ticker → await YOK, batch)
-- =====================================================================
function Matrix.Recruitment.ScanCustomerPool()
    local rows = MySQL.query.await(
        'SELECT * FROM matrix_customer_pool WHERE promoted_to_candidate = 0 LIMIT 200',
        {}
    ) or {}
    if #rows == 0 then return 0 end

    local momentum  = Matrix.Bureau.GetPropagandaMomentum()
    local threshold = Config.Recruitment.BaseEligibilityThreshold / (1.0 + momentum)

    local promotedCids = {}
    local promotedCount = 0

    for _, row in ipairs(rows) do
        local traits = DeriveTraitsFromCustomer(row)
        local score  = traits.resilience + traits.cognitive_shifter + (1.0 - traits.snitch_tendency)

        if score >= threshold then
            local cid = nextCandidateId
            nextCandidateId = cid + 1

            Matrix.Candidates[cid] = {
                id            = cid,
                citizenid     = row.citizenid,
                name          = row.name or ('Aday-%d'):format(cid),
                psychology    = traits,
                addiction_level = tonumber(row.addiction_level) or 0.0,
                revealed_fields = {}
            }
            promotedCids[#promotedCids + 1] = row.citizenid
            promotedCount = promotedCount + 1
            Matrix.Log('RECRUITMENT', 'Aday #%d havuzdan çekildi (skor %.2f / eşik %.2f)',
                cid, score, threshold)
        end
    end

    -- Batch UPDATE (tek sorgu, N satır)
    if #promotedCids > 0 then
        local placeholders = {}
        for i = 1, #promotedCids do placeholders[i] = '?' end
        local q = ('UPDATE matrix_customer_pool SET promoted_to_candidate = 1 WHERE citizenid IN (%s)')
                  :format(table.concat(placeholders, ','))
        MySQL.prepare(q, promotedCids)
    end

    return promotedCount
end

-- =====================================================================
-- INTERROGATION
-- =====================================================================
function Matrix.Recruitment.BeginInterrogation(candidateId, interrogatorSource)
    candidateId = tonumber(candidateId)
    if not candidateId then return nil end
    local candidate = Matrix.Candidates[candidateId]
    if not candidate then return nil end

    local sid = nextSessionId
    nextSessionId = sid + 1

    Matrix.Sessions[sid] = {
        id                  = sid,
        candidate_id        = candidateId,
        interrogator_source = interrogatorSource,
        cumulative_pressure = 0.0,
        lies_told           = 0,
        confessions         = 0,
        revealed            = {}
    }

    Matrix.Log('RECRUITMENT', 'Sorgu #%d başlatıldı -> Aday #%d (%s)', sid, candidateId, candidate.name)
    return sid
end

local function NextUnrevealedField(session)
    for _, field in ipairs(BIO_FIELDS) do
        if not session.revealed[field] then return field end
    end
    return nil
end

function Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
    sessionId = tonumber(sessionId)
    if not sessionId then return nil end
    local session = Matrix.Sessions[sessionId]
    if not session then return nil end

    local candidate = Matrix.Candidates[session.candidate_id]
    if not candidate then return nil end

    pressureAmount = tonumber(pressureAmount) or 0.0
    if pressureAmount ~= pressureAmount or pressureAmount < 0.0 then pressureAmount = 0.0 end
    if pressureAmount > 100.0 then pressureAmount = 100.0 end

    session.cumulative_pressure = session.cumulative_pressure + pressureAmount

    local panic = Matrix.Clamp(
        (session.cumulative_pressure * candidate.psychology.fear_factor)
            - (candidate.psychology.resilience * Config.Recruitment.ResilienceDamping),
        0.0, 1.0
    )

    local field = NextUnrevealedField(session)
    if not field then
        return { panic_index = panic, outcome = 'exhausted' }
    end

    if panic >= Config.Recruitment.ConfessionThreshold then
        session.revealed[field] = candidate.psychology[field]
        session.confessions = session.confessions + 1
        Matrix.Log('RECRUITMENT', '[İTİRAF] Sorgu #%d -> %s = %.2f',
            sessionId, field, candidate.psychology[field])
        return { panic_index = panic, outcome = 'confession', field = field, value = candidate.psychology[field] }
    elseif panic >= Config.Recruitment.LieThreshold then
        local trueValue = candidate.psychology[field]
        local fakeValue = Matrix.Clamp(trueValue + ((trueValue >= 0.5) and -0.4 or 0.4), 0.0, 1.0)
        session.lies_told = session.lies_told + 1
        Matrix.Log('RECRUITMENT', '[YALAN TESPİTİ] Sorgu #%d -> %s alanında sapma tespit edildi.', sessionId, field)
        return { panic_index = panic, outcome = 'lie', field = field, value = fakeValue }
    else
        Matrix.Log('RECRUITMENT', '[SESSİZLİK] Sorgu #%d -> Aday baskıya direniyor (%.2f)', sessionId, panic)
        return { panic_index = panic, outcome = 'silence' }
    end
end

-- =====================================================================
-- PROMOTE
-- =====================================================================
function Matrix.Recruitment.Promote(candidate)
    local bot = Matrix.CreateBotRecord({
        name              = candidate.name,
        role              = 'dealer',
        fear_factor       = candidate.psychology.fear_factor,
        resilience        = candidate.psychology.resilience,
        snitch_tendency   = candidate.psychology.snitch_tendency,
        economic_pressure = candidate.psychology.economic_pressure,
        cognitive_shifter = candidate.psychology.cognitive_shifter,
        skill_chemistry   = candidate.psychology.skill_chemistry,
        addiction_level   = candidate.addiction_level
    })

    Matrix.Log('RECRUITMENT', 'Aday #%d bot matrisine eklendi -> Bot #%d', candidate.id, bot.id)
    return bot
end

-- =====================================================================
-- EVALUATE OUTCOME
-- =====================================================================
function Matrix.Recruitment.EvaluateOutcome(sessionId)
    sessionId = tonumber(sessionId)
    if not sessionId then return nil end
    local session = Matrix.Sessions[sessionId]
    if not session then return nil end

    local candidate = Matrix.Candidates[session.candidate_id]
    if not candidate then return nil end

    local outcome
    if session.lies_told > Config.Recruitment.MaxToleratedLies then
        outcome = 'burned'
    elseif session.confessions >= Config.Recruitment.MinConfessionsToPromote
        and candidate.psychology.snitch_tendency <= Config.Recruitment.SafeSnitchTendencyCeiling
        and candidate.psychology.resilience >= Config.Recruitment.MinOperationalResilience then
        outcome = 'recruited'
    else
        outcome = 'released'
    end

    -- Async insert: sunucuyu bloklamaz
    MySQL.prepare([[
        INSERT INTO matrix_recruitment_sessions (
            candidate_citizenid, fear_factor, resilience, lies_told, confessions, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, NOW())
    ]], {
        candidate.citizenid, candidate.psychology.fear_factor, candidate.psychology.resilience,
        session.lies_told, session.confessions, outcome
    })

    if outcome == 'recruited' then
        Matrix.Recruitment.Promote(candidate)
    end

    Matrix.Candidates[session.candidate_id] = nil
    Matrix.Sessions[sessionId] = nil

    Matrix.Log('RECRUITMENT', 'Sorgu #%d sonuçlandı: %s', sessionId, outcome)
    return outcome
end

-- =====================================================================
-- EVENT BRIDGE (guard'lı)
-- =====================================================================
RegisterNetEvent('matrix:server:beginInterrogation', function(candidateId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    candidateId = tonumber(candidateId)
    if not candidateId then return end
    Matrix.Recruitment.BeginInterrogation(candidateId, src)
end)

RegisterNetEvent('matrix:server:applyInterrogationPressure', function(sessionId, pressureAmount)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    sessionId = tonumber(sessionId)
    if not sessionId then return end
    Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
end)

RegisterNetEvent('matrix:server:evaluateInterrogation', function(sessionId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    sessionId = tonumber(sessionId)
    if not sessionId then return end
    Matrix.Recruitment.EvaluateOutcome(sessionId)
end)
