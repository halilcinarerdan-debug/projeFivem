--[[
    THE BUREAU :: KATMAN 2 -- OPERASYONLAR MOTORU (client/client_bureau.lua)
    ------------------------------------------------------------------------
    Bu dosyada HICBIR arcade HUD, parilti efekti veya bar tabanli mini-oyun
    mantigi yoktur. Yalnizca sunucuya guvenilir sinyal (gercek olay verisi)
    tasiyan sessiz bir veri katmani: silah sesi tespiti (adli delil icin) ve
    meet-point bildirimi. Karar/tetikleme mantiginin tamami server tarafinda
    (the_bureau.lua) calisir; client yalnizca ham veri gonderir.
]]

local WeaponAcousticLookup = {}

CreateThread(function()
    for i = 1, #Config.WeaponAcoustics do
        local entry = Config.WeaponAcoustics[i]
        WeaponAcousticLookup[GetHashKey(entry.model)] = entry.db
    end
end)

local lastGunshotReportAt = 0

AddEventHandler('gameEventTriggered', function(eventName, eventArgs)
    if eventName ~= 'CEventGunShot' then return end

    local shooterPed = eventArgs[1]
    if shooterPed ~= PlayerPedId() then return end

    local now = GetGameTimer()
    if (now - lastGunshotReportAt) < Config.ExploitBorders.MinTimeBetweenDrops then return end
    lastGunshotReportAt = now

    local weaponHash = GetSelectedPedWeapon(shooterPed)
    local coords = GetEntityCoords(shooterPed)
    local soundDb = WeaponAcousticLookup[weaponHash] or Config.DefaultWeaponDb

    local weaponSerial = nil
    local currentWeapon = exports.ox_inventory:GetCurrentWeapon()
    if currentWeapon and currentWeapon.metadata then
        weaponSerial = currentWeapon.metadata.serial
    end

    TriggerServerEvent('bureau:server:reportGunshot', weaponHash, coords, soundDb, weaponSerial)
end)

--- Baska kaynaklarin (uyusturucu satis mantigi vb.) bir "meet point" olusunca
--- cagirmasi icin dis-kaynak export'u. Karar/dogrulama tamamen server'da yapilir.
exports('ReportMeetPoint', function(propertyIdentifier)
    local coords = GetEntityCoords(PlayerPedId())
    TriggerServerEvent('bureau:server:registerMeetPoint', propertyIdentifier, coords)
end)

RegisterNetEvent('bureau:client:onRaidInitiated', function(data)
    if not Config.Debug then return end
    print(('[the_bureau] Baskin tetiklendi -> mulk: %s, sebep: %s, birim sayisi: %d')
        :format(data.propertyIdentifier, data.reason, #data.units))
end)
