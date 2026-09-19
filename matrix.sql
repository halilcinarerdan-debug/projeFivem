-- =====================================================================
-- MATRIX SCHEMA: Katman 1-2-3 Birlesik Motor - Kalici Veri Tabani
-- Bu semadaki adli kayitlar (matrix_forensic_evidence, matrix_ballistic_weapons,
-- matrix_touch_log) uygulama katmani tarafindan asla silinmez (yalnizca eklenir).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Katman 1: Core Matrix - Bot / Dealer Kalici Kimlik ve Biyoloji Profili
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bots` (
    `id` INT NOT NULL,
    `dna_id` VARCHAR(64) NOT NULL,
    `name` VARCHAR(100) NOT NULL,
    `role` VARCHAR(32) NOT NULL DEFAULT 'runner',
    `status` ENUM('active', 'burned', 'deceased', 'retired') NOT NULL DEFAULT 'active',
    `fear_factor` FLOAT NOT NULL DEFAULT 0.0,
    `resilience` FLOAT NOT NULL DEFAULT 0.5,
    `snitch_tendency` FLOAT NOT NULL DEFAULT 0.0,
    `economic_pressure` FLOAT NOT NULL DEFAULT 0.0,
    `cognitive_shifter` FLOAT NOT NULL DEFAULT 0.5,
    `skill_chemistry` FLOAT NOT NULL DEFAULT 0.3,
    `fatigue_level` FLOAT NOT NULL DEFAULT 0.0,
    `cortisol_level` FLOAT NOT NULL DEFAULT 0.0,
    `withdrawal_index` FLOAT NOT NULL DEFAULT 0.0,
    `addiction_level` FLOAT NOT NULL DEFAULT 0.0,
    `base_cortisol_recovery_rate` FLOAT NOT NULL DEFAULT 0.05,
    `trap_house_id` INT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bots_dna_id` (`dna_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 1: Oyuncu Kalici Bio-Durumu (fingerprint/kortizol formulleri icin)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_player_state` (
    `citizenid` VARCHAR(50) NOT NULL,
    `cortisol_level` FLOAT NOT NULL DEFAULT 0.0,
    `fatigue_level` FLOAT NOT NULL DEFAULT 0.0,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 1: Kalici Balistik Silah Kaydi (yiv-set imza kodu ile)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_ballistic_weapons` (
    `ballistic_id` VARCHAR(64) NOT NULL,
    `weapon_serial` VARCHAR(64) NOT NULL,
    `wear_level` FLOAT NOT NULL DEFAULT 0.0,
    `sealed_as_crime_weapon` TINYINT(1) NOT NULL DEFAULT 0,
    `seal_certainty` FLOAT NULL,
    `first_registered` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`ballistic_id`),
    UNIQUE KEY `uq_matrix_ballistic_weapon_serial` (`weapon_serial`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 1: Kalici Adli Kanit Veri Tabani (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_forensic_evidence` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `ballistic_id` VARCHAR(64) NOT NULL,
    `evidence_type` VARCHAR(32) NOT NULL DEFAULT 'casing',
    `striation_quality` FLOAT NOT NULL,
    `fingerprint_id` VARCHAR(64) NOT NULL,
    `fingerprint_quality` FLOAT NOT NULL,
    `match_certainty` FLOAT NOT NULL,
    `sealed_as_crime_weapon` TINYINT(1) NOT NULL DEFAULT 0,
    `coords_x` FLOAT NOT NULL DEFAULT 0.0,
    `coords_y` FLOAT NOT NULL DEFAULT 0.0,
    `coords_z` FLOAT NOT NULL DEFAULT 0.0,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_forensic_evidence_ballistic_id` (`ballistic_id`),
    CONSTRAINT `fk_matrix_forensic_evidence_ballistic`
        FOREIGN KEY (`ballistic_id`) REFERENCES `matrix_ballistic_weapons` (`ballistic_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 1: Dokunulan Nesneler - Genel Parmak Izi Gunlugu (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_touch_log` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `fingerprint_id` VARCHAR(64) NOT NULL,
    `fingerprint_quality` FLOAT NOT NULL,
    `inventory_id` VARCHAR(64) NOT NULL,
    `slot_id` INT NOT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_touch_log_fingerprint_id` (`fingerprint_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 1: Karanlik Mulakat - Musteri Havuzu (recruitment.lua deterministik
-- trait cikarimi icin davranissal istatistikleri tutar; RNG kullanilmaz)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_customer_pool` (
    `citizenid` VARCHAR(50) NOT NULL,
    `name` VARCHAR(100) NOT NULL,
    `police_encounters_nearby` INT NOT NULL DEFAULT 0,
    `completed_deals` INT NOT NULL DEFAULT 0,
    `times_reported` INT NOT NULL DEFAULT 0,
    `failed_payments` INT NOT NULL DEFAULT 0,
    `chemistry_hints` INT NOT NULL DEFAULT 0,
    `addiction_level` FLOAT NOT NULL DEFAULT 0.0,
    `promoted_to_candidate` TINYINT(1) NOT NULL DEFAULT 0,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 1: Karanlik Mulakat - Sorgu Oturumu Sonuc Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_recruitment_sessions` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `candidate_citizenid` VARCHAR(50) NOT NULL,
    `fear_factor` FLOAT NOT NULL,
    `resilience` FLOAT NOT NULL,
    `lies_told` INT NOT NULL DEFAULT 0,
    `confessions` INT NOT NULL DEFAULT 0,
    `outcome` ENUM('recruited', 'released', 'burned') NOT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_recruitment_sessions_candidate` (`candidate_citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 2: The Bureau - Trap House Kayitlari (üçgenleme/desifre hedefleri)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_trap_houses` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `label` VARCHAR(100) NOT NULL,
    `coord_x` FLOAT NOT NULL,
    `coord_y` FLOAT NOT NULL,
    `coord_z` FLOAT NOT NULL,
    `decryption_confidence` FLOAT NOT NULL DEFAULT 0.0,
    `cyber_leak_intensity` FLOAT NOT NULL DEFAULT 0.0,
    `raid_ordered` TINYINT(1) NOT NULL DEFAULT 0,
    `last_raid_at` DATETIME NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 2: Pattern Desifre Dongusu - Saat/Gun Kalibi Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pattern_log` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `trap_house_id` INT NOT NULL,
    `day_of_week` TINYINT NOT NULL,
    `hour_of_day` TINYINT NOT NULL,
    `occurrence_count` INT NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_pattern_log_bucket` (`trap_house_id`, `day_of_week`, `hour_of_day`),
    CONSTRAINT `fk_matrix_pattern_log_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 2: Buro Istihbarat Katmani (uçgenleme / siber sizinti yogunlugu)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_intel` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `trap_house_id` INT NOT NULL,
    `category` ENUM('triangulation', 'cyber_leak', 'pattern') NOT NULL,
    `intensity` FLOAT NOT NULL DEFAULT 0.0,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bureau_intel_bucket` (`trap_house_id`, `category`),
    CONSTRAINT `fk_matrix_bureau_intel_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 3: Ihanet & Muhbirlik Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_snitch_events` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `bot_id` INT NOT NULL,
    `trap_house_id` INT NOT NULL,
    `snitch_index` FLOAT NOT NULL,
    `lied` TINYINT(1) NOT NULL DEFAULT 0,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_snitch_events_bot` (`bot_id`),
    CONSTRAINT `fk_matrix_snitch_events_bot`
        FOREIGN KEY (`bot_id`) REFERENCES `matrix_bots` (`id`),
    CONSTRAINT `fk_matrix_snitch_events_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 3: Mutfak Motoru - Seyreltme/Kesme Isletim Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_kitchen_batches` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `trap_house_id` INT NOT NULL,
    `actor_identifier` VARCHAR(64) NOT NULL,
    `raw_weight` FLOAT NOT NULL,
    `raw_purity` FLOAT NOT NULL,
    `agent_weight` FLOAT NOT NULL,
    `theoretical_purity` FLOAT NOT NULL,
    `error_coefficient` FLOAT NOT NULL,
    `output_purity` FLOAT NOT NULL,
    `waste_volume` FLOAT NOT NULL,
    `theft_amount` FLOAT NOT NULL DEFAULT 0.0,
    `rival_infiltration_triggered` TINYINT(1) NOT NULL DEFAULT 0,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_kitchen_batches_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_kitchen_batches_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 4: İllegal Filo - Aktif Araç Havuzu. Bir araç ele geçirilirse
-- (çatışma/baskın) bu tablodan hard-delete edilir; kalıcı adli mühür
-- ayrı olarak matrix_vehicle_seizures'a yazılır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_fleet` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `plate` VARCHAR(32) NOT NULL,
    `vehicle_class` ENUM('motorbike', 'car') NOT NULL DEFAULT 'car',
    `vin_status` ENUM('factory', 'scratched', 'hot') NOT NULL DEFAULT 'hot',
    `vehicle_wear` FLOAT NOT NULL DEFAULT 0.0,
    `registered_by_citizenid` VARCHAR(50) NULL,
    `assigned_bot_id` INT NULL,
    `assignment_mode` ENUM('permanent', 'temporary') NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_fleet_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 4: Büro ALPR / Görsel Eşkal Eşleşme Günlüğü (asla silinmez).
-- Plaka + dealer'ın fingerprint_dna_id'si + oyuncunun organizasyon
-- imzasını (kayıt sahibi citizenid) adli veri tabanında birbirine bağlar.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_alpr_hits` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `plate` VARCHAR(32) NOT NULL,
    `fingerprint_dna_id` VARCHAR(64) NOT NULL,
    `organization_signature` VARCHAR(50) NOT NULL,
    `trap_house_id` INT NOT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_alpr_hits_plate` (`plate`),
    CONSTRAINT `fk_matrix_alpr_hits_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Katman 4: Ele Geçirilen Araç Mührü - kalıcı kanıt katsayısı (asla silinmez).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_vehicle_seizures` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `plate` VARCHAR(32) NOT NULL,
    `vin_status` ENUM('factory', 'scratched', 'hot') NOT NULL,
    `vehicle_wear` FLOAT NOT NULL DEFAULT 0.0,
    `fingerprint_dna_id` VARCHAR(64) NOT NULL,
    `organization_signature` VARCHAR(50) NOT NULL,
    `seizure_cause` VARCHAR(32) NOT NULL DEFAULT 'unknown',
    `seal_certainty` FLOAT NOT NULL,
    `coords_x` FLOAT NOT NULL DEFAULT 0.0,
    `coords_y` FLOAT NOT NULL DEFAULT 0.0,
    `coords_z` FLOAT NOT NULL DEFAULT 0.0,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_vehicle_seizures_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
