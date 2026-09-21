-- =====================================================================
-- MATRIX / config.lua
-- Shared configuration. Loaded before every server/client script.
-- LAYER 7 - FAZ 2 eklentileri: Config.Kitchen.Packaging, Config.Market,
-- Config.Forensics, Config.Logistics.Trunk, Config.Hud
--
-- Every table below is created with `X = X or {}` and every field with
-- `X.Field = X.Field or default`. This means: if an earlier phase's
-- config.lua already defines a value, THIS FILE NEVER OVERWRITES IT.
-- Safe to merge on top of an existing Faz-1 config.lua without regressions.
-- =====================================================================

Config = Config or {}

-- ---------------------------------------------------------------------
-- Matrix global namespace + logging (created once, first file to load
-- wins; every module below only ever does `Matrix.X = Matrix.X or {}`).
-- ---------------------------------------------------------------------
Matrix = Matrix or {}
Matrix.Log = Matrix.Log or function(tag, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(('^5[MATRIX:%s]^7 %s'):format(tag, ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------
-- Tick / master interval (0.00ms resmon doctrine: every polling loop in
-- this contract reads this instead of hardcoding Wait(0)).
-- ---------------------------------------------------------------------
Config.Tick = Config.Tick or {}
Config.Tick.MasterInterval = Config.Tick.MasterInterval or 1000

-- ---------------------------------------------------------------------
-- Framework / integration switches
-- ---------------------------------------------------------------------
Config.Core = Config.Core or {}
Config.Core.Resource = Config.Core.Resource or 'qb-core'
Config.Core.Inventory = Config.Core.Inventory or 'ox_inventory'
Config.Core.Lib = Config.Core.Lib or 'ox_lib'
Config.Core.MoneyItem = Config.Core.MoneyItem or 'cash'

-- =====================================================================
-- [K7-2/1] MUTFAK PAKETLEME ODASI
-- =====================================================================
Config.Kitchen = Config.Kitchen or {}
Config.Kitchen.Packaging = Config.Kitchen.Packaging or {}

-- 10 gram'lık kurye paketi
Config.Kitchen.Packaging.PackageGrams = Config.Kitchen.Packaging.PackageGrams or 10

-- Ham kütle (imalathaneden çıkan, metadata.purity taşıyan) item adları
Config.Kitchen.Packaging.RawItem = Config.Kitchen.Packaging.RawItem or {
    meth = 'meth_batch',
    coke = 'coke_batch',
}

-- Kurye paketi (metadata.purity taşıyan nihai ürün) item adları
Config.Kitchen.Packaging.PackagedItem = Config.Kitchen.Packaging.PackagedItem or {
    meth = 'meth_bag',
    coke = 'coke_brick',
}

Config.Kitchen.Packaging.CuttingAgentItem = Config.Kitchen.Packaging.CuttingAgentItem or 'cutting_agent'

-- Paket başına harcanan kesme ajanı (gram); her gram saflığı düşürür
Config.Kitchen.Packaging.CuttingAgentGramsPerPackage = Config.Kitchen.Packaging.CuttingAgentGramsPerPackage or 2
Config.Kitchen.Packaging.PurityDilutionPerCutGram = Config.Kitchen.Packaging.PurityDilutionPerCutGram or 1.5
Config.Kitchen.Packaging.MinPurityFloor = Config.Kitchen.Packaging.MinPurityFloor or 5.0

-- lib.progressCircle süresi (ms) - gerçek oyuncu için
Config.Kitchen.Packaging.ProgressMs = Config.Kitchen.Packaging.ProgressMs or 6500

-- Lojistik botu için client'sız asenkron bekleme (ms)
Config.Kitchen.Packaging.BotProcessMs = Config.Kitchen.Packaging.BotProcessMs or 9000

-- Tek seferde en fazla kaç paket üretilebilir (dupe/abuse limiti)
Config.Kitchen.Packaging.MaxPackagesPerRun = Config.Kitchen.Packaging.MaxPackagesPerRun or 12

-- Paketleme masası (kirli masa) yarıçapı - trap house koordinatına göre
Config.Kitchen.Packaging.RoomRadius = Config.Kitchen.Packaging.RoomRadius or 4.0

-- =====================================================================
-- [K7-2/2] SOKAK SATIŞ DÖNGÜSÜ (Street Dealing)
-- =====================================================================
Config.Market = Config.Market or {}

Config.Market.GourmetMinPurity = Config.Market.GourmetMinPurity or 30.0

-- Keş NPC yaklaşma taraması: deterministik sabit aralık (ms), rastgele değil
Config.Market.NpcScanIntervalMs = Config.Market.NpcScanIntervalMs or 1000
Config.Market.NpcApproachIntervalMs = Config.Market.NpcApproachIntervalMs or 25000
Config.Market.NpcSearchRadius = Config.Market.NpcSearchRadius or 40.0
Config.Market.NpcArriveDistance = Config.Market.NpcArriveDistance or 1.6
Config.Market.NpcMaxActive = Config.Market.NpcMaxActive or 1
Config.Market.NpcWalkSpeed = Config.Market.NpcWalkSpeed or 1.0
Config.Market.NpcTimeoutMs = Config.Market.NpcTimeoutMs or 60000

-- İşlem başına min/max satış miktarı ve fiyat (gram/paket başı nakit)
Config.Market.MinSaleCash = Config.Market.MinSaleCash or 60
Config.Market.MaxSaleCash = Config.Market.MaxSaleCash or 140

-- Bot eve dönmeden kirli para "provisional" (tehlikede) kalır
Config.Market.BotHomeRadius = Config.Market.BotHomeRadius or 6.0

-- Radio silence
Config.Market.RadioSilenceStaticStep = Config.Market.RadioSilenceStaticStep or 0.15
Config.Market.RadioSilenceStaticMax = Config.Market.RadioSilenceStaticMax or 1.0
Config.Market.RadioSilenceTraceBase = Config.Market.RadioSilenceTraceBase or 4.0

Config.Market.DealingModeCommand = Config.Market.DealingModeCommand or 'torbacilikyap'
Config.Market.RadioSilenceCommand = Config.Market.RadioSilenceCommand or 'sessizlik'

-- =====================================================================
-- [K7-2/3] FORENSICS - Üst Arama / Çevirme / El Koyma
-- =====================================================================
Config.Forensics = Config.Forensics or {}

Config.Forensics.FriskRadius = Config.Forensics.FriskRadius or 8.0
Config.Forensics.FriskDwellMs = Config.Forensics.FriskDwellMs or 6000
Config.Forensics.FriskCooldownMs = Config.Forensics.FriskCooldownMs or 120000
Config.Forensics.TickIntervalMs = Config.Forensics.TickIntervalMs or Config.Tick.MasterInterval

Config.Forensics.BurnerPhoneMaxHoldSeconds = Config.Forensics.BurnerPhoneMaxHoldSeconds or 120
Config.Forensics.WeaponSerialContrabandPrefix = Config.Forensics.WeaponSerialContrabandPrefix or 'BM-'
Config.Forensics.ScratchedPlateStatus = Config.Forensics.ScratchedPlateStatus or 'scratched'

Config.Forensics.EvidenceIndexJumpPct = Config.Forensics.EvidenceIndexJumpPct or 0.20
Config.Forensics.PoliceJob = Config.Forensics.PoliceJob or 'police'

-- =====================================================================
-- [K7-2/4] LOJİSTİK - Bagaj / Envanter Ameliyatı
-- =====================================================================
Config.Logistics = Config.Logistics or {}
Config.Logistics.Trunk = Config.Logistics.Trunk or {}

Config.Logistics.Trunk.StashPrefix = Config.Logistics.Trunk.StashPrefix or 'matrix_bot_trunk_'
Config.Logistics.Trunk.Slots = Config.Logistics.Trunk.Slots or 40
Config.Logistics.Trunk.MaxWeight = Config.Logistics.Trunk.MaxWeight or 80000
Config.Logistics.Trunk.LoadMsPerStack = Config.Logistics.Trunk.LoadMsPerStack or 450
Config.Logistics.Trunk.DeliverMsPerItem = Config.Logistics.Trunk.DeliverMsPerItem or 300

Config.Logistics.TrapStashPrefix = Config.Logistics.TrapStashPrefix or 'matrix_trap_stash_'
Config.Logistics.TrapStashSlots = Config.Logistics.TrapStashSlots or 60
Config.Logistics.TrapStashMaxWeight = Config.Logistics.TrapStashMaxWeight or 400000

-- =====================================================================
-- [K7-2/5] HUD (K panel) - monokrom veri sanatı, HTML/CSS yok
-- =====================================================================
Config.Hud = Config.Hud or {}
Config.Hud.ToggleKey = Config.Hud.ToggleKey or 'K'
Config.Hud.ToggleControl = Config.Hud.ToggleControl or 311 -- INPUT_MP_TEXT_CHAT_TEAM ~ remapped K by default keymap
Config.Hud.RefreshMs = Config.Hud.RefreshMs or 500
Config.Hud.Font = Config.Hud.Font or 4
Config.Hud.BarSlots = Config.Hud.BarSlots or 10

return Config
