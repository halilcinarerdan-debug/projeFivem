fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'projeFivem'
description 'Katman 1-2-3-4-5 ULTIMATE + KATMAN 6 Birlesik Motor: Core Matrix, Adli Balistik (+ Gercekci Namlu Asinmasi/Tutukluk), Recruitment, The Bureau, Mutfak & Psikoloji Simulasyonu, Programli Lojistik Sevk (+ Otomatik Rota Teslimati), Qbox Co-op Kartel Hiyerarsisi & Bolgesel Piyasa, Taktik Karaborsa Ticaret Agi (+ Rendezvous Teslimati/Buro Pususu), SIGINT/COMINT Bolge Denetleyicileri, Sanal Mahalle Evi (Interior Instance), Silah Tamir Tezgahi & Paketleme Odasi, Kapi Surgu Tahkimati, Monokrom Taktik HUD'
version '1.4.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua'
}

client_scripts {
    'client/hud.lua',
    'client/trap_house_client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/forensics.lua',
    'server/recruitment.lua',
    'server/bureau.lua',
    'server/kitchen.lua',
    'server/logistics.lua',
    'server/market.lua',
    'server/blackmarket.lua',
    'server/rendezvous.lua',
    'server/trap_house_interior.lua',
    'server/workbench.lua',
    'server/door_reinforcement.lua'
}

dependencies {
    'ox_lib',
    'qbx_core',
    'oxmysql',
    'ox_inventory',
    -- ★ KATMAN 6: Trap house iç mekanı (client/trap_house_client.lua)
    -- Trevor'ın treylerini doğru render etmek için bu kaynağı kullanır
    -- (bkz. shared/config.lua Config.TrapHouseInterior.Shell yorumu).
    -- Kurulum: https://github.com/Bob74/bob74_ipl -> resources/ klasörüne
    -- çıkarıp server.cfg'ye "start bob74_ipl" ekleyin (bu satırdan ÖNCE
    -- veya bağımsız bir yerde olabilir, sıra kritik değildir).
    'bob74_ipl'
}
