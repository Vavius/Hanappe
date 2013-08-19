module(..., package.seeall)

function onCreate()
    local layer = flower.Layer()
    layer:setScene(scene)

    layer:setSortMode(MOAILayer.SORT_PRIORITY_ASCENDING)

    local dragon = spine.Skeleton("dragon/dragon.json", "dragon/")

    dragon:setLayer(layer)
    dragon:setLoc(140, 300)
    dragon:playAnimation('fly')

    dragon:setScl(0.5, 0.5)
end

