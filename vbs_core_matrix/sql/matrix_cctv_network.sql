-- =====================================================================
-- MATRIX CCTV NETWORK PATCH / sql/matrix_cctv_network.sql
--
-- Bu migration, server/forensics.lua ★ [OPSEC FAZ 1 EK] FİZİKSEL VE SİBER
-- DELİL İMHA MEKANİZMASI (Matrix.Forensics.HackCCTVNetwork) için TEK yeni
-- tabloyu taşır. matrix.sql'in (veya son layer/hardening dosyasının)
-- KENDİSİ değiştirilmedi -- bu proje layer5_ultimate.sql / layer6_trap_
-- house.sql / layer7_faz1.sql / layer7_faz3.sql / matrix_security_
-- hardening.sql İLE AYNI "ek (additive) migration" disiplinini izler.
-- matrix.sql'den (veya son migration dosyasından) SONRA, FOREIGN_KEY_CHECKS
-- zaten 1'e dönmüş haldeyken import edilmelidir.
--
-- ★ KAPSAM NOTU: bu migration YALNIZCA HackCCTVNetwork'ün SİLDİĞİ tabloyu
-- tanımlar. Mobese ağının oyuncu/bot kıyafet eşleşmesini GERÇEKTEN nasıl
-- TESPİT EDİP bu tabloya YAZACAĞI (bir algılama/computer-vision motoru)
-- bu görevin kapsamı DIŞINDADIR -- Config.AI_Matrix_Brain'in "altyapı
-- hazır, motor gelecekte devreye girer" (enabled=false) köprüsüyle AYNI
-- bilinçli erteleme. server/forensics.lua'daki /cctvkaydet test komutu,
-- gerçek bir algılama motoru olmadan bu tabloyu manuel doldurmak için
-- (bkz. server/bureau.lua /dropsizintiekle İLE AYNI "test-veri-ekleme"
-- disiplini) eklendi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Mobese Dağıtım Kutusu Kayıtları — bölge başına, zaman damgalı kıyafet/
-- maskeleme eşleşme günlüğü. HackCCTVNetwork yalnızca `masked = 0`
-- (maskesiz/şüpheli) VE son 30 dakika içindeki satırları siler; maskeli
-- (masked = 1) satırlar veya 30 dakikadan eski satırlar HİÇ ETKİLENMEZ.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_cctv_logs` (
    `id`           INT          NOT NULL AUTO_INCREMENT,
    `zone_id`      INT          NOT NULL,
    `dna_id`       VARCHAR(64)  NOT NULL,
    `masked`       TINYINT(1)   NOT NULL DEFAULT 0,
    `clothing_tag` VARCHAR(64)  NOT NULL DEFAULT 'unknown',
    `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_cctv_logs_zone_time` (`zone_id`, `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 1 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS matrix_cctv_network_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN ('matrix_cctv_logs');


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği tabloyu geri almak isterseniz.
-- Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- DROP TABLE IF EXISTS `matrix_cctv_logs`;
