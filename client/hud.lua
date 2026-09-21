-- =====================================================================
-- MATRIX HUD / client/hud.lua
-- [K7-2/2] K paneli (satis modu + telsiz sessizligi anahtarlari) ve
-- sokaktaki "kes" NPC yaklasma/satis dongusunun tum client tarafi.
-- [K7-2/1] lib.progressCircle koprusu (Mutfak Paketleme Odasi).
--
-- HTML/CSS YOK: her sey native DrawText/DrawRect ile monokrom "veri
-- sanati" olarak cizilir. 0.00ms resmon doktrini: hicbir Wait(0) thread'i
-- gosterecek bir sey olmadigi surece calismaz - render thread'i, panel
-- kapali/satis modu pasif/aktif mesaj yokken uzun Wait(RefreshMs)'e
-- duser; sadece gosterilecek bir sey oldugunda Wait(0)'a gecer.
-- =====================================================================

local PlayerPedId = PlayerPedId
local GetEntityCoords = GetEntityCoords

local hud = {
    panelOpen = false,
    sellMode = false,
    radioSilence = false,
    lastMsg = nil,
    lastMsgAt = 0,
}

local activeNpc = nil        -- { ped, startedAt }
local lastServicedPed = nil
local lastApproachAt = 0

-- ---------------------------------------------------------------------
-- Monochrome primitives (grayscale only - no color, per "monokrom veri
-- sanati" mandate)
-- ---------------------------------------------------------------------
local function drawMonoText(x, y, scale, text, shade)
    shade = shade or 255
    SetTextFont(Config.Hud.Font)
    SetTextScale(scale, scale)
    SetTextColour(shade, shade, shade, 235)
    SetTextOutline()
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawText(x, y)
end

local function drawMonoRect(x, y, w, h, shade, alpha)
    DrawRect(x, y, w, h, shade, shade, shade, alpha)
end

-- ---------------------------------------------------------------------
-- HUD panel + persistent status line
-- ---------------------------------------------------------------------
local function renderHud()
    if hud.panelOpen then
        drawMonoRect(0.14, 0.30, 0.22, 0.16, 10, 200)
        drawMonoText(0.045, 0.225, 0.42, '=== MATRIX K PANEL ===', 255)
        drawMonoText(0.045, 0.260, 0.35, ('[1] SATIS MODU ..... %s'):format(hud.sellMode and '> AKTIF <' or 'kapali'), hud.sellMode and 255 or 160)
        drawMonoText(0.045, 0.290, 0.35, ('[2] SESSIZLIK ....... %s'):format(hud.radioSilence and '> AKTIF <' or 'kapali'), hud.radioSilence and 255 or 160)
        drawMonoText(0.045, 0.330, 0.28, '[ESC] kapat', 140)
    end

    if hud.sellMode then
        drawMonoText(0.045, 0.05, 0.32, '[ SATIS MODU AKTIF ]', 255)
    end

    if hud.radioSilence then
        drawMonoText(0.045, hud.sellMode and 0.075 or 0.05, 0.28, '[ TELSIZ SESSIZLIGI ]', 200)
    end

    if hud.lastMsg and (GetGameTimer() - hud.lastMsgAt) < 4500 then
        drawMonoText(0.045, 0.10, 0.30, hud.lastMsg, 255)
    end
end

local function needsRender()
    if hud.panelOpen or hud.sellMode or hud.radioSilence then return true end
    if hud.lastMsg and (GetGameTimer() - hud.lastMsgAt) < 4500 then return true end
    return false
end

CreateThread(function()
    while true do
        if needsRender() then
            renderHud()
            if hud.panelOpen then
                DisableControlAction(0, 157, true) -- weapon select 1
                DisableControlAction(0, 158, true) -- weapon select 2
                DisableControlAction(0, 200, true) -- ESC
                if IsDisabledControlJustPressed(0, 157) then
                    hud.sellMode = not hud.sellMode
                    TriggerServerEvent('matrix:server:market:setDealingMode', hud.sellMode, GetEntityCoords(PlayerPedId()))
                elseif IsDisabledControlJustPressed(0, 158) then
                    TriggerServerEvent('matrix:server:market:toggleSilence')
                elseif IsDisabledControlJustPressed(0, 200) then
                    hud.panelOpen = false
                end
            end
            Wait(0)
        else
            Wait(Config.Hud.RefreshMs)
        end
    end
end)

RegisterKeyMapping('matrix_togglehud', 'Matrix K Panelini Ac/Kapat', 'keyboard', Config.Hud.ToggleKey)
RegisterCommand('matrix_togglehud', function()
    hud.panelOpen = not hud.panelOpen
end, false)

RegisterNetEvent('matrix:client:hud:dealingModeState', function(active)
    hud.sellMode = active
end)

RegisterNetEvent('matrix:client:hud:silenceState', function(active)
    hud.radioSilence = active
end)

-- ---------------------------------------------------------------------
-- [K7-2/2] Sokak satis dongusu - "kes" NPC yaklasma mantigi
-- ---------------------------------------------------------------------
local function findNearbyAddict(myCoords)
    local closest, closestDist = nil, Config.Market.NpcSearchRadius
    local handle, ped = FindFirstPed()
    local success

    repeat
        if ped and DoesEntityExist(ped) and not IsPedAPlayer(ped) and IsPedHuman(ped)
            and not IsPedInAnyVehicle(ped, false) and not IsEntityDead(ped) then
            local d = #(myCoords - GetEntityCoords(ped))
            if d < closestDist then
                closestDist = d
                closest = ped
            end
        end
        success, ped = FindNextPed(handle)
    until not success

    EndFindPed(handle)
    return closest
end

local function handleNpcArrival()
    local ped = activeNpc.ped
    lastServicedPed = ped
    activeNpc = nil

    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    TriggerServerEvent('matrix:server:market:attemptSale')
end

-- Scan/approach scheduler: runs on the fixed (non-random) configured
-- interval - only alive while sell mode is on.
CreateThread(function()
    while true do
        if hud.sellMode then
            local now = GetGameTimer()
            if not activeNpc and (now - lastApproachAt) >= Config.Market.NpcApproachIntervalMs then
                local myCoords = GetEntityCoords(PlayerPedId())
                local ped = findNearbyAddict(myCoords)
                if ped then
                    lastApproachAt = now
                    activeNpc = { ped = ped, startedAt = now }
                    ClearPedTasks(ped)
                    TaskGoStraightToCoord(ped, myCoords.x, myCoords.y, myCoords.z, Config.Market.NpcWalkSpeed, -1, 0.0, 0.0)
                end
            end
            Wait(Config.Market.NpcScanIntervalMs)
        else
            Wait(Config.Hud.RefreshMs)
        end
    end
end)

-- Arrival watcher: only spins fast while an NPC is actually en route.
CreateThread(function()
    while true do
        if activeNpc and DoesEntityExist(activeNpc.ped) then
            local myCoords = GetEntityCoords(PlayerPedId())
            local pCoords = GetEntityCoords(activeNpc.ped)
            local d = #(myCoords - pCoords)

            if d <= Config.Market.NpcArriveDistance then
                handleNpcArrival()
            elseif (GetGameTimer() - activeNpc.startedAt) > Config.Market.NpcTimeoutMs then
                activeNpc = nil
            end
            Wait(400)
        else
            Wait(1000)
        end
    end
end)

RegisterNetEvent('matrix:client:hud:saleResult', function(accepted, info)
    hud.lastMsg = accepted
        and ('SATIS TAMAM: +$%d (saflik %%%.0f)'):format(info.cash or 0, info.purity or 0)
        or ('REDDEDILDI: %s (saflik %%%.0f) - BURO IHBAR EDILDI'):format(info.reason == 'tampered' and 'TAHRIF' or 'DUSUK SAFLIK', info.purity or 0)
    hud.lastMsgAt = GetGameTimer()

    if lastServicedPed and DoesEntityExist(lastServicedPed) then
        ClearPedTasks(lastServicedPed)
        if accepted then
            TaskSmartFleePed(lastServicedPed, PlayerPedId(), 30.0, 3000, false, false)
        else
            TaskSmartFleePed(lastServicedPed, PlayerPedId(), 100.0, -1, false, false)
        end
    end
    lastServicedPed = nil
end)

-- ---------------------------------------------------------------------
-- [K7-2/1] Mutfak Paketleme - lib.progressCircle koprusu
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:client:kitchen:startProgress', function(jobId, durationMs, drugType)
    if not (lib and lib.progressCircle) then return end

    local completed = lib.progressCircle({
        duration = durationMs,
        label = ('Paketleniyor: %s'):format(tostring(drugType)),
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true, mouse = false },
    })

    if not completed then
        TriggerServerEvent('matrix:server:kitchen:cancelPackaging', jobId)
    end
end)

RegisterNetEvent('matrix:client:kitchen:packagingResult', function(success, info)
    hud.lastMsg = success
        and ('PAKETLEME TAMAM: %dx paket (saflik %%%.0f)'):format(info.packages or 0, info.purity or 0)
        or ('PAKETLEME BASARISIZ: %s'):format(tostring(info.reason))
    hud.lastMsgAt = GetGameTimer()
end)

Matrix.Log('HUD', 'client/hud.lua loaded (Faz 2 - K Panel + Sokak Satis Dongusu)')
