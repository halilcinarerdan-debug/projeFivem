-- =====================================================================
-- KATMAN 7 [T4] FAZ 3: OX_TARGET SOKAK DEVSIRME KOPRUSU
-- Additive migration. Yukaridaki (matrix.sql / layer5_ultimate.sql /
-- layer6_trap_house.sql / layer7_faz1.sql) hicbir tablosu/alani
-- DEGISTIRILMEDI -- ayni disiplin, yeni bir ALTER TABLE.
--
-- loyalty_base: [0,1] olcek, diger psychology alanlari (resilience,
-- snitch_tendency, ...) ILE AYNI sekilde matrix_bots'a eklenir.
-- server/recruitment.lua Matrix.Recruitment.RecruitStreetNpc'nin
-- ustunde calistigi TEK psikoloji semasi budur -- ikinci bir tablo
-- ACILMAZ. Varsayilan 0.5 (mevcut resilience/cognitive_shifter
-- varsayilanlariyla AYNI taban); yalnizca Ox_Target "Kadroya Kat"
-- devsirmesi (server/market.lua, /sokakdevsir test komutu ile AYNI
-- disiplin) bunu acikca 1.0 (mutlak sadik) yazar.
--
-- NOT: `ADD COLUMN IF NOT EXISTS`, MySQL 8.0.29+ / MariaDB 10.0+
-- gerektirir (oxmysql'in desteklediği surumlerin tamami bunu karsilar).
-- =====================================================================
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `loyalty_base` FLOAT NOT NULL DEFAULT 0.5
        COMMENT '[0,1]; Ox_Target ile devsirilen ajanlar 1.0 (mutlak sadik) alir'
        AFTER `snitch_tendency`;