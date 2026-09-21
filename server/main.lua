Matrix = Matrix or {}
Matrix.Bots = Matrix.Bots or {}

-- =============================================================================
-- KATMAN 7 / FAZ 2 - Iki fazli GTA Online cikis koprusu ve NavMesh duzeltmesi
--
-- Kok neden: GTAOHouseLow1 gibi hazir GTA Online interior kabuklari, harita
-- disinda bir "gokyuzu boslugu" world-koordinatinda oturur (ornek:
-- X:261.45 Y:-998.81 Z:-99.00). Oyuncular bu noktaya interior-portal sistemi
-- uzerinden girer, ama sunucu tarafinda spawn edilen botlar o koordinatta
-- gercekten var olur. GTA V'in yol/path-node streaming'i sadece oyunculara
-- yakin bolgeleri yukler; bu off-map konumun cevresinde hicbir NavMesh/path
-- node yuklenmez. TaskVehicleDriveToCoord bu yuzden sessizce basarisiz olur
-- ve pathing timeout'u botu despawn ettirir ("Task Assignment Failed").
--
-- Cozum: dispatch hesaplanmadan once botun routing bucket'i kontrol edilir;
-- bucket > 0 ise bot once o interior'un gercek dunyadaki fiziki kapisina
-- tasinir, bucket 0'a cekilir ve o koordinat etrafinda collision/path-node
-- streaming zorla tetiklenir (RequestCollisionAtCoord). Sadece bu noktada
-- MinDispatchDistanceMeters koruma esigi devre disi birakilir cunku bu bir
-- dispatch kisayolu degil, konum duzeltmesidir.
-- =============================================================================

function Matrix.RegisterBot(botId, pedHandle, interiorKey)
    Matrix.Bots[botId] = {
        ped = pedHandle,
        vehicle = nil,
        interiorKey = interiorKey,
    }

    if interiorKey then
        SetEntityRoutingBucket(pedHandle, GetEntityRoutingBucket(pedHandle))
    end
end

function Matrix.UnregisterBot(botId)
    Matrix.Bots[botId] = nil
end

function Matrix.ResolveInteriorExitBridge(interiorKey)
    if not interiorKey then
        return nil
    end
    return Config.InteriorExitBridges[interiorKey]
end

-- Ana giris noktasi: bir bota Waypoint/sevk emri atar. Cagiran thread'i
-- bloklamaz -- gercek is her zaman ayri bir CreateThread icinde asenkron
-- yurutulur, boylece bucket sorgusu ve olasi NavMesh bekleme dongusu
-- dispatch cagrisini yapan kodu durdurmaz.
-- destination bir vector3 olmalidir (vektor cikarma/GetEntityCoords ile
-- dogrudan uyumlu olmasi icin).
function Matrix.BeginRouteDispatch(botId, destination)
    local botState = Matrix.Bots[botId]
    if not botState or not botState.ped or not DoesEntityExist(botState.ped) then
        return false, 'invalid_bot'
    end

    local ped = botState.ped
    local bucket = GetEntityRoutingBucket(ped)

    if bucket > 0 then
        local bridge = Matrix.ResolveInteriorExitBridge(botState.interiorKey)
        if not bridge then
            print(('[Matrix][NavMesh] Bot #%s bucket %d icin tanimli exit-bridge yok, dispatch iptal.'):format(tostring(botId), bucket))
            return false, 'no_exit_bridge'
        end

        CreateThread(function()
            Matrix.ExecuteExitBridge(botId, botState, bridge, destination)
        end)

        return true, 'bridging'
    end

    local originCoords = GetEntityCoords(ped)
    local straightDistance = #(originCoords - destination)

    if straightDistance < Config.MinDispatchDistanceMeters then
        return false, 'too_close'
    end

    CreateThread(function()
        Matrix.DispatchOnFoot(botId, botState, destination)
    end)

    return true, 'dispatched'
end

-- Faz 2: interior'dan gercek dunyaya cikis koprusu.
function Matrix.ExecuteExitBridge(botId, botState, bridge, destination)
    local ped = botState.ped
    if not DoesEntityExist(ped) then
        Matrix.Bots[botId] = nil
        return
    end

    local door = bridge.exitDoor

    -- Once fiziksel konum, sonra routing bucket: boylece istemci tarafinda
    -- bot bir an bile GTAO interior'unda "bucket 0" gibi gorunmez.
    SetEntityCoords(ped, door.x, door.y, door.z, false, false, false, true)
    SetEntityHeading(ped, door.w)
    SetEntityRoutingBucket(ped, 0)
    botState.interiorKey = nil

    -- Kok nedenin asil duzeltmesi: kapinin etrafinda path-node/collision
    -- streaming'i zorla tetikle ve yuklenene kadar bekle.
    RequestCollisionAtCoord(door.x, door.y, door.z)

    local attempts = 0
    while not HasCollisionLoadedAroundEntity(ped) and attempts < Config.Dispatch.NavMeshWaitTicks do
        Wait(0)
        attempts = attempts + 1
    end

    if not DoesEntityExist(ped) then
        Matrix.Bots[botId] = nil
        return
    end

    if not HasCollisionLoadedAroundEntity(ped) then
        print(('[Matrix][NavMesh] Bot #%s icin %s cikis noktasinda collision zaman asimina ugradi, yine de dispatch deneniyor.'):format(tostring(botId), bridge.exitZone or '?'))
    end

    Matrix.DispatchOnFoot(botId, botState, destination)
end

-- Faz 3: aracina bindir ve surus gorevini baslat. Bu noktada bot her zaman
-- bucket 0'da ve NavMesh yuklenmis (veya yuklenmeye zorlanmis) durumdadir.
function Matrix.DispatchOnFoot(botId, botState, destination)
    local ped = botState.ped
    if not DoesEntityExist(ped) then
        Matrix.Bots[botId] = nil
        return
    end

    local veh = botState.vehicle
    if not veh or not DoesEntityExist(veh) then
        veh = Matrix.SpawnDispatchVehicle(ped)
        botState.vehicle = veh
    end

    if veh and DoesEntityExist(veh) then
        SetVehicleRoutingBucket(veh, GetEntityRoutingBucket(ped))
        TaskWarpPedIntoVehicle(ped, veh, -1)
        TaskVehicleDriveToCoord(
            ped, veh,
            destination.x, destination.y, destination.z,
            Config.Dispatch.CruiseSpeed,
            0,
            GetEntityModel(veh),
            Config.Dispatch.DriveStyle,
            5.0,
            true
        )
    else
        TaskGoStraightToCoord(ped, destination.x, destination.y, destination.z, 1.0, -1, 0.0, 0.0)
    end
end

function Matrix.SpawnDispatchVehicle(ped)
    local model = Config.Dispatch.DefaultVehicleModel
    RequestModel(model)

    local waited = 0
    while not HasModelLoaded(model) and waited < 200 do
        Wait(0)
        waited = waited + 1
    end

    if not HasModelLoaded(model) then
        print('[Matrix][Dispatch] Arac modeli yuklenemedi, on ayak dispatch a devam ediliyor.')
        return nil
    end

    local coords = GetEntityCoords(ped)
    local veh = CreateVehicle(model, coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
    SetVehicleOnGroundProperly(veh)
    SetModelAsNoLongerNeeded(model)

    return veh
end

exports('BeginRouteDispatch', Matrix.BeginRouteDispatch)
exports('RegisterBot', Matrix.RegisterBot)
exports('UnregisterBot', Matrix.UnregisterBot)
