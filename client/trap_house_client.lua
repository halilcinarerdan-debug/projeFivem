-- =====================================================================
-- MATRIX TRAP HOUSE CLIENT / client/trap_house_client.lua  (KATMAN 6 — YENİ)
--
-- client/hud.lua'nın kapsamı HUD + F10 menüsü olarak kalır; bu dosya
-- KATMAN 6'nın FİZİKSEL DÜNYA öğelerini taşır: kapı blip'i/giriş-çıkış
-- tetikleyicisi, içeride GERÇEKTEN atanmış Matrix.Bots'ların fiziksel
-- temsili (kozmetik/rastgele NPC DEĞİL — netsync de yok, salt görsel),
-- tezgah/paketleme odası E-tetikleri, Rendezvous satıcı/pusu ped'leri.
-- Saf metin tabanlı monokrom felsefe korunur — HTML/CSS/NUI YOK, yalnızca
-- native DrawText/blip/ped.
-- =====================================================================

local TRAP_HOUSE_REFRESH_MS = 30000
local INTERACT_RADIUS       = 2.0

local trapHouses      = {} -- id -> { id, coords, label, blip }
local insideTrapHouse = nil -- şu an içinde bulunulan trap house id (yoksa nil)
local shellData        = nil -- teleportIn payload'ından gelen iç mekan verisi
local residentPeds     = {} -- o an içeride görünen GERÇEK bot temsilleri (kozmetik degil)

-- ★ server/main.lua'nın DEALER_PED_MODEL_HASH'iyle (DEALER_PED_MODEL_NAME =
-- 'g_m_y_famdnf_01') KASITLI OLARAK AYNI model. Bir bot burada göründüğünde
-- oyuncunun sahada gördüğü GERÇEK dealer skin'inden farklı görünmemeli —
-- main.lua'daki [H14] Anti-Crash Guard sabit modeli değiştirilirse buradaki
-- de elle güncellenmelidir (iki dosya arasında paylaşılan bir Config alanı
-- YOKTUR çünkü main.lua bu sabiti dışa hiç açmıyor).
local RESIDENT_BOT_PED_MODEL = 'g_m_y_famdnf_01'

local sellerPeds  = {} -- handoffId -> { entity, coords, radius }
local ambushPeds  = {}

-- =====================================================================
-- YARDIMCI ÇİZİM (monokrom, DrawText — client/hud.lua DrawMonoLine ile
-- AYNI görsel dil, ayrı bir dosya olduğu için küçük bir yerel kopya).
-- =====================================================================
local function DrawWorldPrompt(coords, text)
    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
    if not onScreen then return end

    SetTextFont(4)
    SetTextProportional(1)
    SetTextScale(0.30, 0.30)
    SetTextColour(200, 255, 210, 220)
    SetTextDropshadow(1, 0, 0, 0, 200)
    SetTextEdge(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(sx, sy)
end

-- ★ main.lua'nın _ToVec3 güvenlik önleminin BİREBİR AYNISI: GTA V'de
-- vector3 ile vector4 arasında çıkarma/uzunluk (#) operatörü desteklenmez
-- ("attempt to perform unsupported operation on a vector value"). shellData
-- .enter_coords/.exit_coords heading taşıdığı için vector4 (bkz. shared/
-- config.lua Config.TrapHouseInterior.Shell), ama GetEntityCoords() daima
-- vector3 döner — VDist'e her iki tip de gelebileceğinden burada coerce
-- edilir.
local function _ToVec3(v)
    if type(v) == 'vector4' then
        return vector3(v.x, v.y, v.z)
    end
    return v
end

local function VDist(a, b)
    return #(_ToVec3(a) - _ToVec3(b))
end

local function RequestModelSync(model)
    local hash = type(model) == 'string' and joaat(model) or model
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 200 do
        Wait(10)
        tries = tries + 1
    end
    return HasModelLoaded(hash) and hash or nil
end

-- =====================================================================
-- KAPI BLIP'LERİ + GİRİŞ/ÇIKIŞ
-- =====================================================================
local function RefreshTrapHouseBlipsInner()
    local list = lib.callback.await('matrix:callback:getTrapHouseLocations', false)
    if type(list) ~= 'table' then return end

    local seen = {}
    for _, entry in ipairs(list) do
        seen[entry.id] = true
        local house = trapHouses[entry.id]
        if not house then
            local blip = AddBlipForCoord(entry.coords.x, entry.coords.y, entry.coords.z)
            SetBlipSprite(blip, 1)
            SetBlipColour(blip, 4) -- monokrom gri-mavi, dikkat cekmeyen
            SetBlipScale(blip, 0.55)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString('Dokuntu Kapi')
            EndTextCommandSetBlipName(blip)

            trapHouses[entry.id] = { id = entry.id, coords = entry.coords, label = entry.label, blip = blip }
        else
            house.coords = entry.coords
            house.label  = entry.label
        end
    end

    for id, house in pairs(trapHouses) do
        if not seen[id] then
            if house.blip then RemoveBlip(house.blip) end
            trapHouses[id] = nil
        end
    end
end

-- ★ TEŞHİS/SAĞLAMLIK: lib.callback.await bir kere hata verirse (örn.
-- sunucu callback'i henüz kaydetmeden ilk çağrı tetiklenirse) pcall'suz
-- bir CreateThread'de bu, TÜM thread'i kalıcı olarak öldürür — kapı
-- blip'leri/E-prompt'u bir daha ASLA görünmez (F8 konsolunda tek seferlik
-- bir hata basar, sonra sessiz kalır). forensics.lua'nın LoadCaches'i
-- (aynı .await() + pcall deseni) ile AYNI disiplin burada da uygulanır.
local function RefreshTrapHouseBlips()
    local ok, err = pcall(RefreshTrapHouseBlipsInner)
    if not ok then
        print(('[MATRIX:TRAPHOUSE:CLIENT] [HATA] RefreshTrapHouseBlips basarisiz (yutuldu, bir sonraki tick tekrar denenecek): %s'):format(tostring(err)))
    end
end

CreateThread(function()
    Wait(2000)
    RefreshTrapHouseBlips()
    while true do
        Wait(TRAP_HOUSE_REFRESH_MS)
        RefreshTrapHouseBlips()
    end
end)

RegisterNetEvent('matrix:client:trapHouseInterior:teleportIn', function(data)
    if type(data) ~= 'table' then return end
    insideTrapHouse = data.trap_house_id
    shellData        = data

    -- ★ DÜZELTME (bob74_ipl'in GERÇEK kaynak kodu -- lib/common.lua --
    -- okunarak doğrulandı): `Interior.Set(interior)` yalnızca `Interior.
    -- Clear()` + `EnableIpl(interior, true)` yapar; `EnableIpl` da (aktif
    -- ederken) düz natif `RequestIpl(ipl)` çağırır -- `RefreshInterior` BURADA
    -- HİÇ DEVREYE GİRMEZ (yalnızca "Details" -- kask/evrak çantası gibi
    -- interior İÇİ prop'lar -- için kullanılır, ana treyler IPL takası için
    -- gerekmez). Yani bir önceki düzeltmede bu çağrının "render'ı bozduğu"
    -- varsayımı YANLIŞTI; kaldırılmıştı, şimdi GÜVENLE geri eklendi.
    -- `RequestIpl` zaten `IsIplActive` ile korunuyor (EnableIpl içinde), yani
    -- bu çağrı bob74_ipl'in kendi `TrevorsTrailer.LoadDefault()` ile
    -- başlangıçta yaptığı işin AYNISINI tekrar yapar -- ZARARSIZ ve
    -- IDEMPOTENT. Amaç: bob74_ipl'in kendi tek seferlik başlangıç thread'i
    -- herhangi bir sebeple (resource restart sırası, bu oyuncunun bob74_ipl
    -- henüz tam başlamadan bağlanmış olması vb.) atlanmış olsa bile burada
    -- YENİDEN talep edilmiş olur.
    local iplOk, trailerObj = pcall(function() return exports['bob74_ipl']:GetTrevorsTrailerObject() end)
    if iplOk and type(trailerObj) == 'table' and trailerObj.Interior and trailerObj.Interior.Set then
        pcall(trailerObj.Interior.Set, trailerObj.Interior.trash)
    else
        print('[MATRIX:TRAPHOUSE:CLIENT] [UYARI] bob74_ipl kaynagi bulunamadi veya export basarisiz -- Trevor\'in treyleri dogru render OLMAYABILIR. Teshis icin "/traphouseipldebug" komutunu calistirin.')
    end

    local enter = data.enter_coords
    if enter then
        SetEntityCoords(PlayerPedId(), enter.x, enter.y, enter.z, false, false, false, false)
        SetEntityHeading(PlayerPedId(), enter.w or 0.0)
    end

    -- ★ DÜZELTME: eskiden burada rastgele modelli KOZMETİK "ambient" NPC'ler
    -- (gerçek oyun durumuyla bağlantısı olmayan yabancılar) spawn ediliyordu.
    -- Artık YALNIZCA server'ın gönderdiği `resident_bots` listesindeki
    -- GERÇEK Matrix.Bots kayıtları (bu trap house'a bot.state.trap_house_id
    -- ile atanmış, status='active' olanlar) fiziksel olarak temsil edilir —
    -- "sadece bizim ajanlarımız olsun" talebi. Liste boşsa (atanmış bot
    -- yoksa) içeride HİÇ KİMSE görünmez. Netsync YOK — bu, ilgili bot'un
    -- GERÇEK sunucu-taraflı ped'i DEĞİL, sırf bu oyuncunun gördüğü yerel
    -- bir görsel temsildir (bkz. dosya başı notu: botlar zaten STABİL/
    -- BEKLEMEDE durumundayken dünyada hiç spawn edilmiş bir ped'e sahip
    -- değildir, bkz. main.lua CompleteDispatch).
    if type(data.resident_bots) == 'table' and #data.resident_bots > 0 and shellData.workbench_pos then
        CreateThread(function()
            local scenarios = data.ambient_scenarios or { 'WORLD_HUMAN_SMOKING', 'WORLD_HUMAN_STAND_IMPATIENT', 'WORLD_HUMAN_LEANING' }
            local model = RequestModelSync(RESIDENT_BOT_PED_MODEL)
            if not model then return end

            for i, botInfo in ipairs(data.resident_bots) do
                local offsetX = ((i % 5) - 2) * 1.4
                local offsetY = math.floor(i / 5) * 1.4
                local base = data.workbench_pos
                local px, py, pz = base.x + offsetX, base.y + offsetY, base.z
                local ped = CreatePed(4, model, px, py, pz, 0.0, false, false)
                if ped and ped ~= 0 then
                    SetEntityAsMissionEntity(ped, true, true)
                    SetBlockingOfNonTemporaryEvents(ped, true)
                    TaskStartScenarioInPlace(ped, scenarios[((i - 1) % #scenarios) + 1], 0, true)
                    residentPeds[#residentPeds + 1] = ped
                end
            end
            SetModelAsNoLongerNeeded(model)
        end)
    end

    if lib and lib.notify then
        lib.notify({ title = '[TRAP HOUSE]', description = 'Kapidan icerisi girildi. Cikmak icin kapiya donup [E] tuslayin.', type = 'inform' })
    end
end)

local function CleanupResidentPeds()
    for _, ped in ipairs(residentPeds) do
        if DoesEntityExist(ped) then
            pcall(DeleteEntity, ped)
        end
    end
    residentPeds = {}
end

RegisterNetEvent('matrix:client:trapHouseInterior:teleportOut', function(data)
    CleanupResidentPeds()
    insideTrapHouse = nil
    shellData        = nil

    if type(data) == 'table' and data.exit_world_coords then
        local c = data.exit_world_coords
        SetEntityCoords(PlayerPedId(), c.x, c.y, c.z, false, false, false, false)
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    CleanupResidentPeds()
end)

-- =====================================================================
-- ANA ETKİLEŞİM DÖNGÜSÜ — kapı girişi (dışarıda) + çıkış/tezgah/paketleme
-- (içeride). Tek bir Wait(0)/Wait(500) döngüsü; ayrı ayrı thread'ler yerine
-- tek bir proximity taraması (0 Resmon disiplinine uygun — gereksiz thread
-- çoğaltılmadı).
-- =====================================================================
CreateThread(function()
    while true do
        local sleep = 500
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)

        if insideTrapHouse and shellData then
            sleep = 0

            if shellData.exit_coords and VDist(coords, shellData.exit_coords) <= INTERACT_RADIUS then
                DrawWorldPrompt(shellData.exit_coords, '[E] Disari Cik')
                if IsControlJustPressed(0, 38) then -- INPUT_PICKUP / E
                    TriggerServerEvent('matrix:server:trapHouseInterior:exit')
                end
            end

            if shellData.workbench_pos and VDist(coords, shellData.workbench_pos) <= INTERACT_RADIUS then
                DrawWorldPrompt(shellData.workbench_pos, '[E] Tezgahta Silahi Tamir Et')
                if IsControlJustPressed(0, 38) then
                    local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
                    if ok and type(current) == 'table' and current.slot then
                        TriggerServerEvent('matrix:server:workbench:repairWeapon', current.slot)
                    elseif lib and lib.notify then
                        lib.notify({ title = '[WORKBENCH]', description = 'Elinizde tamir edilebilir bir silah yok.', type = 'error' })
                    end
                end
            end

            if shellData.packaging_pos and VDist(coords, shellData.packaging_pos) <= INTERACT_RADIUS then
                DrawWorldPrompt(shellData.packaging_pos, '[E] Paketleme Odasini Ac/Kapat')
                if IsControlJustPressed(0, 38) then
                    TriggerServerEvent('matrix:server:workbench:togglePackagingRoom', insideTrapHouse)
                end
            end
        else
            for _, house in pairs(trapHouses) do
                if VDist(coords, house.coords) <= 8.0 then
                    sleep = 0
                    if VDist(coords, house.coords) <= INTERACT_RADIUS then
                        DrawWorldPrompt(house.coords, '[E] Kapiyi Ac')
                        if IsControlJustPressed(0, 38) then
                            TriggerServerEvent('matrix:server:trapHouseInterior:enter', house.id)
                        end
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

-- =====================================================================
-- ★ KATMAN 6 [K4]: RENDEZVOUS — satıcı/pusu ped'leri
-- =====================================================================
RegisterNetEvent('matrix:client:rendezvous:spawnSeller', function(data)
    if type(data) ~= 'table' or type(data.coords) ~= 'vector3' then return end

    CreateThread(function()
        local model = RequestModelSync(data.ped_model or 'g_m_y_mexgoon_01')
        if not model then return end

        local ped = CreatePed(4, model, data.coords.x, data.coords.y, data.coords.z - 1.0, 0.0, false, false)
        if ped and ped ~= 0 then
            SetEntityAsMissionEntity(ped, true, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            if data.scenario then
                TaskStartScenarioInPlace(ped, data.scenario, 0, true)
            end
            sellerPeds[data.handoff_id] = { entity = ped, coords = data.coords, radius = data.radius or 8.0 }
        end
        SetModelAsNoLongerNeeded(model)
    end)
end)

RegisterNetEvent('matrix:client:rendezvous:despawnSeller', function(handoffId)
    local entry = sellerPeds[handoffId]
    if entry then
        if DoesEntityExist(entry.entity) then pcall(DeleteEntity, entry.entity) end
        sellerPeds[handoffId] = nil
    end
end)

CreateThread(function()
    while true do
        local sleep = 1000
        if next(sellerPeds) then
            sleep = 0
            local coords = GetEntityCoords(PlayerPedId())
            for handoffId, entry in pairs(sellerPeds) do
                if VDist(coords, entry.coords) <= (entry.radius + 2.0) then
                    DrawWorldPrompt(entry.coords, '[E] Teslimati Al')
                    if IsControlJustPressed(0, 38) then
                        TriggerServerEvent('matrix:server:rendezvous:pickup', handoffId)
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

-- ★ Büro pususu: deterministik olarak server tarafından tetiklenir (bkz.
-- server/rendezvous.lua [R2]); burada yalnızca GÖRSEL/DAVRANIŞSAL tarafı
-- (ped spawn + saldırganlık) uygulanır. HUD kırmızı bülteni zaten
-- server/market.lua BuildSnapshot üzerinden ayrı bir kanaldan gelir.
RegisterNetEvent('matrix:client:rendezvous:triggerAmbush', function(data)
    if type(data) ~= 'table' or type(data.coords) ~= 'vector3' then return end

    if lib and lib.notify then
        lib.notify({
            title       = '[BURO OPERASYONU]',
            description = 'RENDEZVOUS DESIFRE OLDU — PUSU AKTIF!',
            type        = 'error',
            duration    = 8000
        })
    end

    CreateThread(function()
        local model = RequestModelSync(data.ped_model or 's_m_y_swat_01')
        if not model then return end

        local weaponHash = type(data.weapon) == 'string' and joaat(data.weapon) or nil
        local squadSize   = math.min(tonumber(data.squad_size) or 4, 8)
        local spawnRadius = tonumber(data.spawn_radius) or 35.0

        for i = 1, squadSize do
            local angle = (360.0 / squadSize) * i
            local rad = math.rad(angle)
            local px = data.coords.x + (math.cos(rad) * spawnRadius)
            local py = data.coords.y + (math.sin(rad) * spawnRadius)

            local ped = CreatePed(4, model, px, py, data.coords.z, 0.0, true, true)
            if ped and ped ~= 0 then
                SetEntityAsMissionEntity(ped, true, true)
                if weaponHash then
                    GiveWeaponToPed(ped, weaponHash, 250, false, true)
                end
                SetPedCombatAttributes(ped, 46, true)
                SetPedFleeAttributes(ped, 0, false)
                SetPedCombatAbility(ped, 2)
                SetPedAlertness(ped, 3)
                TaskCombatPed(ped, PlayerPedId(), 0, 16)
                ambushPeds[#ambushPeds + 1] = ped
            end
        end
        SetModelAsNoLongerNeeded(model)
    end)
end)

-- Tüm pusu botları etkisiz hale geldiğinde bülteni erken temizle (opsiyonel
-- — bkz. server/rendezvous.lua ambushCleared yorumu, tetiklenmezse zaten
-- zaman aşımıyla otomatik temizlenir).
CreateThread(function()
    while true do
        Wait(2000)
        if #ambushPeds > 0 then
            local allDown = true
            for i = #ambushPeds, 1, -1 do
                local ped = ambushPeds[i]
                if not DoesEntityExist(ped) then
                    table.remove(ambushPeds, i)
                elseif not IsEntityDead(ped) then
                    allDown = false
                end
            end
            if allDown and #ambushPeds == 0 then
                TriggerServerEvent('matrix:server:rendezvous:ambushCleared')
            end
        end
    end
end)

-- =====================================================================
-- ★ KATMAN 6 [K4-son]: "SON ÇARE" (Last Stand) bildirimi — kapı barikatı
-- zorlandığında Bureau'nun içeri girdiği an. Burada YENİ bir çatışma
-- mekaniği İCAT EDİLMEZ; yalnızca oyuncuyu uyaran güçlü bir bildirimdir
-- (K panelindeki kırmızı geri sayım zaten sıfıra indi).
-- =====================================================================
RegisterNetEvent('matrix:client:doorReinforcement:lastStand', function()
    if lib and lib.notify then
        lib.notify({
            title       = '[SON CARE]',
            description = 'Barikat zorlandi! Silahlarinizi cekin, acik hatlari imha edin — Buro icerde.',
            type        = 'error',
            duration    = 10000
        })
    end
end)

-- =====================================================================
-- ★ TEŞHİS KOMUTU (GEÇİCİ): bob74_ipl'in Trevor'ın treyleri için IPL'i
-- GERÇEKTEN aktif edip etmediğini ve o koordinatta oyun motorunun bir
-- interior görüp görmediğini doğrudan F8 konsoluna basar. İki başarısız
-- kod-tahmininden sonra üçüncü kez körlemesine tahmin YAPILMIYOR — bunun
-- yerine gerçek durum ölçülüyor. Konsol çıktısı köke inince bu komut
-- kaldırılabilir.
-- =====================================================================
RegisterCommand('traphouseipldebug', function()
    local ok, trailerObj = pcall(function() return exports['bob74_ipl']:GetTrevorsTrailerObject() end)
    print(('[TRAPHOUSE_IPL_DEBUG] export cagrisi basarili=%s trailerObj tip=%s'):format(tostring(ok), type(trailerObj)))

    if ok and type(trailerObj) == 'table' then
        local interiorId = trailerObj.interiorId
        local tidyName   = trailerObj.Interior and trailerObj.Interior.tidy
        local trashName  = trailerObj.Interior and trailerObj.Interior.trash
        print(('[TRAPHOUSE_IPL_DEBUG] interiorId=%s tidy=%s trash=%s'):format(tostring(interiorId), tostring(tidyName), tostring(trashName)))
        print(('[TRAPHOUSE_IPL_DEBUG] IsIplActive(trash)=%s IsIplActive(tidy)=%s'):format(tostring(IsIplActive(trashName)), tostring(IsIplActive(tidyName))))
    else
        print('[TRAPHOUSE_IPL_DEBUG] UYARI: bob74_ipl export cagrisi basarisiz oldu -- kaynak calismiyor veya export kaydolmamis.')
    end

    local sx, sy, sz = 1985.48132, 3828.76757, 32.5
    local interiorAt = GetInteriorAtCoords(sx, sy, sz)
    print(('[TRAPHOUSE_IPL_DEBUG] GetInteriorAtCoords(%.4f, %.4f, %.4f) = %s'):format(sx, sy, sz, tostring(interiorAt)))

    local ped = PlayerPedId()
    local myCoords = GetEntityCoords(ped)
    local myInteriorEntity = GetInteriorFromEntity(ped)
    print(('[TRAPHOUSE_IPL_DEBUG] oyuncu konumu=%.4f,%.4f,%.4f  GetInteriorFromEntity(ped)=%s'):format(myCoords.x, myCoords.y, myCoords.z, tostring(myInteriorEntity)))
end, false)
