-- =====================================================================
-- MATRIX RECRUITMENT / recruitment.lua
-- Batch UPDATE, async insert, sıfır await ticker.
-- =====================================================================

Matrix.Recruitment = Matrix.Recruitment or {}
Matrix.Candidates  = Matrix.Candidates  or {}
Matrix.Sessions    = Matrix.Sessions    or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table               = tonumber, table
local math_max, math_floor          = math.max, math.floor

local nextCandidateId = 1
local nextSessionId   = 1

local BIO_FIELDS = {
    'fear_factor', 'resilience', 'snitch_tendency',
    'economic_pressure', 'cognitive_shifter', 'skill_chemistry'
}

-- =====================================================================
-- ASCII SES DALGASI (karanlık mülakat terminali)
-- =====================================================================
local function BuildAsciiWaveform(intensity)
    intensity = Matrix.Clamp(tonumber(intensity) or 0.0, 0.0, 1.0)
    local width = Config.Recruitment.WaveformWidth
    local filled = math_floor((intensity * width) + 0.5)
    return '[' .. ('|'):rep(filled) .. ('.'):rep(width - filled) .. ']'
end

-- =====================================================================
-- SORGU ÖZNESİ ÇÖZÜMLEMESİ: /sorgu hem havuzdan çekilmiş bir adayı (candidate)
-- hem de zaten işe alınmış bir botu (örn. yakalanma sonrası sadakat testi)
-- interrogate edebilsin diye tekilleştirilmiş bir görünüm sağlar. İkisi de
-- aynı psychology şemasını (fear_factor/resilience/...) paylaşır.
-- =====================================================================
local function ResolveInterrogationSubject(kind, id)
    if kind == 'bot' then
        local bot = Matrix.Bots[id]
        if not bot then return nil end
        return { kind = 'bot', id = id, name = bot.name, psychology = bot.psychology, ref_key = bot.dna_id }
    end

    local candidate = Matrix.Candidates[id]
    if not candidate then return nil end
    return { kind = 'candidate', id = id, name = candidate.name, psychology = candidate.psychology, ref_key = candidate.citizenid }
end

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

        -- Sokak Kulakları: siber yoğunluk (momentum) yükseldiğinde, ihbar
        -- geçmişi olan müşteriler potansiyel köstebek olarak fısıldanır.
        if momentum > Config.Recruitment.StreetWhisperMomentumThreshold and (row.times_reported or 0) > 0 then
            Matrix.Log('RECRUITMENT', '[SOKAK KULAKLARI] "%s" hakkında fısıltılar var: %d kez ihbar geçmiş.',
                row.name or row.citizenid, row.times_reported)
        end

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
-- subjectRef: eski davranışla uyumlu düz bir candidateId (number) OLABİLİR,
-- ya da { kind = 'candidate'|'bot', id = ... } şeklinde açık bir referans.
function Matrix.Recruitment.BeginInterrogation(subjectRef, interrogatorSource)
    local kind, id
    if type(subjectRef) == 'table' then
        kind, id = subjectRef.kind, tonumber(subjectRef.id)
    else
        kind, id = 'candidate', tonumber(subjectRef)
    end
    if not id then return nil end

    local subject = ResolveInterrogationSubject(kind, id)
    if not subject then return nil end

    local sid = nextSessionId
    nextSessionId = sid + 1

    Matrix.Sessions[sid] = {
        id                  = sid,
        subject_kind        = subject.kind,
        subject_id          = subject.id,
        interrogator_source = interrogatorSource,
        cumulative_pressure = 0.0,
        lies_told           = 0,
        confessions         = 0,
        revealed            = {}
    }

    Matrix.Log('RECRUITMENT', 'Sorgu #%d başlatıldı -> %s #%s (%s)', sid, subject.kind, tostring(subject.id), subject.name)
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

    local subject = ResolveInterrogationSubject(session.subject_kind, session.subject_id)
    if not subject then return nil end
    local psychology = subject.psychology

    pressureAmount = tonumber(pressureAmount) or 0.0
    if pressureAmount ~= pressureAmount or pressureAmount < 0.0 then pressureAmount = 0.0 end
    if pressureAmount > 100.0 then pressureAmount = 100.0 end

    session.cumulative_pressure = session.cumulative_pressure + pressureAmount

    local panic = Matrix.Clamp(
        (session.cumulative_pressure * psychology.fear_factor)
            - (psychology.resilience * Config.Recruitment.ResilienceDamping),
        0.0, 1.0
    )
    local waveform = BuildAsciiWaveform(panic)

    local field = NextUnrevealedField(session)
    if not field then
        Matrix.Log('RECRUITMENT', 'Sorgu #%d tükendi. Panik: %s', sessionId, waveform)
        return { panic_index = panic, outcome = 'exhausted', waveform = waveform }
    end

    if panic >= Config.Recruitment.ConfessionThreshold then
        session.revealed[field] = psychology[field]
        session.confessions = session.confessions + 1
        Matrix.Log('RECRUITMENT', '[İTİRAF] Sorgu #%d -> %s = %.2f | Panik: %s',
            sessionId, field, psychology[field], waveform)
        return { panic_index = panic, outcome = 'confession', field = field, value = psychology[field], waveform = waveform }
    elseif panic >= Config.Recruitment.LieThreshold then
        local trueValue = psychology[field]
        local fakeValue = Matrix.Clamp(trueValue + ((trueValue >= 0.5) and -0.4 or 0.4), 0.0, 1.0)
        session.lies_told = session.lies_told + 1

        -- Yalan söylerken telsiz ses frekans sapması: lies_told'a bağlı
        -- deterministik bozulma (RNG yok) - panikten daha "kısık/parazitli".
        local deviation = Matrix.Clamp(panic - (Config.Recruitment.LieWaveformDeviationPerLie * session.lies_told), 0.0, 1.0)
        local deviationWave = BuildAsciiWaveform(deviation)

        Matrix.Log('RECRUITMENT', '[YALAN TESPİTİ] Sorgu #%d -> %s alanında sapma tespit edildi.\n  SES  : %s\n  SAPMA: %s',
            sessionId, field, waveform, deviationWave)
        return { panic_index = panic, outcome = 'lie', field = field, value = fakeValue, waveform = waveform, deviation_waveform = deviationWave }
    else
        Matrix.Log('RECRUITMENT', '[SESSİZLİK] Sorgu #%d -> Aday baskıya direniyor. Panik: %s', sessionId, waveform)
        return { panic_index = panic, outcome = 'silence', waveform = waveform }
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

    local subject = ResolveInterrogationSubject(session.subject_kind, session.subject_id)
    if not subject then return nil end
    local psychology = subject.psychology

    local outcome
    if session.lies_told > Config.Recruitment.MaxToleratedLies then
        outcome = 'burned'
    elseif session.confessions >= Config.Recruitment.MinConfessionsToPromote
        and psychology.snitch_tendency <= Config.Recruitment.SafeSnitchTendencyCeiling
        and psychology.resilience >= Config.Recruitment.MinOperationalResilience then
        -- Zaten bot olan bir özne için "recruited" anlamsız: sadakat testi geçti demektir.
        outcome = (subject.kind == 'candidate') and 'recruited' or 'released'
    else
        outcome = 'released'
    end

    -- Async insert: sunucuyu bloklamaz. Özne bir bot ise ref_key onun dna_id'sidir
    -- (candidate_citizenid kolonu her iki özne türü için de kimlik alanı olarak kullanılır).
    MySQL.prepare([[
        INSERT INTO matrix_recruitment_sessions (
            candidate_citizenid, fear_factor, resilience, lies_told, confessions, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, NOW())
    ]], {
        subject.ref_key, psychology.fear_factor, psychology.resilience,
        session.lies_told, session.confessions, outcome
    })

    if outcome == 'recruited' and subject.kind == 'candidate' then
        Matrix.Recruitment.Promote(Matrix.Candidates[subject.id])
    end

    if subject.kind == 'candidate' then
        Matrix.Candidates[subject.id] = nil
    end
    Matrix.Sessions[sessionId] = nil

    Matrix.Log('RECRUITMENT', 'Sorgu #%d (%s #%s) sonuçlandı: %s', sessionId, subject.kind, tostring(subject.id), outcome)
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

-- =====================================================================
-- KOMUT: /sorgu [id] [aday|bot] - ASCII ses-dalgalı karanlık mülakat terminali
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[SORGU]', msg } })
    else
        print(('[MATRIX:RECRUITMENT:CONSOLE] %s'):format(msg))
    end
end

RegisterCommand('sorgu', function(src, args)
    local id = tonumber(args[1])
    local kind = (args[2] == 'bot') and 'bot' or 'candidate'

    if not id then
        Reply(src, 'Kullanim: /sorgu [id] [aday|bot]'); return
    end

    local sid = Matrix.Recruitment.BeginInterrogation({ kind = kind, id = id }, src)
    if not sid then
        Reply(src, ('%s #%d bulunamadı.'):format(kind, id)); return
    end

    local result = Matrix.Recruitment.ApplyPressure(sid, 25.0)
    if result then
        Reply(src, ('Sorgu #%d | Panik: %s | Sonuç: %s'):format(sid, result.waveform, result.outcome))
    end
end, false)
