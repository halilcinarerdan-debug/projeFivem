fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'projeFivem'
description 'Katman 1-2-3-4-5 ULTIMATE Birlesik Motor: Core Matrix, Adli Balistik (+ Gercekci Namlu Asinmasi/Tutukluk), Recruitment, The Bureau, Mutfak & Psikoloji Simulasyonu, Programli Lojistik Sevk (+ Otomatik Rota Teslimati), Qbox Co-op Kartel Hiyerarsisi & Bolgesel Piyasa, Taktik Karaborsa Ticaret Agi, SIGINT/COMINT Bolge Denetleyicileri, Monokrom Taktik HUD'
version '1.3.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua'
}

client_scripts {
    'client/hud.lua'
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
    'server/blackmarket.lua'
}

dependencies {
    'ox_lib',
    'qbx_core',
    'oxmysql',
    'ox_inventory'
}
