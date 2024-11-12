--
-- (C) 2021-24 - ntop.org
--

local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/alert_store/?.lua;" .. package.path

-- Import the classes library.
local classes = require "classes"

require "lua_utils"
local alert_store = require "alert_store"
local format_utils = require "format_utils"
local alert_consts = require "alert_consts"
local alert_utils = require "alert_utils"
local alert_entities = require "alert_entities"
local tag_utils = require "tag_utils"
local json = require "dkjson"

-- ##############################################

local interface_alert_store = classes.class(alert_store)

-- ##############################################

function interface_alert_store:init(args)
   self.super:init()

   if ntop.isClickHouseEnabled() then
      self._table_name = "interface_alerts_view"
      self._write_table_name = "interface_alerts"
      self._engaged_write_table_name = "engaged_interface_alerts"
   else
      self._table_name = "interface_alerts_view"
      self._write_table_name = "interface_alerts"
      self._engaged_write_table_name = "mem_db.engaged_interface_alerts"
   end

   self._alert_entity = alert_entities.interface
end

-- ##############################################

function interface_alert_store:_build_insert_query(alert, write_table, alert_status, extra_columns, extra_values)
   local name = getInterfaceName(alert.ifid)
   local alias = getHumanReadableInterfaceName(name)
   local subtype = alert.subtype or ''

   local insert_stmt = string.format("INSERT INTO %s "..
      "(%salert_id, alert_status, require_attention, interface_id, tstamp, tstamp_end, severity, score, ifid, subtype, name, alias, granularity, json) "..
      "VALUES (%s%u, %u, %u, %d, %u, %u, %u, %u, %d, '%s', '%s', '%s', %u, '%s'); ",
      write_table,
      extra_columns,
      extra_values,
      alert.alert_id,
      alert_status,
      ternary(alert.require_attention, 1, 0),
      self:_convert_ifid(interface.getId()),
      alert.tstamp,
      alert.tstamp_end,
      map_score_to_severity(alert.score),
      alert.score,
      self:_convert_ifid(alert.ifid),
      self:_escape(subtype),
      self:_escape(name),
      self:_escape(alias),
      alert.granularity,
      self:_escape(alert.json))

   return insert_stmt
end

-- ##############################################

--@brief Add filters according to what is specified inside the REST API
function interface_alert_store:_add_additional_request_filters()
   -- Add filters specific to the system family
   local subtype = _GET["subtype"]
   
   self:add_filter_condition_list('subtype', subtype)
end

-- ##############################################

--@brief Get info about additional available filters
function interface_alert_store:_get_additional_available_filters()
   local filters = {
      subtype = tag_utils.defined_tags.subtype,
   }

   return filters
end 

-- ##############################################

local RNAME = {
   ALERT_NAME = { name = "alert_name", export = true},
   SUBTYPE = { name = "subtype", export = true},
   DESCRIPTION = { name = "description", export = true},
   MSG = { name = "msg", export = true, elements = {"name", "value", "description"}}
}

function interface_alert_store:get_rnames()
   return RNAME
end

--@brief Convert an alert coming from the DB (value) to a record returned by the REST API
function interface_alert_store:format_record(value, no_html)
   local record = self:format_json_record_common(value, alert_entities.interface.entity_id, no_html)

   local alert_name = alert_consts.alertTypeLabel(tonumber(value["alert_id"]), no_html, alert_entities.interface.entity_id)
   local alert_fullname = alert_consts.alertTypeLabel(tonumber(value["alert_id"]), true, alert_entities.interface.entity_id)
   local subtype = value.subtype
   local alert_info = alert_utils.getAlertInfo(value)
   local msg = alert_utils.formatAlertMessage(interface.getId(), value, alert_info)

   record[RNAME.ALERT_NAME.name] = alert_name
   record[RNAME.SUBTYPE.name] = {
      value = subtype,
      name = getHumanReadableInterfaceName(subtype)
   }

   if string.lower(noHtml(msg)) == string.lower(noHtml(alert_name)) then
      msg = ""
   end

   if no_html then
      msg = noHtml(msg)
   end

   record[RNAME.DESCRIPTION.name] = msg

   record[RNAME.MSG.name] = {
     name = noHtml(alert_name),
     fullname = alert_fullname,
     value = tonumber(value["alert_id"]),
     description = msg,
     configset_ref = alert_utils.getConfigsetAlertLink(alert_info)
   }

   return record
end

-- ##############################################

return interface_alert_store
