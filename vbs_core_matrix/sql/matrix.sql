-- =====================================================================
-- MATRIX SCHEMA v3 — Katman 5 (Qbox Co-op Kartel Hiyerarşisi & Piyasa)
-- Katman 1-2-3-4-5 Birlesik Motor - Kalici Veri Tabani
--
-- ★ DEĞİŞİKLİK NOTU (v2 → v3):
--   (1) KATMAN 5 tabloları eklendi: matrix_hierarchy (co-op rütbe),
--       matrix_market_zones (bölgesel piyasa fiyat çarpanı), matrix_cash_decay
--       (kirlenen nakit sönümlenmesi). v2'nin "ON UPDATE CURRENT_TIMESTAMP
--       KULLANMA" politikası aynen sürdürüldü — `updated_at` uygulama
--       katmanında (market.lua) her UPDATE/UPSERT'te explicit NOW() ile
--       yazılır.
--   (2) matrix_cash_decay, matrix_trap_houses'a FK ile bağlı olduğundan
--       FOREIGN_KEY_CHECKS=0 sarması İÇİNE, diğer Katman 1-4 tablolarından
--       SONRA eklendi (parent zaten mevcut).
--   (3) Katman 1-4 tabloları/yorumları HİÇ DEĞİŞMEDİ (aşağıdaki v1→v2 notu
--       olduğu gibi korunmuştur).
--
-- ★ DEĞİŞİKLİK NOTU (v1 → v2):
--   (1) Tüm `DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`
--       kombinasyonları KALDIRILDI. Neden: bazı MariaDB/MySQL derlemeleri
--       bu kombinasyonu kolon-tanımı parser'ında reddediyor ve CREATE
--       TABLE sessizce başarısız oluyordu → matrix_fleet ve
--       matrix_supplier_trust gibi Katman 4 tabloları hiç yaratılmıyordu.
--       Uygulama katmanı `updated_at = NOW()`'u her UPDATE/UPSERT
--       sorgusunda explicit gönderiyor (main.lua BOT_UPSERT_TAIL,
--       logistics.lua FlushDirtyFleet / FlushDirtySupplierTrust), bu
--       yüzden DB-seviyesi auto-update KAYBI YOKTUR.
--
--   (2) Tüm tablolar parent→child sırasına göre yeniden dizildi:
--       matrix_trap_houses  →  pattern_log/bureau_intel/raid_log/...
--       matrix_ballistic_weapons  →  matrix_forensic_evidence
--       matrix_bots  →  matrix_snitch_events
--
--   (3) `SET FOREIGN_KEY_CHECKS = 0` sarması eklendi: mevcut bir şemayı
--       yeniden import ederken FK ihlali yaşanmaz. Sonunda tekrar 1'e
--       döndürülür.
--
--   (4) Tüm kolon tipleri FULL MySQL 5.7 / MariaDB 10.x uyumludur.
--       DECIMAL ve ENUM sınırları korunmuştur.
--
-- ★ ADLİ KAYIT POLİTİKASI (DOKUNULMADI):
--   matrix_forensic_evidence, matrix_ballistic_weapons, matrix_touch_log,
--   matrix_alpr_hits, matrix_vehicle_seizures, matrix_dead_drop_events,
--   matrix_raid_log, matrix_livestream_events — asla silinmez, yalnızca
--   eklenir. Uygulama katmanı DELETE yalnızca matrix_bots ve matrix_fleet
--   için çağırır (hard-delete politika).
--
-- ★ KATMAN 8 NOTU (Hard-Wipe / E_total): İstek metninde tanımlanan "Ortak
--   Risk Kontratı" (çete-çapında kümülatif kanıt matrisi tetiklendiğinde
--   TÜM oyuncu verisinin aynı saniyede DROP edilmesi) BİLİNÇLİ OLARAK bu
--   şemaya EKLENMEDİ. Eşik/kapsam/hangi tabloların etkileneceği tanımsız;
--   tanımsız bir toplu-silme mekanizmasını tahminle şemaya kilitlemek,
--   yanlış bir tasarımı geri alınması güç hale getirir. Katman 8 netleşince
--   ayrı bir migration olarak eklenmelidir.
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- =====================================================================
-- KATMAN 1: CORE MATRIX  (Kalıcı Kimlik ve Biyoloji)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Bot / Dealer Kalıcı Kimlik ve Biyoloji Profili
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bots` (
    `id`                         INT          NOT NULL,
    `dna_id`                     VARCHAR(64)  NOT NULL,
    `name`                       VARCHAR(100) NOT NULL,
    `role`                       VARCHAR(32)  NOT NULL DEFAULT 'runner',
    `status`                     ENUM('active','burned','deceased','retired') NOT NULL DEFAULT 'active',
    `fear_factor`                FLOAT        NOT NULL DEFAULT 0.0,
    `resilience`                 FLOAT        NOT NULL DEFAULT 0.5,
    `snitch_tendency`            FLOAT        NOT NULL DEFAULT 0.0,
    `economic_pressure`          FLOAT        NOT NULL DEFAULT 0.0,
    `cognitive_shifter`          FLOAT        NOT NULL DEFAULT 0.5,
    `skill_chemistry`            FLOAT        NOT NULL DEFAULT 0.3,
    `skill_cyber`                FLOAT        NOT NULL DEFAULT 0.0,
    `skill_logistics`            FLOAT        NOT NULL DEFAULT 0.0,
    `fatigue_level`              FLOAT        NOT NULL DEFAULT 0.0,
    `cortisol_level`             FLOAT        NOT NULL DEFAULT 0.0,
    `withdrawal_index`           FLOAT        NOT NULL DEFAULT 0.0,
    `addiction_level`            FLOAT        NOT NULL DEFAULT 0.0,
    `base_cortisol_recovery_rate` FLOAT       NOT NULL DEFAULT 0.05,
    `trap_house_id`              INT          NULL,
    `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bots_dna_id` (`dna_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Oyuncu Kalıcı Bio-Durumu (fingerprint/kortizol formülleri için)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_player_state` (
    `citizenid`      VARCHAR(50) NOT NULL,
    `cortisol_level` FLOAT       NOT NULL DEFAULT 0.0,
    `fatigue_level`  FLOAT       NOT NULL DEFAULT 0.0,
    `updated_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kalıcı Balistik Silah Kaydı (yiv-set imza kodu ile)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_ballistic_weapons` (
    `ballistic_id`            VARCHAR(64) NOT NULL,
    `weapon_serial`           VARCHAR(64) NOT NULL,
    `wear_level`              FLOAT       NOT NULL DEFAULT 0.0,
    `sealed_as_crime_weapon`  TINYINT(1)  NOT NULL DEFAULT 0,
    `seal_certainty`          FLOAT       NULL,
    `first_registered`        DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`ballistic_id`),
    UNIQUE KEY `uq_matrix_ballistic_weapon_serial` (`weapon_serial`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kalıcı Adli Kanıt Veri Tabanı (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_forensic_evidence` (
    `id`                      INT          NOT NULL AUTO_INCREMENT,
    `ballistic_id`            VARCHAR(64)  NOT NULL,
    `evidence_type`           VARCHAR(32)  NOT NULL DEFAULT 'casing',
    `striation_quality`       FLOAT        NOT NULL,
    `fingerprint_id`          VARCHAR(64)  NOT NULL,
    `fingerprint_quality`     FLOAT        NOT NULL,
    `match_certainty`         FLOAT        NOT NULL,
    `sealed_as_crime_weapon`  TINYINT(1)   NOT NULL DEFAULT 0,
    `coords_x`                FLOAT        NOT NULL DEFAULT 0.0,
    `coords_y`                FLOAT        NOT NULL DEFAULT 0.0,
    `coords_z`                FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_forensic_evidence_ballistic_id` (`ballistic_id`),
    CONSTRAINT `fk_matrix_forensic_evidence_ballistic`
        FOREIGN KEY (`ballistic_id`) REFERENCES `matrix_ballistic_weapons` (`ballistic_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Dokunulan Nesneler - Genel Parmak İzi Günlüğü (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_touch_log` (
    `id`                  INT          NOT NULL AUTO_INCREMENT,
    `fingerprint_id`      VARCHAR(64)  NOT NULL,
    `fingerprint_quality` FLOAT        NOT NULL,
    `inventory_id`        VARCHAR(64)  NOT NULL,
    `slot_id`             INT          NOT NULL,
    `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_touch_log_fingerprint_id` (`fingerprint_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Karanlık Mülakat - Müşteri Havuzu (deterministik trait çıkarımı)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_customer_pool` (
    `citizenid`                  VARCHAR(50)  NOT NULL,
    `name`                       VARCHAR(100) NOT NULL,
    `police_encounters_nearby`   INT          NOT NULL DEFAULT 0,
    `completed_deals`            INT          NOT NULL DEFAULT 0,
    `times_reported`             INT          NOT NULL DEFAULT 0,
    `failed_payments`            INT          NOT NULL DEFAULT 0,
    `chemistry_hints`            INT          NOT NULL DEFAULT 0,
    `addiction_level`            FLOAT        NOT NULL DEFAULT 0.0,
    `promoted_to_candidate`      TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Karanlık Mülakat - Sorgu Oturumu Sonuç Günlüğü
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_recruitment_sessions` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `candidate_citizenid`    VARCHAR(50)  NOT NULL,
    `fear_factor`            FLOAT        NOT NULL,
    `resilience`             FLOAT        NOT NULL,
    `lies_told`              INT          NOT NULL DEFAULT 0,
    `confessions`            INT          NOT NULL DEFAULT 0,
    `outcome`                ENUM('recruited','released','burned') NOT NULL,
    `created_at`             DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_recruitment_sessions_candidate` (`candidate_citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 2: THE BUREAU  (Trap House + Desifre + Baskin + Yayin)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Trap House Kayıtları (üçgenleme/desifre hedefleri)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_trap_houses` (
    `id`                    INT          NOT NULL AUTO_INCREMENT,
    `label`                 VARCHAR(100) NOT NULL,
    `coord_x`               FLOAT        NOT NULL,
    `coord_y`               FLOAT        NOT NULL,
    `coord_z`               FLOAT        NOT NULL,
    `decryption_confidence` FLOAT        NOT NULL DEFAULT 0.0,
    `cyber_leak_intensity`  FLOAT        NOT NULL DEFAULT 0.0,
    `raid_ordered`          TINYINT(1)   NOT NULL DEFAULT 0,
    `last_raid_at`          DATETIME     NULL,
    `created_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Pattern Desifre Dongusu - Saat/Gun Kalibi Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pattern_log` (
    `id`               INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`    INT      NOT NULL,
    `day_of_week`      TINYINT  NOT NULL,
    `hour_of_day`      TINYINT  NOT NULL,
    `occurrence_count` INT      NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_pattern_log_bucket` (`trap_house_id`, `day_of_week`, `hour_of_day`),
    CONSTRAINT `fk_matrix_pattern_log_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Buro Istihbarat Katmani (ucgenleme / siber sizinti yogunlugu)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_intel` (
    `id`             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`  INT          NOT NULL,
    `category`       ENUM('triangulation','cyber_leak','pattern') NOT NULL,
    `intensity`      FLOAT        NOT NULL DEFAULT 0.0,
    `updated_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bureau_intel_bucket` (`trap_house_id`, `category`),
    CONSTRAINT `fk_matrix_bureau_intel_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Fiziksel Safak Baskini Gunlugu - murettebat/breach/sonuc kaydi
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_raid_log` (
    `id`                             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`                  INT          NOT NULL,
    `squad_size`                     INT          NOT NULL,
    `breach_method`                  VARCHAR(32)  NOT NULL DEFAULT 'ram',
    `decryption_confidence_at_raid`  FLOAT        NOT NULL,
    `escape_window_seconds`          INT          NOT NULL DEFAULT 0,
    `outcome`                        ENUM('pending','captured','escaped','eliminated') NOT NULL DEFAULT 'pending',
    `created_at`                     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `resolved_at`                    DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_raid_log_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_raid_log_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- qb-phone Canli Yayin / Siber Propaganda Gunlugu (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_livestream_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `citizenid`        VARCHAR(50)  NOT NULL,
    `duration_seconds` INT          NOT NULL DEFAULT 0,
    `hype_multiplier`  FLOAT        NOT NULL DEFAULT 1.0,
    `heat_added`       FLOAT        NOT NULL DEFAULT 0.0,
    `trap_house_id`    INT          NULL,
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 3: İHANET & MUTFAK
-- =====================================================================


-- ---------------------------------------------------------------------
-- Ihanet & Muhbirlik Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_snitch_events` (
    `id`             INT         NOT NULL AUTO_INCREMENT,
    `bot_id`         INT         NOT NULL,
    `trap_house_id`  INT         NOT NULL,
    `snitch_index`   FLOAT       NOT NULL,
    `lied`           TINYINT(1)  NOT NULL DEFAULT 0,
    `created_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_snitch_events_bot` (`bot_id`),
    CONSTRAINT `fk_matrix_snitch_events_bot`
        FOREIGN KEY (`bot_id`) REFERENCES `matrix_bots` (`id`),
    CONSTRAINT `fk_matrix_snitch_events_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Mutfak Motoru - Seyreltme/Kesme Isletim Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_kitchen_batches` (
    `id`                           INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`                INT          NOT NULL,
    `actor_identifier`             VARCHAR(64)  NOT NULL,
    `raw_weight`                   FLOAT        NOT NULL,
    `raw_purity`                   FLOAT        NOT NULL,
    `agent_weight`                 FLOAT        NOT NULL,
    `theoretical_purity`           FLOAT        NOT NULL,
    `error_coefficient`            FLOAT        NOT NULL,
    `output_purity`                FLOAT        NOT NULL,
    `waste_volume`                 FLOAT        NOT NULL,
    `theft_amount`                 FLOAT        NOT NULL DEFAULT 0.0,
    `rival_infiltration_triggered` TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`                   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_kitchen_batches_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_kitchen_batches_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 4: İLLEGAL FİLO + TOPTANCI İLİŞKİ MATRİSİ + DEAD DROP
-- =====================================================================


-- ---------------------------------------------------------------------
-- İllegal Filo - Aktif Araç Havuzu. Bir araç ele geçirilirse (çatışma/
-- baskın) bu tablodan hard-delete edilir; kalıcı adli mühür ayrı olarak
-- matrix_vehicle_seizures'a yazılır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_fleet` (
    `id`                      INT          NOT NULL AUTO_INCREMENT,
    `plate`                   VARCHAR(32)  NOT NULL,
    `vehicle_class`           ENUM('motorbike','car') NOT NULL DEFAULT 'car',
    `vin_status`              ENUM('factory','scratched','hot') NOT NULL DEFAULT 'hot',
    `vehicle_wear`            FLOAT        NOT NULL DEFAULT 0.0,
    `registered_by_citizenid` VARCHAR(50)  NULL,
    `assigned_bot_id`         INT          NULL,
    `assignment_mode`         ENUM('permanent','temporary') NULL,
    `verified_stolen_plate`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_fleet_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Büro ALPR / Görsel Eşkal Eşleşme Günlüğü (asla silinmez).
-- Plaka + dealer fingerprint_dna_id + organizasyon imzası bağlanır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_alpr_hits` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `plate`                  VARCHAR(32)  NOT NULL,
    `fingerprint_dna_id`     VARCHAR(64)  NOT NULL,
    `organization_signature` VARCHAR(50)  NOT NULL,
    `trap_house_id`          INT          NOT NULL,
    `created_at`             DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_alpr_hits_plate` (`plate`),
    CONSTRAINT `fk_matrix_alpr_hits_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Ele Geçirilen Araç Mührü - kalıcı kanıt katsayısı (asla silinmez).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_vehicle_seizures` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `plate`                  VARCHAR(32)  NOT NULL,
    `vin_status`             ENUM('factory','scratched','hot') NOT NULL,
    `vehicle_wear`           FLOAT        NOT NULL DEFAULT 0.0,
    `fingerprint_dna_id`     VARCHAR(64)  NOT NULL,
    `organization_signature` VARCHAR(50)  NOT NULL,
    `seizure_cause`          VARCHAR(32)  NOT NULL DEFAULT 'unknown',
    `seal_certainty`         FLOAT        NOT NULL,
    `coords_x`               FLOAT        NOT NULL DEFAULT 0.0,
    `coords_y`               FLOAT        NOT NULL DEFAULT 0.0,
    `coords_z`               FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_vehicle_seizures_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Toptancı Güven Matrisi - oyuncu/toptancı ilişkisi kalıcıdır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_supplier_trust` (
    `citizenid`      VARCHAR(50) NOT NULL,
    `supplier_id`    INT         NOT NULL,
    `trust`          FLOAT       NOT NULL DEFAULT 0.5,
    `late_payments`  INT         NOT NULL DEFAULT 0,
    `forensic_leaks` INT         NOT NULL DEFAULT 0,
    `created_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`, `supplier_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Dead Drop Teslim Alma Günlüğü (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_dead_drop_events` (
    `id`                    INT          NOT NULL AUTO_INCREMENT,
    `drop_id`               INT          NOT NULL,
    `supplier_id`           INT          NOT NULL,
    `citizenid`             VARCHAR(50)  NOT NULL,
    `heat_at_pickup`        FLOAT        NOT NULL DEFAULT 0.0,
    `forensic_trace_left`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_dead_drop_events_drop` (`drop_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 5: QBOX CO-OP KARTEL HİYERARŞİSİ + BÖLGESEL PİYASA +
-- KILCAL DAMAR HARDCORE MEKANİKLER
-- =====================================================================


-- ---------------------------------------------------------------------
-- Co-op Kartel Rütbe Ataması (CitizenID bazlı, kalıcı)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_hierarchy` (
    `citizenid`   VARCHAR(50) NOT NULL,
    `rank`        ENUM('Leader','Logistics_Officer','Chemist') NOT NULL DEFAULT 'Chemist',
    `assigned_by` VARCHAR(50) NULL,
    `created_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Bölgesel Piyasa - anlık fiyat çarpanı / reddedilen parti sayacı
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_market_zones` (
    `zone_id`          INT      NOT NULL,
    `price_multiplier` FLOAT    NOT NULL DEFAULT 1.0,
    `rejected_streak`  INT      NOT NULL DEFAULT 0,
    `updated_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kirlenen Nakit Sönümlenmesi - trap house başına biriken kirli nakit ve
-- ilk yatırılma zamanı (adli koku/seri no izi τ=90 gün formülü buradan
-- türetilir; bkz. market.lua Matrix.CashDecay).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_cash_decay` (
    `trap_house_id`  INT      NOT NULL,
    `dirty_amount`   FLOAT    NOT NULL DEFAULT 0.0,
    `deposited_at`   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_cash_decay_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- FOREIGN KEY CHECK'LERİNİ YENİDEN AÇ
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — çalıştırıldığında 22 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS matrix_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name LIKE 'matrix\_%';


-- =====================================================================
-- BAKIM: Sıfırdan yeniden kurmak isterseniz aşağıdaki blok
-- (yalnızca FK sırasına göre tersten) DROP eder. Yorumdan çıkarıp
-- çalıştırın. Bu blok TÜM VERİYİ SİLER — dikkatli kullanın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_cash_decay`;
-- DROP TABLE IF EXISTS `matrix_market_zones`;
-- DROP TABLE IF EXISTS `matrix_hierarchy`;
-- DROP TABLE IF EXISTS `matrix_livestream_events`;
-- DROP TABLE IF EXISTS `matrix_dead_drop_events`;
-- DROP TABLE IF EXISTS `matrix_supplier_trust`;
-- DROP TABLE IF EXISTS `matrix_vehicle_seizures`;
-- DROP TABLE IF EXISTS `matrix_alpr_hits`;
-- DROP TABLE IF EXISTS `matrix_fleet`;
-- DROP TABLE IF EXISTS `matrix_kitchen_batches`;
-- DROP TABLE IF EXISTS `matrix_snitch_events`;
-- DROP TABLE IF EXISTS `matrix_raid_log`;
-- DROP TABLE IF EXISTS `matrix_bureau_intel`;
-- DROP TABLE IF EXISTS `matrix_pattern_log`;
-- DROP TABLE IF EXISTS `matrix_trap_houses`;
-- DROP TABLE IF EXISTS `matrix_recruitment_sessions`;
-- DROP TABLE IF EXISTS `matrix_customer_pool`;
-- DROP TABLE IF EXISTS `matrix_touch_log`;
-- DROP TABLE IF EXISTS `matrix_forensic_evidence`;
-- DROP TABLE IF EXISTS `matrix_ballistic_weapons`;
-- DROP TABLE IF EXISTS `matrix_player_state`;
-- DROP TABLE IF EXISTS `matrix_bots`;
-- SET FOREIGN_KEY_CHECKS = 1;