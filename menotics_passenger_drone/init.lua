-- Menotics Passenger Drone Mod
-- Transfers players between terminal blocks using a glass drone vehicle
-- No 3D model required - uses box visual with multiple textures

local S = minetest.get_translator("menotics_passenger_drone")

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
local function find_terminals()
    local terminals = {}
    local found_set = {} -- Track found positions to avoid duplicates
    
    -- Search in smaller chunks to avoid exceeding area volume limit (150,000,000 nodes)
    -- Each chunk is 2000x2000x2000 = 8,000,000 nodes (well under the limit)
    local chunk_size = 2000
    local search_radius = 4000 -- Total search area: 8000x8000x8000
    
    local minp_global = vector.new(-search_radius, -search_radius, -search_radius)
    local maxp_global = vector.new(search_radius, search_radius, search_radius)
    
    -- Iterate through chunks
    for x = minp_global.x, maxp_global.x, chunk_size do
        for y = minp_global.y, maxp_global.y, chunk_size do
            for z = minp_global.z, maxp_global.z, chunk_size do
                local chunk_minp = vector.new(x, y, z)
                local chunk_maxp = vector.new(
                    math.min(x + chunk_size - 1, maxp_global.x),
                    math.min(y + chunk_size - 1, maxp_global.y),
                    math.min(z + chunk_size - 1, maxp_global.z)
                )
                
                local pos_list = minetest.find_nodes_in_area(
                    chunk_minp,
                    chunk_maxp,
                    "menotics_passenger_drone:terminal",
                    false
                )
                
                for _, pos in ipairs(pos_list) do
                    local key = pos.x .. "," .. pos.y .. "," .. pos.z
                    if not found_set[key] then
                        found_set[key] = true
                        table.insert(terminals, vector.new(pos))
                    end
                end
                
                -- Stop early if we already have at least 2 terminals
                if #terminals >= 2 then
                    goto continue_outer
                end
            end
        end
        ::continue_outer::
        if #terminals >= 2 then
            break
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
        terminal_cache = find_terminals()
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
        return false
    end
    
    local term_node = minetest.get_node(pos)
    if term_node.name ~= "menotics_passenger_drone:terminal" then
        return false
    end
    
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
        physical = true,
        collide_with_objects = true,
        weight = 5,
        collisionbox = {-2, -0.5, -2, 2, 1.5, 2}, -- 4 blocks long, 3 blocks high
        stepheight = 1.0,
        visual = "cube",
        textures = {
            "menotics_drone_side.png",   -- right
            "menotics_drone_side.png",   -- left
            "menotics_drone_roof.png",   -- top
            "menotics_drone_bottom.png", -- bottom
            "menotics_drone_front.png",  -- front
            "menotics_drone_back.png",   -- back
        },
        pointable = true,
        static_save = true,
        glow = 5,
        visual_size = {x = 4, y = 3, z = 2}, -- 4 blocks long, 3 high, 2 wide
    },
    
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
            local nearest, _ = find_nearest_terminal(pos)
            if nearest then
                self.current_terminal = nearest
                local hover_pos = get_target_hover_pos(nearest)
                if hover_pos then
                    self.object:set_pos(hover_pos)
                    self.waiting = true
                    self.wait_timer = 20 -- 20 seconds wait time
                    self.state = "waiting"
                end
            end
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
                minetest.chat_send_all("[Drone] Passenger disconnected")
                self.driver = nil
            end
        end
        
        -- State machine
        if self.state == "waiting" then
            self.wait_timer = self.wait_timer - dtime
            
            if self.wait_timer <= 0 then
                -- Wait time over, start moving to next terminal
                self.waiting = false
                self.state = "moving"
                
                -- Find next terminal (skip current one)
                local next_terminal = find_nearest_terminal(pos, self.current_terminal)
                
                if next_terminal then
                    local hover_pos = get_target_hover_pos(next_terminal)
                    if hover_pos then
                        self.target_pos = hover_pos
                        self.current_terminal = next_terminal
                        
                        local dir = vector.direction(pos, hover_pos)
                        if dir then
                            local speed = 3 -- blocks per second
                            local velocity = vector.multiply(dir, speed)
                            self.object:set_velocity(velocity)
                            minetest.chat_send_all("[Drone] Departing to next terminal")
                        else
                            self.state = "waiting"
                            self.wait_timer = 20
                        end
                    else
                        minetest.chat_send_all("[Drone] No valid path to terminal")
                        self.state = "idle"
                    end
                else
                    -- No other terminals, go back to current/only terminal
                    minetest.chat_send_all("[Drone] No other terminals available")
                    
                    if self.current_terminal then
                        local hover_pos = get_target_hover_pos(self.current_terminal)
                        if hover_pos and not vector.equals(pos, hover_pos) then
                            self.target_pos = hover_pos
                            local dir = vector.direction(pos, hover_pos)
                            if dir then
                                local speed = 3
                                local velocity = vector.multiply(dir, speed)
                                self.object:set_velocity(velocity)
                                self.state = "moving"
                            else
                                self.state = "waiting"
                                self.wait_timer = 20
                            end
                        else
                            self.state = "waiting"
                            self.wait_timer = 20
                        end
                    else
                        self.state = "idle"
                    end
                end
            end
        elseif self.state == "moving" then
            local vel = self.object:get_velocity()
            
            -- Check for collision (velocity near zero but haven't reached target)
            if vector.length(vel) < 0.1 and self.target_pos then
                local dist_to_target = vector.distance(pos, self.target_pos)
                
                if dist_to_target > 1 then
                    -- Collision detected! Try alternate path
                    minetest.chat_send_all("[Drone] Collision detected, finding alternate path")
                    
                    self.object:set_velocity(vector.new(0, 0, 0))
                    
                    if self.current_terminal then
                        local alt_pos = find_alternative_hover(
                            vector.new(self.current_terminal.x, self.current_terminal.y, self.current_terminal.z)
                        )
                        
                        if alt_pos then
                            self.target_pos = alt_pos
                            local dir = vector.direction(pos, alt_pos)
                            if dir then
                                local speed = 2 -- Slower when rerouting
                                local velocity = vector.multiply(dir, speed)
                                self.object:set_velocity(velocity)
                                minetest.chat_send_all("[Drone] Rerouted to alternative position")
                            end
                        else
                            self.state = "idle"
                            minetest.chat_send_all("[Drone] Stopped - no valid path")
                        end
                    end
                else
                    -- Close enough to target
                    self.object:set_pos(self.target_pos)
                    self.object:set_velocity(vector.new(0, 0, 0))
                    self.target_pos = nil
                    self.waiting = true
                    self.wait_timer = 20
                    self.state = "waiting"
                    minetest.chat_send_all("[Drone] Arrived at terminal")
                end
            elseif self.target_pos then
                -- Still moving, check arrival
                local dist_to_target = vector.distance(pos, self.target_pos)
                
                if dist_to_target < 0.5 then
                    self.object:set_pos(self.target_pos)
                    self.object:set_velocity(vector.new(0, 0, 0))
                    self.target_pos = nil
                    self.waiting = true
                    self.wait_timer = 20
                    self.state = "waiting"
                    minetest.chat_send_all("[Drone] Arrived at terminal")
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
        local player_obj = clicker:get_object()
        if player_obj then
            player_obj:set_attach(self.object)
            self.driver = player_name
            minetest.chat_send_all("[Drone] " .. player_name .. " boarded")
        end
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
        terminal_cache = find_terminals()
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
        terminal_cache = find_terminals()
        last_terminal_update = minetest.get_us_time()
    end,
})

minetest.log("action", "[menotics_passenger_drone] Mod loaded successfully")
