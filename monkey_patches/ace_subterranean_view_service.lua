local constants = require 'constants'
local csg_lib = require 'lib.csg.csg_lib'
local Point3 = _radiant.csg.Point3
local Cube3 = _radiant.csg.Cube3
local Region3 = _radiant.csg.Region3
local RegionCollisionType = _radiant.om.RegionCollisionShape
local TraceCategories = _radiant.dm.TraceCategories
local log = radiant.log.create_logger('subterranean_view')

local SubterraneanViewService = radiant.mods.require('stonehearth.services.client.subterranean_view.subterranean_view_service')
local AceSubterraneanViewService = class()

function AceSubterraneanViewService:terrain_slice_buildings_setting_changed()
   if self.clip_enabled then
      self:_update_all_entities_visibility()
      self:_update_dirty_tiles()
      self._visible_volume_dirty = true
   end
end

AceSubterraneanViewService._ace_old__calculate_visibility = SubterraneanViewService._calculate_visible
function AceSubterraneanViewService:_calculate_visible(entity, ignore_entities, terrain_slice_buildings)
   local call_old
   if ignore_entities then
      call_old = true
   else
      terrain_slice_buildings = terrain_slice_buildings or stonehearth_ace.gameplay_settings:get_gameplay_setting('stonehearth_ace', 'terrain_slice_buildings')
      if not terrain_slice_buildings then
         call_old = true
      end
   end

   if call_old then
      return self:_ace_old__calculate_visibility(entity, ignore_entities)
   end
   
   local mob = entity:get_component('mob')
   local parent = mob and mob:get_parent()

   if not parent then
      -- not in the world, just default to true
      return true
   end

   if not parent:get_component('terrain') then
      -- not a child of the terrain, let our ancestors decide visibility
      return self:_calculate_visible(parent, nil, terrain_slice_buildings)
   end

   -- our parent is the terrain entity, test to see if we're on a visible block
   local location = mob:get_world_grid_location()
   local in_visible_volume = self:_is_in_visible_volume(location)

   if in_visible_volume then
      return true
   end

   return false
end

function AceSubterraneanViewService:_create_entity_traces()
   local entity_container = self:_get_root_entity_container()

   self._entity_container_trace = entity_container:trace_children('subterranean view')
      :on_added(function(id, entity)
            -- ACE: if the entity was already destroyed, it will be nil here
            if self._entity_traces[id] or not entity then
               -- trace already exists
               return
            end

            local location_trace = radiant.entities.trace_grid_location(entity, 'subterranean view')
               :on_changed(function()
                     if self.xray_mode or self.clip_enabled then
                        self:_update_visiblity(entity)
                     end
                  end)
               :push_object_state()

            local parent_trace = entity:add_component('mob'):trace_parent('subterranean view')
               :on_changed(function()
                     if self.xray_mode or self.clip_enabled then
                        self:_update_visiblity(entity)
                     end
                  end)

            self._entity_traces[id] = {
               location = location_trace,
               parent = parent_trace,
            }

            self:_update_visiblity(entity)
         end)
      :on_removed(function(id, entity)
            self:_destroy_entity_traces(id)
         end)
      :push_object_state()
end

return AceSubterraneanViewService
