local startTime = reaper.GetCursorPosition()

local ok, durationText = reaper.GetUserInputs(
    "Set Time Selection from Cursor",
    1,
    "Duration in seconds",
    ""
)

if not ok then
    return
end

local duration = tonumber(durationText)

if not duration or duration <= 0 then
    reaper.MB(
        "Enter a duration greater than zero.",
        "Invalid Duration",
        0
    )
    return
end

reaper.GetSet_LoopTimeRange(
    true,
    false,
    startTime,
    startTime + duration,
    false
)

reaper.UpdateArrange()

