-- =====================================================================
-- KATMAN 7 [T4] FAZ 1: OTONOM DEPO LOJISTIGI VE BURO KILIDI
-- Additive migration. Yukaridaki (matrix.sql / layer5_ultimate.sql /
-- layer6_trap_house.sql) hicbir tablosu/alani DEGISTIRILMEDI -- her
-- ifade IF NOT EXISTS ile guvenlidir.
--
-- ★ KAPSAM NOTU: 'matrix_trap_stash' burada BULUNMUYOR -- trap house'un
-- ortak deposu zaten server/logistics.lua ve server/main.lua'nin
-- matrix_trap_stash_<id> ox_inventory stash'i (RegisterStash/AddItem/
-- RemoveItem) olarak MEVCUT. Ikinci bir SQL tablosu acmak veri
-- tutarsizligina yol acardi.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Kalici Kolektif Ogrenme Hafizasi -- trap house basina, RAID'LERDE
-- SIFIRLANMAYAN, birikimli telsiz ihlali + ele gecirilen urun saflik
-- kaydi. server/bureau.lua [T4] blogunun Buro Kilidi (lockdown_active)
-- karari BU tablodan turer; matrix_bureau_intel (mevcut) ile KARISTIRILMAZ
-- -- o yalnizca heat/triangulation/pattern yogunlugu tasir.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_learning_core` (
    `id`                          INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`               INT      NOT NULL,
    `frequent_zones`              TEXT     NULL COMMENT 'JSON array: bu trap house icin tekrarlanan ihlal etiketleri',
    `radio_breach_count`          INT      NOT NULL DEFAULT 0,
    `average_purity_intercepted`  FLOAT    NOT NULL DEFAULT 0.0 COMMENT '[0,1] olcek, matrix_kitchen_batches.output_purity ile ayni',
    `purity_sample_count`         INT      NOT NULL DEFAULT 0 COMMENT 'average_purity_intercepted hareketli ortalamasinin kendi bagimsiz sayaci',
    `lockdown_active`             TINYINT(1) NOT NULL DEFAULT 0,
    `updated_at`                  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_learning_core_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_learning_core_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Toplu Satis Hub'lari (District Distribution Hubs) -- F10 ile kritik
-- kavsaklara atanan, trap house'un ortak deposundan (matrix_trap_stash_
-- <id>) sabit miktarli/RNG'siz toplu satis dongusu yuruten dugumler.
-- `locked`, server/bureau.lua [T4]'un 'matrix:internal:bureauLockdown'
-- yayinindan senkronize edilir (server/district_hubs.lua).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_district_hubs` (
    `id`             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`  INT          NOT NULL,
    `label`          VARCHAR(100) NOT NULL,
    `coord_x`        FLOAT        NOT NULL,
    `coord_y`        FLOAT        NOT NULL,
    `coord_z`        FLOAT        NOT NULL,
    `active`         TINYINT(1)   NOT NULL DEFAULT 1,
    `locked`         TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_district_hubs_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_district_hubs_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;