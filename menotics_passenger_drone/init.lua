-- Menotics Passenger Drone Mod
-- Transfers players between terminal blocks

local drone_cache = {} -- Store drone entities by position for quick lookup

-- Helper function to find all terminal blocks
local function get_terminals()
    local terminals = {}
    for _, obj in ipairs(minetest.luaentities) do
        if obj.name == "menotics_passenger_drone:terminal" then
            table.insert(terminals, obj)
        end
    end
    return terminals
end

-- Helper function to calculate distance between two positions
local function get_distance(pos1, pos2)
    local dx = pos1.x - pos2.x
    local dy = pos1.y - pos2.y
    local dz = pos1.z - pos2.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Helper function to check if a position is walkable (has blocks)
local function is_position_clear(pos)
    -- Check the position 1 block above the terminal (where drone hovers)
    local check_pos = vector.add(pos, {x=0, y=1, z=0})
    local node = minetest.get_node_or_nil(check_pos)
    if node and minetest.registered_nodes[node.name] then
        if minetest.registered_nodes[node.name].walkable then
            return false
        end
    end
    -- Also check the drone's collision space
    for y = 0, 2 do
        for x = -0.5, 0.5 do
            for z = -0.5, 0.5 do
                local test_pos = {
                    x = math.floor(pos.x + x),
                    y = pos.y + y,
                    z = math.floor(pos.z + z)
                }
                local node = minetest.get_node_or_nil(test_pos)
                if node and minetest.registered_nodes[node.name] and minetest.registered_nodes[node.name].walkable then
                    return false
                end
            end
        end
    end
    return true
end

-- Find next terminal based on rules
local function find_next_terminal(current_pos, current_terminal, all_terminals)
    if #all_terminals < 2 then
        return nil -- Need at least 2 terminals
    end
    
    if #all_terminals == 2 then
        -- If only 2 terminals, fly to the other one
        for _, term in ipairs(all_terminals) do
            if term ~= current_terminal then
                if is_position_clear(term.object:get_pos()) then
                    return term
                end
            end
        end
        return nil
    end
    
    -- More than 2 terminals: fly to nearest but skip the one we just came from
    local current_index = nil
    for i, term in ipairs(all_terminals) do
        if term == current_terminal then
            current_index = i
            break
        end
    end
    
    -- Find the previous terminal (the one we came from)
    local prev_index = nil
    if current_index then
        prev_index = current_index - 1
        if prev_index < 1 then
            prev_index = #all_terminals
        end
    end
    
    -- Find nearest terminal that isn't the previous one
    local nearest = nil
    local nearest_dist = math.huge
    
    for i, term in ipairs(all_terminals) do
        -- Skip current and previous terminal
        if term ~= current_terminal and i ~= prev_index then
            local dist = get_distance(current_pos, term.object:get_pos())
            if dist < nearest_dist and is_position_clear(term.object:get_pos()) then
                nearest = term
                nearest_dist = dist
            end
        end
    end
    
    -- If no clear terminal found, try any terminal except current
    if not nearest then
        for i, term in ipairs(all_terminals) do
            if term ~= current_terminal then
                local dist = get_distance(current_pos, term.object:get_pos())
                if dist < nearest_dist then
                    nearest = term
                    nearest_dist = dist
                end
            end
        end
    end
    
    return nearest
end

-- Drone entity definition
minetest.register_entity("menotics_passenger_drone:drone", {
    initial_properties = {
        visual = "mesh",
        mesh = "menotics_drone.b3d",
        textures = {"menotics-passenger.png"},
        visual_size = {x=4, y=3},
        collisionbox = {-0.4, -0.4, -0.4, 0.4, 0.4, 0.4},
        physical = true,
        gravity = 0,
        stepheight = 1.0,
        automatic_rotate = 0,
        pointable = true,
    },
    
    driver = nil,
    target_pos = nil,
    current_terminal = nil,
    wait_timer = 0,
    state = "idle", -- idle, waiting, moving
    last_collision_check = 0,
    
    on_activate = function(self, staticdata)
        self.driver = nil
        self.target_pos = nil
        self.current_terminal = nil
        self.wait_timer = 0
        self.state = "idle"
        
        -- Parse staticdata if exists
        if staticdata and staticdata ~= "" then
            local data = minetest.deserialize(staticdata)
            if data then
                self.driver = data.driver
                self.state = data.state or "idle"
            end
        end
        
        -- Make sure physics properties are set correctly
        self.object:set_properties({
            physical = true,
            gravity = 0,
            stepheight = 1.0,
        })
    end,
    
    get_staticdata = function(self)
        local data = {
            driver = self.driver,
            state = self.state,
        }
        return minetest.serialize(data)
    end,
    
    on_rightclick = function(self, clicker)
        if not clicker or not clicker:is_player() then
            return
        end
        
        local player_name = clicker:get_player_name()
        
        -- If player is already attached, detach them
        if self.driver == player_name then
            minetest.chat_send_all("[Drone] Player " .. player_name .. " disembarked")
            clicker:dettach()
            self.driver = nil
            
            -- If no driver, stop moving
            if self.state == "moving" then
                self.state = "waiting"
                self.wait_timer = 20
            end
            return
        end
        
        -- If someone else is driving, can't board
        if self.driver then
            minetest.chat_send_player(player_name, "[Drone] Already occupied!")
            return
        end
        
        -- Attach player to drone
        self.driver = player_name
        clicker:attach(self.object, {x=0, y=1, z=0}, {x=0, y=0, z=0}, 0)
        minetest.chat_send_all("[Drone] Player " .. player_name .. " seated")
        
        -- Start movement if we have a target
        if self.target_pos and self.state ~= "moving" then
            self.state = "moving"
        end
    end,
    
    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        if self.driver then
            local player = minetest.get_player_by_name(self.driver)
            if player then
                player:dettach()
                minetest.chat_send_all("[Drone] Player " .. self.driver .. " detached due to damage")
            end
            self.driver = nil
        end
    end,
    
    on_step = function(self, dtime)
        local pos = self.object:get_pos()
        if not pos then
            return
        end
        
        -- Check for collision by comparing expected vs actual position
        if self.state == "moving" and self.target_pos then
            self.last_collision_check = self.last_collision_check + dtime
            if self.last_collision_check >= 0.5 then
                self.last_collision_check = 0
                
                -- Simple collision detection: if we're not getting closer to target
                local old_dist = self.last_dist or get_distance(pos, self.target_pos)
                local new_dist = get_distance(pos, self.target_pos)
                
                -- If distance increased or stayed same for multiple checks, we might be stuck
                if new_dist >= old_dist and old_dist > 2 then
                    minetest.chat_send_all("[Drone] Collision detected! Finding alternative route...")
                    -- Try to find another terminal
                    local terminals = get_terminals()
                    if self.current_terminal then
                        local new_target = find_next_terminal(pos, self.current_terminal, terminals)
                        if new_target and new_target ~= self.current_terminal then
                            self.target_pos = new_target.object:get_pos()
                            self.current_terminal = new_target
                            minetest.chat_send_all("[Drone] New route found!")
                        end
                    end
                end
                
                self.last_dist = new_dist
            end
            
            -- Move towards target
            local dir = vector.direction(pos, self.target_pos)
            if dir then
                -- Normalize and scale speed
                dir = vector.normalize(dir)
                local speed = 3 -- blocks per second
                local velocity = vector.multiply(dir, speed)
                
                -- Set velocity (the physics engine will handle collisions)
                self.object:set_velocity(velocity)
                
                -- Look towards target
                local yaw = math.atan2(dir.x, dir.z) - math.pi/2
                self.object:set_rotation({x=0, y=yaw, z=0})
                
                -- Check if we've reached the target (within 1 block)
                if get_distance(pos, self.target_pos) < 1.5 then
                    self.object:set_velocity({x=0, y=0, z=0})
                    self.state = "waiting"
                    self.wait_timer = 20 -- Wait 20 seconds
                    minetest.chat_send_all("[Drone] Arrived at terminal! Waiting 20 seconds...")
                    
                    -- Detach player on arrival
                    if self.driver then
                        local player = minetest.get_player_by_name(self.driver)
                        if player then
                            player:dettach()
                            minetest.chat_send_all("[Drone] Player " .. self.driver .. " disembarked at destination")
                        end
                        self.driver = nil
                    end
                end
            end
        elseif self.state == "waiting" then
            -- Keep drone stationary while waiting
            self.object:set_velocity({x=0, y=0, z=0})
            
            self.wait_timer = self.wait_timer - dtime
            if self.wait_timer <= 0 then
                -- Time to move to next terminal
                local terminals = get_terminals()
                if #terminals > 0 then
                    local next_terminal = find_next_terminal(pos, self.current_terminal, terminals)
                    if next_terminal then
                        self.current_terminal = next_terminal
                        self.target_pos = next_terminal.object:get_pos()
                        self.state = "moving"
                        minetest.chat_send_all("[Drone] Departing for next terminal!")
                    else
                        minetest.chat_send_all("[Drone] No valid destination found, remaining idle")
                        self.state = "idle"
                    end
                else
                    self.state = "idle"
                end
            end
        elseif self.state == "idle" then
            -- Look for terminals to start route
            local terminals = get_terminals()
            if #terminals > 0 then
                -- Find nearest clear terminal
                local nearest = nil
                local nearest_dist = math.huge
                for _, term in ipairs(terminals) do
                    local tpos = term.object:get_pos()
                    if is_position_clear(tpos) then
                        local dist = get_distance(pos, tpos)
                        if dist < nearest_dist then
                            nearest = term
                            nearest_dist = dist
                        end
                    end
                end
                
                if nearest then
                    self.current_terminal = nearest
                    self.target_pos = nearest.object:get_pos()
                    -- Hover 1 block above terminal
                    self.target_pos = vector.add(self.target_pos, {x=0, y=1, z=0})
                    self.state = "moving"
                    minetest.chat_send_all("[Drone] Starting route to nearest terminal")
                end
            end
        end
    end,
})

-- Terminal block definition
minetest.register_node("menotics_passenger_drone:terminal", {
    description = "Passenger Drone Terminal",
    tiles = {"terminal.png"},
    paramtype2 = "facedir",
    place_param2 = 0,
    is_ground_content = false,
    walkable = true,
    collision_box = {
        type = "fixed",
        fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
    },
    selection_box = {
        type = "fixed",
        fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
    },
    
    on_place = function(itemstack, placer, pointed_thing)
        -- Standard node placement
        local ret = minetest.item_place_node(itemstack, placer, pointed_thing)
        
        -- Create terminal entity for tracking
        local pos = pointed_thing.above
        if pos then
            minetest.add_entity(pos, "menotics_passenger_drone:terminal_entity")
        end
        
        return ret
    end,
    
    after_dig_node = function(pos, oldnode, oldmeta, digger)
        -- Remove associated entity
        for _, obj in ipairs(minetest.get_objects_inside_radius(pos, 1)) do
            local ent = obj:get_luaentity()
            if ent and ent.name == "menotics_passenger_drone:terminal_entity" then
                obj:remove()
            end
        end
    end,
})

-- Invisible entity to track terminals
minetest.register_entity("menotics_passenger_drone:terminal_entity", {
    initial_properties = {
        visual = "sprite",
        textures = {"invisible.png"},
        visual_size = {x=0, y=0},
        collisionbox = {0, 0, 0, 0, 0, 0},
        physical = false,
        pointable = false,
    },
    
    terminal_pos = nil,
    
    on_activate = function(self, staticdata)
        self.terminal_pos = self.object:get_pos()
        -- Move entity to node position below
        local node_pos = vector.add(self.terminal_pos, {x=0, y=-1, z=0})
        self.terminal_pos = node_pos
    end,
    
    get_staticdata = function(self)
        return ""
    end,
    
    on_step = function(self, dtime)
        -- Keep entity synced with terminal node
        if self.terminal_pos then
            local node = minetest.get_node_or_nil(self.terminal_pos)
            if not node or node.name ~= "menotics_passenger_drone:terminal" then
                -- Terminal was removed, remove this entity
                self.object:remove()
                return
            end
        end
    end,
})

-- Craft item for drone
minetest.register_craftitem("menotics_passenger_drone:item", {
    description = "Passenger Drone (place to spawn)",
    inventory_image = "menotics-passenger.png",
    
    on_place = function(itemstack, placer, pointed_thing)
        local pos = pointed_thing.above
        if not pos then
            return itemstack
        end
        
        -- Check if there's enough space (4 blocks long, 3 high)
        local node = minetest.get_node_or_nil(pos)
        if node and minetest.registered_nodes[node.name] then
            if minetest.registered_nodes[node.name].walkable then
                minetest.chat_send_player(placer:get_player_name(), "[Drone] Not enough space!")
                return itemstack
            end
        end
        
        -- Spawn the drone entity
        local drone = minetest.add_entity(pos, "menotics_passenger_drone:drone")
        if drone then
            itemstack:take_item()
            minetest.chat_send_all("[Drone] Passenger drone deployed!")
        end
        
        return itemstack
    end,
})

-- Crafting recipe
minetest.register_craft({
    output = "menotics_passenger_drone:item",
    recipe = {
        {"default:steel_ingot", "default:mese_crystal", "default:steel_ingot"},
        {"default:glass", "default:steel_ingot", "default:glass"},
        {"default:glass", "default:steel_ingot", "default:glass"},
    },
})

-- Debug command to list terminals
minetest.register_chatcommand("list_terminals", {
    params = "",
    description = "List all passenger drone terminals",
    func = function(name)
        local terminals = get_terminals()
        if #terminals == 0 then
            minetest.chat_send_player(name, "[Drone] No terminals found")
        else
            minetest.chat_send_player(name, "[Drone] Found " .. #terminals .. " terminals:")
            for i, term in ipairs(terminals) do
                local pos = term.object:get_pos()
                if pos then
                    minetest.chat_send_player(name, string.format("  %d: (%.1f, %.1f, %.1f)", i, pos.x, pos.y, pos.z))
                end
            end
        end
    end,
})
