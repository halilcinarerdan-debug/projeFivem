-- =====================================================================
-- MATRIX SCHEMA — KATMAN 6 EK MİGRASYONU (sql/layer6_trap_house.sql)
-- Siber-Taktik Operasyon ve Stratejik Trap House Mimarisi
--
-- ★ BU DOSYA TAMAMEN EKLEMELİDİR (ADDITIVE-ONLY):
--   matrix.sql (v3, 22 tablo) ve sql/layer5_ultimate.sql (4 tablo)
--   HİÇBİR ŞEKİLDE değiştirilmez — ALTER YOK, DROP YOK, kolon eklenmedi.
--   Yalnızca 3 YENİ tablo eklenir. matrix.sql VE layer5_ultimate.sql'i
--   İMPORT ETTİKTEN SONRA bu dosyayı çalıştırın.
--
--   Aynı konvansiyonlar korunur: ENGINE=InnoDB DEFAULT CHARSET=utf8mb4,
--   "ON UPDATE CURRENT_TIMESTAMP" KULLANILMAZ (uygulama katmanı NOW() ile
--   yazar), `matrix_` öneki korunur, FK'ler yalnızca gerçekten var olan
--   kalıcı ebeveyn tablolara (matrix_trap_houses) bağlanır.
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- ---------------------------------------------------------------------
-- [K6-4] Kapı Sürgü Tahkimatı — trap house başına TEK aktif seviye
-- (0-3). server/door_reinforcement.lua tarafından okunur/yazılır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_door_reinforcement` (
    `trap_house_id` INT      NOT NULL,
    `level`         TINYINT  NOT NULL DEFAULT 0,
    `installed_by_citizenid` VARCHAR(50) NULL,
    `updated_at`    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_door_reinforcement_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [K6-1] Rendezvous / Dead Drop teslimatı adli kaydı — asla silinmez
-- (mevcut "adli kayıt politikası" ile aynı ruh: bir pusu/teslimatın
-- gerçekten olup olmadığı sonradan denetlenebilir kalır).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_rendezvous_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `citizenid`        VARCHAR(50)  NOT NULL,
    `catalog_type`     ENUM('weapon','ammo') NOT NULL,
    `catalog_id`       VARCHAR(64)  NOT NULL,
    `handoff_x`        FLOAT        NOT NULL DEFAULT 0.0,
    `handoff_y`        FLOAT        NOT NULL DEFAULT 0.0,
    `handoff_z`        FLOAT        NOT NULL DEFAULT 0.0,
    `trace_level_at_handoff` FLOAT  NOT NULL DEFAULT 0.0,
    `ambush_triggered` TINYINT(1)   NOT NULL DEFAULT 0,
    `outcome`          ENUM('pending','delivered','expired') NOT NULL DEFAULT 'pending',
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `resolved_at`      DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_rendezvous_events_citizenid` (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [K6-3] Paketleme Odası çalışma durumu — trap house başına TEK kayıt.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_packaging_room_state` (
    `trap_house_id` INT      NOT NULL,
    `active`        TINYINT(1) NOT NULL DEFAULT 0,
    `started_by_citizenid` VARCHAR(50) NULL,
    `updated_at`    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_packaging_room_state_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 3 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS layer6_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_door_reinforcement',
--       'matrix_rendezvous_events',
--       'matrix_packaging_room_state'
--   );


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği 3 tabloyu geri almak isterseniz
-- (matrix.sql/layer5_ultimate.sql'e DOKUNMAZ). Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_packaging_room_state`;
-- DROP TABLE IF EXISTS `matrix_rendezvous_events`;
-- DROP TABLE IF EXISTS `matrix_door_reinforcement`;
-- SET FOREIGN_KEY_CHECKS = 1;