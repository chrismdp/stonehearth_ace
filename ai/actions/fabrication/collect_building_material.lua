--[[
   collect a building material for this building
   would it be better to allow them to collect many items at once, similar to crafting ingredients?
   if collecting multiple items, would definitely need some kind of reservation system, perhaps an orchestrator
]]

local Entity = _radiant.om.Entity
local CollectBuildingMaterial = radiant.class()
CollectBuildingMaterial.name = 'collect building material'
CollectBuildingMaterial.does = 'stonehearth_ace:collect_building_material'
CollectBuildingMaterial.status_text_key = 'stonehearth_ace:ai.actions.status_text.collect_building_material'
CollectBuildingMaterial.args = {
   building = Entity,
   material = 'string'
}
CollectBuildingMaterial.priority = {0, 1}

-- TODO: should these be in constants somewhere?
local MIN_BANKED = 50
local MAX_BANKED = 250

function CollectBuildingMaterial:start_thinking(ai, entity, args)
   local material = args.material
   local building = args.building
   local work_player_id = radiant.entities.get_work_player_id(entity)
   local building_comp = building:get_component('stonehearth:build2:building')
   local ready = false

   local bank_range = MAX_BANKED - MIN_BANKED

   local check_fn = function()
      local resources = building_comp:currently_building() and building_comp:get_remaining_resource_cost(entity)
      local now_ready = resources and resources[material] ~= nil
      if now_ready ~= ready then
         ready = now_ready
         if ready then
            -- also set the priority based on how many resources of that type are already banked
            local banked, prebanked = building_comp:get_banked_resource_count(material)
            local banked_pos = math.min(MAX_BANKED, math.max(MIN_BANKED, banked + prebanked)) - MIN_BANKED
            ai:set_utility(1 - (banked_pos / bank_range))
            ai:set_think_output({
               owner_player_id = work_player_id,
               resource_delivery_entity = building_comp:get_resource_delivery_entity(),   -- the resource delivery entity has the destination region for the building
            })
         else
            ai:clear_think_output()
         end
      end
   end
   check_fn()

   self._building_costs_changed_listener = radiant.events.listen(building, 'stonehearth:build2:costs_changed', check_fn)
   self._building_resumed_listener = radiant.events.listen(building, 'stonehearth_ace:building_resumed', check_fn)
end

function CollectBuildingMaterial:stop_thinking(ai, entity, args)
   self:_destroy_listeners()
end

function CollectBuildingMaterial:destroy()
   self:_destroy_listeners()
end

function CollectBuildingMaterial:_destroy_listeners()
   if self._building_costs_changed_listener then
      self._building_costs_changed_listener:destroy()
      self._building_costs_changed_listener = nil
   end
   if self._building_resumed_listener then
      self._building_resumed_listener:destroy()
      self._building_resumed_listener = nil
   end
end

local ai = stonehearth.ai
return ai:create_compound_action(CollectBuildingMaterial)
         :execute('stonehearth:abort_on_event_triggered', {
               source = ai.ENTITY,
               event_name = 'stonehearth:work_order:build:work_player_id_changed',
            })
         :execute('stonehearth:abort_on_event_triggered', {
               source = ai.ARGS.building,
               event_name = 'stonehearth_ace:building_paused',
            })
         :execute('stonehearth:maybe_drop_carrying_now', {
               material = ai.ARGS.material
            })
         :execute('stonehearth:pickup_item_made_of', {
               material = ai.ARGS.material,
               owner_player_id = ai.BACK(4).owner_player_id,
            })
         :execute('stonehearth:find_path_to_reachable_entity', {
               destination = ai.BACK(5).resource_delivery_entity,
            })
         :execute('stonehearth_ace:register_building_material_drop_off', {
               building = ai.ARGS.building,
               item = ai.BACK(2).item,
               material = ai.ARGS.material,
            })
         :execute('stonehearth:follow_path', {
               path = ai.BACK(2).path,
            })
         :execute('stonehearth_ace:drop_off_building_material', {
               building = ai.ARGS.building,
               material = ai.ARGS.material,
            })
