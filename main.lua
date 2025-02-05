if pcall(require, "jit.opt") then
    require("jit.opt").start(
        "maxmcode=8192",
        "maxtrace=2000"
        --
    )
end
require "nes"
Nes = nil
local width = 256
local height = 240
local pixSize = 1
local lastSource
local sound = false
local DEBUG = false
function love.load(arg)
    --[[
    love.profiler = require("libs/profile")
    love.profiler.hookall("Lua")
    love.profiler.start()
    --]]
    local file = arg[1] or " "
    local loglvl = loadstring("return " .. (arg[2] or "0"))
    loglvl = loglvl and loglvl()
    DEBUG = not (not (loadstring("return " .. (arg[3] or "false"))))
    local pc = loadstring("return " .. (arg[4] or ""))
    pc = pc and pc()
    imageData = love.image.newImageData(width * pixSize + 1, height * pixSize + 1)
    image = love.graphics.newImage(imageData)
    love.window.setTitle("LuaNEs")
    --Nes = NES:new({file="tests/hello.nes", loglevel=5})
    Nes =
        NES:new(
        {
            file = file,
            loglevel = loglvl,
            pc = pc,
            palette = UTILS.map(
                PALETTE:defacto_palette(),
                function(c)
                    return {c[1] / 256, c[2] / 256, c[3] / 256}
                end
            )
        }
    )
    --Nes:run()
    Nes:reset()
    love.window.setMode(width, height, {resizable = true, minwidth = width, minheight = height})
    local samplerate = 44100
    local bits = 16
    local channels = 1
    sound = love.sound.newSoundData(samplerate / 60 + 1, samplerate, bits, channels)
    QS = love.audio.newQueueableSource(samplerate, bits, channels)
end
local keyEvents = {}
local keyButtons = {
    ["w"] = Pad.UP,
    ["a"] = Pad.LEFT,
    ["s"] = Pad.DOWN,
    ["d"] = Pad.RIGHT,
    ["o"] = Pad.A,
    ["p"] = Pad.B,
    ["i"] = Pad.SELECT,
    ["return"] = Pad.START
}
function love.keypressed(key)
    for k, v in pairs(keyButtons) do
        if k == key then
            keyEvents[#keyEvents + 1] = {"keydown", v}
        end
    end
end

function love.keyreleased(key)
    for k, v in pairs(keyButtons) do
        if k == key then
            keyEvents[#keyEvents + 1] = {"keyup", v}
        end
    end
end

love.frame = 0
local time = 0
local timeTwo = 0
local rate = 1 / 62.5
local fps = 0
local fpstmp = 0
local pixelCount = PPU.SCREEN_HEIGHT * PPU.SCREEN_WIDTH
local function update()
    drawn = true
    fpstmp = fpstmp + 1
    for i, v in ipairs(keyEvents) do
        Nes.pads[v[1]](Nes.pads, 1, v[2])
    end
    keyEvents = {}
    Nes:run_once()
    local samples = Nes.cpu.apu.output
    for i = 1, #samples do
        sound:setSample(i, samples[i])
    end
    QS:queue(sound)
    QS:play()
end
local function drawScreen()
    local sx = love.graphics.getWidth() / image:getWidth()
    local sy = love.graphics.getHeight() / image:getHeight()
    love.graphics.draw(image, 0, 0, 0, sx, sy)
    love.graphics.print(" Nes FPS: " .. tostring(fps), 10, 10)
end
local function drawPalette()
    local palette = Nes.cpu.ppu.output_color
    local w, h = 10, 10
    local x, y = 0, 50
    local row, column = 4, 8
    for i = 1, #palette do
        local px = palette[i]
        if px then
            local r = px[1]
            local g = px[2]
            local b = px[3]
            love.graphics.setColor(r, g, b, 1)
            love.graphics.rectangle("fill", x + ((i - 1) % row) * w, y + math.floor((i - 1) / 4) * h, w, h)
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end
local function drawAPUState()
    local apu = Nes.cpu.apu
    love.graphics.print(" Pulse 1", 10, 140)
    local pulse_0 = apu.pulse_0
    love.graphics.print(
        string.format(
            "F:%d D:%d V:%d  S:%d C:%d",
            pulse_0.freq / 1000,
            pulse_0.duty,
            pulse_0.envelope.output / APU.CHANNEL_OUTPUT_MUL,
            pulse_0.step,
            pulse_0.length_counter.count
        ),
        10,
        160
    )
    love.graphics.print(" Pulse 2", 10, 180)
    local pulse_1 = apu.pulse_1
    love.graphics.print(
        string.format(
            "F:%d D:%d V:%d  S:%d C:%d",
            pulse_1.freq / 1000,
            pulse_1.duty,
            pulse_1.envelope.output / APU.CHANNEL_OUTPUT_MUL,
            pulse_1.step,
            pulse_1.length_counter.count
        ),
        10,
        200
    )
end
local function draw()
    drawScreen()
    if DEBUG then
        drawPalette()
        drawAPUState()
    end
end
function love.draw()
    --[
    time = time + love.timer.getDelta()
    timeTwo = timeTwo + love.timer.getDelta()
    if time > rate then
        time = 0
        update()
    else
        draw()
        return
    end
    if timeTwo > 1 then
        timeTwo = 0
        fps = fpstmp
        fpstmp = 0
    end
    --]]
    --[[
    timeTwo = timeTwo + love.timer.getDelta()
    if timeTwo > 1 then
        timeTwo = 0
        fps = fpstmp
        fpstmp = 0
    end
    update()
    --]]
    --[
    local pxs = Nes.cpu.ppu.output_pixels
    for i = 1, pixelCount do
        local x = (i - 1) % width
        local y = math.floor((i - 1) / width) % height
        local px = pxs[i]
        --[[
        local r = rshift(band(px, 0x00ff0000), 16)
        local g = rshift(band(px, 0x0000ff00), 8)
        local b = band(px, 0x000000ff)
        --]]
        --[[
        local r = px[1]
        local g = px[2]
        local b = px[3]
        for j = 0, pixSize - 1 do
            for k = 0, pixSize - 1 do
                local xx = 1 + pixSize * (x) + j
                local yy = 1 + pixSize * (y) + k
                imageData:setPixel(xx, yy, r, g, b, 1)
            end
        end
        --]]
        --[
        imageData:setPixel(x + 1, y + 1, px[1], px[2], px[3], 1)
        --]]
    end
    image:replacePixels(imageData)
    draw()
end
