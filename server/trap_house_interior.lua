-- =====================================================================
-- MATRIX TRAP HOUSE INTERIOR / server/trap_house_interior.lua (KATMAN 6 — YENİ)
--
-- Sanal Mahalle Evi (Interior Instance): trap house'lar haritada açıkta
-- durmaz. Oyuncu haritadaki gerçek trap house koordinatına (Matrix.
-- TrapHouses[id].coords — Katman 2'den beri var olan alan, DEĞİŞTİRİLMEDİ)
-- yaklaşıp kapıyı açtığında, SetPlayerRoutingBucket ile o trap house'a
-- BİRİCİK bir bucket'a (Config.TrapHouseInterior.BucketBase + trapHouseId)
-- geçirilir ve TEK BİR paylaşımlı vanilla döküntü iç mekan kabuğuna
-- (Config.TrapHouseInterior.Shell) ışınlanır. Routing bucket, aynı fiziksel
-- koordinatları paylaşan farklı trap house'ların birbirini GÖRMEMESİNİ/
-- ETKİLEMEMESİNİ garanti eder — FiveM'in yerleşik "interior olmadan
-- interior" tekniği.
--
-- ★ ÜYELİK KAPISI: girişe yalnızca Matrix.Hierarchy'de (server/market.lua,
-- DEĞİŞTİRİLMEDİ) bir rütbesi olan oyuncular izin verilir — "Kartel'in
-- parçası olmayan biri döküntü eve giremez" mantığı.
--
-- ★ BOT ROUTING (dürüst entegrasyon notu): main.lua'nın kaynak koduna bu
-- oturumda erişim yoktu, bu yüzden "bot varışta otomatik interior'a girer"
-- akışı tam OTOMATİK bağlanamadı — bunun yerine Matrix.TrapHouseInterior.
-- RouteBotIntoInterior(botId, trapHouseId, botPedEntity) DIŞA AÇIK bir
-- fonksiyon olarak sunulur. main.lua'nın mevcut varış tespiti (Config.
-- Logistics.TrapHouseArrivalStashRadius kullanan döngü, bkz. config.lua
-- [U1] notu) bota ait ped entity handle'ını bulduğu noktada bu fonksiyonu
-- TEK SATIRLA çağırmalıdır. Bu dosya main.lua'ya dokunmadan, main.lua'nın
-- kendi kaynak koduna GÜVENMEDEN teslim edilmiştir.
-- =====================================================================

Matrix.TrapHouseInterior = Matrix.TrapHouseInterior or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber                       = tonumber
local math_huge                      = math.huge
local GetPlayerPed                   = GetPlayerPed
local GetEntityCoords                = GetEntityCoords
local TriggerClientEvent             = TriggerClientEvent
local SetPlayerRoutingBucket         = SetPlayerRoutingBucket
local SetEntityRoutingBucket         = SetEntityRoutingBucket

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[TRAP HOUSE]', msg } })
    else
        print(('[MATRIX:TRAPHOUSE:CONSOLE] %s'):format(msg))
    end
end

local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    return #(a - b)
end

-- src -> trapHouseId (oyuncu şu an hangi trap house instance'ının içinde)
local PlayerInteriorState = {}
-- trapHouseId -> { [src] = true }  (barikat/last-stand yayını için occupant listesi)
local Occupants = {}

function Matrix.TrapHouseInterior.GetBucket(trapHouseId)
    return (Config.TrapHouseInterior.BucketBase or 20000) + tonumber(trapHouseId)
end

--- door_reinforcement.lua'nın "Last Stand" yayınının hedef kitlesini
--- bulması için — yalnızca o trap house'un içindeki oyuncuları döner.
function Matrix.TrapHouseInterior.GetOccupants(trapHouseId)
    local list = {}
    for src in pairs(Occupants[trapHouseId] or {}) do
        list[#list + 1] = src
    end
    return list
end

--- server/workbench.lua'nın tezgah/paketleme odası konum kontrolü için:
--- oyuncu şu an hangi trap house instance'ının içinde (yoksa nil).
function Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    return PlayerInteriorState[src]
end

local function HasMembership(citizenid)
    if not citizenid then return false end
    if Matrix.Hierarchy and Matrix.Hierarchy.GetRank then
        return Matrix.Hierarchy.GetRank(citizenid) ~= nil
    end
    -- Matrix.Hierarchy yüklü değilse (savunmacı geri düşüş) herkese izin
    -- ver — bu modülü main.lua/market.lua olmadan test edebilmek için.
    return true
end

-- =====================================================================
-- GİRİŞ
-- =====================================================================
RegisterNetEvent('matrix:server:trapHouseInterior:enter', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    local house = trapHouseId and Matrix.TrapHouses[trapHouseId]
    if not house then Reply(src, 'Trap house bulunamadı.'); return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    if VectorDistance(coords, house.coords) > ((Config.TrapHouseInterior.EntryRadius or 1.5) + 3.0) then
        Reply(src, 'Kapıya yeterince yakın değilsiniz.')
        return
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    if not HasMembership(state and state.citizenid) then
        Reply(src, 'Bu kapı size kilitli — örgüt hiyerarşisinde kayıtlı değilsiniz.')
        return
    end

    local bucket = Matrix.TrapHouseInterior.GetBucket(trapHouseId)
    SetPlayerRoutingBucket(src, bucket)
    PlayerInteriorState[src] = trapHouseId
    Occupants[trapHouseId] = Occupants[trapHouseId] or {}
    Occupants[trapHouseId][src] = true

    local shell = Config.TrapHouseInterior.Shell
    TriggerClientEvent('matrix:client:trapHouseInterior:teleportIn', src, {
        trap_house_id = trapHouseId,
        bucket        = bucket,
        enter_coords  = shell.EnterCoords,
        workbench_pos = shell.WorkbenchPos,
        packaging_pos = shell.PackagingPos,
        exit_coords   = shell.ExitCoords,
        required_ipl  = shell.RequiredIpl,
        ambient       = {
            count     = Config.TrapHouseInterior.AmbientPedCount,
            models    = Config.TrapHouseInterior.AmbientPedModels,
            scenarios = Config.TrapHouseInterior.AmbientScenarios
        }
    })

    Matrix.Log('TRAPHOUSE', 'src=%d trap house #%d içine girdi (bucket:%d).', src, trapHouseId, bucket)
end)

-- =====================================================================
-- ÇIKIŞ
-- =====================================================================
RegisterNetEvent('matrix:server:trapHouseInterior:exit', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local trapHouseId = PlayerInteriorState[src]
    if not trapHouseId then return end

    local house = Matrix.TrapHouses[trapHouseId]
    SetPlayerRoutingBucket(src, 0)
    PlayerInteriorState[src] = nil
    if Occupants[trapHouseId] then Occupants[trapHouseId][src] = nil end

    TriggerClientEvent('matrix:client:trapHouseInterior:teleportOut', src, {
        exit_world_coords = house and house.coords or nil
    })

    Matrix.Log('TRAPHOUSE', 'src=%d trap house #%d dışına çıktı.', src, trapHouseId)
end)

AddEventHandler('playerDropped', function()
    local src = source
    local trapHouseId = PlayerInteriorState[src]
    if trapHouseId and Occupants[trapHouseId] then Occupants[trapHouseId][src] = nil end
    PlayerInteriorState[src] = nil
end)

--- ★ Bkz. dosya başı "BOT ROUTING" notu — main.lua'nın varış tespiti
--- bota ait ped entity handle'ını bulduğunda bunu çağırmalıdır.
function Matrix.TrapHouseInterior.RouteBotIntoInterior(botId, trapHouseId, botPedEntity)
    if not botPedEntity or botPedEntity == 0 then return false end
    local bucket = Matrix.TrapHouseInterior.GetBucket(trapHouseId)
    local ok = pcall(SetEntityRoutingBucket, botPedEntity, bucket)
    if ok then
        Matrix.Log('TRAPHOUSE', 'Bot #%d trap house #%d ic mekanina yonlendirildi (bucket:%d).', botId, trapHouseId, bucket)
    end
    return ok
end

-- =====================================================================
-- ★ KATMAN 6: "MÜHİMMAT / ENVANTER AMELİYATI" — F10 Canlı Kadro bot
-- aksiyon menüsüne eklenir (bkz. client/hud.lua OpenBotActionsMenu).
-- =====================================================================
local function GetBotInventoryId(botId)
    return ('dealer_%d'):format(botId)
end

--- ★ client/trap_house_client.lua'nın kapı blip'lerini/E-tetiklerini
--- çizebilmesi için trap house dünya konumlarını (id+coords+label) döner.
--- Adli/ekonomik hiçbir hassas veri taşımaz — yalnızca zaten haritada
--- bilinmesi gereken kapı konumlarıdır.
lib.callback.register('matrix:callback:getTrapHouseLocations', function(src)
    local list = {}
    for id, house in pairs(Matrix.TrapHouses or {}) do
        list[#list + 1] = { id = id, coords = house.coords, label = house.label }
    end
    return list
end)

lib.callback.register('matrix:callback:getBotInventoryItems', function(src, botId)
    botId = tonumber(botId)
    if not botId or not Matrix.Bots[botId] then return {} end

    local ok, inv = pcall(function()
        return exports['ox_inventory']:GetInventory(GetBotInventoryId(botId))
    end)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return {} end

    local list = {}
    for _, item in pairs(inv.items) do
        if type(item) == 'table' and item.name then
            list[#list + 1] = {
                slot  = item.slot,
                name  = item.name,
                label = item.label or item.name,
                count = item.count or 1
            }
        end
    end
    table.sort(list, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    return list
end)

--- Oyuncunun kendi envanterindeki [playerSlot] öğesini bota elden teslim eder.
RegisterNetEvent('matrix:server:trapHouseInterior:giveItemToBot', function(botId, playerSlot, count)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    playerSlot = tonumber(playerSlot)
    count = tonumber(count) or 1
    if not botId or not Matrix.Bots[botId] or not playerSlot or count < 1 then
        Reply(src, 'Gecersiz teslimat parametreleri.')
        return
    end

    local okSlot, slotData = pcall(function()
        return exports['ox_inventory']:GetSlot(src, playerSlot)
    end)
    if not okSlot or type(slotData) ~= 'table' or not slotData.name then
        Reply(src, 'Belirtilen slotta bir esya yok.')
        return
    end

    local transferCount = math.min(count, tonumber(slotData.count) or 1)

    local removeOk = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, slotData.name, transferCount, nil, playerSlot)
    end)
    if not removeOk then
        Reply(src, 'Esya envanterinizden cikarilamadi.')
        return
    end

    local addOk = pcall(function()
        return exports['ox_inventory']:AddItem(GetBotInventoryId(botId), slotData.name, transferCount, slotData.metadata)
    end)
    if not addOk then
        -- Bota teslim edilemedi (bot envanteri dolu olabilir) — esyayi oyuncuya iade et.
        pcall(function() return exports['ox_inventory']:AddItem(src, slotData.name, transferCount, slotData.metadata) end)
        Reply(src, 'Bot envanteri dolu, teslimat iptal edildi ve esya size iade edildi.')
        return
    end

    Reply(src, ('%s (x%d) Bot #%d envanterine teslim edildi.'):format(slotData.label or slotData.name, transferCount, botId))
    Matrix.Log('TRAPHOUSE', 'src=%d -> Bot #%d envanter teslimi: %s x%d', src, botId, slotData.name, transferCount)
end)

--- Lojistik/Inspector botu, depo botunun (fromBotId) envanterindeki bir
--- kalemi sokaktaki kurye botuna (toBotId) asenkron olarak taşır.
RegisterNetEvent('matrix:server:trapHouseInterior:transferBotToBot', function(fromBotId, toBotId, itemName, count)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    fromBotId = tonumber(fromBotId)
    toBotId   = tonumber(toBotId)
    count     = tonumber(count) or 1
    if not fromBotId or not Matrix.Bots[fromBotId] or not toBotId or not Matrix.Bots[toBotId]
        or type(itemName) ~= 'string' or count < 1 then
        Reply(src, 'Gecersiz aktarim parametreleri.')
        return
    end

    local removeOk = pcall(function()
        return exports['ox_inventory']:RemoveItem(GetBotInventoryId(fromBotId), itemName, count)
    end)
    if not removeOk then
        Reply(src, ('Bot #%d envanterinde yeterli %s yok.'):format(fromBotId, itemName))
        return
    end

    local addOk = pcall(function()
        return exports['ox_inventory']:AddItem(GetBotInventoryId(toBotId), itemName, count)
    end)
    if not addOk then
        pcall(function() return exports['ox_inventory']:AddItem(GetBotInventoryId(fromBotId), itemName, count) end)
        Reply(src, ('Bot #%d envanteri dolu, aktarim iptal edildi.'):format(toBotId))
        return
    end

    Reply(src, ('Bot #%d -> Bot #%d: %s x%d aktarildi.'):format(fromBotId, toBotId, itemName, count))
    Matrix.Log('TRAPHOUSE', 'Bot #%d -> Bot #%d envanter aktarimi (src=%d): %s x%d', fromBotId, toBotId, src, itemName, count)
end)

-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('interiordurum', function(src)
    local count = 0
    for trapHouseId, set in pairs(Occupants) do
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        if n > 0 then
            count = count + n
            Reply(src, ('Trap #%d icinde %d kisi (bucket:%d)'):format(
                trapHouseId, n, Matrix.TrapHouseInterior.GetBucket(trapHouseId)))
        end
    end
    Reply(src, ('--- Toplam %d oyuncu bir trap house icinde ---'):format(count))
end, false)

exports('GetTrapHouseBucket', function(trapHouseId) return Matrix.TrapHouseInterior.GetBucket(trapHouseId) end)
exports('GetTrapHouseOccupants', function(trapHouseId) return Matrix.TrapHouseInterior.GetOccupants(trapHouseId) end)
exports('GetPlayerTrapHouse', function(src) return Matrix.TrapHouseInterior.GetPlayerTrapHouse(src) end)
exports('RouteBotIntoInterior', function(botId, trapHouseId, botPedEntity)
    return Matrix.TrapHouseInterior.RouteBotIntoInterior(botId, trapHouseId, botPedEntity)
end)
