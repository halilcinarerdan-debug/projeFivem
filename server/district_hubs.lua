-- =====================================================================
-- ★★★ KATMAN 7 [T4] FAZ 1: TOPLU SATIŞ HUB'LARI (District Distribution) ★★★
-- YENİ dosya. Mevcut hiçbir tabloya/formüle dokunmaz -- yalnızca zaten var
-- olan sistemlere (matrix_trap_stash_<id> ox_inventory stash'i, server/
-- market.lua Matrix.CashDecay.Deposit kirli-nakit hattı, server/bureau.lua
-- [T4] Matrix.Bureau.IsLockedDown) bağlanır.
--
-- F10 -> "Toplu Satış Hub Ata" (client menüsü bu resource'ta değil; burada
-- sunucu tarafı yetki/kalıcılık uç noktası hazırdır -- bkz. RegisterNetEvent
-- 'matrix:server:districtHubs:assign' ve test komutu /hubata) kritik bir
-- kavşağa bir hub atar. Atanan hub, HubDemandCycleSeconds periyodunda trap
-- house'un ortak deposundan (matrix_trap_stash_<id>) sabit/RNG'siz bir
-- miktar çeker ve MEVCUT Config.Market.StreetBasePricePerGram birim
-- fiyatıyla kirli nakite çevirir -- yeni bir ekonomi formülü İCAT EDİLMEZ.
--
-- BÜRO KİLİDİ: server/bureau.lua [T4]'ün 'matrix:internal:bureauLockdown'
-- yayınını dinler (raidIssued/raidResolved İLE AYNI pasif desen). Kilit
-- aktifken o trap house'a bağlı TÜM hub'lar dondurulur (active=0, locked=1)
-- -- demand-cycle ticker'ı onları otomatik atlar.
--
-- SIFIR RNG: bu dosyada math.random YOK.
-- =====================================================================

Matrix.DistrictHubs = Matrix.DistrictHubs or {}

local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type

local Hubs      = {}   -- [id] = { id, trap_house_id, label, coords, active, locked }
local dirtyHubs = {}

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[HUB]', msg } })
    else
        print(('[MATRIX:DISTRICT_HUBS:CONSOLE] %s'):format(msg))
    end
end

local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
end

-- =====================================================================
-- LOAD / PERSIST (LoadTrapHouses İLE AYNI kalıp)
-- =====================================================================
function Matrix.DistrictHubs.LoadHubs()
    local rows = MySQL.query.await('SELECT * FROM matrix_district_hubs', {}) or {}
    for _, row in ipairs(rows) do
        Hubs[row.id] = {
            id            = row.id,
            trap_house_id = row.trap_house_id,
            label         = row.label or ('Hub #' .. row.id),
            coords        = vector3(row.coord_x or 0.0, row.coord_y or 0.0, row.coord_z or 0.0),
            active        = row.active == 1,
            locked        = row.locked == 1
        }
    end
    Matrix.Log('DISTRICT_HUB', '%d Toplu Satis Hub RAM onbellege yuklendi.', #rows)
end

CreateThread(function()
    Matrix.DistrictHubs.LoadHubs()
end)

local function FlushDirtyHubs()
    for id in pairs(dirtyHubs) do
        local hub = Hubs[id]
        if hub then
            MySQL.prepare('UPDATE matrix_district_hubs SET active = ?, locked = ? WHERE id = ?',
                { hub.active and 1 or 0, hub.locked and 1 or 0, id })
        end
        dirtyHubs[id] = nil
    end
end

CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyHubs()
    end
end)

-- =====================================================================
-- ATAMA (F10 -> "Toplu Satış Hub Ata" arka ucu)
-- =====================================================================
function Matrix.DistrictHubs.Assign(trapHouseId, label, coords, dispatcherSrc)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses or not Matrix.TrapHouses[trapHouseId] then
        return false, 'no_trap_house'
    end
    if not IsValidCoords(coords) then return false, 'bad_coords' end

    if Matrix.Bureau and Matrix.Bureau.IsLockedDown and Matrix.Bureau.IsLockedDown(trapHouseId) then
        return false, 'bureau_lockdown'
    end

    local existingForTrap = 0
    for _, hub in pairs(Hubs) do
        if hub.trap_house_id == trapHouseId then existingForTrap = existingForTrap + 1 end
    end
    if existingForTrap >= (Config.DistrictHubs.MaxPerTrapHouse or 3) then
        return false, 'hub_limit_reached'
    end

    label = (type(label) == 'string' and label ~= '') and label or ('Hub #' .. trapHouseId)

    MySQL.insert([[
        INSERT INTO matrix_district_hubs (trap_house_id, label, coord_x, coord_y, coord_z, active, locked, created_at)
        VALUES (?, ?, ?, ?, ?, 1, 0, NOW())
    ]], { trapHouseId, label, coords.x, coords.y, coords.z },
    function(insertId)
        if not insertId then return end
        Hubs[insertId] = {
            id = insertId, trap_house_id = trapHouseId, label = label,
            coords = vector3(coords.x, coords.y, coords.z), active = true, locked = false
        }
        Matrix.Log('DISTRICT_HUB', 'Yeni Toplu Satis Hub #%d (trap #%d, %s) kuruldu.', insertId, trapHouseId, label)
    end)

    return true
end

RegisterNetEvent('matrix:server:districtHubs:assign', function(trapHouseId, label, coords)
    local src = source
    local ok, reason = Matrix.DistrictHubs.Assign(trapHouseId, label, coords, src)
    if not ok then
        Reply(src, reason == 'bureau_lockdown'
            and '[ADLI ANOMALI: BURO KILIDI DEVREDE] - Hub atamasi reddedildi.'
            or ('Hub atamasi basarisiz: %s'):format(tostring(reason)))
    else
        Reply(src, 'Toplu Satis Hub atama istegi gonderildi (async). /hublistele ile dogrulayin.')
    end
end)

-- /hubata [trapHouseId] [label] [x] [y] [z] -- F10 client menüsü henüz bu
-- resource'ta değilken de sunucu tarafını test etmek için (bkz. /traphouseekle
-- İLE AYNI disiplin: boşlukla ayrılmış argümanlar, virgül YOK).
RegisterCommand('hubata', function(src, args)
    local trapHouseId = tonumber(args[1])
    local label        = args[2]
    local x, y, z       = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
    if not trapHouseId or not x or not y or not z then
        Reply(src, 'Kullanim: /hubata [trapHouseId] [label] [x] [y] [z]'); return
    end

    local ok, reason = Matrix.DistrictHubs.Assign(trapHouseId, label, vector3(x, y, z), src)
    if not ok then
        Reply(src, ('Hub atamasi basarisiz: %s'):format(tostring(reason)))
    else
        Reply(src, 'Hub atama istegi gonderildi (async). /hublistele ile dogrulayin.')
    end
end, false)

RegisterCommand('hublistele', function(src)
    local count = 0
    for id, hub in pairs(Hubs) do
        count = count + 1
        Reply(src, ('#%d trap#%d "%s" | Aktif:%s Kilit:%s'):format(
            id, hub.trap_house_id, hub.label, tostring(hub.active), tostring(hub.locked)))
    end
    Reply(src, ('--- Toplam %d hub ---'):format(count))
end, false)


-- ★ KATMAN 7 FAZ 2: F10 "Otonom Depo Lojistigi" paneli. getRegionalFinancialReport
-- (server/market.lua) ILE AYNI desen: duz metin satirlari, yeni bir formul
-- ICAT EDILMEZ -- yalnizca yukaridaki Hubs tablosu okunur.
lib.callback.register('matrix:callback:getDistrictHubsReport', function(src)
    local lines = { '=== OTONOM DEPO LOJISTIGI (TOPLU SATIS HUBLARI) ===' }

    local count = 0
    for id, hub in pairs(Hubs) do
        count = count + 1
        local house = Matrix.TrapHouses and Matrix.TrapHouses[hub.trap_house_id]
        lines[#lines + 1] = ('Hub #%d -> Trap #%d (%s) | "%s" | Aktif:%s | Kilit:%s'):format(
            id, hub.trap_house_id, (house and house.label) or '?', hub.label,
            tostring(hub.active), tostring(hub.locked))
    end
    if count == 0 then
        lines[#lines + 1] = 'Henuz atanmis bir Toplu Satis Hub yok.'
    end

    return lines
end)

-- =====================================================================
-- BÜRO KİLİDİ DİNLEYİCİSİ (raidIssued/raidResolved İLE AYNI pasif desen)
-- =====================================================================
AddEventHandler('matrix:internal:bureauLockdown', function(trapHouseId, active)
    for id, hub in pairs(Hubs) do
        if hub.trap_house_id == trapHouseId then
            hub.locked = active and true or false
            if active then hub.active = false end
            dirtyHubs[id] = true
        end
    end
    if active then
        Matrix.Log('DISTRICT_HUB', 'Trap #%d icin tum hublar Buro Kilidi nedeniyle donduruldu.', trapHouseId)
    end
end)

-- =====================================================================
-- TALEP DÖNGÜSÜ: sabit-miktar (RNG'siz) toplu satış
-- Depo: matrix_trap_stash_<trapHouseId> (MEVCUT ox_inventory stash --
-- server/logistics.lua Matrix.Logistics.DispatchAmmoRun İLE AYNI API).
-- Ciro: Matrix.CashDecay.Deposit (server/market.lua, MEVCUT kirli-nakit
-- hattı) + Config.Market.StreetBasePricePerGram (MEVCUT birim fiyat).
-- =====================================================================
local function ProcessHubDemandCycle(hubId, hub)
    if not hub.active or hub.locked then return end
    if Matrix.Bureau and Matrix.Bureau.IsLockedDown and Matrix.Bureau.IsLockedDown(hub.trap_house_id) then return end

    local stashId = ('matrix_trap_stash_%d'):format(hub.trap_house_id)
    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], stashId)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return end

    local batchGrams = Config.DistrictHubs.SaleBatchGrams or 10

    for _, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' and (tonumber(item.count) or 0) >= batchGrams then
            local removeOk = pcall(function()
                return exports['ox_inventory']:RemoveItem(stashId, item.name, batchGrams, item.metadata)
            end)
            if removeOk then
                local proceeds = batchGrams * (Config.Market.StreetBasePricePerGram or 20.0)
                Matrix.CashDecay.Deposit(hub.trap_house_id, proceeds)
                Matrix.Log('DISTRICT_HUB', 'Hub #%d (trap #%d, %s) toplu satis: %s x%d, ciro=%.1f (kirli nakite eklendi).',
                    hubId, hub.trap_house_id, hub.label, item.name, batchGrams, proceeds)
            end
            break
        end
    end
end

CreateThread(function()
    while true do
        Wait((Config.DistrictHubs.DemandCycleSeconds or 45) * 1000)
        for hubId, hub in pairs(Hubs) do
            local ok, err = pcall(ProcessHubDemandCycle, hubId, hub)
            if not ok then
                Matrix.Log('DISTRICT_HUB', '[HATA] ProcessHubDemandCycle #%d hata verdi (yutuldu): %s', hubId, tostring(err))
            end
        end
    end
end)