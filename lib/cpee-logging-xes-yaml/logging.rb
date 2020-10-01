# This file is part of CPEE-LOGGING-XES-YAML.
#
# CPEE-LOGGING-XES-YAML is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# CPEE-LOGGING-XES-YAML is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with
# CPEE-LOGGING-XES-YAML (file LICENSE in the main directory).  If not, see
# <http://www.gnu.org/licenses/>.

require 'rubygems'
require 'redis'
require 'json'
require 'yaml'
require 'riddl/server'
require 'time'

module CPEE
  module Logging

    SERVER = File.expand_path(File.join(__dir__,'logging.xml'))

    class Handler < Riddl::Implementation #{{{
      def doc(topic,event_name,log_dir,template,instancenr,notification)
        instance = notification['instance_uuid']
        return unless instance

        activity = notification['activity']
        parameters = notification['parameters']
        receiving = notification['received']

        log = YAML::load(File.read(template))
        log["log"]["trace"]["concept:name"] ||= instancenr
        log["log"]["trace"]["cpee:name"] ||= notification['instance_name'] if notification['instance_name']
        log["log"]["trace"]["cpee:instance"] ||= instance
        File.open(File.join(log_dir,instance+'.xes.yaml'),'w'){|f| f.puts log.to_yaml} unless File.exists? File.join(log_dir,instance+'.xes.yaml')
        event = {}
        event["concept:instance"] = instancenr
        event["concept:name"] = notification["label"] if notification["label"]
        if notification["endpoint"]
          event["concept:endpoint"] = notification["endpoint"]
        end
        event["id:id"] = (activity.nil? || activity == "") ? 'external' : activity
        event["cpee:activity"] = event["id:id"]
        event["cpee:activity_uuid"] = notification['activity_uuid'] if notification['activity_uuid']
        event["cpee:instance"] = instance
        case event_name
          when 'receiving', 'change', 'instantiation'
            event["lifecycle:transition"] = "unknown"
          when 'done'
            event["lifecycle:transition"] = "complete"
          else
            event["lifecycle:transition"] = "start"
        end
        event["cpee:lifecycle:transition"] = "#{topic}/#{event_name}"
        data_send = ((parameters["arguments"].nil? ? [] : parameters["arguments"]) rescue [])
        event["data"] = {"data_send" => data_send} unless data_send.empty?
        if notification['changed']&.any?
          if event.has_key? "data"
            event["data"]["data_changed"] ||= notification['changed']
          else
            event["data"] = {"data_changer" => notification['changed']}
          end
        end
        if notification['values']&.any?
          if event.has_key? "data"
            event["data"]["data_values"] ||= notification['values']
          else
            event["data"] = {"data_values" => notification['values']}
          end
        end
        unless receiving&.empty?
          if event.has_key? "data"
            event["data"]["data_received"] ||= receiving
          else
            event["data"] = {"data_receiver" => receiving}
          end
        end
        event["time:timestamp"]= event['cpee:timestamp'] || Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L%:z")
        File.open(File.join(log_dir,instance+'.xes.yaml'),'a') do |f|
          f << {'event' => event}.to_yaml
        end
        nil
      end

      def response
        topic         = @p[1].value
        event_name    = @p[2].value
        log_dir       = @a[0]
        template      = @a[1]
        instancenr    = @h['CPEE_INSTANCE_URL'].split('/').last
        notification  = JSON.parse(@p[3].value)
        doc topic, event_name, log_dir, template, instancenr, notification
      end
    end #}}}

    def self::implementation(opts)
      opts[:log_dir] ||= File.join(__dir__,'logs')
      opts[:template] ||= File.join(__dir__,'template.xes_yaml')

      Proc.new do
        interface 'events' do
          run Handler, opts[:log_dir], opts[:template] if post 'event'
        end
      end
    end

  end
end
