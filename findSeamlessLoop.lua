local project = 0
local defaultSearchDuration = 1.0
local comparisonDuration = 0.005
local comparisonStride = 8
local readChunkFrames = 16384

local function stop(message, title)
    reaper.MB(message, title or "Find Loop Selection", 0)
end

local function requestSettings()
    local ok, inputValues = reaper.GetUserInputs(
        "Find Loop Selection from Marker",
        3,
        "Marker number,Exact duration in seconds,Search window in seconds",
        "1,32," .. defaultSearchDuration
    )

    if not ok then
        return nil
    end

    local markerText, durationText, searchText =
        inputValues:match(
            "^%s*([^,]+)%s*,%s*([^,]+)%s*,%s*([^,]+)%s*$"
        )

    local markerNumber = tonumber(markerText)
    local duration = tonumber(durationText)
    local searchDuration = tonumber(searchText)

    if not markerNumber or markerNumber % 1 ~= 0 then
        stop("Enter a whole-number marker ID.", "Invalid Marker")
        return nil
    end

    if not duration or duration <= 0 then
        stop(
            "Enter a duration greater than zero.",
            "Invalid Duration"
        )
        return nil
    end

    if not searchDuration or searchDuration <= 0 then
        stop(
            "Enter a search window greater than zero.",
            "Invalid Search Window"
        )
        return nil
    end

    return {
        markerNumber = markerNumber,
        duration = duration,
        searchDuration = searchDuration
    }
end

local function findMarkerTime(markerNumber)
    local _, markerCount, regionCount =
        reaper.CountProjectMarkers(project)

    for index = 0, markerCount + regionCount - 1 do
        local found, isRegion, position, _, _, markerID =
            reaper.EnumProjectMarkers3(project, index)

        if found
            and not isRegion
            and markerID == markerNumber
        then
            return position
        end
    end

    stop(
        "Project marker "
        .. markerNumber
        .. " was not found.",
        "Marker Not Found"
    )

    return nil
end

local function getSelectedAudioTake()
    local selectedItemCount =
        reaper.CountSelectedMediaItems(project)

    if selectedItemCount ~= 1 then
        stop("Select exactly one audio item.")
        return nil
    end

    local item =
        reaper.GetSelectedMediaItem(project, 0)

    local take = reaper.GetActiveTake(item)

    if not take or reaper.TakeIsMIDI(take) then
        stop("The selected item needs an active audio take.")
        return nil
    end

    return item, take
end

local function readAudioFrames(
    accessor,
    startTime,
    totalFrames,
    sampleRate,
    channelCount
)
    local samples = {}
    local framesRead = 0

    while framesRead < totalFrames do
        local frameCount = math.min(
            readChunkFrames,
            totalFrames - framesRead
        )

        local buffer =
            reaper.new_array(
                frameCount * channelCount
            )

        local result =
            reaper.GetAudioAccessorSamples(
                accessor,
                sampleRate,
                channelCount,
                startTime
                    + (framesRead / sampleRate),
                frameCount,
                buffer
            )

        if result ~= 1 then
            return nil, result
        end

        local block = buffer.table()

        for index = 1, #block do
            samples[#samples + 1] = block[index]
        end

        framesRead = framesRead + frameCount
    end

    return samples, 1
end

local function readLoopAnalysis(
    item,
    take,
    markerTime,
    settings
)
    local itemStart =
        reaper.GetMediaItemInfo_Value(
            item,
            "D_POSITION"
        )

    local itemEnd = itemStart
        + reaper.GetMediaItemInfo_Value(
            item,
            "D_LENGTH"
        )

    local source =
        reaper.GetMediaItemTake_Source(take)

    local sampleRate =
        reaper.GetMediaSourceSampleRate(source)

    local channelCount =
        reaper.GetMediaSourceNumChannels(source)

    if sampleRate <= 0 or channelCount <= 0 then
        stop("Could not read the selected take format.")
        return nil
    end

    local searchFrames =
        math.floor(
            settings.searchDuration * sampleRate
        )

    local comparisonFrames = math.max(
        2,
        math.floor(comparisonDuration * sampleRate)
    )

    local requiredEnd = markerTime
        + settings.duration
        + settings.searchDuration
        + comparisonDuration

    local startReadTime = markerTime
        - (comparisonFrames / sampleRate)

    if startReadTime < itemStart
        or requiredEnd > itemEnd
    then
        stop(
            "The selected item does not contain enough audio "
            .. "around the marker, requested duration, and "
            .. string.format(
                "%.3f-second search window.",
                settings.searchDuration
            )
        )
        return nil
    end

    local blockFrames = searchFrames
        + (comparisonFrames * 2)
        + 2

    local accessor =
        reaper.CreateTakeAudioAccessor(take)

    if not accessor then
        stop("Could not create an audio accessor.")
        return nil
    end

    local accessorStartReadTime =
        startReadTime - itemStart

    local startSamples, startResult =
        readAudioFrames(
            accessor,
            accessorStartReadTime,
            blockFrames,
            sampleRate,
            channelCount
        )

    local endReadTime = markerTime
        + settings.duration
        - (comparisonFrames / sampleRate)

    local accessorEndReadTime =
        endReadTime - itemStart

    local endSamples, endResult =
        readAudioFrames(
            accessor,
            accessorEndReadTime,
            blockFrames,
            sampleRate,
            channelCount
        )

    reaper.DestroyAudioAccessor(accessor)

    if startResult ~= 1 then
        stop(
            "Could not read audio around the start-boundary "
            .. "search area. REAPER returned "
            .. tostring(startResult)
            .. "."
        )
        return nil
    end

    if endResult ~= 1 then
        stop(
            "Could not read audio around the exact-duration "
            .. "endpoint search area. REAPER returned "
            .. tostring(endResult)
            .. "."
        )
        return nil
    end

    return {
        channelCount = channelCount,
        comparisonFrames = comparisonFrames,
        endSamples = endSamples,
        itemStart = itemStart,
        sampleRate = sampleRate,
        searchFrames = searchFrames,
        startSamples = startSamples
    }
end

local function findBestSeamOffset(analysis)
    local function sampleAt(samples, frame, channel)
        return samples[
            (frame * analysis.channelCount)
            + channel
            + 1
        ] or 0
    end

    local function crossesZero(samples, frame, channel)
        local previous =
            sampleAt(samples, frame - 1, channel)

        local current =
            sampleAt(samples, frame, channel)

        return (previous <= 0 and current >= 0)
            or (previous >= 0 and current <= 0)
    end

    local function seamScore(offset)
        local score = 0
        local center =
            offset + analysis.comparisonFrames

        for channel = 0, analysis.channelCount - 1 do
            local startValue = sampleAt(
                analysis.startSamples,
                center,
                channel
            )

            local startNext = sampleAt(
                analysis.startSamples,
                center + 1,
                channel
            )

            local endPrevious = sampleAt(
                analysis.endSamples,
                center - 1,
                channel
            )

            local endValue = sampleAt(
                analysis.endSamples,
                center,
                channel
            )

            local boundaryDifference =
                endPrevious - startValue

            local slopeDifference =
                (endValue - endPrevious)
                - (startNext - startValue)

            score = score
                + (boundaryDifference * boundaryDifference)
                + (slopeDifference * slopeDifference)

            for relativeFrame =
                -analysis.comparisonFrames,
                analysis.comparisonFrames,
                comparisonStride
            do
                local difference =
                    sampleAt(
                        analysis.startSamples,
                        center + relativeFrame,
                        channel
                    )
                    - sampleAt(
                        analysis.endSamples,
                        center + relativeFrame,
                        channel
                    )

                score = score
                    + (difference * difference * 0.1)
            end
        end

        return score
    end

    local bestOffset = nil
    local bestScore = math.huge

    for offset = 1, analysis.searchFrames do
        local center =
            offset + analysis.comparisonFrames

        if crossesZero(
            analysis.startSamples,
            center,
            0
        ) and crossesZero(
            analysis.endSamples,
            center,
            0
        ) then
            local score = seamScore(offset)

            if score < bestScore then
                bestScore = score
                bestOffset = offset
            end
        end
    end

    if not bestOffset then
        for offset = 1, analysis.searchFrames do
            local score = seamScore(offset)

            if score < bestScore then
                bestScore = score
                bestOffset = offset
            end
        end
    end

    return bestOffset
end

local function applyLoopSelection(
    item,
    itemStart,
    loopStart,
    loopEnd
)
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    reaper.GetSet_LoopTimeRange(
        true,
        false,
        loopStart,
        loopEnd,
        false
    )

    local loopItem = item

    if loopStart > itemStart then
        loopItem =
            reaper.SplitMediaItem(
                item,
                loopStart
            )
    end

    if loopItem then
        local loopItemStart =
            reaper.GetMediaItemInfo_Value(
                loopItem,
                "D_POSITION"
            )

        local loopItemEnd = loopItemStart
            + reaper.GetMediaItemInfo_Value(
                loopItem,
                "D_LENGTH"
            )

        if loopEnd > loopItemStart
            and loopEnd < loopItemEnd
        then
            reaper.SplitMediaItem(
                loopItem,
                loopEnd
            )
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()

    reaper.Undo_EndBlock(
        "Find exact-duration loop selection",
        -1
    )
end

local function showResult(
    settings,
    markerTime,
    loopStart
)
    reaper.MB(
        string.format(
            "Created an exact %.6f-second selection.\n"
            .. "Start moved %.3f ms after marker %d.\n"
            .. "Search window: %.3f seconds.",
            settings.duration,
            (loopStart - markerTime) * 1000,
            settings.markerNumber,
            settings.searchDuration
        ),
        "Loop Selection Created",
        0
    )
end

local function main()
    local settings = requestSettings()

    if not settings then
        return
    end

    local markerTime =
        findMarkerTime(settings.markerNumber)

    if not markerTime then
        return
    end

    local item, take = getSelectedAudioTake()

    if not item then
        return
    end

    local analysis = readLoopAnalysis(
        item,
        take,
        markerTime,
        settings
    )

    if not analysis then
        return
    end

    local bestOffset =
        findBestSeamOffset(analysis)

    local loopStart = markerTime
        + (bestOffset / analysis.sampleRate)

    local loopEnd =
        loopStart + settings.duration

    applyLoopSelection(
        item,
        analysis.itemStart,
        loopStart,
        loopEnd
    )

    showResult(
        settings,
        markerTime,
        loopStart
    )
end

main()
