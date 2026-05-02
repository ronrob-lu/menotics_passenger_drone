-- Menotics Passenger Drone Mod
-- Eine Drohne, die automatisch zwischen Terminal-Blöcken pendelt und Spieler transportiert

local modname = "menotics_passenger_drone"

-- Konfiguration
local DRONE_SPEED = 5
local DRONE_RANGE = 100
local CHECK_INTERVAL = 1.0

-- Temporäre Speicherung für Drohnen-Daten
local drone_data = {}

-- Terminal-Block Definition (uses single texture, no 3D model)
minetest.register_node("menotics_passenger_drone:terminal", {
    description = "Passenger Drone Terminal",
    tiles = {"terminal.png"},
    paramtype2 = "facedir",
    groups = {cracky = 3},
    is_ground_content = false,
    
    on_place = function(itemstack, placer, pointed_thing)
        local node = minetest.get_node(pointed_thing.above)
        if not node then return end
        
        -- Standard Platzierung mit facedir
        local ret = minetest.item_place_node(itemstack, placer, pointed_thing)
        if ret then
            local pos = pointed_thing.above
            local meta = minetest.get_meta(pos)
            meta:set_string("infotext", "Passenger Drone Terminal")
            meta:set_int("terminal_id", math.random(1, 9999))
        end
        return ret
    end,
    
    on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
        local meta = minetest.get_meta(pos)
        local terminal_id = meta:get_int("terminal_id")
        minetest.chat_send_player(clicker:get_player_name(), 
            "Terminal ID: " .. tostring(terminal_id))
        minetest.chat_send_player(clicker:get_player_name(), 
            "Baue eine Drohne und sie wird automatisch dieses Terminal ansteuern.")
    end,
})

-- Drohne als Entity (4x3x3 blocks size)
minetest.register_entity("menotics_passenger_drone:drone", {
    initial_properties = {
        hp_max = 100,
        physical = true,
        collide_with_objects = true,
        collisionbox = {-2, -1.5, -1.5, 2, 1.5, 1.5},  -- 4 wide, 3 tall, 3 deep
        selectionbox = {-2.1, -1.6, -1.6, 2.1, 1.6, 1.6},
        visual = "cube",
        textures = {
            "menotics_drone_side.png",      -- right
            "menotics_drone_side.png",      -- left
            "menotics_drone_roof.png",      -- top
            "menotics_drone_bottom.png",    -- bottom
            "menotics_drone_front.png",     -- front
            "menotics_drone_back.png",      -- back
        },
        visual_size = {x=4, y=3, z=3},
        automatic_rotate = 0,
        stepheight = 0.6,
        falls = false,
        luminance = 5,
    },
    
    on_activate = function(self, staticdata, dtime_s)
        self.state = "idle"
        self.target_pos = nil
        self.current_terminal = nil
        self.previous_terminal = nil  -- Track previous terminal to skip it
        self.passenger = nil
        self.wait_timer = 0
        self.path_index = 1
        self.path = {}
        self.lamp_lit = false  -- Track if lamp is lit
        
        -- Daten aus staticdata laden
        if staticdata and staticdata ~= "" then
            local data = minetest.deserialize(staticdata)
            if data then
                self.state = data.state or "idle"
                self.current_terminal = data.current_terminal
                self.previous_terminal = data.previous_terminal
                self.wait_timer = data.wait_timer or 0
                self.lamp_lit = data.lamp_lit or false
            end
        end
        
        self.object:set_armor_groups({immortal = 1})
    end,
    
    get_staticdata = function(self)
        local data = {
            state = self.state,
            current_terminal = self.current_terminal,
            previous_terminal = self.previous_terminal,
            wait_timer = self.wait_timer,
            lamp_lit = self.lamp_lit,
        }
        return minetest.serialize(data)
    end,
    
    on_step = function(self, dtime, moveresult)
        -- Timer für Wartezeit
        if self.wait_timer > 0 then
            self.wait_timer = self.wait_timer - dtime
            if self.wait_timer <= 0 then
                self.wait_timer = 0
                -- Nächste Aktion nach Wartezeit
                if self.state == "waiting_at_terminal" then
                    self:find_next_terminal()
                end
            end
            return
        end
        
        -- Zustandsmaschine
        if self.state == "idle" then
            self:search_for_terminals()
            
        elseif self.state == "moving_to_terminal" or self.state == "moving_with_passenger" then
            self:move_to_target()
            
        elseif self.state == "waiting_at_terminal" then
            -- Warten am Terminal, Passagiere können einsteigen
            local passengers = self:get_nearby_players()
            if #passengers > 0 and not self.passenger then
                -- Passagier einsteigen lassen (automatisch erster in der Nähe)
                self.passenger = passengers[1]
                minetest.chat_send_player(self.passenger:get_player_name(), 
                    "Du bist in die Drohne eingestiegen!")
                -- Attach player to drone
                self.passenger:set_attach(self.object, "", {x=0, y=1.5, z=0}, {x=0, y=0, z=0})
                self.passenger:set_eye_offset({x=0, y=5, z=0}, {x=0, y=0, z=0})
            end
            
        else
            self.state = "idle"
        end
    end,
    
    search_for_terminals = function(self)
        local pos = self.object:get_pos()
        if not pos then return end
        
        -- Suche nach Terminal-Blöcken in der Nähe
        local minp = vector.subtract(pos, DRONE_RANGE)
        local maxp = vector.add(pos, DRONE_RANGE)
        
        local terminals = {}
        for x = minp.x, maxp.x do
            for y = minp.y, maxp.y do
                for z = minp.z, maxp.z do
                    local node = minetest.get_node({x=x, y=y, z=z})
                    if node.name == "menotics_passenger_drone:terminal" then
                        table.insert(terminals, {x=x, y=y+1, z=z})
                    end
                end
            end
        end
        
        if #terminals > 0 then
            -- Wähle zufälliges Terminal als Ziel
            local target = terminals[math.random(#terminals)]
            self.target_pos = target
            self.state = "moving_to_terminal"
            
            -- Einfache Pfadplanung (direkte Linie)
            self.path = {target}
            self.path_index = 1
        else
            -- Keine Terminals gefunden, warte kurz
            self.wait_timer = 2.0
        end
    end,
    
    find_next_terminal = function(self)
        local pos = self.object:get_pos()
        if not pos then return end
        
        -- Suche nach anderen Terminals (nicht dem aktuellen und nicht dem vorherigen)
        local minp = vector.subtract(pos, DRONE_RANGE)
        local maxp = vector.add(pos, DRONE_RANGE)
        
        local terminals = {}
        for x = minp.x, maxp.x do
            for y = minp.y, maxp.y do
                for z = minp.z, maxp.z do
                    local node = minetest.get_node({x=x, y=y, z=z})
                    if node.name == "menotics_passenger_drone:terminal" then
                        local term_pos = {x=x, y=y+1, z=z}
                        -- Nicht das aktuelle Terminal und nicht das vorherige
                        local is_current = self.current_terminal and 
                                           vector.distance(term_pos, self.current_terminal) < 2
                        local is_previous = self.previous_terminal and 
                                            vector.distance(term_pos, self.previous_terminal) < 2
                        if not is_current and not is_previous then
                            table.insert(terminals, term_pos)
                        end
                    end
                end
            end
        end
        
        if #terminals > 0 then
            local target
            -- If only two terminals exist, go to the other one
            -- If more than two, pick the nearest one
            if #terminals == 1 then
                target = terminals[1]
            else
                -- Find nearest terminal
                local min_dist = math.huge
                for _, t in ipairs(terminals) do
                    local dist = vector.distance(pos, t)
                    if dist < min_dist then
                        min_dist = dist
                        target = t
                    end
                end
            end
            
            self.target_pos = target
            
            if self.passenger then
                self.state = "moving_with_passenger"
            else
                self.state = "moving_to_terminal"
            end
            
            self.path = {target}
            self.path_index = 1
        else
            self.state = "idle"
            self.wait_timer = 2.0
        end
    end,
    
    move_to_target = function(self)
        if not self.target_pos then
            self.state = "idle"
            return
        end
        
        local pos = self.object:get_pos()
        if not pos then return end
        
        local distance = vector.distance(pos, self.target_pos)
        
        -- Ziel erreicht?
        if distance < 1.5 then
            -- Stop moving
            self.object:set_velocity({x=0, y=0, z=0})
            
            if self.state == "moving_to_terminal" or self.state == "moving_with_passenger" then
                -- Store current as previous before setting new current
                self.previous_terminal = self.current_terminal
                self.current_terminal = self.target_pos
                
                if self.passenger then
                    -- Passenger on board: continue to next terminal after short wait
                    self.state = "waiting_at_terminal"
                    self.wait_timer = 1.0
                else
                    -- No passenger: wait longer at terminal
                    self.state = "waiting_at_terminal"
                    self.wait_timer = 3.0
                end
                
                -- Nachricht an Spieler in der Nähe
                local players = minetest.get_objects_inside_radius(pos, 10)
                for _, player in ipairs(players) do
                    if player:is_player() then
                        minetest.chat_send_player(player:get_player_name(), 
                            "Eine Drohne ist am Terminal angekommen!")
                    end
                end
                
                -- Let passenger out if arrived at destination
                if self.passenger and self.state == "waiting_at_terminal" then
                    local pname = self.passenger:get_player_name()
                    minetest.chat_send_player(pname, "Du bist am Ziel angekommen!")
                    self.passenger:set_attach(nil)
                    self.passenger:set_eye_offset({x=0, y=0, z=0}, {x=0, y=0, z=0})
                    self.passenger = nil
                end
            end
            return
        end
        
        -- Bewegung zum Ziel
        local direction = vector.direction(pos, self.target_pos)
        local velocity = vector.multiply(direction, DRONE_SPEED)
        
        self.object:set_velocity(velocity)
        
        -- Rotation in Bewegungsrichtung
        local yaw = math.atan2(direction.x, direction.z)
        self.object:set_yaw(yaw)
    end,
    
    get_nearby_players = function(self)
        local pos = self.object:get_pos()
        if not pos then return {} end
        
        local players = {}
        local objects = minetest.get_objects_inside_radius(pos, 3.0)
        
        for _, obj in ipairs(objects) do
            if obj:is_player() then
                table.insert(players, obj)
            end
        end
        
        return players
    end,
    
    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        -- Drohne kann nicht verletzt werden
        return false
    end,
    
    on_rightclick = function(self, clicker)
        -- Manuelles Ein- und Aussteigen
        if self.passenger and self.passenger:get_player_name() == clicker:get_player_name() then
            -- Aussteigen
            minetest.chat_send_player(clicker:get_player_name(), "Du bist ausgestiegen.")
            clicker:set_attach(nil)
            clicker:set_eye_offset({x=0, y=0, z=0}, {x=0, y=0, z=0})
            self.passenger = nil
        elseif not self.passenger then
            -- Einsteigen wenn in der Nähe (larger drone = larger interaction range)
            local pos = self.object:get_pos()
            local clicker_pos = clicker:get_pos()
            if vector.distance(pos, clicker_pos) < 4 then
                self.passenger = clicker
                -- Attach player to drone
                clicker:set_attach(self.object, "", {x=0, y=1.5, z=0}, {x=0, y=0, z=0})
                clicker:set_eye_offset({x=0, y=5, z=0}, {x=0, y=0, z=0})
                minetest.chat_send_player(clicker:get_player_name(), "Du bist eingestiegen!")
            end
        end
    end,
})

-- Crafting Rezept für die Drohne
minetest.register_craft({
    output = "menotics_passenger_drone:drone_item",
    recipe = {
        {"default:steel_ingot", "default:gold_ingot", "default:steel_ingot"},
        {"default:steel_ingot", "menotics_passenger_drone:terminal", "default:steel_ingot"},
        {"default:steel_ingot", "default:diamond", "default:steel_ingot"},
    }
})

-- Drohne als Item (zum Platzieren)
minetest.register_craftitem("menotics_passenger_drone:drone_item", {
    description = "Passenger Drone (Place)",
    inventory_image = "menotics_drone.png",
    
    on_place = function(itemstack, placer, pointed_thing)
        local pos = pointed_thing.above
        if not pos then return itemstack end
        
        -- Drohne spawnen
        local obj = minetest.add_entity(pos, "menotics_passenger_drone:drone")
        if obj then
            -- Etwas nach oben setzen damit sie nicht im Boden steckt
            obj:set_pos({x=pos.x, y=pos.y+1, z=pos.z})
            itemstack:take_item()
            minetest.chat_send_player(placer:get_player_name(), "Drohne platziert!")
        end
        
        return itemstack
    end,
})

-- Admin Befehl zum Zurücksetzen aller Drohnen
minetest.register_chatcommand("clear_mdp_master", {
    params = "",
    description = "Entfernt alle Passenger Drones",
    privs = {server = true},
    func = function(name, param)
        local count = 0
        local objects = minetest.get_objects_in_area(
            {x=-30000, y=-30000, z=-30000},
            {x=30000, y=30000, z=30000}
        )
        
        for _, obj in ipairs(objects) do
            local entity = obj:get_luaentity()
            if entity and entity.name == "menotics_passenger_drone:drone" then
                obj:remove()
                count = count + 1
            end
        end
        
        return true, "Alle " .. count .. " Drohnen wurden entfernt."
    end,
})

-- Node aliases für bessere Kompatibilität
minetest.register_alias("menotics_passenger_drone:master", "menotics_passenger_drone:terminal")

print("[MOD] Menotics Passenger Drone geladen!")
