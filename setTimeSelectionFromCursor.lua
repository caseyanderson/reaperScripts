local project = 0
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

local selectedItemCount =
    reaper.CountSelectedMediaItems(project)

if selectedItemCount == 0 then
    reaper.MB(
        "Select at least one media item.",
        "No Selected Items",
        0
    )
    return
end

local selectedItems = {}

for index = 0, selectedItemCount - 1 do
    selectedItems[#selectedItems + 1] =
        reaper.GetSelectedMediaItem(project, index)
end

local endTime = startTime + duration

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

reaper.GetSet_LoopTimeRange(
    true,
    false,
    startTime,
    endTime,
    false
)

for _, item in ipairs(selectedItems) do
    local itemStart =
        reaper.GetMediaItemInfo_Value(
            item,
            "D_POSITION"
        )

    local itemEnd =
        itemStart
        + reaper.GetMediaItemInfo_Value(
            item,
            "D_LENGTH"
        )

    if endTime > itemStart and endTime < itemEnd then
        reaper.SplitMediaItem(item, endTime)
    end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()

reaper.Undo_EndBlock(
    "Set time selection and split selected items",
    -1
)
