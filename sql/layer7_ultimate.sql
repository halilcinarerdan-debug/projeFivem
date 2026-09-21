-- =============================================================================
-- KATMAN 7: OTONOM DEPO LOJISTIGI VE SIBER SESSIZLIK ENTROPISI - FAZ 1
-- Additive migration. Every statement is IF NOT EXISTS safe to run against a
-- live database that already has Layer 1-6 tables; nothing here drops or
-- rewrites existing schema.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- matrix_bureau_learning_core
-- Kalici Kolektif Ogrenme Hafizasi: one row per district/gang territory the
-- Bureau tracks. `district_id` is not in the literal spec list but is added
-- as the lookup key -- without it a single shared row could not represent
-- independent lockdown state per neighborhood, which Faz 3 requires.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_learning_core` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `district_id` VARCHAR(64) NOT NULL,
    `frequent_zones` TEXT NULL COMMENT 'JSON array of zone labels the Bureau has repeatedly intercepted activity in',
    `radio_breach_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `average_purity_intercepted` FLOAT NOT NULL DEFAULT 0,
    `lockdown_active` TINYINT(1) NOT NULL DEFAULT 0,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_learning_district` (`district_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- matrix_trap_stash
-- Ortak depo: shared per-trap-house inventory that courier bots and district
-- hubs draw batches from. Stacks by (stash_owner, item_name) instead of one
-- row per unit so hub sale cycles are a single UPDATE, not a scan.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_trap_stash` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `stash_owner` VARCHAR(64) NOT NULL COMMENT 'Trap house / district identifier that owns this stack',
    `item_name` VARCHAR(64) NOT NULL,
    `amount` INT UNSIGNED NOT NULL DEFAULT 0,
    `purity` FLOAT NOT NULL DEFAULT 0 COMMENT 'Feeds average_purity_intercepted when a stack is busted',
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_stash_owner_item` (`stash_owner`, `item_name`),
    KEY `idx_matrix_stash_owner` (`stash_owner`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- matrix_district_hubs
-- Toplu Satis Hub'lari: F10-assigned bulk distribution nodes. `locked` mirrors
-- matrix_bureau_learning_core.lockdown_active for this hub's district and is
-- what server/bureau.lua actually checks on the hot path (no join needed).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_district_hubs` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `district_name` VARCHAR(64) NOT NULL,
    `coord_x` FLOAT NOT NULL,
    `coord_y` FLOAT NOT NULL,
    `coord_z` FLOAT NOT NULL,
    `assigned_bots` TEXT NULL COMMENT 'JSON array of courier bot identifiers camped at this hub',
    `active` TINYINT(1) NOT NULL DEFAULT 1,
    `locked` TINYINT(1) NOT NULL DEFAULT 0,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_hub_district` (`district_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
