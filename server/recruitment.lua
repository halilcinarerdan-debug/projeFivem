Matrix.Recruitment = {}
Matrix.Candidates = {}
Matrix.Sessions = {}

local nextCandidateId = 1
local nextSessionId = 1

local BIO_FIELDS = { 'fear_factor', 'resilience', 'snitch_tendency', 'economic_pressure', 'cognitive_shifter', 'skill_chemistry' }

local function DeriveTraitsFromCustomer(stats)
    return {
        fear_factor = Matrix.Clamp((stats.police_encounters_nearby or 0) * 0.10, 0.0, 1.0),
        resilience = Matrix.Clamp(0.30 + ((stats.completed_deals or 0) * 0.02), 0.0, 1.0),
        snitch_tendency = Matrix.Clamp((stats.times_reported or 0) * 0.15, 0.0, 1.0),
        economic_pressure = Matrix.Clamp((stats.failed_payments or 0) * 0.12, 0.0, 1.0),
        cognitive_shifter = Matrix.Clamp(0.20 + ((stats.completed_deals or 0) * 0.015), 0.0, 1.0),
        skill_chemistry = Matrix.Clamp((stats.chemistry_hints or 0) * 0.10, 0.0, 1.0)
    }
end

function Matrix.Recruitment.ScanCustomerPool()
    local rows = MySQL.query.await('SELECT * FROM matrix_customer_pool WHERE promoted_to_candidate = 0', {})
    local momentum = Matrix.Bureau.GetPropagandaMomentum()
    local threshold = Config.Recruitment.BaseEligibilityThreshold / (1.0 + momentum)

    for _, row in ipairs(rows) do
        local traits = DeriveTraitsFromCustomer(row)
        local recruitabilityScore = traits.resilience + traits.cognitive_shifter + (1.0 - traits.snitch_tendency)

        if recruitabilityScore >= threshold then
            local candidateId = nextCandidateId
            nextCandidateId = nextCandidateId + 1

            Matrix.Candidates[candidateId] = {
                id = candidateId,
                citizenid = row.citizenid,
                name = row.name,
                psychology = traits,
                addiction_level = row.addiction_level or 0.0,
                revealed_fields = {}
            }

            MySQL.query.await('UPDATE matrix_customer_pool SET promoted_to_candidate = 1 WHERE citizenid = ?', { row.citizenid })
            Matrix.Log('RECRUITMENT', 'Aday #%d havuzdan çekildi (skor %.2f / eşik %.2f)', candidateId, recruitabilityScore, threshold)
        end
    end
end

function Matrix.Recruitment.BeginInterrogation(candidateId, interrogatorSource)
    local candidate = Matrix.Candidates[candidateId]
    if not candidate then return nil end

    local sessionId = nextSessionId
    nextSessionId = nextSessionId + 1

    Matrix.Sessions[sessionId] = {
        id = sessionId,
        candidate_id = candidateId,
        interrogator_source = interrogatorSource,
        cumulative_pressure = 0.0,
        lies_told = 0,
        confessions = 0,
        revealed = {}
    }

    Matrix.Log('RECRUITMENT', 'Sorgu #%d başlatıldı -> Aday #%d (%s)', sessionId, candidateId, candidate.name)
    return sessionId
end

local function NextUnrevealedField(session)
    for _, field in ipairs(BIO_FIELDS) do
        if not session.revealed[field] then
            return field
        end
    end
    return nil
end

function Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
    local session = Matrix.Sessions[sessionId]
    if not session then return nil end

    local candidate = Matrix.Candidates[session.candidate_id]
    if not candidate then return nil end

    session.cumulative_pressure = session.cumulative_pressure + pressureAmount

    local panicIndex = Matrix.Clamp(
        (session.cumulative_pressure * candidate.psychology.fear_factor) -
        (candidate.psychology.resilience * Config.Recruitment.ResilienceDamping),
        0.0, 1.0
    )

    local field = NextUnrevealedField(session)
    if not field then
        return { panic_index = panicIndex, outcome = 'exhausted' }
    end

    if panicIndex >= Config.Recruitment.ConfessionThreshold then
        session.revealed[field] = candidate.psychology[field]
        session.confessions = session.confessions + 1
        Matrix.Log('RECRUITMENT', '[İTİRAF] Sorgu #%d -> %s = %.2f', sessionId, field, candidate.psychology[field])
        return { panic_index = panicIndex, outcome = 'confession', field = field, value = candidate.psychology[field] }
    elseif panicIndex >= Config.Recruitment.LieThreshold then
        local trueValue = candidate.psychology[field]
        local fakeValue = Matrix.Clamp(trueValue + ((trueValue >= 0.5) and -0.4 or 0.4), 0.0, 1.0)
        session.lies_told = session.lies_told + 1
        Matrix.Log('RECRUITMENT', '[YALAN TESPİTİ] Sorgu #%d -> %s alanında sapma tespit edildi.', sessionId, field)
        return { panic_index = panicIndex, outcome = 'lie', field = field, value = fakeValue }
    else
        Matrix.Log('RECRUITMENT', '[SESSİZLİK] Sorgu #%d -> Aday baskıya direniyor (%.2f)', sessionId, panicIndex)
        return { panic_index = panicIndex, outcome = 'silence' }
    end
end

function Matrix.Recruitment.Promote(candidate)
    local bot = Matrix.CreateBotRecord({
        name = candidate.name,
        role = 'dealer',
        fear_factor = candidate.psychology.fear_factor,
        resilience = candidate.psychology.resilience,
        snitch_tendency = candidate.psychology.snitch_tendency,
        economic_pressure = candidate.psychology.economic_pressure,
        cognitive_shifter = candidate.psychology.cognitive_shifter,
        skill_chemistry = candidate.psychology.skill_chemistry,
        addiction_level = candidate.addiction_level
    })

    Matrix.Log('RECRUITMENT', 'Aday #%d bot matrisine eklendi -> Bot #%d', candidate.id, bot.id)
    return bot
end

function Matrix.Recruitment.EvaluateOutcome(sessionId)
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

    MySQL.query.await([[
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

RegisterNetEvent('matrix:server:beginInterrogation', function(candidateId)
    local src = source
    Matrix.Recruitment.BeginInterrogation(candidateId, src)
end)

RegisterNetEvent('matrix:server:applyInterrogationPressure', function(sessionId, pressureAmount)
    Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
end)

RegisterNetEvent('matrix:server:evaluateInterrogation', function(sessionId)
    Matrix.Recruitment.EvaluateOutcome(sessionId)
end)
