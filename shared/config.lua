Config = Config or {}

-- =============================================================================
-- KATMAN 7 / FAZ 1 - paylasilan yapilandirma
-- =============================================================================

-- Normal (interior-disi) dispatch cagrilari icin anti-abuse mesafe koruma esigi.
-- Sadece Matrix.BeginRouteDispatch'in acik-dunya dalinda uygulanir; interior
-- exit-bridge manevrasi (Faz 2) bu koruma disindadir cunku o bir konum
-- duzeltmesidir, dispatch kisayoli degildir.
Config.MinDispatchDistanceMeters = 35.0

-- Bot arac atama ve surus ayarlari.
Config.Dispatch = {
    DefaultVehicleModel = GetHashKey('speedo'),
    DriveStyle = 786603, -- normal surus + trafik kacinma
    CruiseSpeed = 18.0,
    NavMeshWaitTicks = 100, -- HasCollisionLoadedAroundEntity icin ust sinir (tick)
}

-- GTA Online interior kabuklerinin harita disi (gokyuzu boslugu) render
-- konumlarini, gercek dunyadaki fiziki cikis kapisi koordinatlarina baglayan
-- tablo. Sunucu operatorleri kendi interior setlerine gore genisletebilir;
-- exitDoor degerleri kendi haritanizin gercek Rancho/Grove Street noktalarina
-- gore dogrulanmalidir.
Config.InteriorExitBridges = {
    ['GTAOHouseLow1'] = {
        interiorShell = vector3(261.45, -998.81, -99.00), -- Katman 6 raporundaki bozuk render konumu
        exitDoor = vector4(78.5, -1636.2, 29.3, 130.0), -- Rancho sokak seviyesi giris kapisi
        exitZone = 'Rancho',
    },
}

Config.Bureau = {
    BreachCeiling = 12, -- radio_breach_count bu degerde katsayinin telsiz bileseni 1.0'a doyar
    PurityWeightCap = 100.0, -- average_purity_intercepted bu degerde katsayinin saflik bileseni 1.0'a doyar
    BreachWeight = 0.70,
    PurityWeight = 0.30,
    LockdownThreshold = 0.75, -- %75 baraj
    HubSaleBatchSize = 3, -- her talep dongusunde satilan sabit (RNG'siz) miktar
    HubDemandCycleMs = 45000,
}

-- Gelecekteki OpenAI / ChatGPT analiz koprusu. Varsayilan olarak KAPALI ve
-- devreye alinana kadar sifir maliyetlidir (ticker calisir ama hicbir HTTP
-- istegi atmaz). Kilit karari HER ZAMAN server/bureau.lua'daki deterministik
-- motordan gelir; bu blok sadece pasif/istisari bir katmandir.
Config.AI_Matrix_Brain = {
    enabled = false,
    provider = 'openai',
    apiKey = 'sk-...',
    analysisIntervalMinutes = 60,
    fallbackToDeterministic = true,
}
