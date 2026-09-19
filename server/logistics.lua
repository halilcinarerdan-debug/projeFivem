-- =====================================================================
-- MATRIX LOGISTICS / logistics.lua
-- Katman 4: Programli Lojistik Sevk & Zaman-Mesafe Surtunme Motoru +
-- Illegal Filo Tedarik ve Atama Motoru.
--
-- ★ ASYNC I/O HARDENING (v2) ★
-- Bu sürümde önceki sürümdeki iki adet bloklayıcı `MySQL.query.await`
-- çağrısı (satır ~164: matrix_fleet; satır ~376: matrix_supplier_trust)
-- tamamen kaldırılmıştır. Yerine üç sütunlu bir dayanıklılık mimarisi:
--
--   (1) ASENKRON YÜKLEME (callback-tabanlı):
--       MySQL.query('SELECT ...', {}, function(rows) ... end)
--       Ana thread hiçbir SQL yanıtı beklemez; callback geldiğinde RAM
--       cache doldurulur. I/O gecikmesi (network round-trip + DB execute)
--       ile tick süresi arasında sıfır coupling vardır.
--
--   (2) RAM CACHE + DIRTY FLAG (Single Source of Truth):
--       Fleet ve SupplierTrust bellekte tek gerçek kaynak olarak tutulur.
--       Yazma → cache'e uygula + dirty işaretle. Okuma → cache'ten O(1).
--       Ayrı bir flush thread'i (20 sn) dirty kuyruklarını batch UPSERT
--       eder (fire-and-forget, MySQL.prepare async).
--
--   (3) GRACEFUL DEGRADATION (çift katmanlı pcall):
--       Her asenkron yükleme pcall + callback-içi tip kontrolü ile
--       korunur. Tablo yoksa sistem BOŞ cache ile ayağa kalkar; warning
--       tek seferlik basılır (log spam guard).
--
-- MATEMATİKSEL NOT (fallback dayanıklılığı):
--   Fleet eksik  → DispatchDealer 'vehicle_not_found' döner; 'foot'
--                  fallback yolu zaten mevcut → simülasyon sürer.
--   Trust eksik  → GetTrustRecord DefaultTrust (0.5) ile LAZY sanal kayıt
--                  yaratır; kalıcılık olmasa bile formüller bozulmaz.
--   Yani her iki alt sistem, I/O katmanı çökse dahi DETERMİNİSTİK
--   davranışını korur; sadece diske yazma özelliği askıya alınır.
--
-- ★ KATMAN 5 REVİZYONU (bu revizyonda eklendi):
--   (a) BAKIM: Matrix.Fleet.LoadFleet() / Matrix.Supplier.LoadTrust() daha
--       önce TANIMLIYDI ama hiçbir yerden ÇAĞRILMIYORDU (bureau.lua'nın
--       LoadTrapHouses'ı ve forensics.lua'nın LoadCaches'i için var olan
--       "CreateThread(function() Matrix.X.LoadY() end)" kalıbı buradan
--       eksikti) — yani sunucu her yeniden başladığında matrix_fleet ve
--       matrix_supplier_trust RAM'e HİÇ yüklenmiyordu, sıfırdan
--       başlıyordu. İki başlangıç CreateThread'i eklendi (ilgili
--       fonksiyon tanımlarının hemen altında, diğer dosyalarla AYNI
--       yerde/kalıpta).
--   (b) KÖPRÜ TAMAMLANDI: bureau.lua'nın Büro↔Toptancı istihbarat köprüsü
--       Matrix.Supplier.ApplyBureauIntelLeak hook'unu ARIYORDU ve o dosya
--       bunu bulamayınca kendi fallback'ine (doğrudan DB yazımı + tek
--       seferlik uyarı) düşüyordu. Bu hook artık burada TANIMLIDIR ve
--       gerçek trust/dirty-flag/betrayal makinesini kullanır — fallback
--       artık HİÇ tetiklenmez.
--   (c) CO-OP HİYERARŞİ: /sevket, /filoata, /filobirak komutları artık
--       Matrix.Hierarchy.HasCommandAuthority (bkz. market.lua) ile
--       KOŞULLU olarak yetki kontrolünden geçer. Hook yüklü değilse
--       (market.lua henüz yoksa) davranış ESKİSİYLE BİREBİR AYNIDIR —
--       kısıtlama YOKTUR. DispatchDealer/AssignPermanent/UnassignPermanent
--       FONKSİYONLARININ KENDİSİ hiç değişmedi; kontrol yalnızca KOMUT
--       katmanında eklendi (başka bir kaynağın export'u doğrudan
--       çağırması bu politikadan etkilenmez).
-- =====================================================================

Matrix.Logistics = Matrix.Logistics or {}
Matrix.Fleet      = Matrix.Fleet      or {}
Matrix.Supplier   = Matrix.Supplier   or {}

-- ---------- Upvalue localization (perf) ----------
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
-- UYARI: `source` BİLİNÇLİ OLARAK localize edilmez (main.lua notu geçerli).

-- =====================================================================
-- RUNTIME STATE
-- =====================================================================
-- Planlama katmanı state'i (fiziksel yürütme main.lua'da).
local FleetVehicles         = {}   -- plate -> record
local PermanentVehicleByBot = {}   -- botId -> plate
local ActiveVehicleLocks    = {}   -- plate -> botId

-- Toptancı ilişki matrisi + dead drop runtime
local SupplierTrustCache    = {}   -- 'citizenid#supplierId' -> record
local ActiveDrops           = {}   -- dropId -> { supplier_id, citizenid, requested_at, expires_at }
local DropHeat              = {}   -- dropId -> siber yoğunluk (kullanımla büyür, saniye başına söner)

-- ---------- DIRTY FLAG KUYRUKLARI (write-behind batch persistence) ----------
-- Yorum: Bu iki set, RAM cache'in DB ile senkronize edilmesi gereken
-- anahtarlarını tutar. Ticker veya komutlar sadece cache'i mutasyona uğratır
-- ve bu sete bir anahtar atar (O(1) set insert). Flush thread'i 20 sn'de
-- bir bu setleri drene eder ve MySQL.prepare (fire-and-forget) ile yazar.
-- Böylece hiçbir kod yolu SQL yanıtı beklemez.
local dirtyFleet            = {}   -- plate -> true
local dirtySupplierTrust    = {}   -- 'citizenid#supplierId' -> true

-- ---------- GRACEFUL DEGRADATION UYARI BAYRAKLARI ----------
-- Yorum: Tablo eksikse tek seferlik uyarı basılır; sonraki çağrılarda log
-- spam'i yapılmaz (konsol I/O'nun ticker'ı bloklamaması için kritik).
local WARNED_MISSING_FLEET  = false
local WARNED_MISSING_TRUST  = false

-- =====================================================================
-- UTILITIES
-- =====================================================================
-- FORMÜL (Öklid mesafesi, NaN/inf guard'lı):
--   d = sqrt((x1-x2)² + (y1-y2)² + (z1-z2)²)
-- FiveM'in native `#(a - b)` operatörü aynı hesabı yapar; guard'lar
-- yalnızca bozuk girdiler için (#nil hatası önleyici).
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    if type(a) ~= 'userdata' and type(a) ~= 'table' then return math_huge end
    if type(b) ~= 'userdata' and type(b) ~= 'table' then return math_huge end
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

-- FORMÜL: ETA = (Mesafe / (BaseSpeed * Hız_Katsayısı)) *
--               (1 + (W_total * WeightFrictionCoefficient) * EtkinSürtünme)
--   EtkinSürtünme = FrictionMultiplier * (1 + vehicle_wear * WearFrictionBonus)
-- Yorum: klasik zaman = mesafe/hız ilişkisinin taşıma yükü ve araç aşınması
-- ile ÇARPIMSAL bozulmuş halidir. KARMAŞIKLIK: O(1).
local function ValidateDestination(origin, destination)
    if destination == nil then return false, 'missing_vector' end
    if type(destination) ~= 'table' and type(destination) ~= 'userdata' then
        return false, 'corrupt_vector'
    end

    local x, y, z = destination.x, destination.y, destination.z
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
        return false, 'corrupt_vector'
    end
    if x ~= x or y ~= y or z ~= z then return false, 'corrupt_vector' end
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

local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end

local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(coords, zone.coords) <= zone.radius then return zone end
    end
    return nil
end

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
-- ILLEGAL FLEET: ASENKRON YÜKLEME (callback-tabanlı, bloklamayan)
--
-- ★ ESKİ SÜRÜM (KALDIRILDI):
--     local rows = MySQL.query.await('SELECT * FROM matrix_fleet', {})
--   Tablo eksikse bu satır çağrıldığı coroutine'i askıda bırakıyor;
--   oxmysql hata fırlatıyor → merkezi hata zincirine sızıp yan etki
--   yaratıyordu.
--
-- ★ YENİ SÜRÜM — 3 KATMANLI KORUMA:
--   (i)  pcall(MySQL.query ...): sorgu çağrısı anında patlarsa yakalanır.
--   (ii) callback içi pcall: yanıt işlenirken tip hatası olursa yakalanır.
--   (iii) `type(rows) ~= 'table'` explicit guard: DB erişilemezse
--        callback'e nil/invalid gelebilir; buna karşı sessiz-fallback.
-- =====================================================================
function Matrix.Fleet.LoadFleet()
    local callOk, callErr = pcall(function()
        MySQL.query('SELECT * FROM matrix_fleet', {}, function(rows)
            local cbOk, cbErr = pcall(function()
                if type(rows) ~= 'table' then
                    if not WARNED_MISSING_FLEET then
                        WARNED_MISSING_FLEET = true
                        Matrix.Log('LOGISTICS',
                            '[HATA] Filo veri tabani tablosu (matrix_fleet) bulunamadi/okunamadi. Bellekteki yedek onbellek (RAM) devreye alindi; simulasyon kesintisiz suruyor.')
                    end
                    return
                end

                for _, row in ipairs(rows) do
                    if row and row.plate then
                        FleetVehicles[row.plate] = {
                            plate                   = row.plate,
                            vehicle_class           = row.vehicle_class or Config.Logistics.Fleet.DefaultVehicleClass,
                            vin_status              = row.vin_status or Config.Logistics.Fleet.DefaultVinStatus,
                            vehicle_wear            = tonumber(row.vehicle_wear) or 0.0,
                            registered_by_citizenid = row.registered_by_citizenid,
                            assigned_bot_id         = row.assigned_bot_id,
                            assignment_mode         = row.assignment_mode,
                            verified_stolen_plate   = (row.verified_stolen_plate == 1)
                        }
                        if row.assigned_bot_id and row.assignment_mode == 'permanent' then
                            PermanentVehicleByBot[row.assigned_bot_id] = row.plate
                        end
                    end
                end
                Matrix.Log('LOGISTICS', '%d illegal arac filoya yuklendi (async).', #rows)
            end)

            if not cbOk then
                Matrix.Log('LOGISTICS',
                    '[HATA] matrix_fleet callback isleme hatasi (simulasyon suruyor): %s',
                    tostring(cbErr))
            end
        end)
    end)

    if not callOk then
        if not WARNED_MISSING_FLEET then
            WARNED_MISSING_FLEET = true
            Matrix.Log('LOGISTICS',
                '[HATA] matrix_fleet sorgu cagrisi reddedildi; RAM onbellek devrede (simulasyon suruyor): %s',
                tostring(callErr))
        end
    end
end

-- ★ KATMAN 5 BAKIM: bu çağrı daha önce HİÇ YOKTU (bkz. dosya başı notu) —
-- matrix_fleet her resource restart'ında RAM'e hiç yüklenmiyordu.
-- bureau.lua/forensics.lua'daki "CreateThread(function() Matrix.X.LoadY() end)"
-- kalıbıyla BİREBİR aynı yere, aynı şekilde eklendi.
CreateThread(function()
    Matrix.Fleet.LoadFleet()
end)

-- =====================================================================
-- ILLEGAL FLEET: ASENKRON PERSISTENCE (dirty-flag batch UPSERT)
-- =====================================================================
local function MarkFleetDirty(plate)
    if plate then dirtyFleet[plate] = true end
end

local function FlushDirtyFleet()
    for plate in pairs(dirtyFleet) do
        local v = FleetVehicles[plate]
        if v then
            MySQL.prepare([[
                INSERT INTO matrix_fleet
                    (plate, vehicle_class, vin_status, vehicle_wear, registered_by_citizenid,
                     assigned_bot_id, assignment_mode, verified_stolen_plate, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                ON DUPLICATE KEY UPDATE
                    vehicle_class           = VALUES(vehicle_class),
                    vin_status              = VALUES(vin_status),
                    vehicle_wear            = VALUES(vehicle_wear),
                    registered_by_citizenid = VALUES(registered_by_citizenid),
                    assigned_bot_id         = VALUES(assigned_bot_id),
                    assignment_mode         = VALUES(assignment_mode),
                    verified_stolen_plate   = VALUES(verified_stolen_plate),
                    updated_at              = NOW()
            ]], {
                v.plate, v.vehicle_class, v.vin_status, v.vehicle_wear,
                v.registered_by_citizenid, v.assigned_bot_id, v.assignment_mode,
                v.verified_stolen_plate and 1 or 0
            })
        end
        dirtyFleet[plate] = nil
    end
end

-- =====================================================================
-- ILLEGAL FLEET: KAYIT / ATAMA (tam senkron API, RAM-önce yazar)
-- =====================================================================
function Matrix.Fleet.GetVehicle(plate)
    if type(plate) ~= 'string' then return nil end
    return FleetVehicles[plate]
end

-- Plaka doğrulama, ASENKRON olarak QB-Core `player_vehicles` tablosuna
-- sorulur. Sonuç geldiğinde RAM cache güncellenir + dirty-flag kalkar.
-- Yorum: Eski sürümdeki bloklayıcı await burada da kaldırıldı; kayıt
-- işlemi anında RAM'e yazılır, adli doğrulama "arka planda" olgunlaşır.
-- Bu, hem 0 Resmon hedefiyle hem de simülasyon dayanıklılığıyla uyumludur.
local function VerifyStolenPlateAsync(plate)
    pcall(function()
        MySQL.query('SELECT citizenid FROM player_vehicles WHERE plate = ?', { plate }, function(rows)
            local cbOk = pcall(function()
                local v = FleetVehicles[plate]
                if not v then return end
                if type(rows) == 'table' and rows[1] then
                    v.verified_stolen_plate = true
                    MarkFleetDirty(plate)
                    Matrix.Log('LOGISTICS',
                        '[QB-CORE DOĞRULAMA] %s hakiki çalıntı olarak doğrulandı (sahip: %s).',
                        plate, tostring(rows[1].citizenid))
                end
            end)
            if not cbOk then
                Matrix.Log('LOGISTICS', '[HATA] stolen-plate callback hatasi (yutuldu): %s', plate)
            end
        end)
    end)
end

function Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    if type(plate) ~= 'string' or plate == '' or #plate > 32 then return false, 'bad_plate' end
    if FleetVehicles[plate] then return false, 'plate_exists' end

    vehicleClass = (vehicleClass == 'motorbike' or vehicleClass == 'car')
        and vehicleClass or Config.Logistics.Fleet.DefaultVehicleClass
    vinStatus = (vinStatus == 'factory' or vinStatus == 'scratched' or vinStatus == 'hot')
        and vinStatus or Config.Logistics.Fleet.DefaultVinStatus
    vehicleWear = Matrix.Clamp(tonumber(vehicleWear) or 0.0, 0.0, 1.0)

    -- ★ ÖNCE RAM'e yaz (senkron, bloklamaz)
    FleetVehicles[plate] = {
        plate                   = plate,
        vehicle_class           = vehicleClass,
        vin_status              = vinStatus,
        vehicle_wear            = vehicleWear,
        registered_by_citizenid = citizenid,
        assigned_bot_id         = nil,
        assignment_mode         = nil,
        verified_stolen_plate   = false  -- async verify bunu güncelleyecek
    }
    MarkFleetDirty(plate)

    -- ★ Asenkron doğrulama: sonucu bekleyen yok; RAM sonradan güncellenir.
    VerifyStolenPlateAsync(plate)

    Matrix.Log('LOGISTICS',
        'Illegal arac filoya kaydedildi (RAM + dirty-flag): %s [%s/%s] asinma=%.2f (sahip:%s)',
        plate, vehicleClass, vinStatus, vehicleWear, tostring(citizenid))

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
    MarkFleetDirty(plate)

    Matrix.Log('LOGISTICS', 'Arac %s -> Bot #%d (%s) kalici olarak atandi.', plate, botId, bot.name)
    return true
end

function Matrix.Fleet.UnassignPermanent(plate)
    local vehicle = FleetVehicles[plate]
    if not vehicle or not vehicle.assigned_bot_id then return false end

    PermanentVehicleByBot[vehicle.assigned_bot_id] = nil
    vehicle.assigned_bot_id = nil
    vehicle.assignment_mode = nil
    MarkFleetDirty(plate)

    Matrix.Log('LOGISTICS', 'Arac %s serbest birakildi (kalici atama kaldirildi).', plate)
    return true
end

function Matrix.Fleet.RecordAlprHit(plate, dnaId, organizationSignature, trapHouseId)
    -- Fire-and-forget: asla beklenmez.
    MySQL.prepare([[
        INSERT INTO matrix_alpr_hits (plate, fingerprint_dna_id, organization_signature, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { plate, dnaId or 'UNKNOWN', organizationSignature or 'UNKNOWN', trapHouseId })
end

-- Araç çemberde kaldıysa: filodan RAM hard-delete + asenkron DB delete +
-- kalıcı adli mühür. Yorum: DELETED flag RAM'den derhal düşürülür; SQL
-- DELETE asenkron yapılır. Böylece sevkiyat akışı hiç beklemez.
function Matrix.Fleet.SeizeVehicle(plate, cause, dnaId, coords)
    local vehicle = FleetVehicles[plate]
    if not vehicle then return false end

    local certainty = Config.Logistics.Fleet.SeizureSealCertainty[vehicle.vin_status]
        or Config.Logistics.Fleet.SeizureSealCertainty[Config.Logistics.Fleet.DefaultVinStatus]

    if vehicle.verified_stolen_plate then
        certainty = Matrix.Clamp(certainty + 0.03, 0.0, 1.0)
    end

    local cx, cy, cz = 0.0, 0.0, 0.0
    if IsValidCoords(coords) then cx, cy, cz = coords.x, coords.y, coords.z end

    -- Mühür insert'i asenkron (fire-and-forget).
    MySQL.prepare([[
        INSERT INTO matrix_vehicle_seizures (
            plate, vin_status, vehicle_wear, fingerprint_dna_id, organization_signature,
            seizure_cause, seal_certainty, coords_x, coords_y, coords_z, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        plate, vehicle.vin_status, vehicle.vehicle_wear, dnaId or 'UNKNOWN',
        vehicle.registered_by_citizenid or 'UNKNOWN', cause or 'unknown', certainty, cx, cy, cz
    })

    -- FİLODAN RAM SİLME + asenkron SQL DELETE
    if vehicle.assigned_bot_id then PermanentVehicleByBot[vehicle.assigned_bot_id] = nil end
    ActiveVehicleLocks[plate] = nil
    FleetVehicles[plate] = nil
    dirtyFleet[plate] = nil

    MySQL.prepare('DELETE FROM matrix_fleet WHERE plate = ?', { plate })

    Matrix.Log('LOGISTICS',
        '[FILO KAYIP: %s MUHURLENDI VE FILODAN SILINDI] Sebep:%s | VIN:%s | Muhur-Kesinlik:%.2f',
        plate, tostring(cause or 'unknown'), vehicle.vin_status, certainty)
    return true
end

function Matrix.Logistics.OnVehicleEncircled(plate, cause)
    local vehicle = Matrix.Fleet.GetVehicle(plate)
    if not vehicle then return false end

    local usingBotId = ActiveVehicleLocks[plate] or vehicle.assigned_bot_id
    local bot = usingBotId and Matrix.Bots[usingBotId]

    local dnaId, coords = 'UNKNOWN', nil
    if bot then
        dnaId = bot.dna_id
        coords = bot.state.coords
    end

    return Matrix.Fleet.SeizeVehicle(plate, cause or 'police_encirclement', dnaId, coords)
end

-- ★ Yeni yardımcı: main.lua'nın CompleteDispatch'i tarafından çağrılır.
function Matrix.Logistics.ReleaseVehicleLock(plate)
    if plate and ActiveVehicleLocks[plate] then
        ActiveVehicleLocks[plate] = nil
    end
end

-- =====================================================================
-- TOPTANCI İLİŞKİ MATRİSİ & DEAD DROP LOJİSTİĞİ
-- =====================================================================
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

-- ★ ASENKRON TRUST YÜKLEME (eski bloklayıcı await kaldırıldı)
function Matrix.Supplier.LoadTrust()
    local callOk, callErr = pcall(function()
        MySQL.query('SELECT * FROM matrix_supplier_trust', {}, function(rows)
            local cbOk, cbErr = pcall(function()
                if type(rows) ~= 'table' then
                    if not WARNED_MISSING_TRUST then
                        WARNED_MISSING_TRUST = true
                        Matrix.Log('LOGISTICS',
                            '[HATA] Toptanci guven tablosu (matrix_supplier_trust) bulunamadi/okunamadi. RAM onbellek devrede; varsayilan trust (0.5) uzerinden simulasyon suruyor.')
                    end
                    return
                end

                for _, row in ipairs(rows) do
                    if row and row.citizenid then
                        SupplierTrustCache[TrustKey(row.citizenid, row.supplier_id)] = {
                            citizenid       = row.citizenid,
                            supplier_id     = row.supplier_id,
                            trust           = tonumber(row.trust) or Config.Supplier.DefaultTrust,
                            late_payments   = row.late_payments or 0,
                            forensic_leaks  = row.forensic_leaks or 0,
                            last_touched    = Matrix.Now()
                        }
                    end
                end
                Matrix.Log('LOGISTICS', '%d toptanci guven iliskisi yuklendi (async).', #rows)
            end)

            if not cbOk then
                Matrix.Log('LOGISTICS',
                    '[HATA] matrix_supplier_trust callback hatasi (simulasyon suruyor): %s',
                    tostring(cbErr))
            end
        end)
    end)

    if not callOk then
        if not WARNED_MISSING_TRUST then
            WARNED_MISSING_TRUST = true
            Matrix.Log('LOGISTICS',
                '[HATA] matrix_supplier_trust sorgu cagrisi reddedildi; RAM onbellek devrede: %s',
                tostring(callErr))
        end
    end
end

-- ★ KATMAN 5 BAKIM: bu çağrı daha önce HİÇ YOKTU (bkz. dosya başı notu) —
-- matrix_supplier_trust her resource restart'ında RAM'e hiç yüklenmiyordu
-- (GetTrustRecord'un lazy-sanal-kayıt fallback'i formülleri bozmuyordu,
-- ama restart öncesi KALICI trust değerleri sessizce görmezden geliniyordu).
CreateThread(function()
    Matrix.Supplier.LoadTrust()
end)

-- =====================================================================
-- TRUST: DIRTY-FLAG + LAZY DRIFT + ASENKRON PERSISTENCE
-- =====================================================================

-- FORMÜL (pasif güven sürüklenmesi / Newton soğuma yasası):
--   gap       = hedef - güven
--   kapanan   = gap * (1 - (1 - gunluk_oran)^gecen_gun)
--   güven'    = güven + kapanan
-- Yorum: sürekli bileşik faizin ayrık günlük örneklemesidir; sunucu kapalı
-- olsa bile geçen süre dahildir (lazy — sadece kayıt okunduğunda hesaplanır,
-- ekstra tick GEREKTİRMEZ → 0 Resmon).
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
        -- LAZY SANAL KAYIT: DB eksik olsa bile varsayılan trust ile akış sürer.
        rec = {
            citizenid = citizenid, supplier_id = supplierId,
            trust = Config.Supplier.DefaultTrust,
            late_payments = 0, forensic_leaks = 0,
            last_touched = Matrix.Now()
        }
        SupplierTrustCache[key] = rec
    else
        ApplyPassiveTrustDrift(rec)
    end
    return rec
end

function Matrix.Supplier.GetTrust(citizenid, supplierId)
    return Matrix.Supplier.GetTrustRecord(citizenid, supplierId).trust
end

local function MarkSupplierTrustDirty(citizenid, supplierId)
    dirtySupplierTrust[TrustKey(citizenid, supplierId)] = true
end

local function FlushDirtySupplierTrust()
    for key in pairs(dirtySupplierTrust) do
        local rec = SupplierTrustCache[key]
        if rec then
            MySQL.prepare([[
                INSERT INTO matrix_supplier_trust
                    (citizenid, supplier_id, trust, late_payments, forensic_leaks, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, NOW(), NOW())
                ON DUPLICATE KEY UPDATE
                    trust          = VALUES(trust),
                    late_payments  = VALUES(late_payments),
                    forensic_leaks = VALUES(forensic_leaks),
                    updated_at     = NOW()
            ]], { rec.citizenid, rec.supplier_id, rec.trust, rec.late_payments, rec.forensic_leaks })
        end
        dirtySupplierTrust[key] = nil
    end
end

-- FORMÜL: price_multiplier = clamp(1 + (1-trust)*Gain, floor, ceiling)
-- Yorum: trust düştükçe fiyat DOĞRUSAL yükselir; GetTrustRecord her çağrıda
-- lazy drift uyguladığından burada her zaman güncel trust görülür.
function Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = 1.0 + ((1.0 - trust) * Config.Supplier.PriceMultiplierGain)
    return Matrix.Clamp(mult, Config.Supplier.PriceMultiplierFloor, Config.Supplier.PriceMultiplierCeiling)
end

function Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    local targetId = nil
    for id in pairs(Matrix.TrapHouses or {}) do
        if not targetId or id < targetId then targetId = id end
    end
    if targetId then
        Matrix.Bureau.ReceiveSnitchLeak(targetId)
    end

    Matrix.Log('LOGISTICS',
        '[IHANET] Toptanci #%d guven esiginin altina dustu: %s desifre edildi / infaz mangasi yolda.',
        supplierId, tostring(citizenid))
    TriggerClientEvent('matrix:client:executeHitSquad', -1, citizenid, supplierId)
end

function Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    rec.late_payments = rec.late_payments + 1
    rec.trust = Matrix.Clamp(rec.trust - Config.Supplier.TrustLatePaymentPenalty, 0.0, 1.0)
    MarkSupplierTrustDirty(citizenid, supplierId)

    Matrix.Log('LOGISTICS', 'Toptanci #%d guveni dustu (gecikmis odeme): %s -> %.2f',
        supplierId, tostring(citizenid), rec.trust)

    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    end
    return rec.trust
end

-- ★ KATMAN 5: BÜRO ↔ TOPTANCI İSTİHBARAT KÖPRÜSÜ TAMAMLANDI.
-- bureau.lua'nın Matrix.Bureau.TickDropForensics'i, birikmiş dead-drop adli
-- kesinliği eşiği (BureauLeakCertaintyThreshold) aştığında bu hook'u
-- `pcall(Matrix.Supplier.ApplyBureauIntelLeak, citizenid, supplierId,
-- penalty, dropId)` şeklinde çağırır. Önceden bu fonksiyon YOKTU, bu yüzden
-- bureau.lua kendi fallback'ine (doğrudan DB yazımı + tek seferlik uyarı)
-- düşüyordu — o fallback hâlâ mevcut (hook silinir/bozulursa güvenlik ağı),
-- ama artık ASLA tetiklenmemesi beklenir. ReportLatePayment İLE AYNI
-- trust/dirty-flag/betrayal makinesini kullanır; TEK FARKI ceza kaynağının
-- "gecikmiş ödeme" değil "Büro'nun laboratuvar kesinliği" olmasıdır.
function Matrix.Supplier.ApplyBureauIntelLeak(citizenid, supplierId, penalty, dropId)
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    rec.trust = Matrix.Clamp(rec.trust - (tonumber(penalty) or 0.0), 0.0, 1.0)
    rec.forensic_leaks = rec.forensic_leaks + 1
    MarkSupplierTrustDirty(citizenid, supplierId)

    Matrix.Log('LOGISTICS',
        '[BÜRO SIZINTISI] Drop #%s üzerinden toptancı #%d güveni düştü: %s -> %.3f',
        tostring(dropId), supplierId, tostring(citizenid), rec.trust)

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

    Matrix.Log('LOGISTICS',
        'Dead drop #%d (%s) acildi: toptanci #%d, guven=%.2f, fiyat-carpani=x%.2f, pencere=%ds',
        dropId, dropCfg.label, dropCfg.supplier_id, rec.trust, priceMultiplier, Config.Supplier.PickupWindowSeconds)

    return true, {
        price_multiplier = priceMultiplier,
        expires_in       = Config.Supplier.PickupWindowSeconds,
        coords           = dropCfg.coords
    }
end

-- actorRef: teslimi fiilen kimin/hangi botun yaptığı (adli parmak izi kalitesi için).
-- creditCitizenid: trust güncellemesinin hangi oyuncuya işleneceği.
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
    MarkSupplierTrustDirty(citizenid, drop.supplier_id)

    DropHeat[dropId] = math_min(heat + Config.Supplier.DropHeatGrowthPerUse, 10.0)
    ActiveDrops[dropId] = nil

    MySQL.prepare([[
        INSERT INTO matrix_dead_drop_events (drop_id, supplier_id, citizenid, heat_at_pickup, forensic_trace_left, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { dropId, drop.supplier_id, citizenid, heat, forensicTraceLeft and 1 or 0 })

    Matrix.Log('LOGISTICS', 'Dead drop #%d (%s) teslim alindi: %s | heat=%.2f | iz=%s | guven=%.2f',
        dropId, dropCfg.label, tostring(citizenid), heat, tostring(forensicTraceLeft), rec.trust)

    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, drop.supplier_id)
    end

    return true, { heat = heat, forensic_trace_left = forensicTraceLeft, trust = rec.trust }
end

-- =====================================================================
-- DROP HEAT SÖNÜMÜ + PENCERE TEMİZLİĞİ (dakikalık, ayrı thread)
-- FORMÜL: heat' = max(0, heat - decay_per_minute)  (doğrusal sönüm)
-- =====================================================================
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
                Matrix.Log('LOGISTICS', 'Dead drop #%d penceresi suresi doldu, teslim alinmadi.', dropId)
            end
        end
    end
end)

-- =====================================================================
-- DIRTY-FLAG FLUSH THREAD (20 sn, ana ticker'ı kirletmez)
-- Yorum: İki kuyruk da MySQL.prepare (async, promise) ile yazılır; hiçbir
-- SQL yanıtı beklenmez. Batch boyutu doğal olarak dirty kuyruğunun o anki
-- büyüklüğüne eşittir; üst sınır yoktur (kuyruk zaten sadece mutasyon
-- anında O(1) insert aldığı için pratikte birkaç düzine anahtar olur).
-- =====================================================================
CreateThread(function()
    while true do
        Wait(20000)
        FlushDirtyFleet()
        FlushDirtySupplierTrust()
    end
end)

-- =====================================================================
-- KALICI ÖLÜM (PERMADEATH & HARD-DELETE)
-- Yorum: DELETE asenkron; RAM'den temizlik senkron.
-- =====================================================================
function Matrix.Logistics.OnDealerEliminated(botId, cause)
    local bot = Matrix.Bots[botId]
    if not bot then return false end

    -- Fiziksel dispatch kaydı varsa serbest bırak.
    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        local plate = Matrix.Dispatches[botId].plate
        if plate then Matrix.Logistics.ReleaseVehicleLock(plate) end
        if Matrix.DespawnDispatchEntity then Matrix.DespawnDispatchEntity(botId) end
        Matrix.Dispatches[botId] = nil
    end

    local plateToSeize = PermanentVehicleByBot[botId]
    local lastCoords = bot.state.coords
    local dnaId = bot.dna_id

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
    end

    -- Asenkron DELETE (fire-and-forget)
    MySQL.prepare('DELETE FROM matrix_bots WHERE id = ?', { botId })

    Matrix.Persistence.dirtyBots[botId] = nil
    Matrix.Bots[botId] = nil

    Matrix.Log('LOGISTICS',
        '[LOJISTIK KAYIP: DEALER_ID %d KALICI OLARAK DE-REGISTRE EDILDI] Sebep:%s',
        botId, tostring(cause or 'unknown'))

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

    local dispatch = Matrix.Dispatches and Matrix.Dispatches[botId]
    local profile = GetVehicleProfile(dispatch and dispatch.vehicle_type or Config.Logistics.DefaultVehicleType)
    local effectiveDamage = rawDamage * (1.0 - profile.CombatResistance)

    if dispatch then
        dispatch.combat_damage = (dispatch.combat_damage or 0.0) + effectiveDamage
        Matrix.Log('LOGISTICS', 'Bot #%d catisma hasari: ham=%.2f direnc=%.2f etkin=%.2f birikim=%.2f/%.2f',
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
-- DEALER SEVK PLANLAYICI (ETA hesaplayıcı + Filo entegrasyonu)
--
-- ★ REVİZE #1 UYUMU: Bu fonksiyon artık yalnızca PLANLAMA yapar
--   (ETA hesabı, kilit, ön şart kontrolü). Fiziksel yürütme main.lua'daki
--   Matrix.BeginPhysicalDispatch'e devredilir; bot origin'de spawn olur,
--   OneSync routing görevi (TaskVehicleDriveToCoord / TaskGoStraightToCoord)
--   atanır, master ticker GetEntityCoords ile gerçek konumu okur.
--
-- FORMÜL:
--   ETA = (Mesafe / (BaseSpeed * SpeedCoefficient))
--         * (1 + (W_total * WeightFrictionCoefficient) * EtkinSürtünme)
--   EtkinSürtünme = FrictionMultiplier * (1 + vehicle_wear * WearFrictionBonus)
-- Yorum: klasik "zaman = mesafe / hız" ilişkisinin, taşıma yükü (W_total)
-- ve araç aşınması (vehicle_wear) ile ÇARPIMSAL bozulmuş halidir. Fiziksel
-- F=μN analojisi: yük arttıkça etkin sürtünme kuvveti artar; araç aşınması
-- sürtünmeyi ayrıca %20'ye kadar şişirir. KARMAŞIKLIK: O(1) (+ox_inventory
-- envanter ağırlık sorgusu — dispatch anında bir kez).
-- =====================================================================
function Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, dispatcherSrc)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.role ~= 'dealer' then return false, 'not_a_dealer' end

    -- main.lua'nın fiziksel dispatch tablosu ile çift-sevk engeli:
    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        return false, 'already_dispatched'
    end

    local origin = bot.state.coords
    if not IsValidCoords(origin) then return false, 'no_origin' end

    local destOk, destReason, destExtra = ValidateDestination(origin, destination)
    if not destOk then
        Matrix.Log('LOGISTICS',
            '[LOJISTIK HATA: GECERSIZ HEDEF VEKTORU] Bot #%d sevk reddedildi. Sebep:%s',
            botId, destReason)
        return false, destReason
    end

    -- Araç referansı çözümü.
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
    local baseSpeed   = Config.Logistics.BaseSpeedUnitsPerSecond

    local etaSeconds = (distance / (baseSpeed * profile.SpeedCoefficient))
        * (1.0 + (weightTotal * Config.Logistics.WeightFrictionCoefficient) * effectiveFriction)
    etaSeconds = Matrix.Clamp(etaSeconds, 0.0, math_huge)

    Matrix.Log('LOGISTICS',
        'Sevkiyat plani: Bot #%d [%s]%s Mesafe:%.1fm Agirlik:%.1fg ETA:%.1fsn',
        botId, bot.name,
        plate and (' Plaka:%s VIN:%s Asinma:%.2f'):format(plate, vehicle.vin_status, vehicle.vehicle_wear)
              or (' Arac:%s'):format(vehicleType),
        distance, weightTotal, etaSeconds)

    -- ★ FİZİKSEL YÜRÜTMEYİ MAIN.LUA'YA DEVRET
    if Matrix.BeginPhysicalDispatch then
        local ok, reason = Matrix.BeginPhysicalDispatch(
            botId, origin, destination, plate, vehicleType, etaSeconds, dispatcherSrc
        )
        if not ok then
            -- Kilidi geri al (başlatma başarısız oldu).
            if plate then ActiveVehicleLocks[plate] = nil end
            Matrix.Log('LOGISTICS', '[SEVK BASLATILAMADI] Bot #%d Sebep:%s', botId, tostring(reason))
            return false, reason or 'dispatch_failed'
        end
    else
        -- main.lua yüklenmemiş (nadir hata) — kilidi bırakmadan plan donar.
        Matrix.Log('LOGISTICS',
            '[UYARI] BeginPhysicalDispatch exportu tanimli degil; sevk yalnizca plan olarak kayitli.')
    end

    return true, etaSeconds
end

-- Mega-prompt uyumluluk takma adı
Matrix.SevkBot = Matrix.Logistics.DispatchDealer

-- =====================================================================
-- LOGISTICS TICK: Bu dosyada artık fiziksel dispatch takibi YOKTUR
-- (main.lua'nın TickPhysicalDispatches'i bu sorumluluğu devraldı).
-- Burada yalnızca periyodik dead-drop heat sönümü ve pencere temizliği
-- yapan ayrı thread'ler döner (yukarıda tanımlı).
-- =====================================================================

-- =====================================================================
-- KATMAN 5: CO-OP KOMUTA YETKİSİ GUARD'I
-- Matrix.Hierarchy (market.lua) yüklüyse ve çağıran oyuncu
-- HasCommandAuthority değilse komut reddedilir. Hook yoksa (market.lua
-- henüz yüklü değilse) TÜM oyuncular eskisi gibi serbesttir — kısıtlama
-- yalnızca hiyerarşi sistemi fiilen mevcutken devreye girer.
-- =====================================================================
local function HasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end

    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end

-- =====================================================================
-- KOMUTLAR (guard-clause hardened)
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
    vehicle_in_use              = 'Araç şu anda başka bir sevkiyatta kullanılıyor.',
    dispatch_failed             = 'Fiziksel sevk başlatılamadı.'
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
    -- ★ KATMAN 5: ortak bot matrisine komuta, rütbe yetkisi ister.
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu emri vermek için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

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
        Reply(src, ('Bot #%d fiziksel sevke alindi. Tahmini varis: %.1f sn'):format(botId, etaOrReason))
    else
        Reply(src, DISPATCH_FAILURE_MESSAGES[etaOrReason] or ('Sevk basarisiz: %s'):format(tostring(etaOrReason)))
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
        Reply(src, ('Araç filoya kaydedildi: %s (RAM + async persist)'):format(plate))
    else
        Reply(src, FLEET_FAILURE_MESSAGES[reason] or ('Kayıt başarısız: %s'):format(tostring(reason)))
    end
end, false)

RegisterCommand('filoata', function(src, args)
    -- ★ KATMAN 5: ortak filoya kalıcı atama, rütbe yetkisi ister.
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu atamayı yapmak için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

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
    -- ★ KATMAN 5: ortak filodan kalıcı atama kaldırma, rütbe yetkisi ister.
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu işlemi yapmak için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

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
        Reply(src, ('Drop #%d açıldı. Fiyat çarpanı x%.2f, %ds içinde teslim al.'):format(
            dropId, info.price_multiplier, info.expires_in))
    else
        Reply(src, SUPPLIER_FAILURE_MESSAGES[info] or ('Drop açılamadı: %s'):format(tostring(info)))
    end
end, false)

RegisterCommand('dropcek', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropcek [dropId]'); return end

    local dropCfg = GetDropConfig(dropId)
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
        Reply(src, ('Teslim alındı. Heat:%.2f İz:%s Güven:%.2f'):format(
            result.heat, tostring(result.forensic_trace_left), result.trust))
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
-- TAKTİK DEBUG PANELİ
-- =====================================================================

RegisterCommand('aracsizdurumu', function(src, args)
    local plate = args[1]
    local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
    if not vehicle then Reply(src, 'Kullanim: /aracsizdurumu [plaka]'); return end

    Reply(src, ('%s [%s/%s] Asinma:%.3f Sahip:%s Atama:%s->%s Dogrulanmis-Calinti:%s'):format(
        vehicle.plate, vehicle.vehicle_class, vehicle.vin_status, vehicle.vehicle_wear,
        tostring(vehicle.registered_by_citizenid), tostring(vehicle.assignment_mode),
        tostring(vehicle.assigned_bot_id), tostring(vehicle.verified_stolen_plate)))
end, false)

RegisterCommand('aracele', function(src, args)
    local plate = args[1]
    local cause = args[2] or 'debug'
    if type(plate) ~= 'string' then Reply(src, 'Kullanim: /aracele [plaka] [sebep]'); return end

    local ok = Matrix.Logistics.OnVehicleEncircled(plate, cause)
    Reply(src, ok and ('%s ele gecirildi ve muhurlendi.'):format(plate) or 'Arac bulunamadi.')
end, false)

RegisterCommand('hasarver', function(src, args)
    local botId = tonumber(args[1])
    local amount = tonumber(args[2]) or 1.0
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /hasarver [botId] [miktar]'); return end

    Matrix.Logistics.ApplyCombatDamage(botId, amount)
    local stillAlive = Matrix.Bots[botId] ~= nil
    Reply(src, ('Bot #%d hasar aldi. Hayatta:%s'):format(botId, tostring(stillAlive)))
end, false)

RegisterCommand('oldur', function(src, args)
    local botId = tonumber(args[1])
    local cause = args[2] or 'debug'
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /oldur [botId] [sebep]'); return end

    Matrix.Logistics.OnDealerEliminated(botId, cause)
    Reply(src, ('Bot #%d kalici olarak elendi.'):format(botId))
end, false)

RegisterCommand('guvengoster', function(src, args)
    local citizenid = args[1]
    local supplierId = tonumber(args[2])
    if type(citizenid) ~= 'string' or not supplierId then
        Reply(src, 'Kullanim: /guvengoster [citizenid] [supplierId]'); return
    end

    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    Reply(src, ('%s <-> Toptanci #%d | Guven:%.3f | Fiyat-Carpani:x%.2f | Tedarik-Kesik:%s'):format(
        citizenid, supplierId, trust, mult, tostring(trust < Config.Supplier.SupplyCutTrustThreshold)))
end, false)

RegisterCommand('gecodeme', function(src, args)
    local citizenid = args[1]
    local supplierId = tonumber(args[2])
    if type(citizenid) ~= 'string' or not supplierId then
        Reply(src, 'Kullanim: /gecodeme [citizenid] [supplierId]'); return
    end

    local newTrust = Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
    Reply(src, ('Gecikmis odeme islendi. Yeni guven:%.3f'):format(newTrust))
end, false)

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
    Reply(src, ('--- Toplam %d acik drop ---'):format(count))
end, false)

RegisterCommand('korbolgetest', function(src, args)
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not x or not y or not z then
        Reply(src, 'Kullanim: /korbolgetest [x] [y] [z]'); return
    end

    local zone = FindDeadZone(vector3(x, y, z))
    Reply(src, zone and ('Bu koordinat "%s" kor bolgesinin ICINDE.'):format(zone.label)
              or 'Bu koordinat hicbir kor bolgenin icinde degil.')
end, false)

-- ★ Yeni debug: dirty-flag kuyruklarının ve RAM cache boyutlarının anlık
-- durumunu gösterir. Async I/O sağlığını izlemek için kritiktir.
RegisterCommand('cachedebug', function(src)
    local fleetN, dirtyFN = 0, 0
    for _ in pairs(FleetVehicles) do fleetN = fleetN + 1 end
    for _ in pairs(dirtyFleet) do dirtyFN = dirtyFN + 1 end

    local trustN, dirtyTN = 0, 0
    for _ in pairs(SupplierTrustCache) do trustN = trustN + 1 end
    for _ in pairs(dirtySupplierTrust) do dirtyTN = dirtyTN + 1 end

    Reply(src, ('Fleet RAM: %d kayit | dirty kuyruk: %d | eksik-tablo uyarisi:%s'):format(
        fleetN, dirtyFN, tostring(WARNED_MISSING_FLEET)))
    Reply(src, ('Trust RAM: %d kayit | dirty kuyruk: %d | eksik-tablo uyarisi:%s'):format(
        trustN, dirtyTN, tostring(WARNED_MISSING_TRUST)))
end, false)
