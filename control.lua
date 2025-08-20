local util = require("__core__.lualib.util")

local SEARCH_RANGE = 16
local rails_types = {
  "straight-rail",
  "curved-rail-a",
  "curved-rail-b",
  "half-diagonal-rail",
  "elevated-straight-rail",
  "elevated-curved-rail-a",
  "elevated-curved-rail-b",
  "elevated-half-diagonal-rail",
  "legacy-straight-rail",
  "legacy-curved-rail",
  "rail-ramp",
}

local function control(string)
  return "__CONTROL__" .. string .. "__"
end

local function new_train(player, train, input_name, surface_index, unit_number)
  return {
    state = "idle",
    player = player,
    train = train,
    key = input_name,
    surface_index = surface_index,
    loco = unit_number,
  }
end

local function clear_oprphan_trains()
  local del_keys = {}
  for key, train_data in pairs(storage.trains) do
    if not train_data.train.valid then
      table.insert(del_keys, key)
    end
  end
  for _, value in pairs(del_keys) do
    storage.trains[value] = nil
  end
end

--- register a LuaTrain for calling, actually the locomotive
---@param player LuaPlayer
---@param train LuaTrain
---@param event EventData.CustomInputEvent
local function register_train(player, train, event)
  local etc = storage.etc
  local player_id = player.index
  local surface_index = player.opened.surface_index

  if not etc[player_id] then
    etc[player_id] = {}
  end

  if not etc[player_id][surface_index] then
    etc[player_id][surface_index] = {}
  end

  etc[player_id][surface_index][event.input_name] = player.opened -- locomotive

  storage.trains[train.id] = new_train(player, train, event.input_name, surface_index, player.opened.unit_number)
  player.print({ "etc.registered", player.opened.unit_number, control(event.input_name) })
  player.create_local_flying_text({
    text = { "etc.registered", player.opened.unit_number, control(event.input_name) },
    position = player.position,
  })
end

---Remove the current temp stop, if it's ETC record
---@param train LuaTrain
local function remove_current_stop(train)
  local schedule = train.get_schedule()
  ---@type ScheduleRecord?
  local current = schedule.get_record({ schedule_index = schedule.current })

  if current and current.temporary and not current.created_by_interrupt then
    schedule.remove_record({ schedule_index = schedule.current })
  end
end

---Adds a new record
---@param train LuaTrain
---@param the_rail LuaEntity
---@param player LuaPlayer
---@return uint new_index Index of the new Record
local function add_record(train, the_rail, player)
  local schedule = train.get_schedule()
  local wait = player.mod_settings["etc-wait-min"].value * 60 * 60
  local mode = player.mod_settings["etc-arrival-action"].value
  local record_count = schedule.get_record_count() or 0
  local new_index = schedule.add_record({
    rail = the_rail,
    temporary = true,
    index = { schedule_index = schedule.current },
  })

  if new_index == nil then
    return 0
  end
  if mode == "Automatic" then
    -- schedule.remove_wait_condition({schedule_index = new_index}, 1)
    schedule.add_wait_condition({ schedule_index = new_index }, 1, "time")
    schedule.add_wait_condition({ schedule_index = new_index }, 2, "passenger_present")
    schedule.change_wait_condition({ schedule_index = new_index }, 1, {
      type = "time",
      compare_type = "or",
      ticks = wait,
    })
    schedule.change_wait_condition({ schedule_index = new_index }, 2, {
      type = "passenger_present",
      compare_type = "or",
    })
  else -- manual mode
    schedule.add_wait_condition({ schedule_index = new_index }, 1, "time")
    schedule.change_wait_condition({ schedule_index = new_index }, 1, {
      type = "time",
      compare_type = "or",
      ticks = 60,
    })
  end

  -- move new record to "current"
  -- schedule.drag_record(record_count + 1,old_current)
  return new_index
end

---comment
---@param player LuaPlayer
---@return LuaEntity|nil
local function find_rail(player)
  local old_distance = nil
  local position = player.physical_position
  local the_rail = nil --[[@as LuaEntity]]

  local rails = player.physical_surface.find_entities_filtered({
    type = rails_types,
    force = player.force,
    to_be_deconstructed = false,
    position = position,
    radius = SEARCH_RANGE,
  })

  if table_size(rails) == 0 then
    player.print({ "gui-train.too-far-from-rail" })
    return nil
  end

  for _, rail in pairs(rails) do
    local distance = util.distance(position, rail.position)
    if not old_distance or distance < old_distance then
      old_distance = distance
      the_rail = rail
    end
  end

  return the_rail
end

---Set working status and give message to user
---@param train LuaTrain
---@param the_rail LuaEntity
---@param player LuaPlayer
local function set_working(train, the_rail, player)
  storage.trains[train.id].state = "working"
  storage.trains[train.id].tick = game.tick
  storage.trains[train.id].rail = the_rail
  local distance = util.distance(the_rail.position, train.front_end.location.position)
  player.print({ "etc.en-route", storage.trains[train.id].loco, math.floor(distance) })
end

---Set to waiting mode
---@param train LuaTrain
local function set_waiting(train)
  storage.trains[train.id].state = "waiting"
  storage.trains[train.id].tick = game.tick
  -- storage.trains[train.id].rail = nil
end

---Set the train to idle
---@param train LuaTrain
local function set_idle(train)
  storage.trains[train.id].state = "idle"
  storage.trains[train.id].tick = nil
  storage.trains[train.id].rail = nil
end

---@param event EventData.CustomInputEvent
local function on_call_train(event)
  local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
  if not player then
    return
  end
  if
    storage.etc[event.player_index]
    and storage.etc[event.player_index][player.physical_surface_index]
    and storage.etc[event.player_index][player.physical_surface_index][event.input_name]
  then
    -- send train if possible
    local loco = storage.etc[event.player_index][player.physical_surface_index][event.input_name]
    -- check loco exists
    if not loco.valid then
      clear_oprphan_trains()

      storage.etc[event.player_index][player.physical_surface_index][event.input_name] = nil
      player.print({ "etc.invalid", control(event.input_name) })
      return
    end
    -- Is the reference still valid?
    local train = loco.train
    if not storage.trains[train.id] then
      clear_oprphan_trains()
      storage.trains[train.id] =
        new_train(player, train, event.input_name, player.physical_surface_index, loco.unit_number)
    end
    -- check if player in train then open loco gui
    if player.vehicle and player.vehicle.type == "locomotive" and player.vehicle.train.id == train.id then
      player.opened = player.vehicle
      return
    end
    -- sending train finally
    -- rfind ail in reach
    local the_rail = find_rail(player)
    if not the_rail then
      return
    end
    -- train already in working state?
    if storage.trains[train.id].state == "working" or storage.trains[train.id].state == "waiting" then
      remove_current_stop(train)
    end
    local new_record = add_record(train, the_rail, player)
    train.go_to_station(new_record)
    set_working(train, the_rail, player)
  else
    -- register train if possible
    if player.opened_gui_type == defines.gui_type.entity and player.opened.type == "locomotive" then
      local train = player.opened.train --[[@as LuaTrain]]
      --todo:check if train isn't in working state atm, eg. for someone else
      register_train(player, train, event)
    elseif player.opened == nil then
      player.print({ "etc.not-set", control(event.input_name) })
    end
  end
end

local function on_train_schedule_changed(event)
  local train = event.train
  if not event.player_index then
    return
  end
  --is that an etc train?
  if storage.trains[train.id] and storage.trains[train.id].state == "working" then
    --if the current is no temp then give the train up
    local schedule = train.get_schedule()
    local current = schedule.get_record({ schedule_index = schedule.current })
    if current and current.temporary == false then
      set_idle(train)
      if storage.trains[train.id].player.valid then
        storage.trains[train.id].player.print({
          "etc.schedule-changed",
          storage.trains[train.id].loco,
          control(storage.trains[train.id].key),
        })
      end
    end
  end
end

local function on_train_changed_state(event)
  local train = event.train
  if train.state == defines.train_state.wait_station or train.state == defines.train_state.no_path then
    --is that an etc train?
    if not storage.trains then
      storage.trains = {}
    end
    if not storage.trains[train.id] then
      return
    end
    local player = storage.trains[train.id].player
    if not player then
      return
    end

    if storage.trains[train.id].state == "working" then
      -- are we there yet?
      if train.state == defines.train_state.wait_station then
        if
          storage.trains[train.id].rail.valid
          and train.front_end.rail.is_rail_in_same_rail_block_as(storage.trains[train.id].rail)
        then
          if
            player.mod_settings["etc-arrival-action"].value == "Automatic" and not storage.trains[train.id].save_to_stop
          then
            set_waiting(train)
          else
            remove_current_stop(train)
            set_idle(train)
            train.manual_mode = true
          end
          storage.trains[train.id].save_to_stop = nil
          local distance = util.distance(player.physical_position, train.front_end.location.position)
          player.print({ "etc.arrived", storage.trains[train.id].loco, math.floor(distance) })
        end
        -- lost track?
      elseif train.state == defines.train_state.no_path then
        player.print({ "etc.lost-path", storage.trains[train.id].loco })
      end
    elseif storage.trains[train.id] and storage.trains[train.id].state == "waiting" then
      -- wont wait anymore
      set_idle(train)
    end
  end
end

local function check_player_in_etc_train(player, train)
  --check if player vehicle is train
  if
    not (player and player.vehicle and player.vehicle.train and player.vehicle.train.valid and train and train.valid)
  then
    return false
  end
  -- check if player in train
  if storage.trains[train.id] and train.id == player.vehicle.train.id then
    return true
  end
  return false
end

---react when player enters the train in waiting mode
---@param event EventData.on_player_driving_changed_state
local function on_player_driving_changed_state(event)
  if not (event.entity and event.entity.valid and event.entity.train and event.entity.train.valid) then
    return
  end
  local player = game.players[event.player_index]
  local train = event.entity.train
  if not train or not train.valid then
    return
  end
  -- check if etc train and waiting
  if not check_player_in_etc_train(player, train) then
    return
  end

  if storage.trains[train.id].state == "waiting" then
    remove_current_stop(train)
    set_idle(train)
    train.manual_mode = true
  elseif
    storage.trains[train.id].state == "working" and player.mod_settings["etc-arrival-action"].value == "Automatic"
  then
    storage.trains[train.id].save_to_stop = true
  end
end

-- events
script.on_event("etc-one", on_call_train)
script.on_event("etc-two", on_call_train)
script.on_event("etc-three", on_call_train)
script.on_event("etc-four", on_call_train)

script.on_init(function()
  storage.etc = {}
  storage.trains = {}
end)

script.on_event(defines.events.on_train_schedule_changed, on_train_schedule_changed)
script.on_event(defines.events.on_train_changed_state, on_train_changed_state)
script.on_event(defines.events.on_player_driving_changed_state, on_player_driving_changed_state)

commands.add_command("etc-list", { "etc.command-help" }, function(event)
  local player = game.get_player(event.player_index)
  if player == nil then
    return
  end
  for surface_index, register in pairs(storage.etc[event.player_index]) do
    player.print("Player: " .. player.name)
    player.print("Surface: " .. game.surfaces[surface_index].name)
    for key, value in pairs(register) do
      local loco = value
      if loco.valid then
        player.print({ "etc.list", loco.unit_number, control(key) })
      else
        player.print({ "", { "gui-train.invalid" }, " ", { "etc.list", 0, control(key) } })
      end
    end
  end
end)
