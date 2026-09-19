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
    MinOperationalResilience   = 0.25
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
    TriangulationDecryptionGain= 0.04,
    PatternAnalysisGain        = 0.06,
    RaidDecryptionThreshold    = 0.90,
    AnalysisIntervalSeconds    = 300,
    PropagandaGeometricFactor  = 1.15,
    PropagandaMomentumIncrement= 0.10,
    PropagandaMaxMomentum      = 6.0,
    CyberLeakGeometricFactor   = 1.20,
    CyberLeakIncrement         = 0.05,
    CyberLeakMaxIntensity      = 5.0,
    PostRaidHeatmapDecay       = 0.5,
    PostRaidDecryptionReset    = 0.0
}

Config.Kitchen = {
    WorkFactor = {
        idle         = 0.0,
        lookout      = 0.01,
        distribution = 0.02,
        cooking      = 0.035
    },
    FatigueCortisolBleed          = 0.02,
    FatigueWarningThreshold       = 0.8,
    FatigueCriticalThreshold      = 0.9,
    FatigueCriticalDurationSeconds= 3600,
    BurnoutResilienceLoss         = 0.10,
    BurnoutRecoveryRatePenalty    = 0.20,
    BurnoutRecoveryRateFloor      = 0.005,
    CortisolDeviationThreshold    = 0.8,
    CortisolDeviationDistance     = 100.0,
    WithdrawalGainPerAddictionPoint = 0.05,
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
