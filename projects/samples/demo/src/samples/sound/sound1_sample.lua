module(..., package.seeall)

function onCreate(params)
    view = GUI.View {
        scene = scene
    }
    button1 = GUI.Button {
        parent = view,
        text = "play", 
        size = {200, 50},
        pos = {10, 10},
        onClick = button1_onClick,
    }
    button2 = GUI.Button {
        parent = view,
        text = "back",
        size = {200, 50},
        pos = {10, button1:getBottom() + 10},
        onClick = button2_onClick,
    }
    
    sound = SoundManager:getSound("mono16.wav")
end

function button1_onClick(e)
    if sound:isPlaying() then
        sound:stop()
        button1:setText("play")
    else
        sound:play()
        button1:setText("stop")
    end
end

function button2_onClick(e)
    sound:stop()
    SceneManager:closeScene()
end