--
-- (C) 2021-24 - ntop.org
--

local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/?.lua;" .. package.path
package.path = dirs.installdir .. "/scripts/lua/modules/alert_store/?.lua;" .. package.path

-- Import the classes library.
local classes = require "classes"

require "lua_utils"
local alert_store = require "alert_store"
local format_utils = require "format_utils"
local alert_consts = require "alert_consts"
local alert_utils = require "alert_utils"
local alert_entities = require "alert_entities"
local json = require "dkjson"

-- ##############################################

local am_alert_store = classes.class(alert_store)

-- ##############################################

function am_alert_store:init(args)
   self.super:init()

   if ntop.isClickHouseEnabled() then
      self._table_name = "active_monitoring_alerts_view"
      self._write_table_name = "active_monitoring_alerts"
      self._engaged_write_table_name = "engaged_active_monitoring_alerts"
   else
      self._table_name = "active_monitoring_alerts_view"
      self._write_table_name = "active_monitoring_alerts"
      self._engaged_write_table_name = "mem_db.engaged_active_monitoring_alerts"
   end

   self._alert_entity = alert_entities.am_host
end

-- ##############################################

--@brief ifid
function am_alert_store:get_ifid()
   return getSystemInterfaceId()
end

-- ##############################################

function am_alert_store:_build_insert_query(alert, write_table, alert_status, extra_columns, extra_values)
   local resolved_ip
   local resolved_name
   local measurement
   local measure_threshold
   local measure_value

   if not isEmptyString(alert.json) then
      local am_json = json.decode(alert.json)
      if am_json then
         resolved_ip = am_json.ip
         if am_json.host then
            resolved_name = am_json.host.host
	         measurement = am_json.host.measurement or am_json.measurement
         end
         measure_threshold = am_json.threshold
         measure_value = am_json.value
      end
   end

   local insert_stmt = string.format("INSERT INTO %s "..
      "(%salert_id, alert_status, require_attention, interface_id, tstamp, tstamp_end, severity, score, resolved_ip, resolved_name, "..
      "measurement, measure_threshold, measure_value, json) "..
      "VALUES (%s%u, %u, %u, %d, %u, %u, %u, %u, '%s', '%s', '%s', %u, %f, '%s'); ",
      write_table, 
      extra_columns,
      extra_values,
      alert.alert_id,
      alert_status,
      ternary(alert.require_attention, 1, 0),
      self:_convert_ifid(getSystemInterfaceId()),
      alert.tstamp,
      alert.tstamp_end,
      map_score_to_severity(alert.score),
      alert.score,
      self:_escape(resolved_ip),
      self:_escape(resolved_name),
      self._escape(measurement),
      measure_threshold or 0,
      measure_value or 0,
      self:_escape(alert.json))

   -- traceError(TRACE_NORMAL, TRACE_CONSOLE, insert_stmt)

   return interface.alert_store_query(insert_stmt)
end

-- ##############################################

--@brief Add filters according to what is specified inside the REST API
function am_alert_store:_add_additional_request_filters()
   -- Add filters specific to the active monitoring family
end

-- ##############################################

local RNAME = {
   ALERT_NAME = { name = "alert_name", export = true},
   MEASUREMENT = { name = "measurement", export = true},
   MEASURE_THRESHOLD = { name = "measure_threshold", export = true},
   MEASURE_VALUE = { name = "measure_value", export = true},
   DESCRIPTION = { name = "description", export = true},
   MSG = { name = "msg", export = true, elements = {"name", "value", "description"}},
   LINK_TO_PAST_FLOWS = { name = "link_to_past_flows", export = true},
}

function am_alert_store:get_rnames()
   return RNAME
end

-- ##############################################

--@brief Convert an alert coming from the DB (value) to a record returned by the REST API
function am_alert_store:format_record(value, no_html)
   local am_utils = require "am_utils"
   local record = self:format_json_record_common(value, alert_entities.am_host.entity_id, no_html)

   local alert_info = alert_utils.getAlertInfo(value)
   local alert_name = alert_consts.alertTypeLabel(tonumber(value["alert_id"]), no_html, alert_entities.am_host.entity_id)
   local alert_fullname = alert_consts.alertTypeLabel(tonumber(value["alert_id"]), true, alert_entities.am_host.entity_id)
   local msg = alert_utils.formatAlertMessage(ifid, value, alert_info)

   if alert_info.threshold and alert_info.threshold > 0 then
      record[RNAME.MEASURE_THRESHOLD.name] = format_utils.formatValue(alert_info.threshold)
   end

   if alert_info.value and alert_info.value > 0 then
      record[RNAME.MEASURE_VALUE.name] = alert_info.value
   end

   local measurement_info = am_utils.getMeasurementInfo(alert_info.host.measurement or alert_info.measurement)
   if measurement_info then
      record[RNAME.MEASUREMENT.name] = i18n(measurement_info.i18n_label)
   end

   record[RNAME.ALERT_NAME.name] = alert_name

   if string.lower(noHtml(msg)) == string.lower(noHtml(alert_name)) then
      msg = ""
   end

   record[RNAME.DESCRIPTION.name] = msg
   if (not isEmptyString(alert_info.host)) then
      local tmp_table = table.merge(value,{ip = alert_info.host})
      record[RNAME.LINK_TO_PAST_FLOWS.name] = alert_utils.getLinkToPastFlows(ifid, tmp_table, alert_info)
   end
   record[RNAME.MSG.name] = {
     name = noHtml(alert_name),
     fullname = alert_fullname,
     value = tonumber(value["alert_id"]),
     description = msg,
     configset_ref = alert_utils.getConfigsetAlertLink(alert_info, value, alert_entities.am_host.entity_id)
   }

   return record
end

-- ##############################################

return am_alert_store
