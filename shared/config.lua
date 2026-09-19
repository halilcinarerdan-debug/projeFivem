Config = {}

Config.Tick = {
    IntervalMs = 1000,
    SecondsPerMinute = 60,
    SecondsPerHour = 3600
}

-- Katman 1: Balistik / adli sabitler
Config.BaseCortisolRecoveryRate = 0.05
Config.BallisticStriationPrecision = 0.85

Config.Forensics = {
    MatchCertaintyThreshold = 0.75,
    FingerprintQualityCortisolWeight = 0.4,
    CasingWearWeight = 0.3,
    CasingCortisolWeight = 0.2
}

-- Katman 1: Recruitment / karanlik mulakat sabitleri
Config.Recruitment = {
    BaseEligibilityThreshold = 1.2,
    ResilienceDamping = 0.35,
    LieThreshold = 0.35,
    ConfessionThreshold = 0.75,
    MinConfessionsToPromote = 3,
    MaxToleratedLies = 4,
    SafeSnitchTendencyCeiling = 0.6,
    MinOperationalResilience = 0.25
}

-- Katman 2: The Bureau sabitleri
Config.Bureau = {
    CellTowers = {
        { id = 1, coords = vector3(-100.0, -800.0, 30.0) },
        { id = 2, coords = vector3(400.0, -1200.0, 30.0) },
        { id = 3, coords = vector3(150.0, -2200.0, 30.0) },
        { id = 4, coords = vector3(-600.0, -1400.0, 30.0) },
        { id = 5, coords = vector3(900.0, -300.0, 60.0) },
        { id = 6, coords = vector3(-1100.0, -400.0, 35.0) }
    },
    TowerRange = 1200.0,
    BaseSearchRadius = 2500.0,
    TriangulationDecryptionGain = 0.04,
    PatternAnalysisGain = 0.06,
    RaidDecryptionThreshold = 0.90,
    AnalysisIntervalSeconds = 300,
    PropagandaGeometricFactor = 1.15,
    PropagandaMomentumIncrement = 0.10,
    PropagandaMaxMomentum = 6.0,
    CyberLeakGeometricFactor = 1.20,
    CyberLeakIncrement = 0.05,
    CyberLeakMaxIntensity = 5.0,
    PostRaidHeatmapDecay = 0.5,
    PostRaidDecryptionReset = 0.0
}

-- Katman 3: Bot bio/psikoloji ve mutfak sabitleri
Config.Kitchen = {
    WorkFactor = {
        idle = 0.0,
        lookout = 0.01,
        distribution = 0.02,
        cooking = 0.035
    },
    FatigueCortisolBleed = 0.02,
    FatigueWarningThreshold = 0.8,
    FatigueCriticalThreshold = 0.9,
    FatigueCriticalDurationSeconds = 3600,
    BurnoutResilienceLoss = 0.10,
    BurnoutRecoveryRatePenalty = 0.20,
    BurnoutRecoveryRateFloor = 0.005,
    CortisolDeviationThreshold = 0.8,
    CortisolDeviationDistance = 100.0,
    WithdrawalGainPerAddictionPoint = 0.05,
    WithdrawalSkillPenaltyThreshold = 0.7,
    WithdrawalSkillPenaltyMultiplier = 0.5,
    TheftWithdrawalThreshold = 1.0,
    TheftGramsPerAddictionPoint = 10.0,
    RivalInfiltrationPurityThreshold = 0.30,
    CortisolSpike = {
        Gunshot = 0.40,
        BureauVehicle = 0.25,
        BureauVehicleRadius = 50.0
    },
    SnitchThreshold = 0.75
}

-- Oyuncu (player) taraf devletleri icin varsayilanlar (bot psikoloji profiline sahip degildir)
Config.Player = {
    DefaultResilience = 0.5,
    DefaultSkillChemistry = 0.4
}
