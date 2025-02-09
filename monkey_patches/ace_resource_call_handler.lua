--[[
   this file patches the existing resource_call_handler.lua file to adjust functions in there
   we also have our own resource_call_handler.lua file that must be separate in order to be in the stonehearth_ace namespace for our own functions
]]

local entity_forms_lib = require 'stonehearth.lib.entity_forms.entity_forms_lib'
local validator = radiant.validator

local AceResourceCallHandler = class()

--Return true for entities that are clearable: resource nodes, materials,
--any furniture that is iconic, tools, and placed items.
function AceResourceCallHandler:_is_clearable(entity, player_id)
   if radiant.entities.is_owned_by_another_player(entity, player_id) then
      -- don't delete stuff you don't own
      return false
   end

   if entity:get_component('terrain') then
      -- don't delete terrain
      return false
   end

   if entity:get_component('stonehearth:ghost_form') then
      -- don't delete ghost
      return false
   end

   if entity:get_component('stonehearth_ace:interaction_proxy') then
      -- don't delete interaction proxies
      return false
   end

   local entity_data = radiant.entities.get_entity_data(entity, 'stonehearth:item')

   if entity_data and entity_data.clearable == false then
      return false
   end

   local root, iconic = entity_forms_lib.get_forms(entity)
   if iconic then
      entity_data = radiant.entities.get_entity_data(iconic, 'stonehearth:item')
      if entity_data and entity_data.clearable == false then
         return false
      end
   end

   return true
end

-- added setting auto-loot player id
function AceResourceCallHandler:harvest_entity(session, response, entity, from_harvest_tool)
   validator.expect_argument_types({'Entity', validator.optional('boolean')}, entity, from_harvest_tool)   

   local town = stonehearth.town:get_town(session.player_id)

   local renewable_resource_node = entity:get_component('stonehearth:renewable_resource_node')
   local resource_node = entity:get_component('stonehearth:resource_node')

   if renewable_resource_node and renewable_resource_node:get_harvest_overlay_effect() and renewable_resource_node:is_harvestable() then
      renewable_resource_node:request_harvest(session.player_id)
   elseif resource_node then
      -- check that entity can be harvested using the harvest tool
      if not from_harvest_tool or resource_node:is_harvestable_by_harvest_tool() then
         local loot_drops = entity:get_component('stonehearth:loot_drops')
         if loot_drops then
            loot_drops:set_auto_loot_player_id(session.player_id)
         end
         resource_node:request_harvest(session.player_id)
      end
   end
end

return AceResourceCallHandler
