local project = 0
local _, markerCount, regionCount =
    reaper.CountProjectMarkers(project)

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

for index = (markerCount + regionCount) - 1, 0, -1 do
    local found, isRegion, _, _, _, markerID =
        reaper.EnumProjectMarkers3(project, index)

    if found and not isRegion then
        reaper.DeleteProjectMarker(
            project,
            markerID,
            false
        )
    end
end

reaper.GetSet_LoopTimeRange(
    true,
    false,
    0,
    0,
    false
)

reaper.PreventUIRefresh(-1)
reaper.UpdateTimeline()

reaper.Undo_EndBlock(
    "Reset project markers and time selection",
    -1
)

