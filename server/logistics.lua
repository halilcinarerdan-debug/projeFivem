-- =====================================================================
-- MATRIX LOGISTICS / logistics.lua
-- Katman 4: Programli Lojistik Sevk & Zaman-Mesafe Surtunme Motoru +
-- Illegal Filo Tedarik ve Atama Motoru.
-- Sealed Katman 1-2-3 dosyalarina (main/forensics/recruitment/bureau/
-- kitchen) dokunmadan, onlarin dirty-set / async-prepare desenini
-- taklit ederek Matrix.* omurgasina kenetlenir. RNG yok, HUD yok;
-- her deger deterministik denklemlerden ve config sabitlerinden gelir.
-- =====================================================================

Matrix.Logistics = Matrix.Logistics or {}
Matrix.Fleet      = Matrix.Fleet      or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local math_max, math_min, math_huge = math.max, math.min, math.huge

local CreateThread                  = CreateThread
local Wait                          = Wait
local SetTimeout                    = SetTimeout
local GetPlayerPed                  = GetPlayerPed
local GetEntityCoords               = GetEntityCoords
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local DoesEntityExist               = DoesEntityExist
local SetEntityCoords               = SetEntityCoords
local TriggerClientEvent            = TriggerClientEvent
local RegisterCommand               = RegisterCommand
local RegisterNetEvent              = RegisterNetEvent
-- UYARI: `source` BİLİNÇLİ OLARAK localize edilmez (bkz. main.lua'daki not) -
-- dosya yüklenirken bir kez yakalamak her event handler'ında aynı bayat
-- değerin okunmasına yol açar.

-- botId -> dispatch record
local ActiveDispatches = {}

-- plate -> { plate, vehicle_class, vin_status, vehicle_wear,
--            registered_by_citizenid, assigned_bot_id, assignment_mode }
local FleetVehicles = {}
-- botId -> plate (kalıcı atama, hızlı ters bakış)
local PermanentVehicleByBot = {}
-- plate -> botId (o an aktif bir sevkiyatta kullanılıyor; çift atamayı önler)
local ActiveVehicleLocks = {}

-- =====================================================================
-- UTILITIES
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    return #(a - b)
end

local function LerpCoords(a, b, t)
    t = Matrix.Clamp(t, 0.0, 1.0)
    return vector3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t
    )
end

local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' then return false end
    return c.x ~= nil and c.y ~= nil and c.z ~= nil
end

local function GetVehicleProfile(vehicleType)
    return Config.Logistics.VehicleTypes[vehicleType]
        or Config.Logistics.VehicleTypes[Config.Logistics.DefaultVehicleType]
end

-- Hedef vektörünü sıkı biçimde doğrular: eksik, bozuk (NaN/inf) veya
-- origin'e göre menzil dışı ise gerekçesini döndürür.
local function ValidateDestination(origin, destination)
    if destination == nil then return false, 'missing_vector' end
    if type(destination) ~= 'table' and type(destination) ~= 'userdata' then
        return false, 'corrupt_vector'
    end

    local x, y, z = destination.x, destination.y, destination.z
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
        return false, 'corrupt_vector'
    end
    if x ~= x or y ~= y or z ~= z then return false, 'corrupt_vector' end -- NaN guard
    if x == math_huge or x == -math_huge or y == math_huge or y == -math_huge
        or z == math_huge or z == -math_huge then
        return false, 'corrupt_vector'
    end

    if origin then
        local dist = VectorDistance(origin, destination)
        if dist > Config.Logistics.MaxDispatchRangeMeters then
            return false, 'out_of_range', dist
        end
    end

    return true
end

-- ox_inventory üzerinden dealer'ın taşıdığı toplam ağırlık (W_total, gram).
-- Konvansiyon: her dealer botu 'dealer_<id>' adlı bir ox_inventory envanteri kullanır.
local function GetBotInventoryWeight(bot)
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

-- Bureau.lua'daki en yakın trap house taramasının yerel eşdeğeri
-- (o dosya mühürlü olduğu için buradan çağrılamaz, aynı desen tekrarlanır).
local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then
            nearestId, nearestDist = id, d
        end
    end
    return nearestId, nearestDist
end

local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(coords, zone.coords) <= zone.radius then
            return zone
        end
    end
    return nil
end

-- =====================================================================
-- KÖR BÖLGE / GECİKMELİ LOG KUYRUĞU (yalnızca oyuncu-panel telemetrisini
-- geciktirir; Büro'nun fiziksel tespitleri -aşağıda- bundan etkilenmez)
-- =====================================================================
local function QueueOrEmit(dispatch, message)
    if dispatch.comms_lost then
        dispatch.pending_events[#dispatch.pending_events + 1] = message
    else
        Matrix.Log('LOGISTICS', message)
    end
end

local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end

    Matrix.Log('LOGISTICS', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('LOGISTICS', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end

-- =====================================================================
-- ILLEGAL FİLO: YÜKLEME
-- =====================================================================
function Matrix.Fleet.LoadFleet()
    local rows = MySQL.query.await('SELECT * FROM matrix_fleet', {}) or {}
    for _, row in ipairs(rows) do
        FleetVehicles[row.plate] = {
            plate                   = row.plate,
            vehicle_class           = row.vehicle_class,
            vin_status              = row.vin_status,
            vehicle_wear            = tonumber(row.vehicle_wear) or 0.0,
            registered_by_citizenid = row.registered_by_citizenid,
            assigned_bot_id         = row.assigned_bot_id,
            assignment_mode         = row.assignment_mode,
            verified_stolen_plate   = row.verified_stolen_plate == 1
        }
        if row.assigned_bot_id and row.assignment_mode == 'permanent' then
            PermanentVehicleByBot[row.assigned_bot_id] = row.plate
        end
    end
    Matrix.Log('LOGISTICS', '%d illegal araç filoya yüklendi.', #rows)
end

CreateThread(function()
    Matrix.Fleet.LoadFleet()
end)

-- =====================================================================
-- ILLEGAL FİLO: KAYIT / ATAMA
-- =====================================================================
function Matrix.Fleet.GetVehicle(plate)
    if type(plate) ~= 'string' then return nil end
    return FleetVehicles[plate]
end

-- QBCore'un kendi `player_vehicles` tablosunda bu plaka var mı diye bakar:
-- varsa bu, gerçekten kayıtlı bir oyuncu aracının çalıntı olduğu anlamına
-- gelir (sahte değil, hakiki bir "çalıntı"); şasi kazınmamışsa (factory) bu
-- daha güçlü bir adli iz demektir. Tablo yoksa/sorgu patlarsa sessizce false.
local function VerifyStolenPlateAgainstQbCoreVehicles(plate)
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT citizenid FROM player_vehicles WHERE plate = ?', { plate })
    end)
    if not ok or type(rows) ~= 'table' or not rows[1] then return false end
    return true
end

function Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    if type(plate) ~= 'string' or plate == '' or #plate > 32 then return false, 'bad_plate' end
    if FleetVehicles[plate] then return false, 'plate_exists' end

    vehicleClass = (vehicleClass == 'motorbike' or vehicleClass == 'car')
        and vehicleClass or Config.Logistics.Fleet.DefaultVehicleClass
    vinStatus = (vinStatus == 'factory' or vinStatus == 'scratched' or vinStatus == 'hot')
        and vinStatus or Config.Logistics.Fleet.DefaultVinStatus
    vehicleWear = Matrix.Clamp(tonumber(vehicleWear) or 0.0, 0.0, 1.0)

    local verifiedStolen = VerifyStolenPlateAgainstQbCoreVehicles(plate)

    FleetVehicles[plate] = {
        plate                   = plate,
        vehicle_class           = vehicleClass,
        vin_status              = vinStatus,
        vehicle_wear            = vehicleWear,
        registered_by_citizenid = citizenid,
        assigned_bot_id         = nil,
        assignment_mode         = nil,
        verified_stolen_plate   = verifiedStolen
    }

    MySQL.prepare([[
        INSERT INTO matrix_fleet (plate, vehicle_class, vin_status, vehicle_wear, registered_by_citizenid, verified_stolen_plate, created_at)
        VALUES (?, ?, ?, ?, ?, ?, NOW())
    ]], { plate, vehicleClass, vinStatus, vehicleWear, citizenid, verifiedStolen and 1 or 0 })

    Matrix.Log('LOGISTICS', 'İllegal araç filoya kaydedildi: %s [%s/%s] aşınma=%.2f (sahip:%s) | QB-CarDealer doğrulaması:%s',
        plate, vehicleClass, vinStatus, vehicleWear, tostring(citizenid), tostring(verifiedStolen))
    return true
end

function Matrix.Fleet.AssignPermanent(plate, botId)
    local vehicle = FleetVehicles[plate]
    if not vehicle then return false, 'vehicle_not_found' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    if vehicle.assigned_bot_id and vehicle.assigned_bot_id ~= botId then
        return false, 'vehicle_assigned_elsewhere'
    end
    if PermanentVehicleByBot[botId] and PermanentVehicleByBot[botId] ~= plate then
        return false, 'bot_already_has_vehicle'
    end

    vehicle.assigned_bot_id = botId
    vehicle.assignment_mode = 'permanent'
    PermanentVehicleByBot[botId] = plate

    MySQL.prepare('UPDATE matrix_fleet SET assigned_bot_id = ?, assignment_mode = ? WHERE plate = ?',
        { botId, 'permanent', plate })

    Matrix.Log('LOGISTICS', 'Araç %s -> Bot #%d (%s) kalıcı olarak atandı.', plate, botId, bot.name)
    return true
end

function Matrix.Fleet.UnassignPermanent(plate)
    local vehicle = FleetVehicles[plate]
    if not vehicle or not vehicle.assigned_bot_id then return false end

    PermanentVehicleByBot[vehicle.assigned_bot_id] = nil
    vehicle.assigned_bot_id = nil
    vehicle.assignment_mode = nil

    MySQL.prepare('UPDATE matrix_fleet SET assigned_bot_id = NULL, assignment_mode = NULL WHERE plate = ?', { plate })

    Matrix.Log('LOGISTICS', 'Araç %s serbest bırakıldı (kalıcı atama kaldırıldı).', plate)
    return true
end

function Matrix.Fleet.RecordAlprHit(plate, dnaId, organizationSignature, trapHouseId)
    MySQL.prepare([[
        INSERT INTO matrix_alpr_hits (plate, fingerprint_dna_id, organization_signature, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { plate, dnaId or 'UNKNOWN', organizationSignature or 'UNKNOWN', trapHouseId })
end

-- Araç çatışmada/baskında polis çemberinde kalırsa: filodan hard-delete,
-- adli laboratuvarda kalıcı bir kanıt katsayısı olarak mühürlenir.
function Matrix.Fleet.SeizeVehicle(plate, cause, dnaId, coords)
    local vehicle = FleetVehicles[plate]
    if not vehicle then return false end

    local certainty = Config.Logistics.Fleet.SeizureSealCertainty[vehicle.vin_status]
        or Config.Logistics.Fleet.SeizureSealCertainty[Config.Logistics.Fleet.DefaultVinStatus]

    -- QB-CarDealer'da doğrulanmış gerçek bir çalıntı plaka, davayı güçlendirir.
    if vehicle.verified_stolen_plate then
        certainty = Matrix.Clamp(certainty + 0.03, 0.0, 1.0)
    end

    local cx, cy, cz = 0.0, 0.0, 0.0
    if IsValidCoords(coords) then cx, cy, cz = coords.x, coords.y, coords.z end

    MySQL.prepare([[
        INSERT INTO matrix_vehicle_seizures (
            plate, vin_status, vehicle_wear, fingerprint_dna_id, organization_signature,
            seizure_cause, seal_certainty, coords_x, coords_y, coords_z, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        plate, vehicle.vin_status, vehicle.vehicle_wear, dnaId or 'UNKNOWN',
        vehicle.registered_by_citizenid or 'UNKNOWN', cause or 'unknown', certainty, cx, cy, cz
    })

    local deletedOk = pcall(function()
        MySQL.query.await('DELETE FROM matrix_fleet WHERE plate = ?', { plate })
    end)

    if vehicle.assigned_bot_id then PermanentVehicleByBot[vehicle.assigned_bot_id] = nil end
    ActiveVehicleLocks[plate] = nil
    FleetVehicles[plate] = nil

    Matrix.Log('LOGISTICS', '[FİLO KAYIP: %s MÜHÜRLENDİ VE FİLODAN SİLİNDİ] Sebep:%s | VIN:%s | Mühür-Kesinlik:%.2f | SQL Silindi:%s',
        plate, tostring(cause or 'unknown'), vehicle.vin_status, certainty, tostring(deletedOk))

    return true
end

-- Bir bot bağlamı olmadan (örn. baskında bulunan boş araç) doğrudan tetiklenebilen giriş noktası.
function Matrix.Logistics.OnVehicleEncircled(plate, cause)
    local vehicle = Matrix.Fleet.GetVehicle(plate)
    if not vehicle then return false end

    local usingBotId = ActiveVehicleLocks[plate] or vehicle.assigned_bot_id
    local bot = usingBotId and Matrix.Bots[usingBotId]

    local dnaId, coords = 'UNKNOWN', nil
    if bot then
        dnaId = bot.dna_id
        local dispatch = ActiveDispatches[usingBotId]
        coords = (dispatch and dispatch.last_coords) or bot.state.coords
    end

    return Matrix.Fleet.SeizeVehicle(plate, cause or 'police_encirclement', dnaId, coords)
end

-- =====================================================================
-- TOPTANCI İLİŞKİ MATRİSİ & DEAD DROP LOJİSTİĞİ
-- =====================================================================
Matrix.Supplier = Matrix.Supplier or {}

local SupplierTrustCache = {} -- 'citizenid#supplierId' -> { citizenid, supplier_id, trust, late_payments, forensic_leaks }
local ActiveDrops        = {} -- dropId -> { supplier_id, citizenid, requested_at, expires_at }
local DropHeat            = {} -- dropId -> siber yoğunluk (kullanımla büyür, zamanla söner)

local function TrustKey(citizenid, supplierId)
    return tostring(citizenid) .. '#' .. tostring(supplierId)
end

local function GetDropConfig(dropId)
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if drop.id == dropId then return drop end
    end
    return nil
end

local function FindActiveDeadDropAt(coords)
    for dropId, drop in pairs(ActiveDrops) do
        local cfg = GetDropConfig(dropId)
        if cfg and VectorDistance(coords, cfg.coords) <= cfg.radius then
            return dropId, drop, cfg
        end
    end
    return nil
end

function Matrix.Supplier.LoadTrust()
    local rows = MySQL.query.await('SELECT * FROM matrix_supplier_trust', {}) or {}
    for _, row in ipairs(rows) do
        SupplierTrustCache[TrustKey(row.citizenid, row.supplier_id)] = {
            citizenid       = row.citizenid,
            supplier_id     = row.supplier_id,
            trust           = tonumber(row.trust) or Config.Supplier.DefaultTrust,
            late_payments   = row.late_payments or 0,
            forensic_leaks  = row.forensic_leaks or 0,
            -- Basitleştirme: pasif sürüklenme saati her sunucu (yeniden)
            -- başlangıcında sıfırlanır (DB'deki updated_at datetime string'ini
            -- epoch'a çevirmeye gerek yok); kalıcı olan sadece `trust`'ın
            -- kendisidir, drift saati her boot'ta yeniden başlar - bu, gerçek
            -- ilişki değerini bozmayan kabul edilebilir bir sadeleştirmedir.
            last_touched    = Matrix.Now()
        }
    end
    Matrix.Log('LOGISTICS', '%d toptancı güven ilişkisi yüklendi.', #rows)
end

CreateThread(function()
    Matrix.Supplier.LoadTrust()
end)

-- FORMÜL (pasif güven sürüklenmesi / "Newton soğuma yasası" tarzı üstel yaklaşım):
--   gap        = hedef - guven
--   kapanan    = gap * (1 - (1 - gunluk_oran) ^ gecen_gun)
--   guven'     = guven + kapanan
-- gunluk_oran sabit bir günlük "kapanma yüzdesi" olduğundan (örn. 0.02),
-- (1-oran)^gun ifadesi kesirli günler için de matematiksel olarak tutarlıdır
-- (sürekli bileşik faiz formülünün ayrık günlük örneklemesi). Sunucu kapalıyken
-- geçen süre de dahildir (lazy: sadece bu kayıt tekrar okunduğunda hesaplanır,
-- ekstra bir tick/thread GEREKTİRMEZ -> 0 Resmon).
local function ApplyPassiveTrustDrift(rec)
    local now = Matrix.Now()
    local elapsedDays = (now - (rec.last_touched or now)) / 86400.0
    rec.last_touched = now
    if elapsedDays <= 0.0 then return end

    local target = Config.Supplier.PassiveTrustRecoveryTarget
    local closedFraction = 1.0 - ((1.0 - Config.Supplier.PassiveTrustRecoveryPerRealDay) ^ elapsedDays)
    rec.trust = Matrix.Clamp(rec.trust + ((target - rec.trust) * closedFraction), 0.0, 1.0)
end

function Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    local key = TrustKey(citizenid, supplierId)
    local rec = SupplierTrustCache[key]
    if not rec then
        rec = { citizenid = citizenid, supplier_id = supplierId, trust = Config.Supplier.DefaultTrust,
                late_payments = 0, forensic_leaks = 0, last_touched = Matrix.Now() }
        SupplierTrustCache[key] = rec
    else
        ApplyPassiveTrustDrift(rec)
    end
    return rec
end

function Matrix.Supplier.GetTrust(citizenid, supplierId)
    return Matrix.Supplier.GetTrustRecord(citizenid, supplierId).trust
end

local function PersistTrust(rec)
    MySQL.prepare([[
        INSERT INTO matrix_supplier_trust (citizenid, supplier_id, trust, late_payments, forensic_leaks, updated_at)
        VALUES (?, ?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE trust = VALUES(trust), late_payments = VALUES(late_payments),
            forensic_leaks = VALUES(forensic_leaks), updated_at = NOW()
    ]], { rec.citizenid, rec.supplier_id, rec.trust, rec.late_payments, rec.forensic_leaks })
end

-- FORMÜL: price_multiplier = clamp(1.0 + (1.0-trust)*PriceMultiplierGain, floor, ceiling)
-- Yorum: güven DÜŞTÜKÇE fiyat çarpanı DOĞRUSAL yükselir (ters ilişki);
-- trust=1.0 (tam güven) -> çarpan=1.0 (taban fiyat); trust=0.0 -> çarpan
-- tavana (PriceMultiplierCeiling) yakın. GetTrust -> GetTrustRecord
-- zincirinde ApplyPassiveTrustDrift LAZY olarak çalışır, yani bu fonksiyon
-- HER ÇAĞRILDIĞINDA güncel (drift uygulanmış) trust'ı görür.
function Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = 1.0 + ((1.0 - trust) * Config.Supplier.PriceMultiplierGain)
    return Matrix.Clamp(mult, Config.Supplier.PriceMultiplierFloor, Config.Supplier.PriceMultiplierCeiling)
end

-- Güven eşiğin altına düşerse toptancı konumu Büro'ya sızdırır / infaz mangası yollar.
function Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    -- Bu dosyada oyuncuya özel bir trap house izleyicisi yok; deterministik ve
    -- keyfi olmayan bir seçim olarak en düşük ID'li (ilk kurulan) trap house'u
    -- Büro'ya işaret ediyoruz (RNG yok).
    local targetId = nil
    for id in pairs(Matrix.TrapHouses) do
        if not targetId or id < targetId then targetId = id end
    end
    if targetId then
        Matrix.Bureau.ReceiveSnitchLeak(targetId)
    end

    Matrix.Log("LOGISTICS", "[İHANET] Toptancı #%d güven eşiğinin altına düştü: %s deşifre edildi / infaz mangası yolda.",
        supplierId, tostring(citizenid))
    TriggerClientEvent('matrix:client:executeHitSquad', -1, citizenid, supplierId)
end

function Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    rec.late_payments = rec.late_payments + 1
    rec.trust = Matrix.Clamp(rec.trust - Config.Supplier.TrustLatePaymentPenalty, 0.0, 1.0)
    PersistTrust(rec)

    Matrix.Log('LOGISTICS', 'Toptancı #%d güveni düştü (gecikmiş ödeme): %s -> %.2f',
        supplierId, tostring(citizenid), rec.trust)

    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    end
    return rec.trust
end

function Matrix.Supplier.RequestDrop(citizenid, dropId)
    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then return false, 'bad_drop' end
    if ActiveDrops[dropId] then return false, 'already_active' end

    local rec = Matrix.Supplier.GetTrustRecord(citizenid, dropCfg.supplier_id)
    if rec.trust < Config.Supplier.SupplyCutTrustThreshold then
        return false, 'supply_cut'
    end

    ActiveDrops[dropId] = {
        supplier_id  = dropCfg.supplier_id,
        citizenid    = citizenid,
        requested_at = Matrix.Now(),
        expires_at   = Matrix.Now() + Config.Supplier.PickupWindowSeconds
    }

    local priceMultiplier = Matrix.Supplier.GetPriceMultiplier(citizenid, dropCfg.supplier_id)

    Matrix.Log('LOGISTICS', 'Dead drop #%d (%s) açıldı: toptancı #%d, güven=%.2f, fiyat çarpanı=x%.2f, pencere=%ds',
        dropId, dropCfg.label, dropCfg.supplier_id, rec.trust, priceMultiplier, Config.Supplier.PickupWindowSeconds)

    return true, { price_multiplier = priceMultiplier, expires_in = Config.Supplier.PickupWindowSeconds, coords = dropCfg.coords }
end

-- actorRef: teslimi fiilen kimin/hangi botun yaptığı (adli parmak izi kalitesi
-- için); creditCitizenid: güven güncellemesinin hangi oyuncuya işleneceği
-- (bot bir oyuncu adına teslim alıyorsa güven o oyuncuya yazılır).
function Matrix.Supplier.OnPickup(actorRef, dropId, creditCitizenid)
    local drop = ActiveDrops[dropId]
    if not drop then return false, 'no_active_drop' end
    if Matrix.Now() > drop.expires_at then
        ActiveDrops[dropId] = nil
        return false, 'window_expired'
    end

    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then return false, 'bad_drop' end

    local actor = Matrix.ResolveActor(actorRef)
    local fingerprintQuality = actor and Matrix.Forensics.ComputeFingerprintQuality(actor) or 1.0
    local forensicTraceLeft = fingerprintQuality < Config.Supplier.ForensicTraceQualityThreshold
    local heat = DropHeat[dropId] or 0.0

    local citizenid = creditCitizenid or drop.citizenid
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, drop.supplier_id)

    if forensicTraceLeft or heat > 0.0 then
        local penalty = Config.Supplier.TrustForensicLeakPenalty * (1.0 + (heat * Config.Supplier.TrustHeatmapPenaltyFactor))
        rec.trust = Matrix.Clamp(rec.trust - penalty, 0.0, 1.0)
        if forensicTraceLeft then rec.forensic_leaks = rec.forensic_leaks + 1 end
    else
        rec.trust = Matrix.Clamp(rec.trust + Config.Supplier.TrustRecoveryPerCleanPickup, 0.0, 1.0)
    end
    PersistTrust(rec)

    DropHeat[dropId] = math_min(heat + Config.Supplier.DropHeatGrowthPerUse, 10.0)
    ActiveDrops[dropId] = nil

    MySQL.prepare([[
        INSERT INTO matrix_dead_drop_events (drop_id, supplier_id, citizenid, heat_at_pickup, forensic_trace_left, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { dropId, drop.supplier_id, citizenid, heat, forensicTraceLeft and 1 or 0 })

    Matrix.Log('LOGISTICS', 'Dead drop #%d (%s) teslim alındı: %s | heat=%.2f | iz=%s | güven=%.2f',
        dropId, dropCfg.label, tostring(citizenid), heat, tostring(forensicTraceLeft), rec.trust)

    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, drop.supplier_id)
    end

    return true, { heat = heat, forensic_trace_left = forensicTraceLeft, trust = rec.trust }
end

-- Drop heat sönümü + süresi dolan pencerelerin temizliği (dakikalık, ayrı thread).
CreateThread(function()
    while true do
        Wait(60000)
        for dropId, heat in pairs(DropHeat) do
            DropHeat[dropId] = math_max(heat - Config.Supplier.DropHeatDecayPerMinute, 0.0)
        end

        local now = Matrix.Now()
        for dropId, drop in pairs(ActiveDrops) do
            if now > drop.expires_at then
                ActiveDrops[dropId] = nil
                Matrix.Log('LOGISTICS', 'Dead drop #%d penceresi süresi doldu, teslim alınmadı.', dropId)
            end
        end
    end
end)

-- =====================================================================
-- KALICI ÖLÜM (PERMADEATH & HARD-DELETE)
-- =====================================================================
function Matrix.Logistics.OnDealerEliminated(botId, cause)
    local bot = Matrix.Bots[botId]
    if not bot then return false end

    local dispatch = ActiveDispatches[botId]
    local plateToSeize = (dispatch and dispatch.plate) or PermanentVehicleByBot[botId]
    local lastCoords = (dispatch and dispatch.last_coords) or bot.state.coords
    local dnaId = bot.dna_id

    if dispatch then
        if dispatch.plate then ActiveVehicleLocks[dispatch.plate] = nil end
        ActiveDispatches[botId] = nil
    end

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
    end

    local deletedOk = pcall(function()
        MySQL.query.await('DELETE FROM matrix_bots WHERE id = ?', { botId })
    end)

    Matrix.Persistence.dirtyBots[botId] = nil
    Matrix.Bots[botId] = nil

    Matrix.Log('LOGISTICS', '[LOJİSTİK KAYIP: DEALER_ID %d KALICI OLARAK DE-REGİSTRE EDİLDİ] Sebep:%s | SQL Silindi:%s',
        botId, tostring(cause or 'unknown'), tostring(deletedOk))

    if plateToSeize then
        Matrix.Fleet.SeizeVehicle(plateToSeize, cause, dnaId, lastCoords)
    end

    return true
end

-- =====================================================================
-- ÇATIŞMA DİRENCİ (deterministik hasar birikimi, RNG yok)
-- =====================================================================
function Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
    local bot = Matrix.Bots[botId]
    if not bot then return false end

    rawDamage = tonumber(rawDamage) or 1.0
    if rawDamage ~= rawDamage or rawDamage < 0.0 then rawDamage = 0.0 end

    local dispatch = ActiveDispatches[botId]
    local profile = GetVehicleProfile(dispatch and dispatch.vehicle_type or Config.Logistics.DefaultVehicleType)
    local effectiveDamage = rawDamage * (1.0 - profile.CombatResistance)

    if dispatch then
        dispatch.combat_damage = dispatch.combat_damage + effectiveDamage
        Matrix.Log('LOGISTICS', 'Bot #%d çatışma hasarı: ham=%.2f direnç=%.2f etkin=%.2f birikim=%.2f/%.2f',
            botId, rawDamage, profile.CombatResistance, effectiveDamage,
            dispatch.combat_damage, Config.Logistics.CombatEliminationThreshold)

        if dispatch.combat_damage >= Config.Logistics.CombatEliminationThreshold then
            Matrix.Logistics.OnDealerEliminated(botId, 'combat')
        end
    elseif effectiveDamage >= Config.Logistics.CombatEliminationThreshold then
        Matrix.Logistics.OnDealerEliminated(botId, 'combat')
    end

    return true
end

function Matrix.Logistics.OnPoliceCollision(botId)
    return Matrix.Logistics.OnDealerEliminated(botId, 'police_collision')
end

-- =====================================================================
-- DEALER SEVK (ETA hesaplayıcı + Filo entegrasyonu)
--
-- FORMÜL (Zaman-Mesafe Sürtünme Denklemi):
--   ETA = (Mesafe / (BaseSpeed * SpeedCoefficient))
--         * (1.0 + (W_total * WeightFrictionCoefficient) * EtkinSürtünme)
--   EtkinSürtünme = FrictionMultiplier * (1.0 + vehicle_wear * WearFrictionBonus)
-- Yorum: bu, klasik "hız = mesafe/zaman" ilişkisinin TERSİNE çevrilmiş
-- (zaman = mesafe/hız) hâlidir; parantez içindeki (1 + ağırlık*k*sürtünme)
-- çarpanı ise fiziksel sürtünme kuvvetinin (F=μN benzeri) taşıdığı yükle
-- DOĞRUSAL, araç tipiyle ÇARPIMSAL arttığı bir gecikme-katsayısıdır. wear
-- bonusu ayrıca sürtünmeyi wear oranında (maks %20) şişirir - iki katman
-- (yük + araç durumu) BAĞIMSIZ ve ÇARPIMSAL bileşir. KARMAŞIKLIK: O(1)
-- (ox_inventory sorgusu hariç, tek seferlik dispatch anında; Tick() içinde
-- YENİDEN hesaplanmaz - ETA dispatch anında SABİTLENİR).
-- =====================================================================
function Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, dispatcherSrc)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.role ~= 'dealer' then return false, 'not_a_dealer' end
    if ActiveDispatches[botId] then return false, 'already_dispatched' end

    local origin = bot.state.coords
    if not IsValidCoords(origin) then return false, 'no_origin' end

    local destOk, destReason, destExtra = ValidateDestination(origin, destination)
    if not destOk then
        Matrix.Log('LOGISTICS',
            '[LOJİSTİK HATA: GEÇERSİZ HEDEF VEKTÖRÜ] Bot #%d sevk reddedildi. Sebep:%s | x=%s y=%s z=%s%s',
            botId, destReason,
            tostring(destination and destination.x), tostring(destination and destination.y), tostring(destination and destination.z),
            destExtra and (' | Mesafe:%.1fm (Limit:%.1fm)'):format(destExtra, Config.Logistics.MaxDispatchRangeMeters) or '')
        return false, destReason
    end

    -- Araç referansı çözümü: artık soyut 'car'/'motorbike' string'i kabul
    -- edilmez (oyuncu somut bir filo plakası seçer). nil/'' -> botun kalıcı
    -- aracı varsa o, yoksa yaya; 'foot' -> açıkça yaya; başka her şey plaka.
    local plate, vehicle, vehicleType, assignmentMode = nil, nil, nil, nil

    if vehicleRef == nil or vehicleRef == '' then
        plate = PermanentVehicleByBot[botId]
    elseif vehicleRef ~= 'foot' then
        plate = vehicleRef
    end

    if plate then
        vehicle = Matrix.Fleet.GetVehicle(plate)
        if not vehicle then return false, 'vehicle_not_found' end
        if vehicle.assigned_bot_id and vehicle.assigned_bot_id ~= botId then
            return false, 'vehicle_assigned_elsewhere'
        end
        if ActiveVehicleLocks[plate] and ActiveVehicleLocks[plate] ~= botId then
            return false, 'vehicle_in_use'
        end

        vehicleType    = vehicle.vehicle_class
        assignmentMode = (vehicle.assigned_bot_id == botId) and 'permanent' or 'temporary'
        ActiveVehicleLocks[plate] = botId
    else
        vehicleType = 'foot'
    end

    local profile = GetVehicleProfile(vehicleType)
    local wearBonus = vehicle and (1.0 + (vehicle.vehicle_wear * Config.Logistics.Fleet.WearFrictionBonus)) or 1.0
    local effectiveFriction = profile.FrictionMultiplier * wearBonus

    local distance    = VectorDistance(origin, destination)
    local weightTotal = GetBotInventoryWeight(bot)
    local baseSpeed    = Config.Logistics.BaseSpeedUnitsPerSecond

    -- ETA = (Mesafe / (BaseSpeed * Hiz_Katsayisi)) * (1 + (W_total * k) * Etkin_Surtunme)
    local etaSeconds = (distance / (baseSpeed * profile.SpeedCoefficient))
        * (1.0 + (weightTotal * Config.Logistics.WeightFrictionCoefficient) * effectiveFriction)
    etaSeconds = Matrix.Clamp(etaSeconds, 0.0, math_huge)

    ActiveDispatches[botId] = {
        bot_id              = botId,
        vehicle_type        = vehicleType,
        plate               = plate,
        assignment_mode     = assignmentMode,
        origin              = origin,
        destination         = destination,
        eta_total           = etaSeconds,
        elapsed             = 0.0,
        stall_remaining     = 0.0,
        breakdown_pending   = (vehicle ~= nil) and (vehicle.vehicle_wear >= Config.Logistics.Fleet.BreakdownWearThreshold),
        breakdown_triggered = false,
        weight_total        = weightTotal,
        dispatcher_src       = dispatcherSrc,
        comms_lost          = false,
        pending_events      = {},
        alpr_logged_traps   = {},
        combat_damage       = 0.0,
        last_coords         = origin,
        started_at          = Matrix.Now()
    }

    bot.state.activity = 'distribution'

    Matrix.Log('LOGISTICS',
        'Sevkiyat başlatıldı: Bot #%d [%s]%s Mesafe:%.1fm Ağırlık:%.1fg Sürtünme-Katsayı:x%.2f ETA:%.1fsn',
        botId, bot.name,
        plate and (' Plaka:%s VIN:%s Aşınma:%.2f'):format(plate, vehicle.vin_status, vehicle.vehicle_wear)
              or (' Araç:%s'):format(vehicleType),
        distance, weightTotal, wearBonus, etaSeconds)

    return true, etaSeconds
end

-- Mega-prompt'ta anılan isimle uyumluluk için ince bir takma ad.
Matrix.SevkBot = Matrix.Logistics.DispatchDealer

-- =====================================================================
-- TICK (1000ms, sıfır await — main.lua'nın ticker'ından bağımsız)
-- =====================================================================
function Matrix.Logistics.Tick()
    for botId, dispatch in pairs(ActiveDispatches) do
        local bot = Matrix.Bots[botId]
        if not bot then
            if dispatch.plate then ActiveVehicleLocks[dispatch.plate] = nil end
            ActiveDispatches[botId] = nil
        else
            local arrived = false

            if dispatch.stall_remaining > 0.0 then
                dispatch.stall_remaining = math_max(dispatch.stall_remaining - 1.0, 0.0)
                QueueOrEmit(dispatch, ('[ARIZA: MEKANİK BEKLEME] Bot #%d aracı (%s) tamir bekliyor (%.0fsn kaldı).'):format(
                    botId, tostring(dispatch.plate), dispatch.stall_remaining))
            else
                dispatch.elapsed = math_min(dispatch.elapsed + 1.0, dispatch.eta_total)
                local progress = (dispatch.eta_total > 0.0) and (dispatch.elapsed / dispatch.eta_total) or 1.0

                -- Deterministik arıza: wear eşiği geçildiyse yolun ortasında
                -- (progress >= 0.5) bir kereye mahsus sabit süreli tamir molası.
                if dispatch.breakdown_pending and not dispatch.breakdown_triggered and progress >= 0.5 then
                    dispatch.breakdown_triggered = true
                    dispatch.stall_remaining = Config.Logistics.Fleet.BreakdownStallSeconds
                    QueueOrEmit(dispatch, ('[ARIZA: MEKANİK RİSK] Bot #%d aracı (%s) yolun ortasında arızalandı, %ds tamir bekleniyor.'):format(
                        botId, tostring(dispatch.plate), Config.Logistics.Fleet.BreakdownStallSeconds))
                end

                dispatch.last_coords = LerpCoords(dispatch.origin, dispatch.destination, progress)
                bot.state.coords = dispatch.last_coords

                if progress >= 1.0 then arrived = true end
            end

            local currentCoords = dispatch.last_coords or dispatch.origin

            -- Kör bölge tespiti: sadece oyuncu-panel telemetrisini etkiler.
            local zone = FindDeadZone(currentCoords)
            local nowInDeadZone = zone ~= nil

            if nowInDeadZone and not dispatch.comms_lost then
                dispatch.comms_lost = true
                Matrix.Log('LOGISTICS', '[BAĞLANTI KESİLDİ - SİNYAL YOK] Bot #%d (%s) kör bölgeye girdi: %s',
                    botId, bot.name, zone.label)
                if type(dispatch.dispatcher_src) == 'number' and dispatch.dispatcher_src > 0 then
                    Matrix.Radio.ApplyStatic(dispatch.dispatcher_src, 1.0, 'dead_zone')
                end
            elseif (not nowInDeadZone) and dispatch.comms_lost then
                dispatch.comms_lost = false
                Matrix.Log('LOGISTICS', '[SİNYAL YENİDEN ALINDI] Bot #%d (%s) kör bölgeden çıktı, gecikmeli veri akışı %.1fsn içinde gelecek.',
                    botId, bot.name, Config.Logistics.DeadZoneLogFlushDelayMs / 1000.0)
                SetTimeout(Config.Logistics.DeadZoneLogFlushDelayMs, function()
                    FlushPendingEvents(dispatch)
                end)
            end

            -- Büro'nun fiziksel ALPR/eşkal takibi oyuncunun telsiz sinyaliyle
            -- ilgisizdir: kör bölgede de çalışır, sadece bildirimi kuyruklanıp gecikir.
            local profile = GetVehicleProfile(dispatch.vehicle_type)
            if profile.PoliceDecryptionMultiplier > 0.0 then
                local trapHouseId, trapDist = FindNearestTrapHouse(currentCoords)
                if trapHouseId and trapDist <= Config.Bureau.BaseSearchRadius then
                    local vehicle = dispatch.plate and Matrix.Fleet.GetVehicle(dispatch.plate) or nil
                    local vinMultiplier = vehicle
                        and (Config.Logistics.Fleet.VinDecryptionMultiplier[vehicle.vin_status] or 1.0)
                        or 1.0

                    Matrix.Bureau.AdvanceDecryption(
                        trapHouseId,
                        Config.Logistics.PoliceDecryptionGainPerTick * profile.PoliceDecryptionMultiplier * vinMultiplier
                    )

                    -- Plaka + dealer DNA + organizasyon imzası bağını trap house
                    -- başına bir kez kalıcı olarak mühürler (DB spam'ini önler).
                    if vehicle then
                        dispatch.alpr_logged_traps[trapHouseId] = dispatch.alpr_logged_traps[trapHouseId] or false
                        if not dispatch.alpr_logged_traps[trapHouseId] then
                            dispatch.alpr_logged_traps[trapHouseId] = true
                            Matrix.Fleet.RecordAlprHit(dispatch.plate, bot.dna_id, vehicle.registered_by_citizenid, trapHouseId)
                            QueueOrEmit(dispatch, ('[ALPR EŞLEŞMESİ] Plaka %s -> DNA %s -> Org.İmza %s (Trap #%d ile ilişkilendirildi)'):format(
                                dispatch.plate, bot.dna_id, tostring(vehicle.registered_by_citizenid), trapHouseId))
                        end
                    end
                end
            end

            QueueOrEmit(dispatch, ('Bot #%d konum güncellendi: (%.1f, %.1f, %.1f) | Kalan ETA:%.1fsn'):format(
                botId, currentCoords.x, currentCoords.y, currentCoords.z,
                math_max(dispatch.eta_total - dispatch.elapsed, 0.0) + dispatch.stall_remaining))

            if arrived then
                bot.state.coords   = dispatch.destination
                bot.state.activity = 'idle'

                QueueOrEmit(dispatch, ('[VARIŞ NOKTASINDA / AT MEET-POINT] Bot #%d (%s) hedefe ulaştı.'):format(botId, bot.name))

                if bot.state.spawned and bot.state.net_id then
                    local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
                    if ped and ped ~= 0 and DoesEntityExist(ped) then
                        SetEntityCoords(ped, dispatch.destination.x, dispatch.destination.y, dispatch.destination.z, false, false, false, false)
                    end
                end

                -- Hedefte açık bir dead drop varsa, sevk edilen dealer malı
                -- otomatik teslim alır (güven güncellemesi asıl talep sahibi oyuncuya işlenir).
                local dropId, drop = FindActiveDeadDropAt(dispatch.destination)
                if dropId then
                    Matrix.Supplier.OnPickup({ kind = 'bot', id = botId }, dropId, drop.citizenid)
                end

                if dispatch.plate then ActiveVehicleLocks[dispatch.plate] = nil end
                ActiveDispatches[botId] = nil
            end
        end
    end
end

CreateThread(function()
    local interval = Config.Logistics.DispatchTickIntervalMs or Config.Tick.IntervalMs
    while true do
        Wait(interval)
        Matrix.Logistics.Tick()
    end
end)

-- =====================================================================
-- KOMUTLAR (guard-clause hardened, Taktik Komuta Paneli)
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[LOJİSTİK]', msg } })
    else
        print(('[MATRIX:LOGISTICS:CONSOLE] %s'):format(msg))
    end
end

local DISPATCH_FAILURE_MESSAGES = {
    bad_bot_id                 = 'Geçersiz bot ID.',
    bot_missing                = 'Bot matriste bulunamadı.',
    not_a_dealer                = 'Bu bot bir dealer değil.',
    already_dispatched          = 'Bot zaten sevk halinde.',
    no_origin                  = 'Bot için bilinen bir konum yok.',
    missing_vector              = 'Hedef koordinatı eksik.',
    corrupt_vector              = 'Hedef koordinatı bozuk/geçersiz.',
    out_of_range                = 'Hedef menzil dışında.',
    vehicle_not_found            = 'Belirtilen plaka filoda kayıtlı değil.',
    vehicle_assigned_elsewhere  = 'Araç başka bir bota kalıcı olarak atanmış.',
    vehicle_in_use              = 'Araç şu anda başka bir sevkiyatta kullanılıyor.'
}

local FLEET_FAILURE_MESSAGES = {
    bad_plate                  = 'Geçersiz plaka.',
    plate_exists                = 'Bu plaka zaten filoda kayıtlı.',
    vehicle_not_found            = 'Plaka filoda bulunamadı.',
    bot_missing                = 'Bot matriste bulunamadı.',
    vehicle_assigned_elsewhere  = 'Araç başka bir bota atanmış.',
    bot_already_has_vehicle    = 'Bu bota zaten kalıcı bir araç atanmış.'
}

RegisterCommand('sevket', function(src, args)
    local botId = tonumber(args[1])
    local vehicleRef = args[2]

    if not botId then
        Reply(src, 'Kullanim: /sevket [botId] [plaka|foot]'); return
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        Reply(src, 'Meet-point için geçerli bir ped gerekli.'); return
    end
    local destination = GetEntityCoords(ped)

    local ok, etaOrReason = Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, src)
    if ok then
        Reply(src, ('Bot #%d sevk edildi. Tahmini varış: %.1f sn'):format(botId, etaOrReason))
    else
        Reply(src, DISPATCH_FAILURE_MESSAGES[etaOrReason] or ('Sevkiyat başarısız: %s'):format(tostring(etaOrReason)))
    end
end, false)

RegisterCommand('filokaydet', function(src, args)
    local plate         = args[1]
    local vehicleClass  = args[2]
    local vinStatus     = args[3]
    local vehicleWear   = tonumber(args[4])

    local citizenid = nil
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then citizenid = state.citizenid end

    local ok, reason = Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    if ok then
        Reply(src, ('Araç filoya kaydedildi: %s'):format(plate))
    else
        Reply(src, FLEET_FAILURE_MESSAGES[reason] or ('Kayıt başarısız: %s'):format(tostring(reason)))
    end
end, false)

RegisterCommand('filoata', function(src, args)
    local plate = args[1]
    local botId = tonumber(args[2])
    if type(plate) ~= 'string' or not botId then
        Reply(src, 'Kullanim: /filoata [plaka] [botId]'); return
    end

    local ok, reason = Matrix.Fleet.AssignPermanent(plate, botId)
    if ok then
        Reply(src, ('Araç %s -> Bot #%d kalıcı olarak atandı.'):format(plate, botId))
    else
        Reply(src, FLEET_FAILURE_MESSAGES[reason] or ('Atama başarısız: %s'):format(tostring(reason)))
    end
end, false)

RegisterCommand('filobirak', function(src, args)
    local plate = args[1]
    if type(plate) ~= 'string' then Reply(src, 'Kullanim: /filobirak [plaka]'); return end

    local ok = Matrix.Fleet.UnassignPermanent(plate)
    Reply(src, ok and ('Araç %s serbest bırakıldı.'):format(plate) or 'Araç bulunamadı veya kalıcı atanmamış.')
end, false)

local SUPPLIER_FAILURE_MESSAGES = {
    bad_drop         = 'Geçersiz drop.',
    already_active    = 'Bu drop zaten açık, önce teslim alın.',
    supply_cut        = 'Toptancı güveniniz çok düşük, tedarik kesildi.',
    no_active_drop    = 'Bu drop şu anda aktif değil.',
    window_expired    = 'Teslim alma penceresi doldu.'
}

RegisterCommand('dropiste', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropiste [dropId]'); return end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil çözülemedi.'); return end

    local ok, info = Matrix.Supplier.RequestDrop(citizenid, dropId)
    if ok then
        Reply(src, ('Drop #%d açıldı. Fiyat çarpanı x%.2f, %ds içinde teslim al.'):format(dropId, info.price_multiplier, info.expires_in))
    else
        Reply(src, SUPPLIER_FAILURE_MESSAGES[info] or ('Drop açılamadı: %s'):format(tostring(info)))
    end
end, false)

RegisterCommand('dropcek', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropcek [dropId]'); return end

    local dropCfg = nil
    for _, d in ipairs(Config.Supplier.DeadDrops) do
        if d.id == dropId then
            dropCfg = d
            break
        end
    end
    if not dropCfg then Reply(src, 'Geçersiz drop ID.'); return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped bulunamadı.'); return end

    local playerCoords = GetEntityCoords(ped)
    if VectorDistance(playerCoords, dropCfg.coords) > dropCfg.radius then
        Reply(src, 'Drop noktasına yeterince yakın değilsiniz.'); return
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    local ok, result = Matrix.Supplier.OnPickup({ kind = 'player', source = src }, dropId, state and state.citizenid)
    if ok then
        Reply(src, ('Teslim alındı. Heat:%.2f İz:%s Güven:%.2f'):format(result.heat, tostring(result.forensic_trace_left), result.trust))
    else
        Reply(src, SUPPLIER_FAILURE_MESSAGES[result] or ('Teslim alınamadı: %s'):format(tostring(result)))
    end
end, false)

-- =====================================================================
-- EVENT BRIDGE (guard'lı)
-- =====================================================================
RegisterNetEvent('matrix:server:reportDealerEliminated', function(botId, cause)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnDealerEliminated(botId, type(cause) == 'string' and cause or 'unknown')
end)

RegisterNetEvent('matrix:server:reportDealerPoliceCollision', function(botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnPoliceCollision(botId)
end)

RegisterNetEvent('matrix:server:reportDealerCombatDamage', function(botId, rawDamage)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
end)

RegisterNetEvent('matrix:server:registerFleetVehicle', function(plate, vehicleClass, vinStatus, vehicleWear)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    Matrix.Fleet.RegisterVehicle(state and state.citizenid, plate, vehicleClass, vinStatus, vehicleWear)
end)

RegisterNetEvent('matrix:server:assignFleetVehicle', function(plate, botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if type(plate) ~= 'string' or not botId then return end
    Matrix.Fleet.AssignPermanent(plate, botId)
end)

RegisterNetEvent('matrix:server:unassignFleetVehicle', function(plate)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' then return end
    Matrix.Fleet.UnassignPermanent(plate)
end)

RegisterNetEvent('matrix:server:reportVehicleEncircled', function(plate, cause)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' then return end
    Matrix.Logistics.OnVehicleEncircled(plate, type(cause) == 'string' and cause or 'police_encirclement')
end)

RegisterNetEvent('matrix:server:requestDeadDrop', function(dropId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    dropId = tonumber(dropId)
    if not dropId then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then Matrix.Supplier.RequestDrop(state.citizenid, dropId) end
end)

RegisterNetEvent('matrix:server:reportLatePayment', function(supplierId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    supplierId = tonumber(supplierId)
    if not supplierId then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then Matrix.Supplier.ReportLatePayment(state.citizenid, supplierId) end
end)

-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('DispatchDealer', function(botId, dest, vehicleRef, dispatcherSrc)
    return Matrix.Logistics.DispatchDealer(botId, dest, vehicleRef, dispatcherSrc)
end)
exports('ApplyCombatDamageToDealer', function(botId, dmg)
    return Matrix.Logistics.ApplyCombatDamage(botId, dmg)
end)
exports('EliminateDealer', function(botId, cause)
    return Matrix.Logistics.OnDealerEliminated(botId, cause)
end)
exports('ReportDealerPoliceCollision', function(botId)
    return Matrix.Logistics.OnPoliceCollision(botId)
end)

exports('RegisterFleetVehicle', function(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    return Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
end)
exports('AssignFleetVehicle', function(plate, botId)
    return Matrix.Fleet.AssignPermanent(plate, botId)
end)
exports('UnassignFleetVehicle', function(plate)
    return Matrix.Fleet.UnassignPermanent(plate)
end)
exports('GetFleetVehicle', function(plate)
    return Matrix.Fleet.GetVehicle(plate)
end)
exports('SeizeFleetVehicle', function(plate, cause)
    return Matrix.Logistics.OnVehicleEncircled(plate, cause)
end)

exports('GetSupplierTrust', function(citizenid, supplierId)
    return Matrix.Supplier.GetTrust(citizenid, supplierId)
end)
exports('GetSupplierPriceMultiplier', function(citizenid, supplierId)
    return Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
end)
exports('ReportSupplierLatePayment', function(citizenid, supplierId)
    return Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
end)
exports('RequestDeadDrop', function(citizenid, dropId)
    return Matrix.Supplier.RequestDrop(citizenid, dropId)
end)
exports('PickupDeadDrop', function(actorRef, dropId, creditCitizenid)
    return Matrix.Supplier.OnPickup(actorRef, dropId, creditCitizenid)
end)

-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ (herkese açık test grubu, restricted=false)
-- ETA/sürtünme, kör bölge, filo aşınması, toptancı güveni ve dead drop
-- formüllerinin hepsi burada gerçek bir sevkiyat/oyuncu eylemi beklemeden
-- manuel tetiklenebilir/gözlemlenebilir.
-- =====================================================================

-- /sevkdurum - TÜM aktif sevkiyatları (ActiveDispatches) tek ekranda listeler:
-- kalan ETA, kör-bölge/sinyal durumu, kullanılan plaka.
RegisterCommand('sevkdurum', function(src)
    local count = 0
    for botId, dispatch in pairs(ActiveDispatches) do
        count = count + 1
        local remaining = math_max(dispatch.eta_total - dispatch.elapsed, 0.0) + dispatch.stall_remaining
        Reply(src, ('Bot #%d [%s] Plaka:%s Kalan-ETA:%.1fsn Sinyal:%s Arıza-Bekliyor:%s'):format(
            botId, dispatch.vehicle_type, tostring(dispatch.plate), remaining,
            dispatch.comms_lost and 'KESİK' or 'VAR', tostring(dispatch.stall_remaining > 0.0)))
    end
    Reply(src, ('--- Toplam %d aktif sevkiyat ---'):format(count))
end, false)

-- /aracsizdurumu [plaka] - bir filo aracının aşınma/VIN/atama durumunu döker.
RegisterCommand('aracsizdurumu', function(src, args)
    local plate = args[1]
    local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
    if not vehicle then Reply(src, 'Kullanim: /aracsizdurumu [plaka]'); return end

    Reply(src, ('%s [%s/%s] Aşınma:%.3f Sahip:%s Atama:%s->%s Doğrulanmış-Çalıntı:%s'):format(
        vehicle.plate, vehicle.vehicle_class, vehicle.vin_status, vehicle.vehicle_wear,
        tostring(vehicle.registered_by_citizenid), tostring(vehicle.assignment_mode),
        tostring(vehicle.assigned_bot_id), tostring(vehicle.verified_stolen_plate)))
end, false)

-- /aracele [plaka] [sebep] - OnVehicleEncircled wrapper'ı (Hard-Delete + mühür).
RegisterCommand('aracele', function(src, args)
    local plate = args[1]
    local cause = args[2] or 'debug'
    if type(plate) ~= 'string' then Reply(src, 'Kullanim: /aracele [plaka] [sebep]'); return end

    local ok = Matrix.Logistics.OnVehicleEncircled(plate, cause)
    Reply(src, ok and ('%s ele geçirildi ve mühürlendi.'):format(plate) or 'Araç bulunamadı.')
end, false)

-- /hasarver [botId] [miktar] - ApplyCombatDamage wrapper'ı; araç tipinin
-- CombatResistance'ı formülü (etkin_hasar = ham*(1-direnç)) burada test edilir.
RegisterCommand('hasarver', function(src, args)
    local botId = tonumber(args[1])
    local amount = tonumber(args[2]) or 1.0
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /hasarver [botId] [miktar]'); return end

    Matrix.Logistics.ApplyCombatDamage(botId, amount)
    local stillAlive = Matrix.Bots[botId] ~= nil
    Reply(src, ('Bot #%d hasar aldı. Hayatta:%s'):format(botId, tostring(stillAlive)))
end, false)

-- /oldur [botId] [sebep] - OnDealerEliminated wrapper'ı (hard-delete + araç müsaderesi).
RegisterCommand('oldur', function(src, args)
    local botId = tonumber(args[1])
    local cause = args[2] or 'debug'
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /oldur [botId] [sebep]'); return end

    Matrix.Logistics.OnDealerEliminated(botId, cause)
    Reply(src, ('Bot #%d kalıcı olarak elendi.'):format(botId))
end, false)

-- /guvengoster [citizenid] [supplierId] - toptancı güvenini ve ondan türetilen
-- fiyat çarpanını gösterir; pasif drift (ApplyPassiveTrustDrift) burada da
-- lazily uygulanır (GetTrust -> GetTrustRecord üzerinden).
RegisterCommand('guvengoster', function(src, args)
    local citizenid = args[1]
    local supplierId = tonumber(args[2])
    if type(citizenid) ~= 'string' or not supplierId then
        Reply(src, 'Kullanim: /guvengoster [citizenid] [supplierId]'); return
    end

    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    Reply(src, ('%s <-> Toptancı #%d | Güven:%.3f | Fiyat-Çarpanı:x%.2f | Tedarik-Kesik:%s'):format(
        citizenid, supplierId, trust, mult, tostring(trust < Config.Supplier.SupplyCutTrustThreshold)))
end, false)

-- /gecodeme [citizenid] [supplierId] - ReportLatePayment wrapper'ı; güven
-- BetrayalTrustThreshold altına düşerse TriggerBetrayal otomatik tetiklenir.
RegisterCommand('gecodeme', function(src, args)
    local citizenid = args[1]
    local supplierId = tonumber(args[2])
    if type(citizenid) ~= 'string' or not supplierId then
        Reply(src, 'Kullanim: /gecodeme [citizenid] [supplierId]'); return
    end

    local newTrust = Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
    Reply(src, ('Gecikmiş ödeme işlendi. Yeni güven:%.3f'):format(newTrust))
end, false)

-- /dropdurum - TÜM açık dead drop'ları (ActiveDrops) ve yerel heat seviyelerini listeler.
RegisterCommand('dropdurum', function(src)
    local count = 0
    local now = Matrix.Now()
    for dropId, drop in pairs(ActiveDrops) do
        count = count + 1
        local cfg = GetDropConfig(dropId)
        Reply(src, ('Drop #%d (%s) | Sahip:%s | Kalan-Pencere:%ds | Heat:%.3f'):format(
            dropId, cfg and cfg.label or '?', tostring(drop.citizenid),
            math_max(drop.expires_at - now, 0), DropHeat[dropId] or 0.0))
    end
    Reply(src, ('--- Toplam %d açık drop ---'):format(count))
end, false)

-- /korbolgetest [x] [y] [z] - verilen koordinatın Config.Logistics.DeadZones'tan
-- birinin içinde olup olmadığını (ve hangisinin) doğrudan test eder; aktif
-- bir sevkiyat gerektirmez, saf geometri/formül testidir.
RegisterCommand('korbolgetest', function(src, args)
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not x or not y or not z then
        Reply(src, 'Kullanim: /korbolgetest [x] [y] [z]'); return
    end

    local zone = FindDeadZone(vector3(x, y, z))
    Reply(src, zone and ('Bu koordinat "%s" kör bölgesinin İÇİNDE.'):format(zone.label)
              or 'Bu koordinat hiçbir kör bölgenin içinde değil.')
end, false)
