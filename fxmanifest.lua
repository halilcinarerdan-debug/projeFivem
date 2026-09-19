fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'projeFivem'
description 'Katman 1-2-3 Birlesik Motor: Core Matrix, Adli Balistik, Recruitment, The Bureau, Mutfak & Psikoloji Simulasyonu'
version '1.0.0'

shared_scripts {
    'shared/config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/forensics.lua',
    'server/recruitment.lua',
    'server/bureau.lua',
    'server/kitchen.lua'
}

dependencies {
    'qb-core',
    'oxmysql',
    'ox_inventory'
}
