-- =====================================================================
-- MATRIX SCHEMA — KATMAN 5 ULTIMATE EK MİGRASYONU (sql/layer5_ultimate.sql)
-- Co-Op & SIGINT/COMINT Bali-Logistics Matrix
--
-- ★ BU DOSYA TAMAMEN EKLEMELİDİR (ADDITIVE-ONLY):
--   matrix.sql'deki (v3) 16 tabloya HİÇBİRİNE DOKUNULMAZ — ALTER YOK,
--   DROP YOK, kolon eklenmedi. Yalnızca 4 YENİ tablo eklenir. matrix.sql'i
--   İMPORT ETTİKTEN SONRA bu dosyayı çalıştırın.
--
--   Bu dosya, matrix.sql ile AYNI konvansiyonları izler:
--     - ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
--     - "DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP" KULLANILMAZ
--       (bazı MariaDB/MySQL derlemelerinde CREATE TABLE'ı sessizce
--       başarısız kılıyordu — v1→v2 notu, bkz. matrix.sql). `updated_at`/
--       `flagged_at`/`assigned_at` uygulama katmanında (server/market.lua,
--       server/blackmarket.lua) her UPSERT'te explicit NOW() ile yazılır.
--     - Tablo/kolon adları geriye dönük `matrix_` önekini korur.
--
--   ★ KASITLI TASARIM KARARI — FK YOK: `matrix_zone_inspectors.bot_id` ve
--     `matrix_mole_flags.bot_id`, KASITLI OLARAK `matrix_bots.id`'ye FOREIGN
--     KEY İLE BAĞLANMAZ. Sebep: server/logistics.lua'nın Matrix.Logistics.
--     OnDealerEliminated'i (F10 "Operatif Tasfiye Et" -> /operatiftasfiye,
--     bkz. server/main.lua) matrix_bots satırını GERÇEK bir DELETE ile
--     kalıcı olarak siler (hard-delete politikası, matrix.sql başlığında
--     zaten tanımlı). Bir Inspector'a atanmış veya köstebek olarak
--     işaretlenmiş bir botu tasfiye etmek İSTİSNASIZ ÇALIŞMALIDIR — bir FK
--     kısıtı (varsayılan RESTRICT/NO ACTION) bu hard-delete'i SESSİZCE
--     BLOKE ederdi. RAM tarafında (server/market.lua Matrix.Inspector)
--     zaten stale bot_id'lere karşı dayanıklı: silinen bir bot bir
--     sonraki taramada otomatik olarak atamadan düşer (self-healing).
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- ---------------------------------------------------------------------
-- [U2] Karaborsa Ticaret Ağı - satın alma günlüğü (asla silinmez; mevcut
-- "adli kayıt politikası" ruhuna uygun kalıcı bir kâğıt izi).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_blackmarket_purchases` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NOT NULL,
    `item_type`   ENUM('vehicle','weapon','barrel','burner_phone') NOT NULL,
    `item_ref`    VARCHAR(64)  NOT NULL,
    `price_paid`  FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_blackmarket_purchases_citizenid` (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U4] SIGINT - Bölge Denetleyicisi (Inspector) ataması. Bölge başına
-- TEK aktif denetleyici (PRIMARY KEY = zone_id); yeniden atama UPSERT ile
-- öncekinin yerini alır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_zone_inspectors` (
    `zone_id`                INT         NOT NULL,
    `bot_id`                 INT         NOT NULL,
    `assigned_by_citizenid`  VARCHAR(50) NULL,
    `assigned_at`            DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U4] SIGINT - Köstebek/muhbir tarama sonucu kalıcı bülteni. Bir botun
-- Operatif Tasfiye Et ile arındırılmasından SONRA da (kanıt/denetim amaçlı)
-- kalır; matrix_bots.id hard-delete sonrası hiçbir zaman yeniden
-- kullanılmaz (Matrix.NextBotId monoton artar), bu yüzden stale satır bir
-- sonraki bot ile ASLA çakışmaz.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_mole_flags` (
    `bot_id`           INT      NOT NULL,
    `snitch_tendency`  FLOAT    NOT NULL DEFAULT 0.0,
    `flagged_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`bot_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U6] Bölgesel Mali Rapor - bölge başına yuvarlanan (rolling) kâr/zarar
-- bilançosu. matrix_market_zones (fiyat çarpanı/ardarda-red) ile AYNI
-- zone_id uzayını paylaşır ama BAĞIMSIZ bir tablodur (o da zone_id'ye FK
-- taşımıyor — zone'lar Config.Market.Zones'ta statik tanımlı, ayrı bir
-- "zones" ebeveyn tablosu hiç var olmadı).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_zone_ledger` (
    `zone_id`            INT      NOT NULL,
    `sale_count`         INT      NOT NULL DEFAULT 0,
    `total_grams`        FLOAT    NOT NULL DEFAULT 0.0,
    `gross_revenue`      FLOAT    NOT NULL DEFAULT 0.0,
    `net_profit`         FLOAT    NOT NULL DEFAULT 0.0,
    `price_crash_count`  INT      NOT NULL DEFAULT 0,
    `updated_at`         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 4 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS layer5_ultimate_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_blackmarket_purchases',
--       'matrix_zone_inspectors',
--       'matrix_mole_flags',
--       'matrix_zone_ledger'
--   );


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği 4 tabloyu geri almak isterseniz
-- (matrix.sql'in 16 tablosuna DOKUNMAZ). Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_zone_ledger`;
-- DROP TABLE IF EXISTS `matrix_mole_flags`;
-- DROP TABLE IF EXISTS `matrix_zone_inspectors`;
-- DROP TABLE IF EXISTS `matrix_blackmarket_purchases`;
-- SET FOREIGN_KEY_CHECKS = 1;