local Point3 = _radiant.csg.Point3
local rng = _radiant.math.get_default_rng()
local CombatService = require 'stonehearth.services.server.combat.combat_service'
local AceCombatService = class()

local get_player_id = radiant.entities.get_player_id

local EXP_SPLIT_AMOUNT = 0.7  -- each entity involved will get 30% of the raw exp value; 70% will be divided out among them

AceCombatService._ace_old_calculate_healing = CombatService.calculate_healing
function AceCombatService:calculate_healing(healer, target, heal_info)
   local total_healing = self:_ace_old_calculate_healing(healer, target, heal_info)

   local attributes_component = target:get_component('stonehearth:attributes')
   if attributes_component then
      local additive_heal_modifier = attributes_component:get_attribute('additive_heal_received_modifier')
      local multiplicative_heal_modifier = attributes_component:get_attribute('multiplicative_heal_received_modifier')

      if multiplicative_heal_modifier then
         total_healing = total_healing + total_healing * multiplicative_heal_modifier
      end
      if additive_heal_modifier then
         total_healing = total_healing + additive_heal_modifier
      end

      total_healing = radiant.math.round(total_healing)
   end

   return total_healing
end

--AceCombatService._ace_old__on_target_killed = CombatService._on_target_killed
function AceCombatService:_on_target_killed(attacker, target)
   local attacker_player_id = get_player_id(attacker)
   local target_player_id = get_player_id(target)

   if attacker_player_id ~= target_player_id then
      local nearby_units = self:_get_nearby_units(target, attacker, attacker_player_id)
      self:distribute_exp(attacker, target, nearby_units)
      self:_notify_combat_participants(attacker, target, nearby_units)

      if radiant.entities.has_free_will(target) then
         self:_record_kill_stats(attacker, target, nearby_units)
      end
   end

   self:_queue_killed_entity_craft_order(target)
   self:_handle_loot_drop(attacker, target)
end

function AceCombatService:_queue_killed_entity_craft_order(entity)
   local player_id = get_player_id(entity)
   local job_controller = stonehearth.job:get_jobs_controller(player_id)
   if job_controller then
      local auto_craft = stonehearth.client_state:get_client_gameplay_setting(player_id, 'stonehearth_ace', 'auto_craft_killed_items', true)
      if auto_craft then
         job_controller:request_craft_product(entity:get_uri(), 1)
      end
   end
end

-- record kill stats for killer, assistants, and killer's equipment:
--    player_id of victim, category of victim (if available), total kills/assists, and notable victim kills
function AceCombatService:_record_kill_stats(attacker, target, units)
   local enemy_player = get_player_id(target)

   if enemy_player and enemy_player ~= '' then   
      local catalog_data = stonehearth.catalog:get_catalog_data(target:get_uri())
      local enemy_category = catalog_data and catalog_data.category
      local enemy_specifier = radiant.entities.get_property_value(target, 'stats_specifier')

      for _, unit in pairs(units) do
         -- for the attacker, record kills; otherwise record assists
         -- only record assists for hearthlings that are in a combat stance
         local stance = self:get_stance(unit)
         if stance == 'defensive' or stance == 'aggressive' then
            self:_record_kill_stats_for_entity(unit, unit == attacker and 'kills' or 'assists', enemy_player, enemy_category, enemy_specifier, true)
         end
      end
      self:_record_notable_kill_for_entity(attacker, target)

      -- also add the stat to the attacker's equipment
      local equipment = attacker:get_component('stonehearth:equipment')
      if equipment then
         for _, piece in pairs(equipment:get_all_items()) do
            self:_record_kill_stats_for_entity(piece, 'kills', enemy_player, enemy_category, enemy_specifier, true)
            self:_record_notable_kill_for_entity(piece, target)
         end
      end
   end
end

function AceCombatService:_record_kill_stats_for_entity(entity, category, name, enemy_category, enemy_specifier, increment_totals)
   local stats_comp = entity:get_component('stonehearth_ace:statistics')

   if stats_comp then
      stats_comp:increment_stat(category, name)

      if enemy_category then
         stats_comp:increment_stat('category_' .. category, enemy_category)
      end

      if enemy_specifier then
         stats_comp:increment_stat('specific_' .. category, enemy_specifier)
      end

      if increment_totals then
         stats_comp:increment_stat('totals', category)
      end
   end
end

function AceCombatService:_record_notable_kill_for_entity(entity, target)
   local stats_comp = entity:get_component('stonehearth_ace:statistics')
   if stats_comp then
      local is_notable = radiant.entities.get_property_value(target, 'notable')
      if is_notable then
         stats_comp:add_to_stat_list('notable_kills', 'names', radiant.entities.get_custom_name(target))
      end
   end
end

-- Split exp among attacking player's combat units
function AceCombatService:distribute_exp(attacker, target, units)

   if stonehearth.player:is_npc(attacker) then
      -- no exp for npc players
      return
   end

   local attacker_player_id = get_player_id(attacker)
   local target_player_id = get_player_id(target)

   local attributes_component = target:get_component('stonehearth:attributes')
   local exp = attributes_component:get_attribute('exp_reward') or 0 -- exp given from killing target, default is 0
   if exp == 0 then -- if target gives no exp, no need to continue
      return
   end

   -- if player's citizen killed an enemy target then reward xp to nearby combat units
   if attacker_player_id ~= target_player_id then
      -- Get all combat units that we should give xp to
      local combat_units, num_nearby_combatants = self:_get_nearby_non_max_level_combat_units(target, attacker, units)
      if num_nearby_combatants <= 0 then
         num_nearby_combatants = 1
      end
       -- TODO(yshan): SHOULD we split exp reward with all nearby combat units? We tried it and xp was too low.
       -- Paul: only split part of the exp
      exp = math.floor((1 - EXP_SPLIT_AMOUNT) * exp + EXP_SPLIT_AMOUNT * exp / num_nearby_combatants)
      for _, combat_unit in pairs(combat_units) do
         local job_component = combat_unit:get_component('stonehearth:job')
         job_component:add_exp(exp)
         radiant.events.trigger_async(combat_unit, 'stonehearth:combat_exp_awarded', {exp_awarded = exp, attacker = attacker, target = target})
      end
   end
end

function AceCombatService:_notify_combat_participants(attacker, target, units)
   for _, unit in pairs(units) do
      radiant.events.trigger_async(unit, 'stonehearth:combat_participated', { attacker = attacker, target = target })
   end
end

function AceCombatService:_get_nearby_non_max_level_combat_units(target, attacker, units)
   local count = 0
   local combat_units = {}

   for id, unit in pairs(units) do
      local job_component = unit:get_component('stonehearth:job')
      if not job_component:is_max_level() and job_component:has_role('combat') then
         combat_units[id] = unit
         count = count + 1
      end
   end

   return combat_units, count
end

-- ACE: also include support for shared cooldowns
function CombatService:start_cooldown(entity, action_info)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:start_cooldown(action_info.name, action_info.cooldown)

   if action_info.shared_cooldown_name then
      combat_state:start_cooldown(action_info.shared_cooldown_name, action_info.shared_cooldown)
   end
end

function CombatService:in_cooldown(entity, action_name, shared_cooldown_name)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end

   return combat_state:in_cooldown(action_name, shared_cooldown_name)
end

function CombatService:get_cooldown_end_time(entity, action_name, shared_cooldown_name)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return nil
   end

   return combat_state:get_cooldown_end_time(action_name, shared_cooldown_name)
end

-- get the highest priority action that is ready now
-- assumes actions are sorted by descending priority
-- ACE: modifies filter_fn to consider any required equipment types
function AceCombatService:choose_attack_action(entity, actions)
   local filter_fn = function(combat_state, action_info)
      if not combat_state:in_cooldown(action_info.name, action_info.shared_cooldown_name) then
         -- check any equipment requirements
         if action_info.required_equipment then
            for slot, types in pairs(action_info.required_equipment) do
               local item = radiant.entities.get_equipped_item(entity, slot)
               local ep = item and item:add_component('stonehearth:equipment_piece')
               -- types is specified as an array of types, any one of which is acceptable
               local wants_no_item = not next(types) or (#types == 1 and types[1] == '')
               
               -- if there is an item equipped there, but there shouldn't be, or vice-versa
               if (ep and wants_no_item) or (not ep and not wants_no_item) then
                  return false
               end

               -- check if any of these types is present
               local found_type = false
               for _, eq_type in ipairs(types) do
                  -- if it allows for nothing equipped here and that's the case
                  -- or if it requires a specific type equipped and that's the case
                  if (not ep and eq_type == '') or (ep and ep:is_type(eq_type)) then
                     found_type = true
                     break
                  end
               end
               -- if it didn't find a valid type, it was no good
               -- we only return false early: true will get returned later if all conditions are met
               if not found_type then
                  return false
               end
            end
         end

         return true
      end
   end
   return self:_choose_combat_action(entity, actions, filter_fn)
end

-- get the highest priority action that can take effect before the impact_time
-- assumes actions are sorted by descending priority
-- ACE: add support for shared cooldowns
function CombatService:choose_defense_action(entity, actions, attack_impact_time)
   local filter_fn = function(combat_state, action_info)
      local ready_time = combat_state:get_cooldown_end_time(action_info.name, action_info.shared_cooldown_name) or radiant.gamestate.now()
      local defense_impact_time = ready_time + action_info.time_to_impact
      return defense_impact_time <= attack_impact_time
   end
   return self:_choose_combat_action(entity, actions, filter_fn)
end

-- Adds resistance to wounds
function AceCombatService:try_inflict_debuffs(target, debuff_list)
   local attributes = target:get_component('stonehearth:attributes')
	local debuff_resistance = attributes and attributes:get_attribute('debuff_resistance') or 0
   for i, debuff_data in ipairs(debuff_list) do
      for name, debuff in pairs(debuff_data) do
         local infliction_chance = debuff.chance or 1
         local n = 100 * infliction_chance
         local i = rng:get_int(1,100)
			if debuff.resistable and debuff_resistance ~= 0 then
				i = i + (debuff_resistance * 100)
			end
         if i <= n then
            target:add_component('stonehearth:buffs'):add_buff(debuff.uri)
         end
      end
   end
end

-- allow specifying locations for attack and target
function AceCombatService:has_potential_line_of_sight(attacker, target, attacker_location, target_location)
   local result = _physics:has_line_of_sight(attacker, target, attacker_location, target_location)
   return result
end

-- changed to take elevation into account, and allow specifying locations for attack and target
function AceCombatService:in_range(attacker, target, weapon, attacker_location, target_location)
   if not (target and target:is_valid()) then
      return false
   end

   attacker_location = attacker_location or attacker:add_component('mob'):get_world_grid_location()
   target_location = target_location or target:add_component('mob'):get_world_grid_location()
   if not (attacker_location and target_location) then
      return false
   end

   local range = self:get_weapon_range(attacker, weapon)
   return self:location_in_range(attacker_location, target_location, range)
end

function AceCombatService:location_in_range(attacker_location, target_location, range)
   -- weapon range is at same elevation
   -- R*sqrt(1+2*h/R), where R is normal weapon range and h is height difference
   local elevation_factor = attacker_location.y - target_location.y
   if elevation_factor >= 0.5 * range then
      return false
   end

   local adjusted_range = range * math.sqrt(1 + 2 * elevation_factor / range)

   local distance = Point3(attacker_location.x, 0, attacker_location.z):distance_to(Point3(target_location.x, 0, target_location.z))
   local result = distance <= adjusted_range
   return result
end

return AceCombatService