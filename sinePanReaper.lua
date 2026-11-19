

-- Opposing panning for two selected audio items

-- local cycle = 12 -- default
-- local cycle = 3 -- fast
local cycle = 20 -- slow
local width = 0.8
local interval = 0.1

if reaper.CountSelectedMediaItems(0) ~= 2 then
    reaper.MB("Select exactly two items.", "Error", 0)
    return
end

reaper.Undo_BeginBlock()

for i = 0, 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)

    if take then
        local env = reaper.GetTakeEnvelopeByName(take, "Pan")

        if env then
            local length = reaper.GetMediaItemInfo_Value(
                item, "D_LENGTH"
            )

            reaper.DeleteEnvelopePointRange(
                env, 0, length + 0.000001
            )

            local steps = math.ceil(length / interval)

            for j = 0, steps do
                local t = math.min(j * interval, length)

                local pan = math.sin(
                    2 * math.pi * t / cycle
                ) * width

                if i == 1 then
                    pan = -pan
                end

                reaper.InsertEnvelopePoint(
                    env, t, pan, 0, 0, false, true
                )
            end

            reaper.Envelope_SortPoints(env)
        end
    end
end

reaper.UpdateArrange()
reaper.Undo_EndBlock("Opposing Pan Automation", -1)

