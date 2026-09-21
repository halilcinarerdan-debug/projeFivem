Config = {}


Config.Tick = {
    IntervalMs       = 1000,
    SecondsPerMinute = 60,
    SecondsPerHour   = 3600
}


-- Persistence / write-behind
Config.Persistence = {
    BotFlushIntervalMs      = 15000,
    BotFlushMaxBatch        = 250,
    TrapHouseFlushIntervalMs= 20000,
    AsyncRetryBackoffMs     = 5000
}


-- Katman 1: Balistik / adli sabitler
Config.BaseCortisolRecoveryRate   = 0.05
Config.BallisticStriationPrecision= 0.85


Config.Forensics = {
    MatchCertaintyThreshold        = 0.75,
    FingerprintQualityCortisolWeight = 0.4,
    CasingWearWeight               = 0.3,
    CasingCortisolWeight           = 0.2
}


Config.Recruitment = {
    BaseEligibilityThreshold   = 1.2,
    ResilienceDamping          = 0.35,
    LieThreshold               = 0.35,
    ConfessionThreshold        = 0.75,
    MinConfessionsToPromote    = 3,
    MaxToleratedLies           = 4,
    SafeSnitchTendencyCeiling  = 0.6,
    MinOperationalResilience   = 0.25,


    -- ASCII ses-dalgası sorgu terminali
    WaveformWidth              = 20,
    LieWaveformDeviationPerLie = 0.15,


    -- Sokak Kulakları: bu momentum eşiğinin üstünde köstebek fısıltıları basılır.
    StreetWhisperMomentumThreshold = 0.5
}


Config.Bureau = {
    CellTowers = {
        { id = 1, coords = vector3(-100.0, -800.0, 30.0) },
        { id = 2, coords = vector3(400.0, -1200.0, 30.0) },
        { id = 3, coords = vector3(150.0, -2200.0, 30.0) },
        { id = 4, coords = vector3(-600.0, -1400.0, 30.0) },
        { id = 5, coords = vector3(900.0, -300.0, 60.0) },
        { id = 6, coords = vector3(-1100.0, -400.0, 35.0) }
    },
    TowerRange                 = 1200.0,
    BaseSearchRadius           = 2500.0,


    -- Triangulation AKTİF bir oyuncu hatasının (şifresiz telsiz kullanımı)
    -- ANLIK bedelidir - zamana yayılan pasif bir oran değildir, bu yüzden
    -- "Yarılanma Ömrü" türetmesine girmez. Doğrudan bir sabit olarak kalır,
    -- ama "ilk 1 saat çöküşü" riskini azaltmak için 0.04'ten 0.025'e
    -- yumuşatıldı (yaklaşık %37 daha az sert; hâlâ hatanın gerçek bir
    -- bedeli var, sadece anlık ölüm değil).
    TriangulationDecryptionGain= 0.025,


    RaidDecryptionThreshold    = 0.90,
    AnalysisIntervalSeconds    = 300,
    PropagandaGeometricFactor  = 1.15,
    PropagandaMomentumIncrement= 0.10,
    PropagandaMaxMomentum      = 6.0,
    CyberLeakGeometricFactor   = 1.20,
    CyberLeakIncrement         = 0.05,
    CyberLeakMaxIntensity      = 5.0,
    PostRaidHeatmapDecay       = 0.5,
    PostRaidDecryptionReset    = 0.0,


    -- qb-phone Canlı Yayın / Siber Propaganda Köprüsü. Hype, propagandaMomentum'un
    -- kendisini besler (Recruit_chance zaten momentum'a bağlı); bedel olarak en
    -- yakın trap house'un cyber-leak heatmap'i ve deşifre katsayısı da yükselir.
    -- (Gerçek per-tick artım oranları aşağıda "YARILANMA ÖMRÜ" bölümünde
    -- gerçek-zaman hedeflerinden TÜRETİLİR, burada magic number yazılmaz.)
    LivestreamHypeGeometricFactor    = 1.05,
    LivestreamHypeIncrementPerTick   = 0.05,


    -- Fiziksel Şafak Baskını mürettebat/breach matrisi (deterministik, RNG yok).
    RaidBaseSquadSize          = 2,
    RaidHeatSquadFactor        = 1.5,
    RaidMaxSquadSize           = 8,
    RaidExplosiveBreachThreshold = 0.97,
    RaidBaseEscapeWindowSeconds = 20,
    RaidDeadZoneEscapeBonusSeconds = 25
}


-- =====================================================================
-- YARILANMA ÖMRÜ / GERÇEK-ZAMAN DENGELEMESİ (OYNANABİLİRLİK KİLİDİ)
-- (v1 metni AYNEN korundu.)
-- =====================================================================
Config.Bureau.PatternFullDecryptionRealDays = 5.0
Config.Bureau.PatternAnalysisGain =
    Config.Bureau.RaidDecryptionThreshold
    / ((Config.Bureau.PatternFullDecryptionRealDays * 86400.0) / Config.Bureau.AnalysisIntervalSeconds)


Config.Bureau.LivestreamHeatFullSaturationRealMinutes = 20.0
Config.Bureau.LivestreamAloneFullDecryptionRealHours  = 3.0
Config.Bureau.LivestreamHeatIncrementPerTick =
    Config.Bureau.CyberLeakMaxIntensity / (Config.Bureau.LivestreamHeatFullSaturationRealMinutes * 60.0)
Config.Bureau.LivestreamDecryptionGainPerTick =
    Config.Bureau.RaidDecryptionThreshold / (Config.Bureau.LivestreamAloneFullDecryptionRealHours * 3600.0)


Config.Kitchen = {
    WorkFactor = {
        idle           = 0.0,
        lookout        = 0.01,
        distribution   = 0.02,
        cooking        = 0.035,
        cyber_ops      = 0.015,
        -- ★ KATMAN 7 FAZ 2: sokakta canlı NPC "keş" satışı yapan bir bot,
        -- distribution İLE AYNI yorgunluk yükünü taşır — yeni bir formül
        -- İCAT EDİLMEZ, mevcut ölçek yeniden kullanılır.
        street_dealing = 0.02
    },


    SkillGrowthRate = 0.01,
    FatigueCortisolBleed          = 0.02,
    FatigueWarningThreshold       = 0.8,
    FatigueCriticalThreshold      = 0.9,
    FatigueCriticalDurationSeconds= 3600,
    BurnoutResilienceLoss         = 0.10,
    BurnoutRecoveryRatePenalty    = 0.20,
    BurnoutRecoveryRateFloor      = 0.005,
    CortisolDeviationThreshold    = 0.8,
    CortisolDeviationDistance     = 100.0,


    WithdrawalGainPerAddictionPoint = 0.02,
    WithdrawalSkillPenaltyThreshold = 0.7,
    WithdrawalSkillPenaltyMultiplier= 0.5,
    TheftWithdrawalThreshold      = 1.0,
    TheftGramsPerAddictionPoint   = 10.0,
    RivalInfiltrationPurityThreshold = 0.30,
    CortisolSpike = {
        Gunshot              = 0.40,
        BureauVehicle        = 0.25,
        BureauVehicleRadius  = 50.0
    },
    SnitchThreshold = 0.75
}


Config.Player = {
    DefaultResilience      = 0.5,
    DefaultSkillChemistry  = 0.4,
    StateIdleTimeoutSec    = 600
}


Config.RoleModels = {
    dealer  = 's_m_y_dealer_01',
    runner  = 'a_m_y_runner_01',
    lookout = 'a_m_y_skater_01',
    cooking = 's_m_m_chemsec_01'
}
Config.DefaultRoleModel = 's_m_y_dealer_01'


-- =====================================================================
-- Katman 4: Programli Lojistik Sevk & Zaman-Mesafe Surtunme Motoru
-- =====================================================================
Config.Logistics = {
    BaseSpeedUnitsPerSecond   = 5.0,
    WeightFrictionCoefficient = 0.005,


    DefaultVehicleType     = 'foot',
    DispatchTickIntervalMs = 1000,


    VehicleTypes = {
        foot = {
            SpeedCoefficient           = 0.2,
            FrictionMultiplier         = 1.00,
            PoliceDecryptionMultiplier = 0.05,
            CombatResistance           = 0.00
        },
        motorbike = {
            SpeedCoefficient           = 1.0,
            FrictionMultiplier         = 1.25,
            PoliceDecryptionMultiplier = 1.40,
            CombatResistance           = 0.30
        },
        car = {
            SpeedCoefficient           = 0.6,
            FrictionMultiplier         = 1.85,
            PoliceDecryptionMultiplier = 1.00,
            CombatResistance           = 0.80
        }
    },


    CombatEliminationThreshold = 1.0,


    PoliceDecryptionGainPerTick = 0.01,


    MaxDispatchRangeMeters = 6000.0,


    -- Origin ile hedef arasındaki mesafe bu değerin ALTINDAYSA (nil hedef dahil)
    -- sevk tamamen İPTAL edilir.
    MinDispatchDistanceMeters = 5.0,


    DeadZones = {
        { id = 1, label = 'Tunel Bolgesi',    coords = vector3(-1200.0, -560.0, 30.0),  radius = 300.0 },
        { id = 2, label = 'Endustriyel Vadi', coords = vector3(900.0, -2400.0, 10.0),   radius = 250.0 },
        { id = 3, label = 'Dag Gecidi',       coords = vector3(-1900.0, 2200.0, 150.0), radius = 400.0 }
    },
    DeadZoneLogFlushDelayMs = 4000,


    Fleet = {
        DefaultVehicleClass = 'car',
        DefaultVinStatus    = 'hot',


        WearFrictionBonus = 0.20,


        VinDecryptionMultiplier = {
            factory   = 3.0,
            scratched = 1.5,
            hot       = 1.0
        },


        SeizureSealCertainty = {
            factory   = 0.95,
            scratched = 0.65,
            hot       = 0.40
        },


        BreakdownWearThreshold = 0.75,
        BreakdownStallSeconds  = 45
    }
}


-- =====================================================================
-- Katman 4: Toptancı İlişki Matrisi & Dead Drop Lojistiği
-- =====================================================================
Config.Supplier = {
    Suppliers = {
        { id = 1, name = 'Los Santos Kartel',      base_price_per_gram = 12.0 },
        { id = 2, name = 'Vagos Baglantisi',       base_price_per_gram = 9.5  },
        { id = 3, name = 'Rus Ithalat Agi',        base_price_per_gram = 15.0 }
    },
    DeadDrops = {
        { id = 1, supplier_id = 1, label = 'Liman Konteyner Sahasi',       coords = vector3(-50.0, -2400.0, 5.0),   radius = 15.0 },
        { id = 2, supplier_id = 2, label = 'Terkedilmis Benzin Istasyonu', coords = vector3(1700.0, 3200.0, 40.0),  radius = 15.0 },
        { id = 3, supplier_id = 3, label = 'Havaalani Kargo Deposu',      coords = vector3(-1000.0, -2700.0, 15.0), radius = 15.0 }
    },


    DefaultTrust                = 0.5,
    TrustLatePaymentPenalty     = 0.15,
    TrustForensicLeakPenalty    = 0.10,
    TrustHeatmapPenaltyFactor   = 0.20,
    TrustRecoveryPerCleanPickup = 0.03,


    PassiveTrustRecoveryPerRealDay = 0.02,
    PassiveTrustRecoveryTarget     = 0.5,


    PriceMultiplierFloor   = 1.0,
    PriceMultiplierCeiling = 4.0,
    PriceMultiplierGain    = 1.0,


    SupplyCutTrustThreshold = 0.1,
    BetrayalTrustThreshold  = 0.1,


    ForensicTraceQualityThreshold = 0.5,


    DropHeatGrowthPerUse   = 0.25,
    DropHeatDecayPerMinute = 0.01,


    PickupWindowSeconds = 600
}


-- =====================================================================
-- KATMAN 5: QBOX CO-OP KARTEL HİYERARŞİSİ + BÖLGESEL PİYASA +
-- KILCAL DAMAR HARDCORE MEKANİKLER
-- =====================================================================
Config.Hierarchy = {
    Ranks = {
        Leader            = { level = 3, label = 'Baron' },
        Logistics_Officer = { level = 2, label = 'Lojistik Subayı' },
        Chemist           = { level = 1, label = 'Kimyager' }
    },
    MinRankLevelForCommand = 2
}


Config.Market = {
    Zones = {
        { id = 1, label = 'Liman Bölgesi',  coords = vector3(-50.0, -2400.0, 5.0),   radius = 400.0 },
        { id = 2, label = 'Sanayi Bölgesi', coords = vector3(900.0, -2400.0, 10.0),  radius = 400.0 },
        { id = 3, label = 'Merkez Bölgesi', coords = vector3(200.0, -800.0, 30.0),   radius = 400.0 },
        { id = 4, label = 'Banliyö Bölgesi',coords = vector3(-1200.0, -560.0, 30.0), radius = 400.0 }
    },


    GourmetCognitiveShifterThreshold = 0.7,
    GourmetMinPurity                 = 0.30,


    RejectionPriceDecayRate    = 0.35,
    DemandElasticity           = 0.6,
    PriceMultiplierFloor       = 0.4,
    PriceMultiplierCeiling     = 2.5,
    PriceMultiplierDefault     = 1.0
}


Config.Forensics.WeaponDurabilityLabBlindnessThreshold = 0.5
Config.Forensics.WeaponDurabilityBlindnessDecayRate     = 4.0
Config.Forensics.WeaponJamChanceThreshold               = 0.2
Config.Forensics.WeaponJamBaseChance                    = 0.65
Config.Forensics.WeaponJamHardDeleteRisk                = 0.90


Config.RadioSilence = {
    MaxDurationMinutes = 30
}


-- ---------------------------------------------------------------------
-- ★ KATMAN 7 [T3]: SESSİZLİK İHLALİ CEZA KATSAYILARI
-- Yolda seyir halindeki (aktif dispatch) bir bota, dispatcher /sessizlik
-- altındayken telsizden müdahale edilirse (bkz. server/main.lua
-- Matrix.TriggerPanicEvacuation -> server/market.lua Matrix.RadioSilence.
-- BreakForRedirect) statik parazit şiddeti VE Büro'nun ilgili trap house
-- decryption_confidence'ı (Matrix.Bureau.AdvanceDecryption) BU İKİ TABANDAN
-- BreakGeometricFactor üssel katsayısıyla büyür — art arda ihlaller
-- katlanarak daha pahalıya patlar. Sayaç /sessizlik yeniden başlatıldığında
-- sıfırlanır (bkz. server/market.lua Matrix.RadioSilence.Start).
-- ---------------------------------------------------------------------
Config.RadioSilence.BreakBaseStatic         = 0.35
Config.RadioSilence.BreakBaseDecryptionGain = 0.05
Config.RadioSilence.BreakGeometricFactor    = 1.75


Config.CashDecay = {
    TraceHalfLifeRealDays         = 90.0,
    RaidRiskMultiplierAtMaxTrace  = 2.0,
    LaunderReducesAmount          = true,
    TickIntervalMs                = 60000
}


Config.Undercover = {
    InfiltrationMomentumThreshold = 3.0,
    SuspicionReportWeight   = 0.40,
    SuspicionDealWeight     = -0.15,
    SuspicionThreshold      = 0.50,
    ScanIntervalSeconds     = 300
}


-- =====================================================================
-- KATMAN 5: SAF METİN TABANLI MONOKROM TAKTİK HUD (client/hud.lua)
-- Veri, server'ın zaten dönen 1000ms master ticker'ından push edilir
-- (Config.Tick.IntervalMs) — ayrı bir server-side thread AÇILMAZ.
--
-- ★ SERTLEŞTİRME: inputDialog çıktıları ExecuteCommand'a girmeden önce
-- bu sınırlara göre sanitize edilir (bkz. client/hud.lua). Boşluk içeren
-- veya [%w%-_%.] dışında karakter taşıyan girdiler REDDEDİLİR.
--
-- ★ KATMAN 5 EVRİM: "Sıfır Sayı Standardı" + Multi-Waypoint Rota Motoru.
--   - Bulletins: HUD/F10 arayüzlerinde ham float YASAK; bu eşikler ham
--     cortisol_level/fatigue_level/durability değerlerini edebi/askeri
--     bültenlere çevirmek için client/hud.lua tarafından okunur. Sunucu
--     konsolu (print/Matrix.Log) ve /matrixdump HER ZAMAN ham float
--     döker — bu eşikler yalnızca HUD/F10 GÖRÜNÜMÜNÜ etkiler.
--   - MaxWaypointInputLength / RouteWaypointCount: /rotaciz (F10 -> "Rota
--     Çiz") çoklu-uğrak taktik rota motorunun girdi sanitizasyon sınırları.
--     Waypoint girdisi ya "x,y,z" (vector3) ya da bir Trap House ID (tam
--     sayı) formatındadır; her ikisi de yalnızca rakam/nokta/virgül/eksi
--     karakterlerinden oluşabilir (bkz. client/hud.lua SanitizeWaypointArg).
-- =====================================================================
Config.Hud = {
    ToggleKey            = 'F6',
    MaxBotIdInputValue   = 999999,
    MaxPlateInputLength  = 32,
    MaxHudLines          = 64,


    MaxWaypointInputLength = 64,
    RouteWaypointCount     = 3,


    Bulletins = {
        Cortisol = {
            CalmMax    = 0.20,  -- < 0.20     -> [NABIZ: SOĞUKKANLI SUBAY]
            AnxietyMax = 0.60   -- 0.20-0.60  -> ANKSİYETE; > 0.60 -> AKUT PANİK
        },
        Fatigue = {
            FreshMax   = 0.30,  -- < 0.30     -> [KONDİSYON: DİNÇ]
            ChronicMax = 0.80   -- 0.30-0.80  -> KRONİK BİTKİNLİK; > 0.80 -> NÖRON HASARI
        },
        Mechanical = {
            PristineMin = 0.80, -- > 0.80     -> [MEKANİK: KUSURSUZ CONDITION]
            WornMin     = 0.40  -- 0.40-0.80  -> YİV-SET AŞINMASI; < 0.40 -> KRİTİK ERİME
        }
    }
}


-- =====================================================================
-- ★★★ KATMAN 5 ULTIMATE: CO-OP & SIGINT/COMINT BALİ-LOJİSTİK MATRİSİ ★★★
-- Aşağıdaki bloklar YENİ eklemelerdir; yukarıdaki hiçbir alan/tablo/anahtar
-- DEĞİŞTİRİLMEDİ (mevcut 16 tablo şeması ve tüm eski davranış korunuyor).
-- =====================================================================


-- ---------------------------------------------------------------------
-- [U1] Multi-Waypoint Otomatik İntikal — Trap House varışında otomatik
-- stash teslimatı için "varış" sayılacak yarıçap (metre).
-- ---------------------------------------------------------------------
Config.Logistics.TrapHouseArrivalStashRadius = 15.0


-- ---------------------------------------------------------------------
-- ★ KATMAN 7 [T2]: MÜHİMMAT DAĞITIM GÖREVİ MANİFESTOSU
-- Lojistik rütbesindeki (bot.role == 'runner') bir bot, "Mühimmat Dağıtım
-- Görevi" tetiklendiğinde trap house'un ortak deposundan (matrix_trap_
-- stash_<id>) BU listedeki kalemleri kendi envanterine (dealer_<id>)
-- çeker (bkz. server/logistics.lua Matrix.Logistics.DispatchAmmoRun).
-- Kalemler KASITLI olarak Config.BlackMarket'te ZATEN tanımlı item id'leri
-- kullanır — yeni bir item icat edilmez. Silahlar mühimmatsız (ayrı
-- ammo_rifle item'ı yüklenmeden) teslim edilir; bu ox_inventory'nin zaten
-- var olan silah/mühimmat ayrımıdır.
-- ---------------------------------------------------------------------
Config.Logistics.AmmoRunManifest = {
    { item = 'weapon_assaultrifle', count = 1  }, -- silahsız AK-47 (Config.BlackMarket.Weapons ile aynı item)
    { item = 'ammo_rifle',          count = 90 }, -- şarjör/mühimmat (Config.BlackMarket.Ammo ile aynı item)
    { item = 'weapon_spare_barrel', count = 1  }  -- yedek namlu (Config.BlackMarket.SpareBarrelItem ile aynı item)
}


-- ---------------------------------------------------------------------
-- [U2] TAKTİK KARABORSA TİCARET AĞI (Config.BlackMarket)
-- Tüm fiyatlar oyuncunun nakit (qbx 'cash') parasından tahsil edilir.
-- Kimlik üretimi (plaka/seri no) KESİNLİKLE RNG KULLANMAZ — bkz.
-- server/blackmarket.lua GenerateScratchedPlate/GenerateWeaponSerial
-- (GetGameTimer + girdi-türevli sağlama toplamı, tamamen deterministik).
-- ---------------------------------------------------------------------
Config.BlackMarket = {
    -- Karaborsa araç kataloğu: matrix_fleet'e vin_status='scratched' ile
    -- eklenir. `vehicle_class` DISPATCH_VEHICLE_MODELS (server/main.lua)
    -- üzerinden fiziksel sevk sırasında spawn edilecek modeli belirler —
    -- mevcut sınıf-bazlı spawn mimarisi DEĞİŞTİRİLMEDİ, katalog yalnızca
    -- bu sınıflardan (car/motorbike) seçim sunar.
    Vehicles = {
        { id = 'bm_sultan',  label = 'Sultan (Plaka Silinmiş)',        vehicle_class = 'car',       price = 45000.0, vehicle_wear = 0.35 },
        { id = 'bm_buffalo', label = 'Buffalo (Kaçak İthal Gövde)',    vehicle_class = 'car',       price = 62000.0, vehicle_wear = 0.45 },
        { id = 'bm_bati',    label = 'Bati Motosiklet (Şase Kazınmış)',vehicle_class = 'motorbike', price = 18000.0, vehicle_wear = 0.25 }
    },


    -- Karaborsa silah kataloğu: ox_inventory item adı + başlangıç metadata.
    Weapons = {
        { id = 'bm_pistol', label = 'Tabanca (Seri No Silinmiş)', item = 'weapon_combatpistol', price = 3800.0,  durability = 55.0 },
        { id = 'bm_ak47',   label = 'AK-47 (Seri No Silinmiş)',   item = 'weapon_assaultrifle', price = 15500.0, durability = 45.0 }
    },


    -- ★ KATMAN 6: mühimmat kataloğu — silahlarla AYNI Rendezvous teslim
    -- akışından geçer (bkz. server/rendezvous.lua). `item`/`count` çifti
    -- ox_inventory'ye handoff anında AddItem ile eklenir.
    Ammo = {
        { id = 'bm_ammo_pistol', label = 'Tabanca Mühimmatı (x60, Elden)', item = 'ammo_pistol', count = 60, price = 900.0  },
        { id = 'bm_ammo_rifle',  label = 'Tüfek Mühimmatı (x90, Elden)',   item = 'ammo_rifle',   count = 90, price = 2100.0 }
    },


    -- Yedek Namlu: sarf malzemesi item; /namludegistir bunu tüketir.
    SpareBarrelItem  = 'weapon_spare_barrel',
    SpareBarrelLabel = 'Yedek Namlu (Temiz)',
    SpareBarrelPrice = 2200.0,


    -- Açık Hat (Burner Phone): sahte IMEI'li, COMINT modülünün
    -- "GÜVENLİ AÇIK HAT" durumunu tetikleyen item.
    BurnerPhones = {
        { id = 'bm_burner', label = 'Açık Hat (Sahte IMEI)', item = 'burner_phone', price = 2500.0 }
    },


    -- /namludegistir yalnızca bu whitelist'teki silah item'ları için çalışır.
    ReplaceableWeaponItems = {
        weapon_combatpistol = true,
        weapon_assaultrifle = true
    }
}


Config.Forensics.WeaponShotLifespan = {
    weapon_combatpistol = 15000,
    weapon_assaultrifle = 20000
}
Config.Forensics.WeaponShotLifespanDefault = 15000


Config.Forensics.MechanicalJamThresholdPercent = 40.0 -- Durability (%) bu esigin altindaysa risk baslar
Config.Forensics.MechanicalJamExponent         = 3
Config.Forensics.MechanicalJamCoefficient      = 0.35


Config.Forensics.WeaponEvacuationSeconds = 6 -- 'X' tusu / F10 tahliye progressCircle suresi


-- ---------------------------------------------------------------------
-- [U4] SIGINT — BÖLGE DENETLEYİCİLERİ (Inspectors) & KÖSTEBEK TARAMASI
-- ---------------------------------------------------------------------
Config.Inspector = {
    -- Yalnızca bu rollerdeki botlar 'Inspector'a terfi ettirilebilir
    -- ('dealer' rolünün üstünde çalışacak kıdemli kurye tanımına uyar).
    PromotableRoles = { dealer = true, runner = true },


    MoleSnitchThreshold = 0.75, -- bot.psychology.snitch_tendency bu esigi GECERSE kostebek isaretlenir
    ScanIntervalSeconds = 180
}


-- ---------------------------------------------------------------------
-- [U5] COMINT — TELSİZ / TELEFON İLETİŞİM PROFİLİ
-- ---------------------------------------------------------------------
Config.Comint = {
    NormalCallTriangulationSeconds = 120, -- normal hatta bu sureyi gecen goruşme kirmizi uyari tetikler
    ToggleKey = 'K'                        -- COMINT panelini (Taktik HUD) acan ek tus
}


-- ---------------------------------------------------------------------
-- [U6] BÖLGESEL MALİ RAPOR — Karaborsa ekonomisi kâr/zarar bilançosu.
-- Bu iki sabit, ham gram satışlarını Bölgesel Mali Rapor için brüt
-- ciro/net kâra çevirmek amacıyla kullanılan ŞEFFAF varsayılan birim
-- fiyatlardır (gerçek toptancı fiyatlarının ortalamasına yakın tutuldu).
-- ---------------------------------------------------------------------
Config.Market.StreetBasePricePerGram   = 20.0
Config.Market.EstimatedCostBasisPerGram= 12.0


-- =====================================================================
-- ★★★ KATMAN 6: SİBER-TAKTIK OPERASYON VE STRATEJİK TRAP HOUSE MİMARİSİ ★★★
-- Aşağıdaki bloklar TAMAMEN YENİ EKLEMELERDİR. Katman 1-5(Ultimate)'in
-- hiçbir alanı/tablosu/anahtarı DEĞİŞTİRİLMEDİ. Bu bölüm, yeni server/
-- rendezvous.lua, server/trap_house_interior.lua, server/workbench.lua ve
-- server/door_reinforcement.lua dosyalarının Config sözleşmesidir — o
-- dosyalar YALNIZCA burada tanımlı anahtarları okur.
-- =====================================================================


-- ---------------------------------------------------------------------
-- [K6-1] RENDEZVOUS / DEAD DROP TESLİMATI + BÜRO PUSUSU
-- Karaborsa silah/mühimmat alımı artık envantere ANINDA düşmez; bir
-- buluşma koordinatı (satıcı NPC) üretilir. RNG YOK: koordinat, alıcının
-- citizenid'i + monoton bir sayaç + satın alma anındaki oyuncu konumundan
-- türetilen deterministik bir açı/mesafe ile hesaplanır (bkz.
-- server/rendezvous.lua Matrix.Rendezvous.ComputeHandoffCoords — aynı
-- ChecksumOf deseni server/blackmarket.lua'dan ödünç alınır).
-- ---------------------------------------------------------------------
Config.Rendezvous = {
    Enabled                 = true,
    MinOffsetMeters         = 150.0,
    MaxOffsetMeters         = 400.0,
    PickupWindowSeconds     = 900,
    PickupRadiusMeters      = 8.0,


    SellerPedModel          = 'g_m_y_mexgoon_01',
    SellerScenario          = 'WORLD_HUMAN_STAND_IMPATIENT',


    -- Handoff anında en yakın trap house'un Büro siber ısısı (bkz.
    -- Matrix.Bureau.GetHeat, zaten var olan salt-okunur getter) bu eşiği
    -- (heat / CyberLeakMaxIntensity oranı) GEÇERSE pusu tetiklenir.
    AmbushTraceLevelThreshold = 0.55,


    AmbushPedModel          = 's_m_y_swat_01',
    AmbushWeapon            = 'WEAPON_CARBINERIFLE',
    AmbushSquadSize         = 4,
    AmbushSpawnRadius       = 35.0,
    AmbushAggroRadius       = 60.0
}


-- ---------------------------------------------------------------------
-- [K6-2] SANAL MAHALLE EVİ (INTERIOR INSTANCE)
-- Fütüristik/high-tech sığınak YASAK — vanilla GTA V döküntü iç mekan
-- kabukları (motel/apartman) + SetRoutingBucket ile ORTAK koordinatlar
-- üzerinde ÖZEL (instance) bir oda üretilir. Bucket = BucketBase +
-- trapHouseId (her trap house'a biricik bir bucket garanti eder).
-- ---------------------------------------------------------------------
Config.TrapHouseInterior = {
    BucketBase        = 20000,
    EntryRadius       = 1.5,
    ExitRadius        = 1.5,


    -- ★ TEŞHİS DÜZELTMESİ: giriş mesafesi yatay (X,Y) ve dikey (Z) olarak
    -- AYRI ölçülür (bkz. server/trap_house_interior.lua HorizontalDistance).
    -- Trap house koordinatı yer seviyesinde kaydedilmiş olsa bile oyuncu
    -- bir kaldırım/basamak/eşikte durunca Z birkaç metre kayabilir; dikeyde
    -- bu yüzden çok daha toleranslı bir sınır kullanılır.
    EntryZTolerance   = 8.0,


    -- ★ KÖKLÜ DEĞİŞİKLİK (canlı testte doğrulandı): önce Trevor'ın treyleri
    -- (bob74_ipl, interiorId 2562) denendi — koordinat/IPL/export hepsi
    -- doğruydu (IsIplActive=true, GetInteriorAtCoords sıfır değil) ama
    -- `PinInteriorInMemory` + 15 saniye beklemeye rağmen `IsInteriorReady`
    -- HİÇBİR ZAMAN true olmadı: bu sunucu ortamında bu spesifik (tek
    -- oyunculu hikaye içeriği) interior güvenilir şekilde stream edilemiyor.
    -- Kullanıcı kararıyla TAMAMEN TERK EDİLDİ. Yerine bob74_ipl'in GTA Online
    -- "düşük gelirli ev" interior'ı kullanılıyor (GTAOHouseLow1, interiorId
    -- 149761 — bkz. client/trap_house_client.lua GetGTAOHouseLow1Object()).
    -- DLC/çok-oyunculu interior'lar milyonlarca GTA Online oyuncusu
    -- tarafından günlük kullanıldığından çok daha güvenilir stream ediliyor;
    -- ayrıca `Smoke.Set(stage2)` ile bedavaya "hafif kirli/dumanlı" atmosfer
    -- sağlıyor. Koordinat (bob74_ipl'in kendi client.lua'sındaki yorumdan
    -- doğrulandı): X:261.4586 Y:-998.8196 Z:-99.00863 — bu, apartman
    -- interior'larının paylaştığı ayrı/yeraltı "interior cebi" konumudur
    -- (normal harita ile çakışmaz).
    --
    -- ★ DÜZELTME (canlı testte bulundu, KALICI kök-neden çözümü uygulandı):
    -- Workbench/Packaging kapıya çok yakın olunca (INTERACT_RADIUS=2.0
    -- içinde çakışınca) tezgaha basmak için E'ye basıldığında oyuncu AYNI
    -- ANDA çıkış tetiğinin de menzilindeydi ve hem tamir hem çıkış birlikte
    -- tetikleniyordu, oyuncu dışarı fırlıyordu. Asıl düzeltme client/
    -- trap_house_client.lua'nın etkileşim döngüsünde: artık exit/workbench/
    -- packaging bağımsız üç `if` değil, "en yakın TEK bölge" seçiliyor —
    -- noktalar ne kadar yakın olursa olsun çift tetikleme artık YAPISAL
    -- olarak imkansız. Bu yüzden koordinatlar arasındaki mesafe artık bir
    -- doğruluk sorunu değil, yalnızca kozmetik bir tercih. WorkbenchPos,
    -- kullanıcının oyun içinde bizzat durup "/coords" ile aldığı gerçek
    -- konum (bkz. ekran görüntüsü) — EnterCoords/ExitCoords (kapı) kasıtlı
    -- olarak DEĞİŞTİRİLMEDİ. İnteriorun render OLMAMASI durumunda client/
    -- trap_house_client.lua'daki "/traphouseipldebug" teşhis komutu
    -- IsIplActive/GetInteriorAtCoords/IsInteriorReady sonuçlarını F8
    -- konsoluna basar.
    Shell = {
        EnterCoords  = vector4(261.4586, -998.8196, -99.00863, 0.0),
        WorkbenchPos = vector3(258.303, -997.279, -99.015),
        PackagingPos = vector3(258.303, -994.279, -99.015),
        ExitCoords   = vector4(261.4586, -998.8196, -99.00863, 180.0)
    },


    -- ★ DÜZELTME: eskiden burada rastgele modelli KOZMETİK "ambient" NPC
    -- listesi (AmbientPedCount/AmbientPedModels) vardı. Kaldırıldı — içeride
    -- artık YALNIZCA server/trap_house_interior.lua'nın GetResidentBots'unun
    -- döndürdüğü, o trap house'a GERÇEKTEN atanmış Matrix.Bots kayıtları
    -- görünür (bkz. client/trap_house_client.lua RESIDENT_BOT_PED_MODEL).
    -- AmbientScenarios sadece bu GERÇEK botların oynadığı animasyon
    -- havuzu olarak kalıyor (kimlik değil, salt duruş/aksiyon çeşitliliği).
    AmbientScenarios = {
        'WORLD_HUMAN_SMOKING', 'WORLD_HUMAN_STAND_IMPATIENT', 'WORLD_HUMAN_LEANING'
    }
}


-- ---------------------------------------------------------------------
-- [K6-3] SİLAH TAMİR TEZGAHI (WORKBENCH) + PAKETLEME ODASI
-- Nakit YOK — yalnızca bileşen tüketimi. Tamir tamamlandığında
-- server/forensics.lua'nın MEVCUT Matrix.Forensics.WipeBallisticRecord
-- fonksiyonu (değiştirilmedi) çağrılır.
-- ---------------------------------------------------------------------
Config.Workbench = {
    Radius = 2.0,
    RequiredItems = {
        { item = 'yiv_set_raybasi',        label = 'Yiv-Set Raybası',            count = 1 },
        { item = 'namlu_celik_tiraslama',  label = 'Namlu Çeliği Tıraşlama Sıvısı', count = 1 },
        { item = 'mekanik_igne_yayi',      label = 'Mekanik İğne Yayı',          count = 1 }
    }
}


Config.PackagingRoom = {
    Radius = 2.0,
    -- Paketleme odasında "çalıştırılan" bir trap house'daki tüm dealer
    -- botları mevcut Kitchen motorunun 'distribution' aktivitesine
    -- (skill_logistics büyümesi + normal fatigue formülü) geçirilir —
    -- YENİ bir ekonomi formülü İCAT EDİLMEZ, var olan sistem yeniden kullanılır.
    FlavorLogIntervalSeconds = 300
}


-- ---------------------------------------------------------------------
-- [K6-4] KAPI SÜRGÜ TAHKİMATI (Door Reinforcement)
-- Seviye arttıkça Matrix.Bureau.IssueRaid'in escapeWindow'una (kapı
-- kırılma süresi) EKLENEN bonus artar. Level 3 + düz arazi (dead-zone
-- bonusu yok) varsayılan olarak TAM 240 saniye üretir:
--   RaidBaseEscapeWindowSeconds(20) + Level3 bonus(220) = 240s.
-- ---------------------------------------------------------------------
Config.DoorReinforcement = {
    MaxLevel = 3,
    Levels = {
        [0] = { label = 'Takviyesiz Eski Ahşap Kapı',      price = 0,     breach_bonus_seconds = 0   },
        [1] = { label = 'Takviyeli Ahşap Sürgü',           price = 8000,  breach_bonus_seconds = 60  },
        [2] = { label = 'Çelik Sürgü Barikatı',            price = 22000, breach_bonus_seconds = 150 },
        [3] = { label = 'Çift Katlı Çelik Barikat (Maks)', price = 45000, breach_bonus_seconds = 220 }
    }
}


-- =====================================================================
-- ★★★ KATMAN 7 [T4] FAZ 1: OTONOM DEPO LOJİSTİĞİ VE BÜRO KİLİDİ ★★★
-- Aşağıdaki bloklar TAMAMEN YENİ EKLEMELERDİR. Katman 1-6'nın hiçbir
-- alanı/tablosu/anahtarı DEĞİŞTİRİLMEDİ. Bu bölüm server/bureau.lua'nın
-- (dosya sonuna eklenen [T4] bloğu) ve YENİ server/district_hubs.lua'nın
-- Config sözleşmesidir.
--
-- ★ ÖNEMLİ KAPSAM NOTU: 'matrix_trap_stash' burada AYRI bir SQL tablosu
-- olarak YENİDEN İCAT EDİLMEDİ — trap house'un ortak deposu zaten
-- server/logistics.lua ve server/main.lua'nın matrix_trap_stash_<id>
-- ox_inventory stash'i (RegisterStash/AddItem/RemoveItem) olarak MEVCUT.
-- server/district_hubs.lua bu MEVCUT stash'ten çeker; ikinci bir kalıcılık
-- kaynağı açmak veri tutarsızlığına yol açardı.
-- =====================================================================

-- [T4-1] BÜRO KİLİDİ (Nükleer Abluka) — decryption_confidence/IssueRaid'in
-- (tek trap house, %90 baraj) ÜZERİNE, aynı trap house'un BİRİKMİŞ telsiz
-- ihlali + ele geçirilen ürün saflığından beslenen İKİNCİ, bağımsız bir
-- deterministik eşik. RNG YOK: coefficient = breachRatio*BreachWeight +
-- purityRatio*PurityWeight; her iki oran da [0,1]'e kırpılır.
Config.Bureau.LockdownEvidenceThreshold = 0.75
Config.Bureau.LockdownBreachCeiling     = 12   -- radio_breach_count bu değerde breachRatio 1.0'a doyar
Config.Bureau.LockdownBreachWeight      = 0.70
Config.Bureau.LockdownPurityWeight      = 0.30
-- IssueRaid tetiklendiğinde (bkz. Config.Bureau.PostRaidHeatmapDecay ile
-- AYNI felsefe) learning-core sayaçları da soğur — ayrı bir sabit İCAT
-- EDİLMEZ, mevcut decay katsayısı yeniden kullanılır.

-- [T4-2] TOPLU SATIŞ HUB'LARI (District Distribution Hubs) — F10 ile
-- kritik kavşaklara atanan, trap house'un ortak deposundan (matrix_trap_
-- stash_<id>) sabit miktarlı/RNG'siz toplu satış döngüsü yürüten düğümler.
-- Ciro, MEVCUT Matrix.CashDecay.Deposit (server/market.lua) kirli-nakit
-- hattına, MEVCUT Config.Market.StreetBasePricePerGram birim fiyatıyla
-- akar — yeni bir ekonomi formülü icat edilmez.
Config.DistrictHubs = {
    MaxPerTrapHouse       = 3,
    SaleBatchGrams        = 10,
    DemandCycleSeconds    = 45
}

-- [T4-3] GELECEKTEKİ OPENAI / CHATGPT ANALİZ KÖPRÜSÜ — server/bureau.lua
-- [T4] tick'ine eklenen PASİF, varsayılan KAPALI danışma katmanı.
-- fallbackToDeterministic=true olduğu sürece (ve HER durumda, çünkü Büro'nun
-- kilit kararı ASLA bu bloğu beklemez) matrix_bureau_learning_core'daki
-- deterministik motor bu köprüden bağımsız çalışmaya devam eder; internet
-- kesilirse veya apiKey boşsa sistem otomatik olarak yerel sıfır-RNG
-- şablonlarına düşer, resmon 0'da kalır (yeni bir thread AÇILMAZ, mevcut
-- [T4] tick'inin periyoduna eklenir).
Config.AI_Matrix_Brain = {
    enabled                 = false,
    provider                = 'openai',
    apiKey                  = 'sk-...',
    analysisIntervalMinutes = 60,
    fallbackToDeterministic = true
}


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: PAKETLEME ODASI, SOKAK SATIŞ DÖNGÜSÜ, REAL-TIME
-- ÜST ARAMA/EL KOYMA, BAGAJ AMELİYATI, PROPAGANDA→DEVŞİRME KÖPRÜSÜ ★★★
-- Aşağıdaki bloklar TAMAMEN YENİ EKLEMELERDİR. Katman 1-7[T4]'ün hiçbir
-- alanı/tablosu/formülü DEĞİŞTİRİLMEDİ — her biri ZATEN VAR OLAN bir
-- motora (ProcessCook/output_purity, EvaluateSale/GourmetMinPurity,
-- Fleet.SeizeVehicle, Forensics.WipeBallisticRecord, Bureau.
-- RecordRadioBreach, CashDecay.Deposit, CompleteDispatch'in guard'lı
-- hook zinciri) bağlanır; yeni bir paralel ekonomi/formül İCAT EDİLMEZ.
-- =====================================================================

-- [F2-1] MUTFAK PAKETLEME ODASI — Matrix.Kitchen.ProcessCook'un ürettiği
-- output_purity/final_weight, dosya sonuna eklenen tek satırlık bir hook
-- ile trap house deposuna (matrix_trap_stash_<id>) fiziksel bir ham madde
-- item'ı (metadata.purity taşır) olarak yansıtılır. Bu oda o kütleyi
-- kesme ajanıyla karıştırıp 10 gramlık, metadata-purity taşıyan kurye
-- paketlerine (Products listesindeki item'lardan biri) böler.
Config.Kitchen.Packaging = {
    RawItem = 'meth_raw_batch',
    Products = {
        { item = 'meth_bag',   label = 'Metamfetamin Torbasi' },
        { item = 'coke_brick', label = 'Kokain Kalibi' }
    },
    PackageGrams                 = 10.0,
    CuttingAgentItem              = 'cutting_agent',
    CuttingAgentGramsPerPackage   = 2.0,
    PurityDilutionPerCutGram      = 0.015,
    MinPurityFloor                = 0.05,
    MaxPackagesPerRun             = 12,
    ProgressMs                    = 6500
}

-- [F2-2] SOKAKTA CANLI NPC "KEŞ" SATIŞ DÖNGÜSÜ — GourmetMinPurity ZATEN
-- Config.Market'te var (Katman 5); burada yalnızca NPC yaklaşma/devşirme
-- parametreleri eklenir. "Keşin addiction_level'ı" burada matrix_customer_
-- pool (gerçek oyuncu kimliği gerektirir) İLE KARIŞTIRILMAZ — ambient NPC
-- müşteriler kalıcı bir citizenid taşımadığından, bağımlılık BİRİKİMİ
-- dealer/bot başına bir "sokak doygunluğu" sayacı (RAM, matrix_dispatches
-- ile AYNI kalıcılık sınıfı) olarak modellenir; eşik aşılınca bir sonraki
-- yaklaşan NPC devşirme adayı olarak işaretlenir.
Config.Market.StreetDealing = {
    DealingModeCommand         = 'torbacilikyap',
    NpcScanIntervalMs          = 1000,
    NpcApproachIntervalMs      = 25000,
    NpcSearchRadius            = 40.0,
    NpcArriveDistance          = 1.6,
    NpcWalkSpeed               = 1.0,
    NpcTimeoutMs               = 60000,
    MinSaleCash                = 60,
    MaxSaleCash                = 140,
    StreetAddictionGainPerSale = 6.0,
    RecruitAddictionThreshold  = 80.0,
    RecruitDistance            = 3.0
}

-- [F2-3] REAL-TIME BÜRO ÜST ARAMASI / ÇEVİRME — main.lua'nın ZATEN VAR
-- OLAN DISPATCH_BUSTED_* dwell mekaniği botları yakalıyor (DEĞİŞTİRİLMEDİ);
-- burada eklenen SADECE o yakalama anındaki kontrabant muayenesi (gerçek
-- oyuncular için ayrı, hafif bir 8m/dwell taraması) ve el koyma zinciridir.
Config.Forensics.Frisk = {
    Radius                       = 8.0,
    DwellMs                      = 6000,
    CooldownMs                   = 120000,
    BurnerPhoneMaxHoldSeconds    = 120,
    WeaponSerialContrabandPrefix = 'BM-',
    EvidenceIndexJumpRatio       = 0.20
}

-- [F2-4] BAGAJ / ENVANTER AMELİYATI — matrix_fleet ZATEN plaka bazlı kayıt
-- tutuyor; ikinci bir "trunk" tablosu İCAT EDİLMEZ. Bagaj, bota kalıcı
-- atanmış aracın plakasına bağlı bir ox_inventory stash'idir.
Config.Logistics.TrunkOps = {
    StashPrefix = 'matrix_bot_trunk_',
    Slots       = 40,
    MaxWeight   = 80000
}

-- [F2-5] PROPAGANDA → DEVŞİRME KALİTE KÖPRÜSÜ — Matrix.Bureau.
-- GetPropagandaMomentum() (DEĞİŞTİRİLMEDİ) burada YENİ bir tüketici kazanır:
-- server/market.lua'nın sokak satış döngüsünde bağımlılık eşiğini aşan bir
-- "keş", server/recruitment.lua Matrix.Recruitment.RecruitStreetNpc ile
-- ANINDA devşirilirken, yeni ajanın taban resilience/snitch_tendency
-- değerleri AYNI momentum ile DOĞRUSAL ölçeklenir — yeni bir psychology
-- alanı İCAT EDİLMEZ, mevcut Matrix.CreateBotRecord şeması (main.lua) aynen
-- kullanılır. Kampanya ne kadar "ısıtıyorsa" sokaktan gelen devşirmeler o
-- kadar güvenilir (yüksek resilience/düşük snitch_tendency) olur. RNG YOK.
Config.Recruitment.MomentumQualityDivisor      = Config.Bureau.PropagandaMaxMomentum
Config.Recruitment.MomentumQualityCeiling      = 1.6
Config.Recruitment.BaseCandidateResilience     = 0.35
Config.Recruitment.BaseCandidateSnitchTendency = 0.35

return Config