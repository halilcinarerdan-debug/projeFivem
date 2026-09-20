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
        idle         = 0.0,
        lookout      = 0.01,
        distribution = 0.02,
        cooking      = 0.035,
        cyber_ops    = 0.015
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

    -- ★★★ BİLİNEN SORUN — HENÜZ ÇÖZÜLMEDİ ★★★
    -- Buradaki koordinat DOĞRULANMAMIŞ bir tahmindi ve oyuncuyu Sandy
    -- Shores'ta AÇIK HAVAYA (Trevor'ın treylerinin GERÇEK konumuna değil)
    -- ışınladığı doğrulandı. Ayrıca Trevor'ın treyleri, FiveM'in bilinen
    -- "kırık/delikli interior" listesindeki lokasyonlardan biri — düz bir
    -- RequestIpl çağrısıyla doğru render OLMUYOR (bkz. bob74_ipl projesinin
    -- bu konumu özel olarak ele alması). Kalıcı çözüm kullanıcıyla
    -- konuşulan üç seçenekten birine bağlı (bob74_ipl bağımlılığı / kendi
    -- prop'larımızdan inşa edilen oda / gerçek bir MLO kaynağı) — o karar
    -- verilene kadar bu Shell BİLEREK yanlış/placeholder durumda bırakıldı.
    Shell = {
        RequiredIpl  = 'trailertrash_i2',
        EnterCoords  = vector4(2001.6, 3820.9, 32.3, 90.0),
        WorkbenchPos = vector3(2000.9, 3818.6, 32.3),
        PackagingPos = vector3(2003.4, 3819.4, 32.3),
        ExitCoords   = vector4(2001.6, 3820.9, 32.3, 270.0)
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
