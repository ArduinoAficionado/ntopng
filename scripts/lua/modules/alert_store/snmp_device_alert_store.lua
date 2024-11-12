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
local snmp_utils = require "snmp_utils"
local tag_utils = require "tag_utils"
local json = require "dkjson"

-- ##############################################

local snmp_device_alert_store = classes.class(alert_store)

-- ##############################################

function snmp_device_alert_store:init(args)
   self.super:init()

   if ntop.isClickHouseEnabled() then
      self._table_name = "snmp_alerts_view"
      self._write_table_name = "snmp_alerts"
      self._engaged_write_table_name = "engaged_snmp_alerts"
   else
      self._table_name = "snmp_alerts_view"
      self._write_table_name = "snmp_alerts"
      self._engaged_write_table_name = "mem_db.engaged_snmp_alerts"
   end

   self._alert_entity = alert_entities.snmp_device
end

-- ##############################################

--@brief ifid
function snmp_device_alert_store:get_ifid()
   return getSystemInterfaceId()
end

-- ##############################################

function snmp_device_alert_store:_entity_val_to_ip_and_port(entity_val)
   local ip, port

   local ip_port = string.split(entity_val, "_ifidx")
   if ip_port and #ip_port > 1 then
      -- Device IP and interface
      ip = ip_port[1]
      port = tonumber(ip_port[2])
   else
      -- Device IP only
      ip = entity_val
   end

   return ip, port
end

-- ##############################################

function snmp_device_alert_store:_build_insert_query(alert, write_table, alert_status, extra_columns, extra_values)
   local device_ip
   local device_name
   local port
   local port_name

   if not isEmptyString(alert.json) then
      local snmp_json = json.decode(alert.json)
      if snmp_json then
         device_ip = snmp_json.device

         device_name = snmp_json.device_name
         if (isEmptyString(device_name)) then
            device_name = snmp_device_alert_store:get_snmp_device_sysname(device_ip)
         end
         port = snmp_json.interface
         port_name = snmp_json.interface_name
      end
   end

   if isEmptyString(device_ip) then
      -- Extract them from the entity value
      device_ip, port = self:_entity_val_to_ip_and_port(alert.entity_val)
   end

   local insert_stmt = string.format("INSERT INTO %s "..
      "(%salert_id, alert_status, require_attention, interface_id, tstamp, tstamp_end, severity, score, ip, name, port, port_name, json) "..
      "VALUES (%s%u, %u, %u, %d, %u, %u, %u, %u, '%s', '%s', %u, '%s', '%s'); ",
      write_table,
      extra_columns or "",
      extra_values or "",
      alert.alert_id,
      alert_status,
      ternary(alert.require_attention, 1, 0),
      self:_convert_ifid(interface.getId()),
      alert.tstamp,
      alert.tstamp_end,
      map_score_to_severity(alert.score),
      alert.score,
      self:_escape(device_ip or alert.entity_val),
      self:_escape(device_name or ""),
      tonumber(port) or 0,
      self:_escape(port_name or ""),
      self:_escape(alert.json)
   )

   return insert_stmt
end

-- ##############################################

--@brief Add filters according to what is specified inside the REST API
function snmp_device_alert_store:_add_additional_request_filters()
   local ip = _GET["ip"]
   local port = _GET["snmp_interface"]

   self:add_filter_condition_list('ip', ip)

   --  self:add_filter_condition_list('port', port, 'number')
   self:add_filter_condition_list('snmp_interface', port)
end

-- ##############################################

--@brief Get info about additional available filters
function snmp_device_alert_store:_get_additional_available_filters()
   local filters = {
      ip             = tag_utils.defined_tags.ip,
      snmp_interface = tag_utils.defined_tags.snmp_interface,
   }

   return filters
end 

-- ##############################################

local RNAME = {
   IP = { name = "ip", export = true},
   NAME = { name = "name", export = true},
   PORT = { name = "port", export = true, elements = {"value", "label"}},
   ALERT_NAME = { name = "alert_name", export = true},
   DESCRIPTION = { name = "description", export = true},
   MSG = { name = "msg", export = true, elements = {"name", "value", "description"}}
}

function snmp_device_alert_store:get_rnames()
   return RNAME
end

function snmp_device_alert_store:get_snmp_device_sysname(ip)
   return snmp_utils.get_snmp_device_sysname(ip) or ""
end

-- ##############################################

--@brief Convert an alert coming from the DB (value) to a record returned by the REST API
function snmp_device_alert_store:format_record(value, no_html, is_engaged)
   -- This is an in-memory engaged alert, let's extract the ip and the port from the entity_val
   -- if are not present already in memory
   value["port"] = tonumber(value["port"])
   if (is_engaged and (isEmptyString(value["ip"]) or value["port"] == 0)) then
      value["ip"], value["port"] = self:_entity_val_to_ip_and_port(value["entity_val"])
   end

   -- Suppress zero ports
   if value["port"] == 0 then
      value["port"] = ""
      value["port_name"] = ""
   else
      -- get port name from json info
      local json_info = json.decode(value["json"])
      if (json_info) then
         value["port_name"] = json_info.interface_name
      end
   end

   -- If there's no port name stored, use the id
   if isEmptyString(value["port_name"]) then
      value["port_name"] = value["port"]
   end

   local device_name = value["name"]
   if (isEmptyString(device_name)) then
      device_name = snmp_device_alert_store:get_snmp_device_sysname(value["ip"])
   end

   local record = self:format_json_record_common(value, alert_entities.snmp_device.entity_id, no_html)

   local alert_info = alert_utils.getAlertInfo(value)
   local alert_name = alert_consts.alertTypeLabel(tonumber(value["alert_id"]), no_html, alert_entities.snmp_device.entity_id)
   local alert_fullname = alert_consts.alertTypeLabel(tonumber(value["alert_id"]), true, alert_entities.snmp_device.entity_id)
   local msg = alert_utils.formatAlertMessage(ifid, value, alert_info)

   record[RNAME.IP.name] = value["ip"]
   record[RNAME.NAME.name] = device_name
   record[RNAME.PORT.name] = {
      value = value["port"],
      label = value["port_name"]
   }
   
   local alert_snmp_trap_id = 4096 + 36 -- See scripts/lua/modules/alert_keys/other_alert_keys.lua

   if tonumber(value["alert_id"]) == alert_snmp_trap_id then
      record.disable_info = true
   end

   record[RNAME.ALERT_NAME.name] = alert_name

   if string.lower(noHtml(msg)) == string.lower(noHtml(alert_name)) then
      msg = ""
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

return snmp_device_alert_store
