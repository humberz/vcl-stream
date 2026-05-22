-- scene-switcher.lua
-- Monitors BeachCam and LakeCam, switches to BRB when either drops
-- Restarts stopped/ended/errored sources aggressively
-- Waits 2 minutes after recovery before switching back
-- Sends email alerts via PowerShell when cameras drop or recover

-- CONFIG
local MAIN_SCENE      = "Lake & Beach"
local BRB_SCENE       = "BRB"
local CHECK_MS            = 2000
local RECOVERY_DELAY      = 60
local RESTART_AFTER_S     = 15
local POST_SWITCH_GRACE_S = 15
local RETURN_OVERLAY_S    = 60
local RETURN_OVERLAY_SOURCE = "BRBSlide"
local OPENING_TIMEOUT_S   = 30
local ALERT_SCRIPT    = "C:\\BeachCam\\scripts\\send-alert.ps1"

local SOURCES = {
    "BeachCam",
    "LakeCam"
}

local obs = obslua
local currently_brb = false
local alert_sent = false
local recovery_since = nil
local recovery_restart_done = false
local source_down_since = {}
local switch_grace_until = nil
local overlay_hide_at = nil
local post_switch_reinit_pending = false
local source_opening_since = {}

function get_time_s()
    return os.time()
end

function get_source_state_name(state)
    if state == obs.OBS_MEDIA_STATE_PLAYING then return "PLAYING"
    elseif state == obs.OBS_MEDIA_STATE_PAUSED then return "PAUSED"
    elseif state == obs.OBS_MEDIA_STATE_STOPPED then return "STOPPED"
    elseif state == obs.OBS_MEDIA_STATE_ENDED then return "ENDED"
    elseif state == obs.OBS_MEDIA_STATE_ERROR then return "ERROR"
    elseif state == obs.OBS_MEDIA_STATE_OPENING then return "OPENING"
    elseif state == obs.OBS_MEDIA_STATE_BUFFERING then return "BUFFERING"
    else return "UNKNOWN(" .. tostring(state) .. ")"
    end
end

function is_source_playing(source_name)
    local source = obs.obs_get_source_by_name(source_name)
    if source == nil then return false end
    local state = obs.obs_source_media_get_state(source)
    obs.obs_source_release(source)

    if state == obs.OBS_MEDIA_STATE_PLAYING then
        source_opening_since[source_name] = nil
        return true
    elseif state == obs.OBS_MEDIA_STATE_OPENING or state == obs.OBS_MEDIA_STATE_BUFFERING then
        local now = get_time_s()
        if source_opening_since[source_name] == nil then
            source_opening_since[source_name] = now
        end
        local stuck_for = now - source_opening_since[source_name]
        if stuck_for >= OPENING_TIMEOUT_S then
            obs.script_log(obs.LOG_INFO, source_name .. " stuck in " .. get_source_state_name(state) .. " for " .. stuck_for .. "s - treating as failed")
            return false
        end
        return true
    else
        source_opening_since[source_name] = nil
        return false
    end
end

function restart_source(source_name)
    local source = obs.obs_get_source_by_name(source_name)
    if source == nil then
        obs.script_log(obs.LOG_INFO, "Could not find source: " .. source_name)
        return
    end
    local state = obs.obs_source_media_get_state(source)
    local state_name = get_source_state_name(state)
    obs.script_log(obs.LOG_INFO, "Restarting source: " .. source_name .. " (state: " .. state_name .. ")")
    local settings = obs.obs_source_get_settings(source)
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(source)
end

function switch_to_scene(scene_name)
    local scene = obs.obs_get_source_by_name(scene_name)
    if scene ~= nil then
        obs.obs_frontend_set_current_scene(scene)
        obs.obs_source_release(scene)
    end
end

function set_return_overlay(visible)
    local scene_source = obs.obs_get_source_by_name(MAIN_SCENE)
    if scene_source == nil then return end
    local scene = obs.obs_scene_from_source(scene_source)
    if scene ~= nil then
        local items = obs.obs_scene_enum_items(scene)
        if items ~= nil then
            for _, item in ipairs(items) do
                local item_source = obs.obs_sceneitem_get_source(item)
                if obs.obs_source_get_name(item_source) == RETURN_OVERLAY_SOURCE then
                    obs.obs_sceneitem_set_visible(item, visible)
                    obs.script_log(obs.LOG_INFO, "Return overlay " .. (visible and "shown" or "hidden"))
                    break
                end
            end
            obs.sceneitem_list_release(items)
        end
    end
    obs.obs_source_release(scene_source)
end

function send_alert(subject, body)
    local cmd = 'start "" /b powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "' .. ALERT_SCRIPT .. '" -Subject "' .. subject .. '" -Body "' .. body .. '"'
    os.execute(cmd)
end

function get_down_sources()
    local down = {}
    for _, name in ipairs(SOURCES) do
        if not is_source_playing(name) then
            table.insert(down, name)
        end
    end
    return down
end

function check_sources()
    if not obs.obs_frontend_streaming_active() then
        return
    end

    local now = get_time_s()

    if overlay_hide_at ~= nil and now >= overlay_hide_at then
        obs.script_log(obs.LOG_INFO, "Hiding return overlay")
        set_return_overlay(false)
        overlay_hide_at = nil
    end

    if post_switch_reinit_pending then
        local cs = obs.obs_frontend_get_current_scene()
        if cs ~= nil then
            local cs_name = obs.obs_source_get_name(cs)
            obs.obs_source_release(cs)
            if cs_name == MAIN_SCENE then
                obs.script_log(obs.LOG_INFO, "Post-switch reinit - restarting sources while active in scene...")
                for _, name in ipairs(SOURCES) do
                    restart_source(name)
                end
                post_switch_reinit_pending = false
            end
        end
    end

    local down_sources = get_down_sources()
    local all_playing = #down_sources == 0

    -- Handle source restart logic
    for _, name in ipairs(SOURCES) do
        if is_source_playing(name) then
            if source_down_since[name] ~= nil then
                obs.script_log(obs.LOG_INFO, name .. " is now playing again")
            end
            source_down_since[name] = nil
        else
            -- Log current state for diagnostics
            local source = obs.obs_get_source_by_name(name)
            if source ~= nil then
                local state = obs.obs_source_media_get_state(source)
                obs.obs_source_release(source)
                obs.script_log(obs.LOG_INFO, name .. " state: " .. get_source_state_name(state))
            end

            if source_down_since[name] == nil then
                source_down_since[name] = now
                obs.script_log(obs.LOG_INFO, name .. " not playing - starting restart countdown")
            else
                local down_for = now - source_down_since[name]
                if down_for >= RESTART_AFTER_S then
                    restart_source(name)
                    source_down_since[name] = now
                else
                    obs.script_log(obs.LOG_INFO, name .. " down for " .. down_for .. "s - restarting in " .. (RESTART_AFTER_S - down_for) .. "s")
                end
            end
        end
    end

    -- Handle scene switching
    local current = obs.obs_frontend_get_current_scene()
    local current_name = ""
    if current ~= nil then
        current_name = obs.obs_source_get_name(current)
        obs.obs_source_release(current)
    end

    if not all_playing then
        recovery_since = nil
        if current_name == MAIN_SCENE then
            if switch_grace_until ~= nil and now < switch_grace_until then
                obs.script_log(obs.LOG_INFO, "Post-switch grace period - ignoring transient drop for " .. (switch_grace_until - now) .. "s")
            else
                obs.script_log(obs.LOG_INFO, "Switching to BRB - down: " .. table.concat(down_sources, ", "))
                switch_to_scene(BRB_SCENE)
                currently_brb = true
                recovery_restart_done = false
            end
        end
        if not alert_sent then
            send_alert("Camera Drop - Switched to BRB", "The following cameras stopped playing: " .. table.concat(down_sources, ", ") .. ". Stream has switched to BRB scene.")
            alert_sent = true
        end

    elseif all_playing and currently_brb then
        if recovery_since == nil then
            if not recovery_restart_done then
                obs.script_log(obs.LOG_INFO, "Cameras detected healthy - restarting sources for fresh connection...")
                for _, name in ipairs(SOURCES) do
                    restart_source(name)
                end
                recovery_restart_done = true
            else
                recovery_since = now
                obs.script_log(obs.LOG_INFO, "Cameras recovered - waiting " .. RECOVERY_DELAY .. "s before switching back...")
            end
        else
            local waited = now - recovery_since
            local remaining = RECOVERY_DELAY - waited
            if remaining > 0 then
                obs.script_log(obs.LOG_INFO, "Cameras healthy - switching back in " .. remaining .. "s...")
            else
                obs.script_log(obs.LOG_INFO, "Recovery delay complete - switching back to Lake & Beach")
                switch_to_scene(MAIN_SCENE)
                set_return_overlay(true)
                obs.script_log(obs.LOG_INFO, "Return overlay shown - hiding in " .. RETURN_OVERLAY_S .. "s")
                overlay_hide_at = now + RETURN_OVERLAY_S
                post_switch_reinit_pending = true
                currently_brb = false
                recovery_since = nil
                switch_grace_until = now + POST_SWITCH_GRACE_S
                source_down_since = {}
                obs.script_log(obs.LOG_INFO, "Grace period started - ignoring source state for " .. POST_SWITCH_GRACE_S .. "s")
                if alert_sent then
                    send_alert("Cameras Recovered", "All cameras are playing again. Stream has switched back to Lake & Beach.")
                    alert_sent = false
                end
            end
        end
    end
end

function script_load(settings)
    obs.timer_add(check_sources, CHECK_MS)
    obs.script_log(obs.LOG_INFO, "Scene switcher loaded - monitoring: " .. table.concat(SOURCES, ", "))
end

function script_unload()
    obs.timer_remove(check_sources)
end

function script_description()
    return "Switches to BRB when BeachCam or LakeCam stops playing.\nRestarts stopped/ended/errored sources after 15s.\nLogs source state on every check for diagnostics.\nWaits 2 minutes after recovery before switching back.\nSends email alerts on drop and recovery."
end
