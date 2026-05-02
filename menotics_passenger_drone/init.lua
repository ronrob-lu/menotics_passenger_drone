-- Menotics Passenger Drone Mod
-- Transfers players between terminal blocks using a glass drone vehicle
-- No 3D model required - uses box visual with multiple textures

local S = minetest.get_translator("menotics_passenger_drone")

-- Debug flag for verbose logging
local DEBUG = true

local function debug_log(msg)
    if DEBUG then
        minetest.chat_send_all("[Drone DEBUG] " .. msg)
        minetest.log("action", "[Drone DEBUG] " .. msg)
    end
end

-- Terminal block definition (solid, non-passable)
minetest.register_node("menotics_passenger_drone:terminal", {
    description = S("Passenger Drone Terminal"),
    tiles = {"terminal.png"},
    paramtype2 = "facedir",
    is_ground_content = false,
    groups = {cracky = 3},
    sounds = (default and default.node_sound_metal_sounds) and (default.node_sound_metal_sounds() or {
        footstep = {name = "default_metal_footstep", gain = 1.0},
        dig = {name = "default_metal_footstep", gain = 1.0},
        dug = {name = "default_metal_footstep", gain = 1.0},
        place = {name = "default_place_node_metal", gain = 1.0},
    }) or {
        footstep = {name = "default_metal_footstep", gain = 1.0},
        dig = {name = "default_metal_footstep", gain = 1.0},
        dug = {name = "default_metal_footstep", gain = 1.0},
        place = {name = "default_place_node_metal", gain = 1.0},
    },
    on_place = function(itemstack, placer, pointed_thing)
        return minetest.item_place_node(itemstack, placer, pointed_thing)
    end,
    after_place_node = function(pos, placer, itemstack, pointed_thing)
        local node = minetest.get_node(pos)
        if placer and placer:is_player() then
            local dir = minetest.dir_to_facedir(placer:get_look_dir())
            node.param2 = dir
            minetest.set_node(pos, node)
        end
    end,
})

-- Helper function to find all terminal blocks
local function find_terminals(pos)
    local terminals = {}
    local found_set = {} -- Track found positions to avoid duplicates
    
    local start_pos = vector.floor(pos or {x=0, y=0, z=0})
    
    -- SIMPLE SAFE APPROACH: Search a fixed moderate area around the drone/start position
    -- 150 block radius = 300x300x300 = 27,000,000 nodes - VERY SAFE (under 150M limit)
    local search_dist = 150
    
    local minp = vector.subtract(start_pos, search_dist)
    local maxp = vector.add(start_pos, search_dist)

    local pos_list = minetest.find_nodes_in_area(
        minp,
        maxp,
        "menotics_passenger_drone:terminal",
        false
    )
    
    for _, p in ipairs(pos_list) do
        local key = p.x .. "," .. p.y .. "," .. p.z
        if not found_set[key] then
            found_set[key] = true
            table.insert(terminals, vector.new(p))
        end
    end
    
    return terminals
end

-- Cache for terminal positions (updated periodically)
local terminal_cache = {}
local last_terminal_update = 0

local function get_terminals_cached()
    local current_time = minetest.get_us_time()
    -- Update cache every 5 seconds
    if current_time - last_terminal_update > 5000000 then
        terminal_cache = find_terminals({x=0, y=0, z=0})
        last_terminal_update = current_time
    end
    return terminal_cache
end

-- Calculate distance between two positions (horizontal only)
local function horizontal_distance(pos1, pos2)
    local dx = pos1.x - pos2.x
    local dz = pos1.z - pos2.z
    return math.sqrt(dx * dx + dz * dz)
end

-- Find the nearest terminal from a position, optionally excluding one
local function find_nearest_terminal(from_pos, exclude_pos)
    local terminals = get_terminals_cached()
    local nearest = nil
    local nearest_dist = math.huge
    
    for _, term_pos in ipairs(terminals) do
        if exclude_pos then
            if vector.equals(term_pos, exclude_pos) then
                goto continue
            end
        end
        
        local dist = horizontal_distance(from_pos, term_pos)
        if dist < nearest_dist then
            nearest_dist = dist
            nearest = term_pos
        end
        
        ::continue::
    end
    
    return nearest, nearest_dist
end

-- Check if a position is safe (no solid blocks at hover height)
local function is_position_safe(pos)
    local hover_pos = vector.new(pos.x, pos.y + 1, pos.z)
    local node = minetest.get_node(hover_pos)
    local def = minetest.registered_nodes[node.name]
    
    if def and def.walkable then
        debug_log("Position unsafe: block above is walkable: " .. tostring(node.name))
        return false
    end
    
    local term_node = minetest.get_node(pos)
    if term_node.name ~= "menotics_passenger_drone:terminal" then
        debug_log("Position unsafe: not a terminal, got: " .. tostring(term_node.name))
        return false
    end
    
    debug_log("Position safe: terminal at " .. minetest.pos_to_string(pos))
    return true
end

-- Find an alternative nearby position if the direct hover spot is blocked
local function find_alternative_hover(base_pos)
    local offsets = {
        {x = 1, y = 0, z = 0},
        {x = -1, y = 0, z = 0},
        {x = 0, y = 0, z = 1},
        {x = 0, y = 0, z = -1},
        {x = 1, y = 0, z = 1},
        {x = -1, y = 0, z = 1},
        {x = 1, y = 0, z = -1},
        {x = -1, y = 0, z = -1},
    }
    
    for _, offset in ipairs(offsets) do
        local alt_pos = vector.add(base_pos, offset)
        if is_position_safe(alt_pos) then
            return alt_pos
        end
    end
    
    return nil
end

-- Get target hover position (1 block above terminal, or alternative)
local function get_target_hover_pos(terminal_pos)
    if is_position_safe(terminal_pos) then
        return vector.new(terminal_pos.x, terminal_pos.y + 1, terminal_pos.z)
    else
        return find_alternative_hover(terminal_pos)
    end
end

-- Drone entity definition
minetest.register_entity("menotics_passenger_drone:drone", {
    initial_properties = {
        physical = false, -- Non-physical for free flying
        collide_with_objects = false, -- Disable collision to allow free movement
        weight = 0, -- No weight for flying drone
        collisionbox = {-0.01, -0.01, -0.01, 0.01, 0.01, 0.01}, -- Minimal collision box
        stepheight = 0,
        visual = "cube",
        textures = {
            "menotics_drone_side.png",   -- right (+x)
            "menotics_drone_side.png",   -- left (-x)
            "menotics_drone_front.png",  -- front (+z)
            "menotics_drone_back.png",   -- back (-z)
            "menotics_drone_roof.png",   -- top (+y)
            "menotics_drone_bottom.png", -- bottom (-y)
        },
        pointable = true,
        static_save = true,
        glow = 8,
        visual_size = {x = 4, y = 3, z = 2}, -- 4 blocks long, 3 high, 2 wide
        backface_culling = false, -- Allow seeing textures from inside (for transparent PNGs)
        use_texture_alpha = "blend", -- Enable alpha transparency for textures (proper blend mode)
        hp_max = 999999, -- Nearly immortal
        armor_groups = {immortal = 1},
        automatic_rotate = false, -- Don't rotate automatically
    },
    
    -- Override acceleration to zero for direct velocity control
    acceleration = {x = 0, y = 0, z = 0},
    max_drop = 0,
    max_push = 0,
    
    driver = nil,
    target_pos = nil,
    current_terminal = nil,
    wait_timer = 0,
    waiting = false,
    state = "idle",
    
    on_activate = function(self, staticdata, dtime_s)
        self.driver = nil
        self.target_pos = nil
        self.current_terminal = nil
        self.wait_timer = 0
        self.waiting = false
        self.state = "idle"
        
        local pos = self.object:get_pos()
        if pos then
            debug_log("=== DRONE ACTIVATED ===")
            debug_log("Drone activated at " .. minetest.pos_to_string(pos))
            
            -- Force terminal cache refresh on activate
            terminal_cache = find_terminals(pos)
            last_terminal_update = minetest.get_us_time()
            debug_log("Found " .. #terminal_cache .. " terminals in cache")
            
            -- Find nearest terminal
            local nearest, dist = find_nearest_terminal(pos)
            if nearest then
                self.current_terminal = nearest
                debug_log("Found nearest terminal at " .. minetest.pos_to_string(nearest) .. " (dist: " .. tostring(dist) .. ")")
                
                -- Set hover position directly above the terminal
                local hover_pos = vector.new(nearest.x, nearest.y + 1, nearest.z)
                debug_log("Setting hover position to " .. minetest.pos_to_string(hover_pos))
                self.object:set_pos(hover_pos)
                self.object:set_velocity(vector.new(0, 0, 0))
                
                self.waiting = true
                self.wait_timer = 5 -- 5 seconds wait time (shorter for testing)
                self.state = "waiting"
                debug_log("=== DRONE STATE: WAITING FOR " .. self.wait_timer .. "s ===")
            else
                debug_log("No terminals found near drone - will stay idle")
                minetest.chat_send_all("[Drone] No terminals found - place terminal blocks nearby")
            end
        else
            debug_log("Drone activated but no position available")
        end
    end,
    
    on_step = function(self, dtime)
        local pos = self.object:get_pos()
        if not pos then
            return
        end
        
        -- Handle passenger attachment
        if self.driver then
            local player = minetest.get_player_by_name(self.driver)
            if not player or not player:get_attach() then
                debug_log("Passenger disconnected: " .. tostring(self.driver))
                minetest.chat_send_all("[Drone] Passenger disconnected")
                self.driver = nil
            end
        end
        
        -- CRITICAL DEBUG: Log every step with full state info
        local vel = self.object:get_velocity()
        local yaw = self.object:get_yaw() or 0
        debug_log(string.format("on_step: state=%s, pos=(%.1f,%.1f,%.1f), timer=%.2f, velocity=(%.2f,%.2f,%.2f), yaw=%.2f, current_terminal=%s", 
            self.state, pos.x, pos.y, pos.z, self.wait_timer, vel.x, vel.y, vel.z, yaw,
            self.current_terminal and "SET" or "NIL"))
        
        -- State machine
        if self.state == "waiting" then
            self.wait_timer = self.wait_timer - dtime
            
            -- Maintain hover position while waiting
            if self.current_terminal then
                local expected_hover = vector.new(self.current_terminal.x, self.current_terminal.y + 1, self.current_terminal.z)
                local dist_from_hover = vector.distance(pos, expected_hover)
                if dist_from_hover > 0.3 then
                    debug_log("Drift detected, correcting position from " .. minetest.pos_to_string(pos) .. " to " .. minetest.pos_to_string(expected_hover))
                    self.object:set_pos(expected_hover)
                    self.object:set_velocity(vector.new(0, 0, 0))
                end
            end
            
            if self.wait_timer <= 0 then
                debug_log("=== WAIT TIMER EXPIRED, STARTING MOVEMENT ===")
                -- Wait time over, start moving to next terminal
                self.waiting = false
                self.state = "moving_to_terminal"
                
                -- Find ALL terminals and pick one that's not current
                local all_terminals = get_terminals_cached()
                debug_log("Total terminals found: " .. #all_terminals)
                
                local next_terminal = nil
                if #all_terminals >= 2 then
                    -- Pick a random terminal that's not the current one
                    local candidates = {}
                    for _, term in ipairs(all_terminals) do
                        if not self.current_terminal or not vector.equals(term, self.current_terminal) then
                            table.insert(candidates, term)
                        end
                    end
                    if #candidates > 0 then
                        next_terminal = candidates[math.random(1, #candidates)]
                        debug_log("Selected next terminal: " .. minetest.pos_to_string(next_terminal))
                    end
                elseif #all_terminals == 1 then
                    -- Only one terminal exists, go back to it after leaving
                    next_terminal = all_terminals[1]
                    debug_log("Only one terminal, will return to: " .. minetest.pos_to_string(next_terminal))
                end
                
                if next_terminal then
                    local hover_pos = get_target_hover_pos(next_terminal)
                    if hover_pos then
                        self.target_pos = hover_pos
                        self.current_terminal = next_terminal
                        debug_log("Moving to terminal at " .. minetest.pos_to_string(hover_pos))
                        
                        local dir = vector.direction(pos, hover_pos)
                        if dir then
                            local speed = 3 -- blocks per second
                            local velocity = vector.multiply(dir, speed)
                            debug_log("About to set velocity to: " .. minetest.pos_to_string(velocity))
                            
                            -- Set position directly for instant movement (no physics interference)
                            local new_pos = vector.add(pos, velocity)
                            self.object:set_pos(new_pos)
                            self.object:set_velocity(velocity)
                            
                            -- Also set rotation to face direction
                            local yaw = math.atan2(dir.x, dir.z)
                            self.object:set_yaw(yaw)
                            
                            -- Verify velocity was set
                            local new_vel = self.object:get_velocity()
                            debug_log("Set pos from " .. minetest.pos_to_string(pos) .. " to " .. minetest.pos_to_string(new_pos))
                            debug_log("Velocity after set: " .. minetest.pos_to_string(new_vel))
                            debug_log("Yaw set to: " .. tostring(yaw))
                            minetest.chat_send_all("[Drone] Departing to next terminal")
                        else
                            debug_log("No direction vector to target")
                            self.state = "waiting"
                            self.wait_timer = 20
                        end
                    else
                        debug_log("No valid hover position for next terminal")
                        minetest.chat_send_all("[Drone] No valid path to terminal")
                        self.state = "idle"
                    end
                else
                    debug_log("No terminals available at all")
                    minetest.chat_send_all("[Drone] No terminals available")
                    self.state = "idle"
                end
            end
        elseif self.state == "moving_to_terminal" then
            local vel = self.object:get_velocity()
            
            -- Move continuously towards target
            if self.target_pos then
                local dist_to_target = vector.distance(pos, self.target_pos)
                
                if dist_to_target < 0.5 then
                    -- Arrived at target
                    debug_log("Arrived at target (within 0.5)")
                    self.object:set_pos(self.target_pos)
                    self.object:set_velocity(vector.new(0, 0, 0))
                    self.target_pos = nil
                    self.waiting = true
                    self.wait_timer = 5  -- Shorter wait time
                    self.state = "waiting"
                    minetest.chat_send_all("[Drone] Arrived at terminal")
                else
                    -- Keep moving towards target
                    local dir = vector.direction(pos, self.target_pos)
                    if dir then
                        local speed = 3 -- blocks per second
                        local velocity = vector.multiply(dir, speed)
                        local new_pos = vector.add(pos, velocity)
                        self.object:set_pos(new_pos)
                        self.object:set_velocity(velocity)
                        -- Update yaw to face direction
                        local yaw = math.atan2(dir.x, dir.z)
                        self.object:set_yaw(yaw)
                    end
                end
            else
                -- No target, go idle
                self.state = "idle"
            end
                end
            else
                self.state = "idle"
            end
        elseif self.state == "idle" then
            -- Hover in place
            local vel = self.object:get_velocity()
            if vector.length(vel) > 0.1 then
                self.object:set_velocity(vector.new(0, 0, 0))
            end
        end
    end,
    
    on_rightclick = function(self, clicker)
        if not clicker or not clicker:is_player() then
            return
        end
        
        local player_name = clicker:get_player_name()
        
        debug_log("Drone rightclicked by " .. player_name .. ", driver=" .. tostring(self.driver))
        
        -- If already driving, detach (dismount)
        if self.driver and self.driver == player_name then
            local player = minetest.get_player_by_name(player_name)
            if player then
                player:set_detach()
                minetest.chat_send_all("[Drone] " .. player_name .. " disembarked")
                
                local pos = self.object:get_pos()
                if pos then
                    player:set_pos(vector.new(pos.x + 1, pos.y, pos.z))
                end
                
                self.driver = nil
            end
            return
        end
        
        -- If someone else is driving
        if self.driver then
            minetest.chat_send_player(player_name, "[Drone] Already occupied!")
            return
        end
        
        -- Attach player to drone
        debug_log("Attaching player " .. player_name .. " to drone")
        clicker:set_attach(self.object, "", {x=0, y=1, z=0}, {x=0, y=0, z=0})
        self.driver = player_name
        minetest.chat_send_all("[Drone] " .. player_name .. " boarded")
    end,
    
    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        -- Eject passenger when punched
        if self.driver then
            local player = minetest.get_player_by_name(self.driver)
            if player then
                player:set_detach()
                minetest.chat_send_all("[Drone] " .. self.driver .. " ejected due to damage")
                
                local pos = self.object:get_pos()
                if pos then
                    player:set_pos(vector.new(pos.x + 1, pos.y, pos.z))
                end
                
                self.driver = nil
            end
        end
    end,
    
    on_deactivate = function(self, removal)
        -- Eject passenger when drone is removed
        if self.driver then
            local player = minetest.get_player_by_name(self.driver)
            if player then
                player:set_detach()
                minetest.chat_send_all("[Drone] " .. self.driver .. " ejected (drone removed)")
                self.driver = nil
            end
        end
    end,
})

-- Craft item for spawning the drone
minetest.register_craftitem("menotics_passenger_drone:item", {
    description = S("Passenger Drone (Place on ground to spawn)"),
    inventory_image = "menotics_drone_front.png",
    
    on_place = function(itemstack, placer, pointed_thing)
        if not pointed_thing or not pointed_thing.under then
            return itemstack
        end
        
        local pos = pointed_thing.under
        local node = minetest.get_node(pos)
        
        local def = minetest.registered_nodes[node.name]
        if def and def.walkable then
            pos = vector.new(pos.x, pos.y + 1, pos.z)
            node = minetest.get_node(pos)
            def = minetest.registered_nodes[node.name]
            
            if def and def.walkable then
                minetest.chat_send_player(placer:get_player_name(), 
                    "[Drone] Cannot place here - position blocked")
                return itemstack
            end
        end
        
        local drone_obj = minetest.add_entity(pos, "menotics_passenger_drone:drone")
        
        if drone_obj then
            itemstack:take_item()
            minetest.chat_send_all("[Drone] Passenger drone deployed!")
        else
            minetest.chat_send_player(placer:get_player_name(), 
                "[Drone] Failed to spawn drone")
        end
        
        return itemstack
    end,
})

-- Crafting recipe: Steel Ingots + Mese Crystal + Glass
minetest.register_craft({
    output = "menotics_passenger_drone:item",
    recipe = {
        {"default:steel_ingot", "default:mese_crystal", "default:steel_ingot"},
        {"default:glass", "default:glass", "default:glass"},
        {"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
    },
})

-- Periodic terminal cache update
minetest.register_globalstep(function(dtime)
    local current_time = minetest.get_us_time()
    if current_time - last_terminal_update > 10000000 then
        terminal_cache = find_terminals({x=0, y=0, z=0})
        last_terminal_update = current_time
    end
end)

-- ABM to update cache when terminals are placed
minetest.register_abm({
    label = "Update terminal cache on placement",
    nodenames = {"menotics_passenger_drone:terminal"},
    interval = 1,
    chance = 1,
    action = function(pos, node, active_object_count, active_object_count_wider)
        terminal_cache = find_terminals({x=0, y=0, z=0})
        last_terminal_update = minetest.get_us_time()
    end,
})

minetest.log("action", "[menotics_passenger_drone] Mod loaded successfully")

-- /clear_mdp_master command - kills all drones and deletes all terminals
minetest.register_chatcommand("clear_mdp_master", {
    description = "Deletes all passenger drone terminals and removes all drones",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "Player not found"
        end
        
        debug_log("Starting clear_mdp_master command by " .. name)
        
        -- Find and remove all drones
        local drone_count = 0
        for _, obj in ipairs(minetest.luaentities) do
            if obj and obj.object and obj.object:get_luaentity() then
                local luaentity = obj.object:get_luaentity()
                if luaentity and luaentity.name == "menotics_passenger_drone:drone" then
                    -- Eject any passenger first
                    if luaentity.driver then
                        local driver_player = minetest.get_player_by_name(luaentity.driver)
                        if driver_player then
                            driver_player:set_detach()
                            minetest.chat_send_all("[Drone] " .. luaentity.driver .. " ejected (master clear)")
                        end
                    end
                    obj.object:remove()
                    drone_count = drone_count + 1
                end
            end
        end
        
        -- Also try to find entities directly
        local objects = minetest.get_objects_inside_radius({x=0, y=0, z=0}, 5000)
        for _, obj in ipairs(objects) do
            if obj and obj:get_luaentity() then
                local luaentity = obj:get_luaentity()
                if luaentity and luaentity.name == "menotics_passenger_drone:drone" then
                    if luaentity.driver then
                        local driver_player = minetest.get_player_by_name(luaentity.driver)
                        if driver_player then
                            driver_player:set_detach()
                        end
                    end
                    obj:remove()
                    drone_count = drone_count + 1
                end
            end
        end
        
        -- Find and delete all terminals
        local terminal_count = 0
        local terminals = find_terminals({x=0, y=0, z=0})
        for _, term_pos in ipairs(terminals) do
            local node = minetest.get_node(term_pos)
            if node.name == "menotics_passenger_drone:terminal" then
                minetest.set_node(term_pos, {name="air"})
                terminal_count = terminal_count + 1
            end
        end
        
        local msg = string.format("[Drone Master Clear] Removed %d drones and %d terminals", drone_count, terminal_count)
        minetest.chat_send_all(msg)
        debug_log("Clear complete: " .. drone_count .. " drones, " .. terminal_count .. " terminals")
        
        return true, msg
    end,
})
