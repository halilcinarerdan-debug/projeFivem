-- =====================================================================
-- MATRIX SECURITY HARDENING PATCH / sql/matrix_security_hardening.sql
--
-- Bu migration, server/blackmarket.lua + server/bureau.lua ADLİ GÜVENLİK
-- DENETİMİ (7 maddelik zafiyet raporu) sonucu eklenen TEK yeni tabloyu
-- taşır: [SEC-2] "Hard Drop-Out / Orphan State" düzeltmesinin son çare
-- (son-kertede) tahsilat defteri.
--
-- matrix.sql'in KENDİSİ değiştirilmedi (mevcut şemaya elle dokunmak
-- riskli) -- bu proje layer5_ultimate.sql / layer6_trap_house.sql /
-- layer7_faz1.sql / layer7_faz3.sql ile AYNI "ek (additive) migration"
-- disiplinini izler. matrix.sql'den (veya son layer dosyasından) SONRA,
-- FOREIGN_KEY_CHECKS zaten 1'e dönmüş haldeyken import edilmelidir.
--
-- NOT: bu dosya "layer8" olarak ADLANDIRILMADI -- matrix.sql'in kendi
-- yorumunda KATMAN 8 zaten "Hard-Wipe / E_total" adlı, henüz tanımsız ve
-- BİLİNÇLİ OLARAK ertelenmiş ayrı bir özelliğe ayrılmış. Bu dosya o
-- katmanla KARIŞTIRILMASIN diye bağımsız bir isim taşır.
-- =====================================================================


-- ---------------------------------------------------------------------
-- ★ [SEC-2] Offline İade Son Çare Defteri
--
-- RefundCash (server/blackmarket.lua) şu sırayla dener:
--   1) Oyuncu çevrimiçiyse: Matrix.QBX Functions.AddMoney (anında).
--   2) Değilse: players.money JSON_SET ile ACID tek-UPDATE offline iade.
--   3) O UPDATE 0 satır etkilerse (citizenid players'ta yok -- silinmiş/
--      tanınmayan karakter): bu tabloya yazılır. Para HİÇBİR KOŞULDA
--      sessizce kaybolmaz; bir admin bu tabloyu görüp manuel mutabakat
--      yapabilir. Asla otomatik silinmez/işlenmez (yalnızca INSERT).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pending_refunds` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NOT NULL,
    `amount`      DECIMAL(12,2) NOT NULL,
    `reason`      VARCHAR(100) NOT NULL,
    `resolved`    TINYINT(1)   NOT NULL DEFAULT 0,
    `resolved_by` VARCHAR(50)  DEFAULT NULL,
    `resolved_at` DATETIME     DEFAULT NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_pending_refunds_citizenid` (`citizenid`),
    KEY `idx_matrix_pending_refunds_resolved` (`resolved`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;