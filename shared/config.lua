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
    RaidExplosiveBreachThreshold = 0.97, -- bu kesinlikte breach_method='explosive', altinda 'ram'
    RaidBaseEscapeWindowSeconds = 20,
    RaidDeadZoneEscapeBonusSeconds = 25 -- trap house bir kör noktaya yakınsa Büro telsizi de bozulur
}

-- =====================================================================
-- YARILANMA ÖMRÜ / GERÇEK-ZAMAN DENGELEMESİ (OYNANABİLİRLİK KİLİDİ)
--
-- Amaç: "1. saatte kaçınılmaz Hard-Wipe" riskini YAPISAL olarak ortadan
-- kaldırmak. Bunu magic-number oranları küçültmek yerine, her PASİF
-- (zamana bağlı, tick-tabanlı) birikim için önce "gerçek hayatta kaç
-- gün/saat/dakika sürsün" diye bir HEDEF tanımlıyoruz, sonra gerçek
-- per-tick katsayıyı bu hedeften cebirsel olarak TÜRETİYORUZ. Böylece
-- başka bir model (örn. DeepSeek R1) tek bir "*RealDays"/"*RealHours"
-- alanını değiştirerek dengeyi yeniden ayarlayabilir; hardcoded 0.0006
-- gibi bir sayının NEREDEN geldiğini tahmin etmesi gerekmez.
--
-- Genel türetme formülü (sabit-adımlı Euler birikimi, doğrusal yaklaşım):
--   toplam_tick_sayisi = (hedef_sure_saniye) / (tick_araligi_saniye)
--   gain_per_tick       = esik_degeri / toplam_tick_sayisi
-- Yani "mükemmel/en kötü koşullarda dahi" (regularity=1.0, heat=0 veya
-- sürekli aktif kalma gibi) tam hedef süre sonunda eşiğe ulaşılır; daha
-- gevşek koşullarda süre otomatik olarak UZAR (asla kısalmaz).
-- =====================================================================

-- Pasif örüntü analizi (Bureau.Tick, AnalysisIntervalSeconds'ta bir çalışır):
-- oyuncu HİÇBİR hata yapmasa, sadece mükemmel düzenli çalışsa bile bir trap
-- house'un sıfırdan RaidDecryptionThreshold'a (0.90) ulaşması için hedeflenen
-- GERÇEK GÜN sayısı. Mekanik matematiksel olarak DOĞRU işler, ama saf pasif
-- zaman bunu tetiklemek için günler ister - asıl risk oyuncunun AKTİF
-- hatalarından (triangulation/propaganda/canlı yayın) gelir.
Config.Bureau.PatternFullDecryptionRealDays = 5.0
Config.Bureau.PatternAnalysisGain =
    Config.Bureau.RaidDecryptionThreshold
    / ((Config.Bureau.PatternFullDecryptionRealDays * 86400.0) / Config.Bureau.AnalysisIntervalSeconds)

-- Canlı yayın AKTİF ve sürekli bir risktir (oyuncunun kendi seçimi); pasif
-- sistemden çok daha hızlı ilerlemeli ki "bedel" gerçekten hissedilsin, ama
-- "1 dakika yayın = ölüm" da OLMAMALI. Hedefler: sürekli yayınla heatmap
-- tavana bu GERÇEK DAKİKADA ulaşır; SADECE canlı yayının (başka hiçbir
-- katkı olmadan) tek başına 0.90 deşifreye ulaşması bu GERÇEK SAATTE olur.
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

    -- Pratikle organik beceri büyümesi (RNG yok): her döngüde eksik olan mesafenin
    -- sabit bir oranı kapanır (lojistik/asymptotik öğrenme eğrisi, tavan 1.0).
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

    -- OYNANABİLİRLİK KİLİDİ: eski değer (0.05) addiction_level>=20 olan HER
    -- botu TEK bir saatlik döngüde (Kitchen.ProcessHourCycle) tam yoksunluğa
    -- (withdrawal_index=1.0) itiyordu - bu da anlık hırsızlık/sızma zinciri
    -- demekti. 0.02'ye düşürüldü: aynı bot için tam yoksunluğa ulaşmak artık
    -- ~2.5 gerçek saat sürer (gerçek yoksunluk sendromunun saatler içinde
    -- başlaması hâlâ korunur, ama "ilk saatte kaçınılmaz çöküş" kaldırılır).
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
    -- ETA = (Mesafe / (BaseSpeed * Hiz_Katsayisi)) * (1 + (W_total * WeightFrictionCoefficient) * Surtunme_Carpani)
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

    -- Çatışma direnci normalize edilmiş hasar biriktirir; 1.0'a ulaşınca kalıcı ölüm.
    CombatEliminationThreshold = 1.0,

    -- Sevk sırasında en yakın trap house'a sızan Büro deşifre kazancı. Büro'nun
    -- fiziksel ALPR/eşkal takibi oyuncunun telsiz sinyaliyle ilgisizdir; sadece
    -- bildirim (log) kör bölgede gecikir, kazancın kendisi kesilmez.
    PoliceDecryptionGainPerTick = 0.01,

    -- Sevk hedefinin origin'e olan mesafesi bu limiti aşarsa "menzil dışı" reddi.
    MaxDispatchRangeMeters = 6000.0,

    -- Telekomünikasyon kör noktaları: bu koordinat + yarıçap içine giren dealer'ın
    -- komuta paneliyle sinyali kopar; olaylar kör bölgeden çıkana kadar gecikmeli iletilir.
    DeadZones = {
        { id = 1, label = 'Tunel Bolgesi',    coords = vector3(-1200.0, -560.0, 30.0),  radius = 300.0 },
        { id = 2, label = 'Endustriyel Vadi', coords = vector3(900.0, -2400.0, 10.0),   radius = 250.0 },
        { id = 3, label = 'Dag Gecidi',       coords = vector3(-1900.0, 2200.0, 150.0), radius = 400.0 }
    },
    DeadZoneLogFlushDelayMs = 4000,

    -- İllegal Filo Tedarik ve Atama Motoru
    Fleet = {
        DefaultVehicleClass = 'car',
        DefaultVinStatus    = 'hot',

        -- Aşınması yüksek araçlar sürtünmeyi wear oranında (maksimum %20) artırır.
        WearFrictionBonus = 0.20,

        -- Şasi kazınmamış (factory) araçlar yakalandığında Büro deşifre kazancını
        -- geometrik (çarpımsal) olarak büyütür; hot en zor iz sürülen VIN durumu.
        VinDecryptionMultiplier = {
            factory   = 3.0,
            scratched = 1.5,
            hot       = 1.0
        },

        -- Ele geçirilen aracın adli mühür kesinliği VIN durumuna göre değişir.
        SeizureSealCertainty = {
            factory   = 0.95,
            scratched = 0.65,
            hot       = 0.40
        },

        -- wear bu eşiği geçerse sevkiyat yol ortasında (progress >= 0.5) bir kereye
        -- mahsus deterministik arızayla durur (RNG yok, sabit bekleme süresi).
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
    -- Her drop sabit bir toptancıya bağlıdır (tasarımcı-yerleşimli, RNG'siz).
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

    -- OYNANABİLİRLİK KİLİDİ / NEFES ALMA PENCERESİ: temas edilmese de güven
    -- yavaşça DefaultTrust'a doğru sürüklenir (üstel/"Newton soğuma yasası"
    -- tarzı yaklaşım - bkz. logistics.lua ApplyPassiveTrustDrift). Yarı-ömür
    -- (gap'in yarısının kapanma süresi) ~ln(0.5)/ln(1-oran) gün'dür; oran
    -- 0.02 için bu ~34 gerçek gündür: kötü bir seri oyuncuyu SONSUZA DEK
    -- SupplyCutTrustThreshold altında hapsetmez, ama hızlı bir "reset" de
    -- değildir - gerçek hayat günlerine yayılan yavaş bir iyileşmedir.
    PassiveTrustRecoveryPerRealDay = 0.02,
    PassiveTrustRecoveryTarget     = 0.5,

    PriceMultiplierFloor   = 1.0,
    PriceMultiplierCeiling = 4.0,
    PriceMultiplierGain    = 1.0, -- fiyat = base * (1 + (1-trust) * gain), floor/ceiling'e clamp

    -- Bu eşiğin altında toptancı tedariği tamamen keser.
    SupplyCutTrustThreshold = 0.1,
    -- Bu eşiğin altında toptancı konumu Büro'ya sızdırır / infaz mangası yollar.
    BetrayalTrustThreshold  = 0.1,

    -- Fingerprint kalitesi bu eşiğin altındaysa (yüksek kortizol/panik) teslimde
    -- adli iz bırakılmış sayılır.
    ForensicTraceQualityThreshold = 0.5,

    -- Drop'un yerel siber yoğunluğu her kullanımda büyür, boşta yavaşça söner.
    DropHeatGrowthPerUse   = 0.25,
    DropHeatDecayPerMinute = 0.01,

    PickupWindowSeconds = 600
}
