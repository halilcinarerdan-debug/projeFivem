--[[
    THE BUREAU :: CBA/ACE3 TARZI MODULER AYAR MERKEZI
    ---------------------------------------------------
    Tum katsayilar ve esikler bu dosyadan yonetilir. Hicbir deger the_bureau.lua
    veya client_bureau.lua icinde sabit (hardcoded) yazilmaz; her yeni gun/katman
    yalnizca bu tabloyu genisletir. Birim notasyonu her alanin yaninda belirtilmistir.
]]

Config = {}

-- ============================================================
--  GENEL / CORE
-- ============================================================
Config.Debug     = false      -- true olursa konsola tanilama (diagnostic) ciktisi basilir
Config.Framework = 'qb-core'  -- ileride cok-framework koprusu icin ayrilan alan
Config.Locale    = 'tr'

-- ============================================================
--  BUREAU AI :: Asenkron Istihbarat Tarayici Thread
-- ============================================================
Config.BureauAI = {
    ScanInterval                 = 5000,     -- ms, ana AI dongusunun tek Wait() periyodu
    HeatmapDecay                 = 0.15,     -- her tarama turunda hucre heat'inden dusulecek oran (0.0 - 1.0)
    HeatmapGridSize              = 50.0,     -- metre, heatmap hucre boyutu
    HeatmapCellCap               = 100.0,    -- bir hucrenin ulasabilecegi azami heat puani
    PatternDeceptionsBeforeRaid  = 3,        -- ayni mulkte tekrarlanan meet-point orunutusu esigi
    PatternWindowMs              = 1800000,  -- 30 dk, orunutu sayaclarinin gecerli sayildigi zaman penceresi
    MeetPointRadius              = 20.0,     -- metre, bir bulusmanin "meet point" sayilacagi yaricap
    BaseWantedMulti              = 1.2,      -- deSifre edilen her pattern/olay icin heat/wanted carpani
    RaidTriggerCooldownMs        = 900000,   -- 15 dk, ayni mulke art arda baskin tetiklenmesini onleyen bekleme
    MinUnitsForRaid              = 2,        -- baskin ekibindeki asgari arac/personel sayisi
    MaxUnitsForRaid              = 5,        -- baskin ekibindeki azami arac/personel sayisi
    RaidApproachDistance         = 40.0,     -- metre, cember/drive-by icin asgari yaklasma mesafesi
    RaidUnitLifetimeMs           = 300000,   -- 5 dk, baskin ekibinin sahnede kalma suresi (sonra despawn)
    UnmarkedVehicles              = {         -- sivil (unmarked) baskin araclari havuzu
        'asterope2', 'primo2', 'regina', 'tahoma',
    },
    CivilianRaidPedModel          = 's_m_y_swat_01', -- sivil kiyafetli tim personeli modeli
}

-- ============================================================
--  FORENSIC THRESHOLDS :: Adli Bilisim Esikleri
-- ============================================================
Config.ForensicThresholds = {
    LatentPrintLimit          = 60.0,  -- %, bu kalitenin USTUNDEKI izler AFIS soguk vaka kaydina dusec
    AcousticDesibelAlert      = 140.0, -- dB, bu esigi asan ates sesi ShotSpotter alarmini tetikler
    PrintDecayPerMinute       = 2.5,   -- % / dk, yuzey turune gore iz kalitesinin zamanla bozulma orani
    StriationHashLength       = 64,    -- karakter, namlu yiv-set imza hash'inin hex uzunlugu
    BallisticLogRetentionDays = 30,    -- gun, balistik kayitlarin saklama suresi (temizlik gorevleri icin referans)
}

-- ============================================================
--  STASH LIMITS :: ox_inventory Agirlik Koprusu
-- ============================================================
Config.StashLimits = {
    MotelMaxGram   = 10000.0, -- gram, motel odasi basina azami kacak madde agirligi
    TrapHouseMaxKg = 500.0,   -- kg, trap house basina azami toplam envanter agirligi
    MotelSlots     = 40,      -- ox_inventory stash slot sayisi (motel)
    TrapHouseSlots = 100,     -- ox_inventory stash slot sayisi (trap house)
}

-- ============================================================
--  EXPLOIT BORDERS :: Istismar/Sahtecilik Sinirlari
-- ============================================================
Config.ExploitBorders = {
    SafeClaimRadius      = 3.0,   -- metre, meet-point bildiriminin gercek mulk konumuna izinli sapma payi
    ShotSpotterMaxDist   = 15.0,  -- metre, bir atisin yakindaki bir mulke "isabet" sayilacagi azami mesafe
    MinTimeBetweenDrops  = 4000,  -- ms, art arda silah sesi/rapor spam korumasi
}

-- ============================================================
--  SIGINT :: Sinyal Istihbarati / Kripto Simulasyonu
-- ============================================================
Config.Sigint = {
    HoneypotChance          = 0.08,  -- yeni hucre kaydinda honeypot olarak isaretlenme olasiligi
    PacketLeakBaseRatio     = 0.05,  -- her operasyon basina baz sizinti artisi
    PacketLeakCompromiseAt  = 0.75,  -- bu esigin ustu is_compromised bayragini tetikler
    CryptoCurrency          = 'XMR', -- Monero
}

-- ============================================================
--  AGENT SKILLS :: Bot Yetenek Matrisi (sigint_cellular_matrix koprusu)
--  synthesis_skill / trade_skill / opsec_skill icin min-maks carpan limitleri.
--  Yalnizca Opsec alt tablosu bugun the_bureau.lua tarafindan aktif tuketilir;
--  Synthesis ve Trade katsayilari ileriki katmanlarin (cooking/pazarlik)
--  ayni kaynaktan okumasi icin simdiden CBA usulu tanimlanir.
-- ============================================================
Config.AgentSkills = {
    MinSkill     = 0.00,
    MaxSkill     = 1.00,
    DefaultSkill = 0.10,

    -- OPSEC :: siber gizlilik / telsiz-burner telefon disiplini
    Opsec = {
        LowSkillThreshold      = 0.35,   -- bu esigin ALTINDAKI opsec_skill "dusuk disiplin" sayilir
        LeakPenaltyMulti       = 2.5,    -- opsec_skill = 0 iken Packet_Leak_Ratio artisina uygulanan azami carpan
        LeakLogBase            = 2.0,    -- logaritmik tirmanis tabani (deficiency 0->1 araliginda log egrisi)
        StingRayBaseChance     = 0.10,   -- esik ustu (disiplinli) bir hucre icin taban StingRay sevk olasiligi
        StingRayDispatchMulti  = 3.0,    -- LowSkillThreshold altinda, skill 0'a yaklastikca uygulanan azami sevk carpani
        StingRayVehicle        = 'speedo',
        StingRayPedModel       = 's_m_m_msec_01',
        StingRayLoiterDistance = 60.0,   -- metre, StingRay biriminin pasif konumlanma mesafesi
        StingRayLifetimeMs     = 240000, -- 4 dk, StingRay biriminin sahnede kalma suresi
    },

    -- SYNTHESIS :: kimyasal seyreltme/kesme (ileriki "cooking" katmani tuketecek)
    Synthesis = {
        LowSkillThreshold      = 0.35,
        OverdoseBaseChance     = 0.02,   -- taban hatali doz/overdose olasiligi (skill = MaxSkill iken)
        OverdoseLowSkillMulti  = 8.0,    -- synthesis_skill = 0 iken overdose olasiligina uygulanan azami carpan
        FireBaseChance         = 0.01,   -- taban laboratuvar/yangin olasiligi
        FireLowSkillMulti      = 6.0,    -- synthesis_skill = 0 iken yangin olasiligina uygulanan azami carpan
    },

    -- TRADE :: ticari ikna / pazar yonetim gucu (ileriki satis/pazarlik katmani tuketecek)
    Trade = {
        LowSkillThreshold      = 0.35,
        PriceNegotiationMulti  = 1.5,    -- trade_skill = MaxSkill iken azami satis fiyati carpani
        HeatSuppressionMulti   = 0.6,    -- trade_skill = MaxSkill iken satisin ekledigi heat'i bastirma carpani
    },
}

-- ============================================================
--  WEAPON ACOUSTICS :: Silah Sesi -> dB Referans Tablosu
--  (client_bureau.lua acilista bunu hash tablosuna donusturur)
-- ============================================================
Config.WeaponAcoustics = {
    { model = 'WEAPON_PISTOL',        db = 120.0 },
    { model = 'WEAPON_COMBATPISTOL',  db = 122.0 },
    { model = 'WEAPON_MICROSMG',      db = 128.0 },
    { model = 'WEAPON_SMG',           db = 130.0 },
    { model = 'WEAPON_ASSAULTRIFLE',  db = 155.0 },
    { model = 'WEAPON_CARBINERIFLE',  db = 157.0 },
    { model = 'WEAPON_SNIPERRIFLE',   db = 165.0 },
    { model = 'WEAPON_PUMPSHOTGUN',   db = 145.0 },
    { model = 'WEAPON_COMBATMG',      db = 150.0 },
}
Config.DefaultWeaponDb = 110.0 -- tabloda olmayan silahlar icin varsayilan dB
