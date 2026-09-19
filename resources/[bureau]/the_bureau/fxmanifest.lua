fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'the_bureau'
author 'projeFivem'
description 'Katman 2 :: The Bureau -- Asimetrik Harp ve Organize Suc Simulatoru, Yapay Zeka Istihbarat Motoru'
version '1.0.0'

shared_scripts {
    'config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/the_bureau.lua'
}

client_scripts {
    'client/client_bureau.lua'
}

dependency 'qb-core'
dependency 'oxmysql'
dependency 'ox_inventory'
