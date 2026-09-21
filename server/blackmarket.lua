-- =====================================================================
-- MATRIX BLACK MARKET / server/blackmarket.lua  (KATMAN 6 — RENDEZVOUS)
--
-- Taktik Karaborsa Ticaret Ağı: illegal araç filosu, seri no silinmiş
-- silahlar, mühimmat, Yedek Namlu (bkz. server/forensics.lua /namludegistir)
-- ve sahte IMEI'li Açık Hat (Burner Phone, bkz. server/market.lua Matrix.
-- Comint) satın alma akışlarını tek bir dosyada toplar.
--
-- ★ TASARIM KARARLARI:
--   [B1] "0 RNG" prensibi HARFİYEN korunur: plaka/seri numarası üretimi
--        math.random KULLANMAZ. server/forensics.lua'nın RegisterOrGetBallisticId
--        fonksiyonundaki AYNI desen izlenir — GetGameTimer() + monoton bir
--        sayaç + girdi-türevli bir sağlama toplamı (checksum). Aynı
--        (citizenid, item, sayaç, oyun-zamanlayıcısı) girdisi HER ZAMAN
--        aynı kimliği üretir; iki ardışık satın alma ASLA çakışmaz çünkü
--        sayaç her çağrıda kesin olarak artar.
--   [B2] Ödeme bütünlüğü: Matrix.Fleet.RegisterVehicle, Matrix.Rendezvous.
--        ScheduleHandoff veya ox_inventory AddItem başarısız olursa tahsil
--        edilen nakit OTOMATİK iade edilir — oyuncu asla parasını verip
--        karşılığında hiçbir şey alamadan kalmaz.
--   [B3] Araç kataloğu yalnızca `vehicle_class` (car/motorbike) taşır —
--        server/main.lua'nın DISPATCH_VEHICLE_MODELS tablosu (sınıf bazlı
--        spawn modeli seçimi) DEĞİŞTİRİLMEDİ; katalog bu mevcut mimariyle
--        tutarlı kalması için yalnızca desteklenen sınıflardan seçim sunar.
--
-- ★ KATMAN 6 DEĞİŞİKLİĞİ (bu sürüm): "silah veya mühimmat" satın alımı
--   artık ANINDA envantere düşmez. buyWeapon/buyAmmo, ödeme başarılı
--   olduktan sonra server/rendezvous.lua'nın Matrix.Rendezvous.
--   ScheduleHandoff'unu çağırır — mal bir buluşma noktasında (satıcı NPC)
--   fiziksel olarak teslim alınır ve o handoff anında Büro pusu riski
--   taşır (bkz. server/rendezvous.lua). Matrix.Rendezvous modülü
--   YÜKLENMEMİŞSE (savunmacı geri düşüş — bkz. WARN_MISSING_RENDEZVOUS)
--   davranış ESKİ Katman 5 Ultimate haliyle BİREBİR AYNIDIR: mal doğrudan
--   ox_inventory'ye eklenir. Araç/Yedek Namlu/Açık Hat akışları bu
--   revizyondan ETKİLENMEDİ (kullanıcı talebi yalnızca silah/mühimmatı
--   kapsıyor).
-- =====================================================================


Matrix.BlackMarket = Matrix.BlackMarket or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local GetGameTimer                  = GetGameTimer
local TriggerClientEvent            = TriggerClientEvent
local TriggerEvent                  = TriggerEvent
local RegisterNetEvent              = RegisterNetEvent
local RegisterCommand               = RegisterCommand


local WARN_MISSING_RENDEZVOUS = false


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[KARABORSA]', msg } })
    else
        print(('[MATRIX:BLACKMARKET:CONSOLE] %s'):format(msg))
    end
end


-- =====================================================================
-- [B1] DETERMİNİSTİK KİMLİK ÜRETİMİ (RNG YOK)
-- =====================================================================
local purchaseSequence = 0
local function NextSequence()
    purchaseSequence = purchaseSequence + 1
    return purchaseSequence
end


local PLATE_ALPHABET = '0123456789ABCDEFGHJKLMNPQRSTUVWXYZ' -- I/O kazayla karismasin diye cikarildi


local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


--- Karaborsa aracı için kazınmış/sahte plaka üretir. RNG YOK: GetGameTimer()
--- + monoton sayaç + citizenid'den türetilmiş bir sağlama toplamı,
--- sabit-genişlikte bir alfabede kodlanır.
function Matrix.BlackMarket.GenerateScratchedPlate(citizenid)
    local seq = NextSequence()
    local raw = ('%s#%d#%d'):format(tostring(citizenid), GetGameTimer(), seq)
    local sum = ChecksumOf(raw, 11)


    local chars = {}
    local base = #PLATE_ALPHABET
    local value = sum
    for i = 1, 7 do
        local idx = (value % base) + 1
        chars[i] = PLATE_ALPHABET:sub(idx, idx)
        value = math.floor(value / base)
    end
    return 'KB' .. table.concat(chars)
end


--- Karaborsa silahı için yeni bir weapon_serial üretir. server/forensics.lua
--- /namludegistir de (barrel değişiminden sonra) AYNI fonksiyonu kullanır —
--- tek bir kimlik üretim kaynağı.
function Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItemName)
    local seq = NextSequence()
    local raw = ('%s#%s#%d#%d'):format(tostring(citizenid), tostring(weaponItemName), GetGameTimer(), seq)
    local sum = ChecksumOf(raw, 23)
    local suffix = (type(weaponItemName) == 'string' and weaponItemName:sub(-6) or 'XXXXXX'):upper()
    return ('BM-%s-%07X'):format(suffix, sum)
end


-- =====================================================================
-- KATALOG ARAMA YARDIMCILARI
-- =====================================================================
local function FindVehicleCatalogEntry(id)
    for _, v in ipairs(Config.BlackMarket.Vehicles) do
        if v.id == id then return v end
    end
    return nil
end


local function FindWeaponCatalogEntry(id)
    for _, w in ipairs(Config.BlackMarket.Weapons) do
        if w.id == id then return w end
    end
    return nil
end


local function FindAmmoCatalogEntry(id)
    for _, a in ipairs(Config.BlackMarket.Ammo or {}) do
        if a.id == id then return a end
    end
    return nil
end


local function FindBurnerPhoneCatalogEntry(id)
    for _, p in ipairs(Config.BlackMarket.BurnerPhones or {}) do
        if p.id == id then return p end
    end
    return nil
end


-- =====================================================================
-- ÖDEME
-- =====================================================================
local function ChargeCash(src, amount)
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return false, 'player_not_found' end


    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < amount then return false, 'insufficient_funds' end


    local removeOk = pcall(function()
        return player.Functions.RemoveMoney('cash', amount, 'blackmarket-purchase')
    end)
    if not removeOk then return false, 'charge_failed' end
    return true
end


local function RefundCash(src, amount)
    pcall(function()
        local player = Matrix.QBX:GetPlayer(src)
        if player then player.Functions.AddMoney('cash', amount, 'blackmarket-refund') end
    end)
end


local function LogPurchase(citizenid, itemType, itemRef, price)
    MySQL.prepare([[
        INSERT INTO matrix_blackmarket_purchases (citizenid, item_type, item_ref, price_paid, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { citizenid, itemType, tostring(itemRef), price })
end


-- =====================================================================
-- SATIN ALMA: ARAÇ  (DEĞİŞMEDİ — anında filoya kaydedilir)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buyVehicle', function(catalogId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local entry = FindVehicleCatalogEntry(catalogId)
    if not entry then Reply(src, 'Gecersiz karaborsa arac kalemi.'); return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local ok, reason = ChargeCash(src, entry.price)
    if not ok then
        Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    local plate = Matrix.BlackMarket.GenerateScratchedPlate(citizenid)
    local regOk, regReason = Matrix.Fleet.RegisterVehicle(citizenid, plate, entry.vehicle_class, 'scratched', entry.vehicle_wear)
    if not regOk then
        RefundCash(src, entry.price)
        Reply(src, ('Filo kaydi basarisiz, odeme iade edildi: %s'):format(tostring(regReason)))
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    LogPurchase(citizenid, 'vehicle', plate, entry.price)


    Reply(src, ('%s satin alindi. Plaka: %s (VIN kazinmis, illegal filoya eklendi).'):format(entry.label, plate))
    TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, plate)
    Matrix.Log('BLACKMARKET', '[SATIS] %s -> arac %s (%s) $%.0f', citizenid, entry.label, plate, entry.price)
end)


-- =====================================================================
-- ★ KATMAN 6: ORTAK RENDEZVOUS YÖNLENDİRİCİSİ (silah + mühimmat)
-- Matrix.Rendezvous modülü (server/rendezvous.lua) yüklüyse mal bir
-- buluşma noktasında teslim edilir; DEĞİLSE (savunmacı geri düşüş) mal
-- ESKİ davranışla ANINDA ox_inventory'ye eklenir — hiçbir zaman "ödedim
-- ama hiçbir şey olmadı" durumu oluşmaz.
-- =====================================================================
local function DeliverViaRendezvousOrFallback(src, citizenid, catalogType, entry, itemName, itemCount, metadata)
    if Matrix.Rendezvous and Matrix.Rendezvous.ScheduleHandoff then
        local ok, reasonOrHandoff = pcall(Matrix.Rendezvous.ScheduleHandoff, src, citizenid, {
            catalog_type = catalogType,
            catalog_id   = entry.id,
            label        = entry.label,
            item         = itemName,
            count        = itemCount or 1,
            metadata     = metadata
        })
        if ok and reasonOrHandoff then
            return true, 'rendezvous'
        end
        Matrix.Log('BLACKMARKET', '[UYARI] Matrix.Rendezvous.ScheduleHandoff basarisiz, dogrudan teslimata dusuluyor: %s',
            tostring(reasonOrHandoff))
    elseif not WARN_MISSING_RENDEZVOUS then
        WARN_MISSING_RENDEZVOUS = true
        Matrix.Log('BLACKMARKET',
            '[UYARI] Matrix.Rendezvous yuklu degil; silah/muhimmat satislari ESKI (anlik) teslimat moduna dustu.')
    end


    local addOk = pcall(function()
        return exports['ox_inventory']:AddItem(src, itemName, itemCount or 1, metadata)
    end)
    if not addOk then return false, 'inventory_full' end
    return true, 'direct'
end


-- =====================================================================
-- SATIN ALMA: SİLAH  (★ KATMAN 6: Rendezvous üzerinden teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buyWeapon', function(catalogId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local entry = FindWeaponCatalogEntry(catalogId)
    if not entry then Reply(src, 'Gecersiz karaborsa silah kalemi.'); return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local ok, reason = ChargeCash(src, entry.price)
    if not ok then
        Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    local weaponSerial = Matrix.BlackMarket.GenerateWeaponSerial(citizenid, entry.item)
    local metadata = {
        weapon_serial   = weaponSerial,
        durability      = entry.durability,
        shots_fired     = 0,
        jam_accumulator = 0.0,
        jammed          = false,
        description     = ('[KARABORSA SILAHI]\nSeri No: SILINMIS\nAsinma: %.0f%%'):format(entry.durability)
    }


    local deliverOk, mode = DeliverViaRendezvousOrFallback(src, citizenid, 'weapon', entry, entry.item, 1, metadata)
    if not deliverOk then
        RefundCash(src, entry.price)
        Reply(src, 'Silah teslimati ayarlanamadi, odeme iade edildi (envanter dolu olabilir).')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    LogPurchase(citizenid, 'weapon', weaponSerial, entry.price)


    if mode == 'rendezvous' then
        Reply(src, ('%s icin odeme alindi. Buluşma noktasi Taktik Not Defterine islendi — teslimati fiziksel olarak alman gerekiyor.'):format(entry.label))
    else
        Reply(src, ('%s satin alindi. Seri No: SILINMIS.'):format(entry.label))
    end
    TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, weaponSerial)
    Matrix.Log('BLACKMARKET', '[SATIS] %s -> silah %s (seri:%s, mod:%s) $%.0f', citizenid, entry.label, weaponSerial, mode, entry.price)
end)


-- =====================================================================
-- SATIN ALMA: MÜHİMMAT  (★ KATMAN 6: YENİ — Rendezvous üzerinden teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buyAmmo', function(catalogId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local entry = FindAmmoCatalogEntry(catalogId)
    if not entry then Reply(src, 'Gecersiz karaborsa muhimmat kalemi.'); return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local ok, reason = ChargeCash(src, entry.price)
    if not ok then
        Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    local deliverOk, mode = DeliverViaRendezvousOrFallback(src, citizenid, 'ammo', entry, entry.item, entry.count, nil)
    if not deliverOk then
        RefundCash(src, entry.price)
        Reply(src, 'Muhimmat teslimati ayarlanamadi, odeme iade edildi (envanter dolu olabilir).')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    LogPurchase(citizenid, 'ammo', entry.item, entry.price)


    if mode == 'rendezvous' then
        Reply(src, ('%s icin odeme alindi. Buluşma noktasi Taktik Not Defterine islendi.'):format(entry.label))
    else
        Reply(src, ('%s satin alindi.'):format(entry.label))
    end
    TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, entry.item)
    Matrix.Log('BLACKMARKET', '[SATIS] %s -> muhimmat %s x%d (mod:%s) $%.0f', citizenid, entry.label, entry.count, mode, entry.price)
end)


-- =====================================================================
-- SATIN ALMA: YEDEK NAMLU  (DEĞİŞMEDİ — anında teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buySpareBarrel', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local price = Config.BlackMarket.SpareBarrelPrice
    local item  = Config.BlackMarket.SpareBarrelItem


    local ok, reason = ChargeCash(src, price)
    if not ok then
        Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, Config.BlackMarket.SpareBarrelLabel, nil)
        return
    end


    local addOk = pcall(function()
        return exports['ox_inventory']:AddItem(src, item, 1)
    end)
    if not addOk then
        RefundCash(src, price)
        Reply(src, 'Yedek Namlu teslim edilemedi, odeme iade edildi (envanter dolu olabilir).')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, Config.BlackMarket.SpareBarrelLabel, nil)
        return
    end


    LogPurchase(citizenid, 'barrel', item, price)


    Reply(src, ('%s satin alindi. /namludegistir ile mevcut silahiniza takabilirsiniz.'):format(Config.BlackMarket.SpareBarrelLabel))
    TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, Config.BlackMarket.SpareBarrelLabel, item)
    Matrix.Log('BLACKMARKET', '[SATIS] %s -> Yedek Namlu $%.0f', citizenid, price)
end)


-- =====================================================================
-- SATIN ALMA: AÇIK HAT (BURNER PHONE)  (DEĞİŞMEDİ — anında teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buyBurnerPhone', function(catalogId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local entry = FindBurnerPhoneCatalogEntry(catalogId)
    if not entry then Reply(src, 'Gecersiz karaborsa kalemi.'); return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local ok, reason = ChargeCash(src, entry.price)
    if not ok then
        Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    local addOk = pcall(function()
        return exports['ox_inventory']:AddItem(src, entry.item, 1, { imei_masked = true })
    end)
    if not addOk then
        RefundCash(src, entry.price)
        Reply(src, 'Acik Hat teslim edilemedi, odeme iade edildi (envanter dolu olabilir).')
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
        return
    end


    LogPurchase(citizenid, 'burner_phone', entry.item, entry.price)


    Reply(src, ('%s satin alindi. IMEI maskeleme aktif.'):format(entry.label))
    TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, entry.item)
    Matrix.Log('BLACKMARKET', '[SATIS] %s -> Acik Hat $%.0f', citizenid, entry.price)
end)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('karaborsagecmisi', function(src, args)
    local citizenid = args[1]
    if type(citizenid) ~= 'string' then Reply(src, 'Kullanim: /karaborsagecmisi [citizenid]'); return end


    local rows = MySQL.query.await(
        'SELECT item_type, item_ref, price_paid, created_at FROM matrix_blackmarket_purchases WHERE citizenid = ? ORDER BY id DESC LIMIT 20',
        { citizenid }
    ) or {}


    Reply(src, ('--- %s icin son %d karaborsa islemi ---'):format(citizenid, #rows))
    for _, row in ipairs(rows) do
        Reply(src, ('  [%s] %s | $%.0f | %s'):format(row.item_type, tostring(row.item_ref), row.price_paid, tostring(row.created_at)))
    end
end, false)


-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('BuyBlackMarketVehicle', function(src, catalogId)
    TriggerEvent('matrix:server:blackmarket:buyVehicle', catalogId)
end)
exports('GenerateScratchedPlate', function(citizenid) return Matrix.BlackMarket.GenerateScratchedPlate(citizenid) end)
exports('GenerateWeaponSerial',  function(citizenid, weaponItem) return Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItem) end)
