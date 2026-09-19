-- ============================================================================
--  THE BUREAU :: KATMAN 1 -- THE CORE MATRIX (new_framework.sql)
--  MariaDB / InnoDB / utf8mb4 -- tamamen idempotent (IF NOT EXISTS)
--
--  ON BOSUL: Bu dosya, qb-core'un kendi semasi (ozellikle `players` tablosu)
--  zaten kurulu, "sifir kilometre" bos bir sunucuda calistirilmak uzere
--  tasarlanmistir. FK kisitlari `players.citizenid` alanina baglanir.
--  Tablolar, birbirlerine olan FK bagimliliklarina gore sirali kurulur.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) sigint_afis_cold_cases
--    Parmak izi kalitesi esigini gecen izlerin dustugu AFIS soguk vaka
--    veritabani. (forensic_ballistic_logs bu tabloya referans verdigi icin
--    ondan once kurulur.)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `sigint_afis_cold_cases` (
    `id`                  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `fingerprint_id`      VARCHAR(64)  NOT NULL,
    `suspect_citizenid`   VARCHAR(50)  DEFAULT NULL,
    `case_coords_x`       DOUBLE       NOT NULL,
    `case_coords_y`       DOUBLE       NOT NULL,
    `case_coords_z`       DOUBLE       NOT NULL,
    `print_quality`       DECIMAL(5,2) NOT NULL COMMENT '%, Config.ForensicThresholds.LatentPrintLimit ustundeki degerler burada',
    `status`              ENUM('cold', 'under_review', 'matched', 'closed') NOT NULL DEFAULT 'cold',
    `matched_citizenid`   VARCHAR(50)  DEFAULT NULL,
    `reported_at`          TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fingerprint_id` (`fingerprint_id`),
    KEY `idx_status` (`status`),
    KEY `idx_suspect_citizenid` (`suspect_citizenid`),
    CONSTRAINT `fk_afis_suspect_citizenid`
        FOREIGN KEY (`suspect_citizenid`) REFERENCES `players` (`citizenid`)
        ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT `fk_afis_matched_citizenid`
        FOREIGN KEY (`matched_citizenid`) REFERENCES `players` (`citizenid`)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 2) sigint_cellular_matrix
--    Kiralanan alt torbacilarin (agents) ve dusman cete hucrelerinin
--    sinyal istihbarati (SIGINT) izini tutar.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `sigint_cellular_matrix` (
    `id`                       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `owner_citizenid`          VARCHAR(50)  DEFAULT NULL COMMENT 'Hucreyi kiralayan oyuncu; NULL ise dusman cete hucresidir',
    `entity_type`              ENUM('player_agent', 'enemy_cell') NOT NULL DEFAULT 'player_agent',
    `imei`                     VARCHAR(20)  NOT NULL,
    `imsi`                     VARCHAR(20)  NOT NULL,
    `crypto_balance`           DECIMAL(24,12) NOT NULL DEFAULT 0.000000000000 COMMENT 'Monero (XMR) bakiyesi',
    `packet_leak_ratio`        DECIMAL(5,4) NOT NULL DEFAULT 0.0000 COMMENT '0.0000 - 1.0000 arasi sizinti orani',
    `latent_print_weight`      DECIMAL(5,2) NOT NULL DEFAULT 0.00 COMMENT 'Cihaz uzerindeki parmak izi risk skoru',
    `crypto_challenge_phrase`  VARCHAR(255) DEFAULT NULL COMMENT 'Sifreli iletisim challenge/response ifadesinin hash''i',
    `is_compromised`           TINYINT(1)   NOT NULL DEFAULT 0 COMMENT 'Honeypot / deSifre edilmis hat bayragi',
    `last_ping_at`             DATETIME     DEFAULT NULL,
    `created_at`                TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_imei` (`imei`),
    UNIQUE KEY `uq_imsi` (`imsi`),
    KEY `idx_owner_citizenid` (`owner_citizenid`),
    KEY `idx_is_compromised` (`is_compromised`),
    CONSTRAINT `fk_sigint_owner_citizenid`
        FOREIGN KEY (`owner_citizenid`) REFERENCES `players` (`citizenid`)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 3) forensic_ballistic_logs
--    Patlayan her merminin tam koordinati, ses basinc logu ve namlunun
--    mikroskobik yiv-set imza hash'i (striation_pattern_hash).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `forensic_ballistic_logs` (
    `id`                       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `shooter_identifier`       VARCHAR(64)   NOT NULL COMMENT 'citizenid veya NPC/hucre kimligi',
    `weapon_hash`              VARCHAR(32)   NOT NULL,
    `coords_x`                 DOUBLE        NOT NULL,
    `coords_y`                 DOUBLE        NOT NULL,
    `coords_z`                 DOUBLE        NOT NULL,
    `sound_pressure_db`        DECIMAL(6,2)  NOT NULL DEFAULT 0.00,
    `striation_pattern_hash`   CHAR(64)      NOT NULL COMMENT 'Namlunun sabit yiv-set imzasi (silah seri numarasindan turetilir)',
    `shot_spotter_triggered`   TINYINT(1)    NOT NULL DEFAULT 0,
    `case_linked_id`           INT UNSIGNED  DEFAULT NULL COMMENT 'Eslesen AFIS soguk vakasi (varsa)',
    `created_at`                TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_shooter_identifier` (`shooter_identifier`),
    KEY `idx_striation_pattern_hash` (`striation_pattern_hash`),
    KEY `idx_coords` (`coords_x`, `coords_y`),
    KEY `idx_case_linked_id` (`case_linked_id`),
    CONSTRAINT `fk_ballistic_case_linked`
        FOREIGN KEY (`case_linked_id`) REFERENCES `sigint_afis_cold_cases` (`id`)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 4) trap_house_stashes
--    Motel odalari ve gizli trap house'larin envanter agirliklarini
--    (Gram/Kilogram sinirlariyla) ve arama karari (Search Warrant)
--    bayragini tutar. ox_inventory ile agirlik birimi koprusu buradadir.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `trap_house_stashes` (
    `id`                       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `property_identifier`     VARCHAR(100)  NOT NULL COMMENT 'ox_inventory stash id ile birebir eslesir',
    `property_type`           ENUM('motel_room', 'trap_house') NOT NULL,
    `owner_citizenid`         VARCHAR(50)   DEFAULT NULL,
    `current_weight_grams`    DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    `max_weight_grams`        DECIMAL(12,2) NOT NULL COMMENT 'Config.StashLimits degerlerinden senkronize edilir (her zaman gram)',
    `heat_score`               DECIMAL(8,2) NOT NULL DEFAULT 0.00,
    `meet_point_count`         INT UNSIGNED NOT NULL DEFAULT 0,
    `search_warrant_flag`      TINYINT(1)   NOT NULL DEFAULT 0,
    `warrant_issued_at`        DATETIME     DEFAULT NULL,
    `last_raid_at`             DATETIME     DEFAULT NULL,
    `coords_x`                 DOUBLE       NOT NULL,
    `coords_y`                 DOUBLE       NOT NULL,
    `coords_z`                 DOUBLE       NOT NULL,
    `created_at`                TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_property_identifier` (`property_identifier`),
    KEY `idx_owner_citizenid` (`owner_citizenid`),
    KEY `idx_search_warrant_flag` (`search_warrant_flag`),
    KEY `idx_property_type` (`property_type`),
    CONSTRAINT `fk_stash_owner_citizenid`
        FOREIGN KEY (`owner_citizenid`) REFERENCES `players` (`citizenid`)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
