Matrix = Matrix or {}
Matrix.Bureau = Matrix.Bureau or {}

-- =============================================================================
-- KATMAN 7 / FAZ 3+4 - Akilli Buro Ogrenme Hucresi, Nukleer Buro Kilidi ve
-- gelecekteki OpenAI koprusu.
--
-- SIFIR RNG: bu dosyada math.random cagrisi yoktur. Buronun her karari
-- (kilit tetikleme, hub dondurma) dogrudan matrix_bureau_learning_core'a
-- yazilan gercek operasyonel verilerden (radio_breach_count,
-- average_purity_intercepted) turetilir.
-- =============================================================================

local resourceName = GetCurrentResourceName()

Matrix.Bureau.LearningCache = Matrix.Bureau.LearningCache or {}
Matrix.Bureau.Hubs = Matrix.Bureau.Hubs or {}
Matrix.Bureau.FrozenAccounts = Matrix.Bureau.FrozenAccounts or {}

-- ============================================================================
-- BASLANGIC: ogrenme hafizasini ve hub'lari RAM onbellege kilitle
-- ============================================================================
AddEventHandler('onResourceStart', function(startedResource)
    if startedResource ~= resourceName then return end

    Matrix.Bureau.LoadLearningCache()
    Matrix.Bureau.LoadHubCache()
    Matrix.Bureau.StartHubTicker()
    Matrix.Bureau.StartAIBridgeTicker()
end)

function Matrix.Bureau.DecodeJsonArray(raw)
    if not raw or raw == '' then
        return {}
    end

    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then
        return decoded
    end

    return {}
end

function Matrix.Bureau.LoadLearningCache()
    exports.oxmysql:execute('SELECT * FROM matrix_bureau_learning_core', {}, function(rows)
        rows = rows or {}
        Matrix.Bureau.LearningCache = {}

        for _, row in ipairs(rows) do
            row.frequent_zones = Matrix.Bureau.DecodeJsonArray(row.frequent_zones)
            row.lockdown_active = (tonumber(row.lockdown_active) or 0) == 1
            Matrix.Bureau.LearningCache[row.district_id] = row
        end

        print(('[Matrix][Bureau] Ogrenme hafizasi RAM onbellege kilitlendi (%d bolge).'):format(#rows))
    end)
end

function Matrix.Bureau.LoadHubCache()
    exports.oxmysql:execute('SELECT * FROM matrix_district_hubs', {}, function(rows)
        rows = rows or {}
        Matrix.Bureau.Hubs = {}

        for _, row in ipairs(rows) do
            row.assigned_bots = Matrix.Bureau.DecodeJsonArray(row.assigned_bots)
            row.active = (tonumber(row.active) or 0) == 1
            row.locked = (tonumber(row.locked) or 0) == 1
            Matrix.Bureau.Hubs[row.id] = row
        end

        print(('[Matrix][Bureau] %d Toplu Satis Hub RAM onbellege yuklendi.'):format(#rows))
    end)
end

function Matrix.Bureau.GetDistrictState(districtId)
    local state = Matrix.Bureau.LearningCache[districtId]

    if not state then
        state = {
            id = nil,
            district_id = districtId,
            frequent_zones = {},
            radio_breach_count = 0,
            average_purity_intercepted = 0.0,
            lockdown_active = false,
        }
        Matrix.Bureau.LearningCache[districtId] = state
    end

    return state
end

-- ============================================================================
-- DETERMINISTIK IHLAL KAYDI
-- Bir botun operasyonel acigi (telsiz kesintisi, basilan stash vb.) her
-- gerceklestiginde cagrilir. Sans oyunu yok: sayaclar dogrudan artirilir,
-- ortalama saflik hareketli ortalama formuluyle guncellenir.
-- ============================================================================
function Matrix.Bureau.RecordBreach(districtId, zoneLabel, purityIntercepted)
    if not districtId then return end

    local state = Matrix.Bureau.GetDistrictState(districtId)

    state.radio_breach_count = (state.radio_breach_count or 0) + 1

    local n = state.radio_breach_count
    local prevAvg = state.average_purity_intercepted or 0.0
    local sample = tonumber(purityIntercepted) or 0.0
    state.average_purity_intercepted = prevAvg + ((sample - prevAvg) / n)

    if zoneLabel then
        local zones = state.frequent_zones or {}
        local alreadyKnown = false

        for _, zone in ipairs(zones) do
            if zone == zoneLabel then
                alreadyKnown = true
                break
            end
        end

        if not alreadyKnown then
            zones[#zones + 1] = zoneLabel
        end

        state.frequent_zones = zones
    end

    Matrix.Bureau.PersistDistrictState(districtId)

    return Matrix.Bureau.EvaluateLockdown(districtId)
end

-- ============================================================================
-- DETERMINISTIK KANIT KATSAYISI VE KILIT DEGERLENDIRMESI
-- coefficient = (telsiz_orani * 0.70) + (saflik_orani * 0.30), her ikisi de
-- [0,1] araligina kirpilir. %75 baraji asilinca kilit tetiklenir.
-- ============================================================================
function Matrix.Bureau.ComputeEvidenceCoefficient(districtId)
    local state = Matrix.Bureau.GetDistrictState(districtId)

    local breachRatio = math.min((state.radio_breach_count or 0) / Config.Bureau.BreachCeiling, 1.0)
    local purityRatio = math.min((state.average_purity_intercepted or 0.0) / Config.Bureau.PurityWeightCap, 1.0)

    return (breachRatio * Config.Bureau.BreachWeight) + (purityRatio * Config.Bureau.PurityWeight)
end

function Matrix.Bureau.EvaluateLockdown(districtId)
    local state = Matrix.Bureau.GetDistrictState(districtId)
    local coefficient = Matrix.Bureau.ComputeEvidenceCoefficient(districtId)

    if coefficient >= Config.Bureau.LockdownThreshold and not state.lockdown_active then
        Matrix.Bureau.TriggerLockdown(districtId, coefficient)
    elseif coefficient < Config.Bureau.LockdownThreshold and state.lockdown_active then
        Matrix.Bureau.LiftLockdown(districtId, coefficient)
    end

    return coefficient
end

-- ============================================================================
-- NUKLEER BURO KILIDI (ADLI ABLUKA)
-- ============================================================================
function Matrix.Bureau.TriggerLockdown(districtId, coefficient)
    local state = Matrix.Bureau.GetDistrictState(districtId)
    state.lockdown_active = true

    Matrix.Bureau.PersistDistrictState(districtId)
    Matrix.Bureau.FreezeDistrictHubs(districtId)
    Matrix.Bureau.FreezeShellAccounts(districtId)

    TriggerClientEvent('matrix:hud:bulletin', -1, {
        text = '[ADLI ANOMALI: BURO KILIDI DEVREDE]',
        district = districtId,
        color = 'red',
        coefficient = coefficient,
    })

    print(('[Matrix][Bureau] LOCKDOWN devrede: %s (katsayi %.2f)'):format(districtId, coefficient))
end

function Matrix.Bureau.LiftLockdown(districtId, coefficient)
    local state = Matrix.Bureau.GetDistrictState(districtId)
    state.lockdown_active = false

    Matrix.Bureau.PersistDistrictState(districtId)

    for _, hub in pairs(Matrix.Bureau.Hubs) do
        if hub.district_name == districtId then
            hub.locked = false
        end
    end

    exports.oxmysql:execute('UPDATE matrix_district_hubs SET locked = 0 WHERE district_name = ?', { districtId })

    TriggerClientEvent('matrix:hud:bulletin', -1, {
        text = '[ADLI ANOMALI SONA ERDI: BURO KILIDI KALKTI]',
        district = districtId,
        color = 'green',
        coefficient = coefficient,
    })

    print(('[Matrix][Bureau] Lockdown kaldirildi: %s (katsayi %.2f)'):format(districtId, coefficient))
end

function Matrix.Bureau.FreezeDistrictHubs(districtId)
    for _, hub in pairs(Matrix.Bureau.Hubs) do
        if hub.district_name == districtId then
            hub.locked = true
            hub.active = false
        end
    end

    exports.oxmysql:execute('UPDATE matrix_district_hubs SET locked = 1, active = 0 WHERE district_name = ?', { districtId })
end

function Matrix.Bureau.FreezeShellAccounts(districtId)
    Matrix.Bureau.FrozenAccounts[districtId] = true

    -- Paravan sirket banka hesaplari ayri bir ekonomi kaynaginda yasar; Buro
    -- sadece dondurma kararini verir ve bir event ile devreder, dogrudan
    -- baska bir resource'un tablosuna yazmaz.
    TriggerEvent('matrix:bureau:shellAccountsFrozen', districtId)
end

function Matrix.Bureau.IsDistrictLocked(districtId)
    local state = Matrix.Bureau.LearningCache[districtId]
    return state ~= nil and state.lockdown_active == true
end

-- ============================================================================
-- KALICILIK (yazma islemleri hot path disinda, RAM onbellek her zaman gercek
-- kaynaktir; DB sadece write-through hedefidir)
-- ============================================================================
function Matrix.Bureau.PersistDistrictState(districtId)
    local state = Matrix.Bureau.GetDistrictState(districtId)

    exports.oxmysql:execute([[
        INSERT INTO matrix_bureau_learning_core
            (district_id, frequent_zones, radio_breach_count, average_purity_intercepted, lockdown_active, updated_at)
        VALUES (?, ?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            frequent_zones = VALUES(frequent_zones),
            radio_breach_count = VALUES(radio_breach_count),
            average_purity_intercepted = VALUES(average_purity_intercepted),
            lockdown_active = VALUES(lockdown_active),
            updated_at = NOW()
    ]], {
        districtId,
        json.encode(state.frequent_zones or {}),
        state.radio_breach_count or 0,
        state.average_purity_intercepted or 0.0,
        state.lockdown_active and 1 or 0,
    })
end

-- ============================================================================
-- TOPLU SATIS HUB YONETIMI (F10 menu backend)
-- Istemci taraf F10 menusu bu event'i TriggerServerEvent ile cagirir; tum
-- yetki kontrolleri (kilit durumu, koordinat gecerliligi) burada, sunucu
-- tarafinda yapilir.
-- ============================================================================
RegisterNetEvent('matrix:bureau:assignHub', function(districtName, coords, botId)
    local src = source

    if type(districtName) ~= 'string' or districtName == '' then return end
    if type(coords) ~= 'table' or type(coords.x) ~= 'number' or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' then return end

    if Matrix.Bureau.IsDistrictLocked(districtName) then
        TriggerClientEvent('matrix:hud:bulletin', src, {
            text = '[ADLI ANOMALI: BURO KILIDI DEVREDE] - Hub atamasi reddedildi.',
            district = districtName,
            color = 'red',
        })
        return
    end

    Matrix.Bureau.AssignDistrictHub(districtName, coords, botId)
end)

function Matrix.Bureau.AssignDistrictHub(districtName, coords, botId)
    exports.oxmysql:insert([[
        INSERT INTO matrix_district_hubs (district_name, coord_x, coord_y, coord_z, assigned_bots, active, locked, created_at)
        VALUES (?, ?, ?, ?, ?, 1, 0, NOW())
    ]], {
        districtName, coords.x, coords.y, coords.z, json.encode(botId and { botId } or {}),
    }, function(insertId)
        if not insertId then return end

        Matrix.Bureau.Hubs[insertId] = {
            id = insertId,
            district_name = districtName,
            coord_x = coords.x,
            coord_y = coords.y,
            coord_z = coords.z,
            assigned_bots = botId and { botId } or {},
            active = true,
            locked = false,
        }

        print(('[Matrix][Bureau] Yeni Toplu Satis Hub kuruldu: %s (#%d)'):format(districtName, insertId))
    end)
end

function Matrix.Bureau.GetActiveHubs()
    local active = {}

    for hubId, hub in pairs(Matrix.Bureau.Hubs) do
        if hub.active and not hub.locked then
            active[hubId] = hub
        end
    end

    return active
end

-- ============================================================================
-- HUB TICKER: sabit-boyutlu (RNG'siz) toplu ticaret dongusu
-- ============================================================================
function Matrix.Bureau.StartHubTicker()
    CreateThread(function()
        while true do
            Wait(Config.Bureau.HubDemandCycleMs)

            for hubId, hub in pairs(Matrix.Bureau.Hubs) do
                if hub.active and not hub.locked then
                    Matrix.Bureau.ProcessHubDemandCycle(hubId, hub)
                end
            end
        end
    end)
end

function Matrix.Bureau.ProcessHubDemandCycle(hubId, hub)
    local batchSize = Config.Bureau.HubSaleBatchSize

    exports.oxmysql:execute(
        'SELECT item_name FROM matrix_trap_stash WHERE stash_owner = ? AND amount >= ? ORDER BY item_name LIMIT 1',
        { hub.district_name, batchSize },
        function(rows)
            local row = rows and rows[1]
            if not row then return end

            exports.oxmysql:execute(
                'UPDATE matrix_trap_stash SET amount = amount - ?, updated_at = NOW() WHERE stash_owner = ? AND item_name = ?',
                { batchSize, hub.district_name, row.item_name }
            )

            TriggerEvent('matrix:bureau:hubSaleProcessed', hub.district_name, row.item_name, batchSize)
        end
    )
end

-- ============================================================================
-- GELECEKTEKI OPENAI / CHATGPT KOPRUSU (pasif, varsayilan kapali)
-- Deterministik motor bu koprunun sonucunu ASLA beklemez ve ondan
-- etkilenmez; kilit kararlari her zaman Matrix.Bureau.EvaluateLockdown'dan
-- gelir. Bu ticker sadece istege bagli, danisma amacli bir katmandir.
-- ============================================================================
function Matrix.Bureau.StartAIBridgeTicker()
    CreateThread(function()
        while true do
            Wait(Config.AI_Matrix_Brain.analysisIntervalMinutes * 60000)

            if Config.AI_Matrix_Brain.enabled then
                Matrix.Bureau.RunAIAnalysisPass()
            end
        end
    end)
end

function Matrix.Bureau.RunAIAnalysisPass()
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        print('[Matrix][Bureau][AI] AI_Matrix_Brain enabled=true fakat apiKey yapilandirilmamis, deterministik moda devam ediliyor.')
        return
    end

    local payloadRows = {}
    for districtId, state in pairs(Matrix.Bureau.LearningCache) do
        payloadRows[#payloadRows + 1] = {
            district_id = districtId,
            frequent_zones = state.frequent_zones,
            radio_breach_count = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            lockdown_active = state.lockdown_active,
        }
    end

    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a deterministic police-heat auditor for a GTA roleplay server. Summarize risk trends only, do not invent data.' },
            { role = 'user', content = json.encode(payloadRows) },
        },
    })

    PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
        if statusCode ~= 200 then
            if Config.AI_Matrix_Brain.fallbackToDeterministic then
                print(('[Matrix][Bureau][AI] OpenAI istegi basarisiz (HTTP %s); fallbackToDeterministic=true, deterministik motor degismeden calismaya devam ediyor.'):format(tostring(statusCode)))
            else
                print(('^1[Matrix][Bureau][AI] OpenAI istegi basarisiz (HTTP %s) ve fallbackToDeterministic=false; bu dongude AI danismanligi atlandi.^0'):format(tostring(statusCode)))
            end
            return
        end

        local ok, decoded = pcall(json.decode, response)
        if not ok then
            print('[Matrix][Bureau][AI] OpenAI yaniti cozumlenemedi, deterministik motor etkilenmedi.')
            return
        end

        TriggerEvent('matrix:bureau:aiAdvisoryReceived', decoded)
    end, 'POST', body, {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. Config.AI_Matrix_Brain.apiKey,
    })
end

exports('RecordBreach', Matrix.Bureau.RecordBreach)
exports('IsDistrictLocked', Matrix.Bureau.IsDistrictLocked)
exports('AssignDistrictHub', Matrix.Bureau.AssignDistrictHub)
exports('GetActiveHubs', Matrix.Bureau.GetActiveHubs)
