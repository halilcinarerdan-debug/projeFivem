fx_version 'cerulean'
game 'gta5'

name 'projeFivem'
description 'Katman 7: Otonom Depo Lojistigi ve Siber Sessizlik Entropisi - Faz 1'
author 'projeFivem'
version '7.1.0'

shared_scripts {
    'shared/config.lua',
}

server_scripts {
    'server/main.lua',
    'server/bureau.lua',
}

dependencies {
    'oxmysql',
}
