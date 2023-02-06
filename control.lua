local util = require("__core__.lualib.util")

local SEARCH_RANGE = 16

local function new_train(player, train, input_name, surface_index, unit_number)
  return {
    state = "idle",
    player = player,
    train = train,
    key = input_name,
    surface_index = surface_index,
    loco = unit_number
  }
end

local function clear_oprphan_trains()
  local del_keys = {}
  for key, train_data in pairs(global.trains) do
    if not train_data.train.valid then
      table.insert(del_keys, key)
    end
  end
  for _, value in pairs(del_keys) do
    global.trains[value] = nil
  end
end

--- register a LuaTrain for calling, actually the locomotive
---@param player LuaPlayer
---@param train LuaTrain
---@param event CustomInputEvent
local function register_train(player, train, event)
  local etc = global.etc
  local player_id = player.index
  local surface_index = player.opened.surface_index

  if not etc[player_id] then
    etc[player_id] = {}
  end

  if not etc[player_id][surface_index] then
    etc[player_id][surface_index] = {}
  end

  etc[player_id][surface_index][event.input_name] = player.opened -- locomotive

  global.trains[train.id] = new_train(player, train, event.input_name, surface_index,
    player.opened.unit_number)
  player.print({ "etc.registered", player.opened.unit_number, event.input_name })

end

---Remove the current temp stop
---@param train LuaTrain
local function remove_current_stop(train)
  local schedule = train.schedule
  if schedule and schedule.records and schedule.current and schedule.records[schedule.current].temporary then
    table.remove(schedule.records, schedule.current)
    local len = table_size(schedule.records)
    if len > 0 then
      if schedule.current > len then
        schedule.current = 1
      end
      train.schedule = schedule
    else
      train.schedule = nil
    end
  end
end

---Adds a new record to the given schedule and returns it
---@param old_schedule TrainSchedule
---@param the_rail LuaEntity
---@returns schedule TrainSchedule
local function add_record(old_schedule, the_rail)
  local schedule = old_schedule
  if not schedule then
    schedule = {
      current = 1,
      records = {}
    }
  end
  local new_record = {
    rail = the_rail,
    temporary = true,
    wait_conditions = {
      {
        type = "time",
        compare_type = "or",
        ticks = 60,
      }
    }
  }
  table.insert(schedule.records, schedule.current, new_record)

  return schedule
end

---comment
---@param player LuaPlayer
---@return LuaEntity|nil
local function find_rail(player)
  local old_distance = nil
  local position =player.position
  local the_rail = nil --[[@as LuaEntity]]

  local rails = player.surface.find_entities_filtered({
    type = "straight-rail",
    force = player.force,
    to_be_deconstructed = false,
    position = position,
    radius = SEARCH_RANGE
  })

  if table_size(rails) == 0 then
    player.print({ "etc.no-rail-found" })
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
  global.trains[train.id].state = "working"
  global.trains[train.id].tick = game.tick
  global.trains[train.id].rail = the_rail
  local distance = util.distance(the_rail.position, train.front_rail.position)
  player.print({ "etc.en-route", global.trains[train.id].loco, math.floor(distance) })

end

---Set the train to idle
---@param train LuaTrain
local function set_idle(train)
  global.trains[train.id].state = "idle"
  global.trains[train.id].tick = nil
  global.trains[train.id].rail = nil

end

---@param event CustomInputEvent
local function on_call_train(event)
  local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
  if not player then return end
  if global.etc[event.player_index] and
      global.etc[event.player_index][player.surface_index] and
      global.etc[event.player_index][player.surface_index][event.input_name] then
    -- send train if possible
    local loco = global.etc[event.player_index][player.surface_index][event.input_name]
    -- check loco exists
    if not loco.valid then
      clear_oprphan_trains()

      global.etc[event.player_index][player.surface_index][event.input_name] = nil
      player.print({ "etc.invalid", event.input_name })
      return
    end
    -- Is the reference still valid?
    local train = loco.train
    if not global.trains[train.id] then
      clear_oprphan_trains()
      global.trains[train.id] = new_train(player, train, event.input_name, player.surface_index, loco.unit_number)
    end
    --todo check player in train and open ui
    if player.vehicle and player.vehicle.type == "locomotive" and player.vehicle.train.id == train.id then
      player.opened = player.vehicle
      return
    end
    -- sending train finally
    -- rail in reach
    local the_rail = find_rail(player)
    if not the_rail then return end
    -- train already in working state?
    if global.trains[train.id].state == "working" then
      remove_current_stop(train)
    end
    train.schedule = add_record(train.schedule, the_rail)
    train.go_to_station(train.schedule.current)
    set_working(train, the_rail, player)

  else
    -- register train if possible
    if player.opened_gui_type == defines.gui_type.entity and
        player.opened.type == "locomotive"
    then
      local train = player.opened.train --[[@as LuaTrain]]
      --todo:check if train isn't in working state atm, eg. for someone else
      register_train(player, train, event)
    elseif player.opened == nil then
      player.print({ "etc.not-set", event.input_name })
    end
  end
end

local function on_train_schedule_changed(event)
  local train = event.train
  if not event.player_index then return end
  --is that an etc train?
  if global.trains[train.id] and global.trains[train.id].state == "working" then
    --if the current is no temp then give the train up
    if train.schedule.records and
        train.schedule.current and
        train.schedule.records[train.schedule.current].temporary == false then
      set_idle(train)
      if global.trains[train.id].player.valid then
        global.trains[train.id].player.print({ "etc.schedule-changed", global.trains[train.id].loco,
          global.trains[train.id].key })
      end
    end
  end

end

local function on_train_changed_state(event)
  local train = event.train
  if train.state == defines.train_state.wait_station or
      train.state == defines.train_state.no_path or
      train.state == defines.train_state.path_lost
  then
    --is that an etc train?
    if not global.trains then global.trains = {} end
    if global.trains[train.id] and global.trains[train.id].state == "working" then
      -- are we there yet?
      if train.state == defines.train_state.wait_station then
        if train.front_rail.is_rail_in_same_rail_block_as(global.trains[train.id].rail) then
          train.manual_mode = true
          remove_current_stop(train)
          set_idle(train)
          if global.trains[train.id].player.valid then
            local distance = util.distance(global.trains[train.id].player.position, train.front_rail.position)
            global.trains[train.id].player.print({ "etc.arrived", global.trains[train.id].loco, math.floor(distance) })
          end
        end
        -- lost track?
      elseif train.state == defines.train_state.no_path or
          train.state == defines.train_state.path_lost then
        if global.trains[train.id].player.valid then
          global.trains[train.id].player.print({ "etc.lost-path", global.trains[train.id].loco })
        end
      end
    end
  end
end

-- events
script.on_event("etc-one", on_call_train)
script.on_event("etc-two", on_call_train)
script.on_event("etc-three", on_call_train)

script.on_init(function()
  global.etc = {}
  global.trains = {}
end)

script.on_event(defines.events.on_train_schedule_changed, on_train_schedule_changed)

script.on_event(defines.events.on_train_changed_state, on_train_changed_state)
