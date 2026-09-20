-- =====================================================================
-- MATRIX MARKET / server/market.lua  (KATMAN 5 — MÜHÜRLÜ SÜRÜM)
--
-- ★ BU SÜRÜMDEKİ EK SERTLEŞTİRME:
--   [M1] FormatCortisolThreshold / FormatFatigueThreshold artık
--        `tonumber() or 0.0` yeterli değil — NaN ve ±inf değerler
--        KARŞILAŞTIRMA MATRİSİNE SOKULMADAN önce açıkça filtrelenir.
--        (Lua'da NaN tüm karşılaştırmalarda false döner; inf ise sessizce
--        "else" dalına düşerdi. Her iki davranış da deterministik ama
--        AÇIKÇA ifade edilmesi gerekir — çökme yok, ama "hangi metin çıkar"
--        belirsizliği de ortadan kalktı.)
--   [M2] BuildSnapshot artık tüm sayısal alanları (cortisol, fatigue,
--        heat, decryption_confidence) HUD'a push etmeden ÖNCE
--        Matrix.Clamp'ten geçirir. Master ticker'ın ürettiği hiçbir
--        NaN/inf, client DrawText katmanına ulaşamaz.
--   [M3] PushSnapshots içindeki TriggerClientEvent yalnızca pcall BAŞARILI
--        ise çağrılır (mevcut davranış), ekstra olarak snapshot tipi
--        kontrol edilir.
-- =====================================================================

Matrix.Hierarchy    = Matrix.Hierarchy    or {}
Matrix.Market        = Matrix.Market        or {}
Matrix.RadioSilence  = Matrix.RadioSilence  or {}
Matrix.CashDecay     = Matrix.CashDecay     or {}
Matrix.Undercover    = Matrix.Undercover    or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local math_max, math_min, math_huge = math.max, math.min, math.huge

local CreateThread       = CreateThread
local Wait                = Wait
local RegisterCommand     = RegisterCommand
local RegisterNetEvent    = RegisterNetEvent
local TriggerClientEvent  = TriggerClientEvent

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[MARKET]', msg } })
    else
        print(('[MATRIX:MARKET:CONSOLE] %s'):format(msg))
    end
end

-- =====================================================================
-- 1) CO-OP KARTEL HİYERARŞİSİ
-- =====================================================================
local HierarchyRanks = {}   -- citizenid -> { rank, assigned_by }

function Matrix.Hierarchy.LoadHierarchy()
    local callOk = pcall(function()
        MySQL.query('SELECT citizenid, rank, assigned_by FROM matrix_hierarchy', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.citizenid and Config.Hierarchy.Ranks[row.rank] then
                            HierarchyRanks[row.citizenid] = { rank = row.rank, assigned_by = row.assigned_by }
                        end
                    end
                    Matrix.Log('MARKET', '%d co-op rutbe atamasi yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('MARKET', '[HATA] matrix_hierarchy sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end

CreateThread(function()
    Matrix.Hierarchy.LoadHierarchy()
end)

function Matrix.Hierarchy.GetRank(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    local rec = HierarchyRanks[citizenid]
    return rec and rec.rank or nil
end

function Matrix.Hierarchy.HasCommandAuthority(citizenid)
    local rank = Matrix.Hierarchy.GetRank(citizenid)
    if not rank then return false end
    local rankCfg = Config.Hierarchy.Ranks[rank]
    if not rankCfg then return false end
    return rankCfg.level >= Config.Hierarchy.MinRankLevelForCommand
end

function Matrix.Hierarchy.SetRank(citizenid, rank, assignedBy)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'bad_citizenid' end
    if not Config.Hierarchy.Ranks[rank] then return false, 'bad_rank' end

    HierarchyRanks[citizenid] = { rank = rank, assigned_by = assignedBy }

    MySQL.prepare([[
        INSERT INTO matrix_hierarchy (citizenid, rank, assigned_by, created_at, updated_at)
        VALUES (?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE rank = VALUES(rank), assigned_by = VALUES(assigned_by), updated_at = NOW()
    ]], { citizenid, rank, assignedBy })

    Matrix.Log('MARKET', 'Rutbe atandi: %s -> %s (atayan: %s)', citizenid, rank, tostring(assignedBy))
    return true
end

local function ResolveTargetCitizenidWithRetry(targetSrc)
    for attempt = 1, 3 do
        local state = Matrix.GetOrCreatePlayerState(targetSrc)
        if state and state.citizenid then return state.citizenid end
        if attempt < 3 then Wait(300) end
    end
    return nil
end

RegisterCommand('rutbeata', function(src, args)
    local targetSrc = tonumber(args[1])
    local rank = args[2]
    if not targetSrc or not rank then
        Reply(src, 'Kullanim: /rutbeata [targetSrc] [Leader|Logistics_Officer|Chemist]'); return
    end

    local targetCitizenid = ResolveTargetCitizenidWithRetry(targetSrc)
    if not targetCitizenid then
        Reply(src, 'Hedef oyuncu bulunamadi (3 deneme sonrasi da cozulemedi; oyuncu hala yukleniyor olabilir, birkac saniye sonra tekrar deneyin).'); return
    end

    local assignerState = Matrix.GetOrCreatePlayerState(src)
    local ok, reason = Matrix.Hierarchy.SetRank(targetCitizenid, rank, assignerState and assignerState.citizenid)
    if ok then
        Reply(src, ('%s rutbesi %s olarak ayarlandi.'):format(targetCitizenid, rank))
    elseif reason == 'bad_rank' then
        Reply(src, 'Gecersiz rutbe: Leader, Logistics_Officer veya Chemist olmali.')
    else
        Reply(src, 'Rutbe atamasi basarisiz.')
    end
end, false)

RegisterCommand('rutbemgoster', function(src)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then Reply(src, 'Profil cozulemedi.'); return end

    local rank = Matrix.Hierarchy.GetRank(state.citizenid)
    if not rank then
        Reply(src, 'Hiyerarside kayitli degilsiniz (komuta yetkiniz yok).')
    else
        Reply(src, ('Rutbeniz: %s (%s) | Komuta yetkisi: %s'):format(
            rank, Config.Hierarchy.Ranks[rank].label, tostring(Matrix.Hierarchy.HasCommandAuthority(state.citizenid))))
    end
end, false)

-- =====================================================================
-- 2) BÖLGESEL MADDE PİYASASI & GURME MÜŞTERİ REAKSİYONU
-- =====================================================================
local MarketZones      = {}
local dirtyMarketZones = {}

function Matrix.Market.LoadMarketZones()
    local callOk = pcall(function()
        MySQL.query('SELECT * FROM matrix_market_zones', {}, function(rows)
            pcall(function()
                local loaded = {}
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        loaded[row.zone_id] = true
                        MarketZones[row.zone_id] = {
                            zone_id          = row.zone_id,
                            price_multiplier = tonumber(row.price_multiplier) or Config.Market.PriceMultiplierDefault,
                            rejected_streak  = tonumber(row.rejected_streak) or 0
                        }
                    end
                end
                for _, zoneCfg in ipairs(Config.Market.Zones) do
                    if not loaded[zoneCfg.id] then
                        MarketZones[zoneCfg.id] = {
                            zone_id          = zoneCfg.id,
                            price_multiplier = Config.Market.PriceMultiplierDefault,
                            rejected_streak  = 0
                        }
                        dirtyMarketZones[zoneCfg.id] = true
                    end
                end
                Matrix.Log('MARKET', '%d bolgesel piyasa kaydi yuklendi.', type(rows) == 'table' and #rows or 0)
            end)
        end)
    end)
    if not callOk then
        for _, zoneCfg in ipairs(Config.Market.Zones) do
            MarketZones[zoneCfg.id] = MarketZones[zoneCfg.id] or {
                zone_id = zoneCfg.id, price_multiplier = Config.Market.PriceMultiplierDefault, rejected_streak = 0
            }
        end
        Matrix.Log('MARKET', '[HATA] matrix_market_zones sorgu cagrisi reddedildi; RAM varsayilanlariyla devam ediliyor.')
    end
end

CreateThread(function()
    Matrix.Market.LoadMarketZones()
end)

local function GetOrCreateZoneRecord(zoneId)
    local rec = MarketZones[zoneId]
    if not rec then
        rec = { zone_id = zoneId, price_multiplier = Config.Market.PriceMultiplierDefault, rejected_streak = 0 }
        MarketZones[zoneId] = rec
    end
    return rec
end

function Matrix.Market.FindNearestZone(coords)
    if not coords then return nil end
    local nearestId, nearestDist = nil, math_huge
    for _, zoneCfg in ipairs(Config.Market.Zones) do
        local d = #(coords - zoneCfg.coords)
        if d < nearestDist then nearestId, nearestDist = zoneCfg.id, d end
    end
    return nearestId
end

function Matrix.Market.EvaluateSale(zoneId, buyerCitizenid, buyerCognitiveShifter, purity, sellerBallisticId)
    zoneId = tonumber(zoneId)
    if not zoneId then return nil end

    local zone = GetOrCreateZoneRecord(zoneId)
    buyerCognitiveShifter = Matrix.Clamp(tonumber(buyerCognitiveShifter) or 0.0, 0.0, 1.0)
    purity                = Matrix.Clamp(tonumber(purity) or 0.0, 0.0, 1.0)

    local isGourmet = buyerCognitiveShifter > Config.Market.GourmetCognitiveShifterThreshold
    local rejected   = isGourmet and (purity < Config.Market.GourmetMinPurity)

    if rejected then
        zone.rejected_streak = zone.rejected_streak + 1

        local decayRate = Config.Market.RejectionPriceDecayRate * Config.Market.DemandElasticity
        zone.price_multiplier = Config.Market.PriceMultiplierFloor
            + ((zone.price_multiplier - Config.Market.PriceMultiplierFloor) * math.exp(-decayRate))
        zone.price_multiplier = Matrix.Clamp(
            zone.price_multiplier, Config.Market.PriceMultiplierFloor, Config.Market.PriceMultiplierCeiling)
        dirtyMarketZones[zoneId] = true

        Matrix.Log('MARKET',
            '[PAZAR ANOMALİSİ: KALİTESİZ ARZ REDDEDİLDİ] Bölge #%d | Saflık:%.3f | Ardarda-Red:%d | Yeni-Çarpan:x%.3f',
            zoneId, purity, zone.rejected_streak, zone.price_multiplier)
    elseif zone.rejected_streak ~= 0 then
        zone.rejected_streak = 0
        dirtyMarketZones[zoneId] = true
    end

    local isUndercover = Matrix.Undercover.IsUndercoverAgent(buyerCitizenid)
    if isUndercover and type(sellerBallisticId) == 'string' and sellerBallisticId ~= '' then
        Matrix.Forensics.ForceSeal(sellerBallisticId)
        Matrix.Log('MARKET', '[UNDERCOVER TESLİMAT] %s -> gizli ajan tespit edildi, balistik #%s zorla mühürlendi.',
            tostring(buyerCitizenid), sellerBallisticId)
    end

    return {
        rejected         = rejected,
        is_gourmet       = isGourmet,
        price_multiplier = zone.price_multiplier,
        is_undercover    = isUndercover
    }
end

local function FlushDirtyMarketZones()
    for zoneId in pairs(dirtyMarketZones) do
        local zone = MarketZones[zoneId]
        if zone then
            MySQL.prepare([[
                INSERT INTO matrix_market_zones (zone_id, price_multiplier, rejected_streak, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE
                    price_multiplier = VALUES(price_multiplier),
                    rejected_streak  = VALUES(rejected_streak),
                    updated_at       = NOW()
            ]], { zoneId, zone.price_multiplier, zone.rejected_streak })
        end
        dirtyMarketZones[zoneId] = nil
    end
end

RegisterNetEvent('matrix:server:reportSaleAttempt', function(botId, buyerCognitiveShifter, purity, sellerBallisticId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    local bot = botId and Matrix.Bots[botId]
    if not bot or not bot.state.coords then return end

    local zoneId = Matrix.Market.FindNearestZone(bot.state.coords)
    if not zoneId then return end

    local state = Matrix.GetOrCreatePlayerState(src)
    Matrix.Market.EvaluateSale(zoneId, state and state.citizenid, buyerCognitiveShifter, purity, sellerBallisticId)
end)

RegisterCommand('piyasasifirla', function(src, args)
    local zoneId = tonumber(args[1])
    if not zoneId then Reply(src, 'Kullanim: /piyasasifirla [zoneId]'); return end

    local zone = GetOrCreateZoneRecord(zoneId)
    zone.price_multiplier = Config.Market.PriceMultiplierDefault
    zone.rejected_streak  = 0
    dirtyMarketZones[zoneId] = true

    Reply(src, ('Bolge #%d fiyat carpani varsayilana (x%.2f) sifirlandi.'):format(zoneId, Config.Market.PriceMultiplierDefault))
end, false)

RegisterCommand('piyasasorgu', function(src, args)
    local zoneId = tonumber(args[1])
    if zoneId then
        local zone = MarketZones[zoneId]
        if not zone then Reply(src, 'Bu bolge icin kayit yok.'); return end
        Reply(src, ('Bolge #%d | Fiyat-Carpani:x%.3f | Ardarda-Red:%d'):format(
            zoneId, zone.price_multiplier, zone.rejected_streak))
        return
    end

    for _, zoneCfg in ipairs(Config.Market.Zones) do
        local zone = MarketZones[zoneCfg.id]
        if zone then
            Reply(src, ('#%d %s | Fiyat-Carpani:x%.3f | Ardarda-Red:%d'):format(
                zoneCfg.id, zoneCfg.label, zone.price_multiplier, zone.rejected_streak))
        end
    end
end, false)

-- =====================================================================
-- 3) TELSİZ SESSİZLİĞİ MODU
-- =====================================================================
local SilenceExpiry = {}

function Matrix.RadioSilence.Start(citizenid, minutes)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    minutes = Matrix.Clamp(tonumber(minutes) or 5.0, 1.0, Config.RadioSilence.MaxDurationMinutes)
    SilenceExpiry[citizenid] = Matrix.Now() + math.floor(minutes * 60.0)
    return true, minutes
end

function Matrix.RadioSilence.IsActive(citizenid)
    if type(citizenid) ~= 'string' then return false end
    local expiresAt = SilenceExpiry[citizenid]
    if not expiresAt then return false end
    if Matrix.Now() >= expiresAt then
        SilenceExpiry[citizenid] = nil
        return false
    end
    return true
end

function Matrix.RadioSilence.IsActiveForSource(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local state = Matrix.GetOrCreatePlayerState(src)
    return state ~= nil and Matrix.RadioSilence.IsActive(state.citizenid)
end

RegisterCommand('sessizlik', function(src, args)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then Reply(src, 'Profil cozulemedi.'); return end

    local ok, minutes = Matrix.RadioSilence.Start(state.citizenid, tonumber(args[1]))
    if ok then
        Reply(src, ('Telsiz sessizligi %d dakika aktif. Bu sure boyunca canli yayin siber heatmap artisi durur.'):format(minutes))
    else
        Reply(src, 'Sessizlik baslatilamadi.')
    end
end, false)

-- =====================================================================
-- 4) KİRLENEN NAKİT SÖNÜMLENMESİ
-- =====================================================================
local CashByTrapHouse = {}
local dirtyCash        = {}

function Matrix.CashDecay.LoadCashDecay()
    local callOk = pcall(function()
        MySQL.query('SELECT trap_house_id, dirty_amount FROM matrix_cash_decay', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.trap_house_id then
                            CashByTrapHouse[row.trap_house_id] = {
                                dirty_amount = tonumber(row.dirty_amount) or 0.0,
                                deposited_at = Matrix.Now()
                            }
                        end
                    end
                    Matrix.Log('MARKET', '%d kirli nakit kaydi yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('MARKET', '[HATA] matrix_cash_decay sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end

CreateThread(function()
    Matrix.CashDecay.LoadCashDecay()
end)

function Matrix.CashDecay.Deposit(trapHouseId, amount)
    trapHouseId = tonumber(trapHouseId)
    amount      = tonumber(amount) or 0.0
    if not trapHouseId or amount <= 0.0 then return false end

    local rec = CashByTrapHouse[trapHouseId]
    if not rec then
        rec = { dirty_amount = 0.0, deposited_at = Matrix.Now() }
        CashByTrapHouse[trapHouseId] = rec
    end
    rec.dirty_amount = rec.dirty_amount + amount
    dirtyCash[trapHouseId] = true

    Matrix.Log('MARKET', 'Trap house #%d kirli nakit yatirimi: +%.1f (toplam:%.1f)', trapHouseId, amount, rec.dirty_amount)
    return true
end

function Matrix.CashDecay.Launder(trapHouseId, amount)
    trapHouseId = tonumber(trapHouseId)
    amount      = tonumber(amount) or 0.0
    local rec = trapHouseId and CashByTrapHouse[trapHouseId]
    if not rec or amount <= 0.0 then return false end

    rec.dirty_amount = math_max(rec.dirty_amount - amount, 0.0)
    if rec.dirty_amount <= 0.0 then
        rec.deposited_at = Matrix.Now()
    end
    dirtyCash[trapHouseId] = true

    Matrix.Log('MARKET', 'Trap house #%d nakit aklandi: -%.1f (kalan:%.1f)', trapHouseId, amount, rec.dirty_amount)
    return true
end

function Matrix.CashDecay.Tick()
    local now = Matrix.Now()
    for trapHouseId, rec in pairs(CashByTrapHouse) do
        if rec.dirty_amount > 0.0 and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId] then
            local ageDays    = math_max((now - rec.deposited_at) / 86400.0, 0.0)
            local traceLevel = Matrix.Clamp(1.0 - (0.5 ^ (ageDays / Config.CashDecay.TraceHalfLifeRealDays)), 0.0, 1.0)

            local raidGain = Config.Bureau.PatternAnalysisGain * traceLevel
                * (Config.CashDecay.RaidRiskMultiplierAtMaxTrace - 1.0)
            if raidGain > 0.0 then
                Matrix.Bureau.AdvanceDecryption(trapHouseId, raidGain)
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.CashDecay.TickIntervalMs)
        local ok, err = pcall(Matrix.CashDecay.Tick)
        if not ok then
            Matrix.Log('MARKET', '[HATA] CashDecay.Tick hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

local function FlushDirtyCash()
    for trapHouseId in pairs(dirtyCash) do
        local rec = CashByTrapHouse[trapHouseId]
        if rec then
            MySQL.prepare([[
                INSERT INTO matrix_cash_decay (trap_house_id, dirty_amount, deposited_at, updated_at)
                VALUES (?, ?, FROM_UNIXTIME(?), NOW())
                ON DUPLICATE KEY UPDATE
                    dirty_amount = VALUES(dirty_amount),
                    deposited_at = VALUES(deposited_at),
                    updated_at   = NOW()
            ]], { trapHouseId, rec.dirty_amount, rec.deposited_at })
        end
        dirtyCash[trapHouseId] = nil
    end
end

RegisterCommand('nakityatir', function(src, args)
    local trapHouseId = tonumber(args[1])
    local amount = tonumber(args[2])
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] or not amount then
        Reply(src, 'Kullanim: /nakityatir [trapHouseId] [miktar]'); return
    end
    Matrix.CashDecay.Deposit(trapHouseId, amount)
    Reply(src, ('Trap #%d kirli nakit: %.1f'):format(trapHouseId, CashByTrapHouse[trapHouseId].dirty_amount))
end, false)

RegisterCommand('nakitakla', function(src, args)
    local trapHouseId = tonumber(args[1])
    local amount = tonumber(args[2])
    if not trapHouseId or not amount then Reply(src, 'Kullanim: /nakitakla [trapHouseId] [miktar]'); return end

    local ok = Matrix.CashDecay.Launder(trapHouseId, amount)
    Reply(src, ok and ('Aklandi. Kalan kirli nakit: %.1f'):format(CashByTrapHouse[trapHouseId].dirty_amount)
              or 'Aklama basarisiz (kayit yok veya gecersiz miktar).')
end, false)

RegisterCommand('nakitdurum', function(src, args)
    local trapHouseId = tonumber(args[1])
    local rec = trapHouseId and CashByTrapHouse[trapHouseId]
    if not rec then Reply(src, 'Kullanim: /nakitdurum [trapHouseId]'); return end

    local ageDays = math_max((Matrix.Now() - rec.deposited_at) / 86400.0, 0.0)
    local traceLevel = Matrix.Clamp(1.0 - (0.5 ^ (ageDays / Config.CashDecay.TraceHalfLifeRealDays)), 0.0, 1.0)
    Reply(src, ('Trap #%d | Kirli-Nakit:%.1f | Yas:%.2f gun | Iz-Seviyesi:%.3f'):format(
        trapHouseId, rec.dirty_amount, ageDays, traceLevel))
end, false)

-- =====================================================================
-- 5) UNDERCOVER AJAN YOĞUNLAŞMASI
-- =====================================================================
local UndercoverFlags = {}

function Matrix.Undercover.IsUndercoverAgent(citizenid)
    return type(citizenid) == 'string' and UndercoverFlags[citizenid] == true
end

function Matrix.Undercover.Tick()
    local momentum = Matrix.Bureau.GetPropagandaMomentum()
    if momentum < Config.Undercover.InfiltrationMomentumThreshold then return end

    local rows = MySQL.query.await(
        'SELECT citizenid, times_reported, completed_deals FROM matrix_customer_pool WHERE promoted_to_candidate = 0', {}
    ) or {}

    for _, row in ipairs(rows) do
        if row.citizenid and not UndercoverFlags[row.citizenid] then
            local suspicion = Matrix.Clamp(
                ((row.times_reported or 0) * Config.Undercover.SuspicionReportWeight)
                    + ((row.completed_deals or 0) * Config.Undercover.SuspicionDealWeight),
                0.0, 1.0
            )
            if suspicion >= Config.Undercover.SuspicionThreshold then
                UndercoverFlags[row.citizenid] = true
                Matrix.Log('MARKET', '[UNDERCOVER ŞÜPHESİ] %s gizli ajan olarak isaretlendi (supheydi:%.2f, momentum:%.2f)',
                    row.citizenid, suspicion, momentum)
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Undercover.ScanIntervalSeconds * 1000)
        local ok, err = pcall(Matrix.Undercover.Tick)
        if not ok then
            Matrix.Log('MARKET', '[HATA] Undercover.Tick hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

RegisterCommand('gizliajandurum', function(src)
    local count = 0
    for citizenid in pairs(UndercoverFlags) do
        count = count + 1
        Reply(src, ('- %s'):format(citizenid))
    end
    Reply(src, ('--- Toplam %d isaretli gizli ajan | Propaganda-Momentum:%.2f (esik:%.2f) ---'):format(
        count, Matrix.Bureau.GetPropagandaMomentum(), Config.Undercover.InfiltrationMomentumThreshold))
end, false)

-- =====================================================================
-- 6) TAKTİK HUD ANLIK GÖRÜNTÜ  (★ M1+M2 SERTLEŞTİRME)
-- =====================================================================
Matrix.Hud = Matrix.Hud or {}
local HudViewers = {}   -- src -> true

RegisterNetEvent('matrix:server:hudToggled', function(active)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if active then
        HudViewers[src] = true
    else
        HudViewers[src] = nil
    end
end)

AddEventHandler('playerDropped', function()
    HudViewers[source] = nil
end)

-- ★ [M1] NaN/inf/type filtresi + sabit metin eşlemesi. Aynı girdi → aynı
-- çıktı. Çağrıldığında MASTER TICKER THREAD'İNİ ASLA DONDURMAZ.
local function FormatCortisolThreshold(value)
    local v = tonumber(value)
    if not v or v ~= v or v == math_huge or v == -math_huge then
        v = 0.0
    end
    if v < 0.20 then
        return '[NABIZ: SOĞUKKANLI SUBAY]'
    elseif v <= 0.60 then
        return '[NABIZ: ANKSİYETE BAŞLANGICI — TETİKTE]'
    else
        return '[NABIZ: AKUT PANİK ATAK KRİZİ — ELLERİN TİTRİYOR]'
    end
end

local function FormatFatigueThreshold(value)
    local v = tonumber(value)
    if not v or v ~= v or v == math_huge or v == -math_huge then
        v = 0.0
    end
    if v < 0.30 then
        return '[KONDİSYON: DİNÇ]'
    elseif v <= 0.80 then
        return '[KONDİSYON: KRONİK BİTKİNLİK]'
    else
        return '[KONDİSYON: NÖRON HASARI SINIRI — BEYİN SAKATLIĞI RİSKİ]'
    end
end

local function FindNearestTrapHouseCoordsForHud(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId
end

-- ★ [M2] Tüm sayısal değerler Clamp'ten geçer; hiçbir NaN/inf HUD'a
-- ulaşmaz. Saf okuma, mutasyon yok.
function Matrix.Hud.BuildSnapshot(src)
    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid

    local rank      = citizenid and Matrix.Hierarchy.GetRank(citizenid)
    local authority = (citizenid and Matrix.Hierarchy.HasCommandAuthority(citizenid)) or false
    local silent    = (citizenid and Matrix.RadioSilence.IsActive(citizenid)) or false

    local ped    = GetPlayerPed(src)
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    local trapId = coords and FindNearestTrapHouseCoordsForHud(coords)
    local house  = trapId and Matrix.TrapHouses[trapId]

    local heatRaw = (trapId and Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(trapId)) or 0.0
    local heat    = Matrix.Clamp(heatRaw, 0.0, Config.Bureau.CyberLeakMaxIntensity)

    local decryption = house and Matrix.Clamp(house.decryption_confidence or 0.0, 0.0, 1.0) or 0.0

    local cortisol = Matrix.Clamp((state and state.biology and state.biology.cortisol_level) or 0.0, 0.0, 1.0)
    local fatigue  = Matrix.Clamp((state and state.biology and state.biology.fatigue_level) or 0.0, 0.0, 1.0)

    local botCount = 0
    for _ in pairs(Matrix.Bots or {}) do botCount = botCount + 1 end
    local dispatchCount = 0
    for _ in pairs(Matrix.Dispatches or {}) do dispatchCount = dispatchCount + 1 end

    return {
        { text = '[KARTEL BUROSU]', header = true },
        { text = ('RUTBE:%s  KOMUTA-YETKISI:%s'):format(rank or 'YOK', tostring(authority)) },
        { text = '[SIBER RADAR]', header = true },
        { text = house
            and ('BOLGE:#%d DESIFRE:%.2f SIZINTI:%.2f SESSIZLIK:%s'):format(trapId, decryption, heat, tostring(silent))
            or 'BOLGE: BILINMIYOR' },
        { text = '[BIYOLOJIK PROFIL]', header = true },
        { text = FormatCortisolThreshold(cortisol) },
        { text = FormatFatigueThreshold(fatigue) },
        { text = '[SAHA OPERASYONU]', header = true },
        { text = ('AKTIF-BOT:%d  SEVKIYAT:%d'):format(botCount, dispatchCount) }
    }
end

function Matrix.Hud.PushSnapshots()
    for src in pairs(HudViewers) do
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then
            HudViewers[src] = nil
        else
            local ok, snapshot = pcall(Matrix.Hud.BuildSnapshot, src)
            if ok and type(snapshot) == 'table' then
                TriggerClientEvent('matrix:client:hudSnapshot', src, snapshot)
            end
        end
    end
end

-- =====================================================================
-- DIRTY-SET FLUSH THREAD
-- =====================================================================
CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyMarketZones()
        FlushDirtyCash()
    end
end)

-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('GetRank',              function(cid) return Matrix.Hierarchy.GetRank(cid) end)
exports('HasCommandAuthority',  function(cid) return Matrix.Hierarchy.HasCommandAuthority(cid) end)
exports('SetRank',              function(cid, rank, by) return Matrix.Hierarchy.SetRank(cid, rank, by) end)

exports('EvaluateSale',         function(zoneId, cid, cog, purity, ballisticId)
    return Matrix.Market.EvaluateSale(zoneId, cid, cog, purity, ballisticId)
end)
exports('FindNearestMarketZone',function(coords) return Matrix.Market.FindNearestZone(coords) end)

exports('StartRadioSilence',    function(cid, minutes) return Matrix.RadioSilence.Start(cid, minutes) end)
exports('IsRadioSilent',        function(cid) return Matrix.RadioSilence.IsActive(cid) end)

exports('DepositDirtyCash',     function(trapHouseId, amount) return Matrix.CashDecay.Deposit(trapHouseId, amount) end)
exports('LaunderDirtyCash',     function(trapHouseId, amount) return Matrix.CashDecay.Launder(trapHouseId, amount) end)

exports('IsUndercoverAgent',    function(cid) return Matrix.Undercover.IsUndercoverAgent(cid) end)
