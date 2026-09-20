-- =====================================================================
-- MATRIX TRAP HOUSE CLIENT / client/trap_house_client.lua  (KATMAN 6 — YENİ)
--
-- client/hud.lua'nın kapsamı HUD + F10 menüsü olarak kalır; bu dosya
-- KATMAN 6'nın FİZİKSEL DÜNYA öğelerini taşır: kapı blip'i/giriş-çıkış
-- tetikleyicisi, iç mekan ambient dekor (kozmetik, netsync YOK), tezgah/
-- paketleme odası E-tetikleri, Rendezvous satıcı/pusu ped'leri. Saf metin
-- tabanlı monokrom felsefe korunur — HTML/CSS/NUI YOK, yalnızca native
-- DrawText/blip/ped.
-- =====================================================================

local TRAP_HOUSE_REFRESH_MS = 30000
local INTERACT_RADIUS       = 2.0

local trapHouses      = {} -- id -> { id, coords, label, blip }
local insideTrapHouse = nil -- şu an içinde bulunulan trap house id (yoksa nil)
local shellData        = nil -- teleportIn payload'ından gelen iç mekan verisi
local ambientPeds       = {}

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

local function VDist(a, b)
    return #(a - b)
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
local function RefreshTrapHouseBlips()
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

    local enter = data.enter_coords
    if enter then
        SetEntityCoords(PlayerPedId(), enter.x, enter.y, enter.z, false, false, false, false)
        SetEntityHeading(PlayerPedId(), enter.w or 0.0)
    end

    if data.required_ipl and type(data.required_ipl) == 'string' then
        pcall(RequestIpl, data.required_ipl)
    end

    -- ★ Ambient dekor: KOZMETİK, netsync YOK (yalnızca bu istemcide görünür).
    -- "20 adam sigara icip paketliyor" atmosferi — hicbir oynanis mantigina
    -- bagli DEGILDIR, resource stop/teleportOut'ta temizlenir.
    if data.ambient and data.ambient.count and data.ambient.count > 0 and shellData.workbench_pos then
        CreateThread(function()
            local models    = data.ambient.models or {}
            local scenarios = data.ambient.scenarios or {}
            if #models == 0 or #scenarios == 0 then return end

            for i = 1, data.ambient.count do
                local model = RequestModelSync(models[((i - 1) % #models) + 1])
                if model then
                    local offsetX = ((i % 5) - 2) * 1.4
                    local offsetY = math.floor(i / 5) * 1.4
                    local base = data.workbench_pos
                    local px, py, pz = base.x + offsetX, base.y + offsetY, base.z
                    local ped = CreatePed(4, model, px, py, pz, 0.0, false, false)
                    if ped and ped ~= 0 then
                        SetEntityAsMissionEntity(ped, true, true)
                        SetBlockingOfNonTemporaryEvents(ped, true)
                        TaskStartScenarioInPlace(ped, scenarios[((i - 1) % #scenarios) + 1], 0, true)
                        ambientPeds[#ambientPeds + 1] = ped
                    end
                    SetModelAsNoLongerNeeded(model)
                end
            end
        end)
    end

    if lib and lib.notify then
        lib.notify({ title = '[TRAP HOUSE]', description = 'Kapidan icerisi girildi. Cikmak icin kapiya donup [E] tuslayin.', type = 'inform' })
    end
end)

local function CleanupAmbientPeds()
    for _, ped in ipairs(ambientPeds) do
        if DoesEntityExist(ped) then
            pcall(DeleteEntity, ped)
        end
    end
    ambientPeds = {}
end

RegisterNetEvent('matrix:client:trapHouseInterior:teleportOut', function(data)
    CleanupAmbientPeds()
    insideTrapHouse = nil
    shellData        = nil

    if type(data) == 'table' and data.exit_world_coords then
        local c = data.exit_world_coords
        SetEntityCoords(PlayerPedId(), c.x, c.y, c.z, false, false, false, false)
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    CleanupAmbientPeds()
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
