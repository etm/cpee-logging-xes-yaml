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
      def doc(topic,event_name,log_dir,template,payload)
        notification = JSON.parse(payload)
        instance = notification['instance-uuid']
        return unless instance

        instancenr = notification['instance']
        content = notification['content']
        activity = content['activity']
        parameters = content['parameters']
        receiving = content['received']

        log = YAML::load(File.read(template))
        log["log"]["trace"]["concept:name"] ||= instancenr
        log["log"]["trace"]["cpee:name"] ||= notification['instance-name'] if notification['instance-name']
        log["log"]["trace"]["cpee:instance"] ||= instance
        File.open(File.join(log_dir,instance+'.xes.yaml'),'w'){|f| f.puts log.to_yaml} unless File.exists? File.join(log_dir,instance+'.xes.yaml')
        event = {}
        event["concept:instance"] = instancenr
        event["concept:name"] = content["label"] if content["label"]
        if content["endpoint"]
          event["concept:endpoint"] = content["endpoint"]
        end
        event["id:id"] = (activity.nil? || activity == "") ? 'external' : activity
        event["cpee:activity"] = event["id:id"]
        event["cpee:activity_uuid"] = content['activity-uuid'] if content['activity-uuid']
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
        event["cpee:state"] = content['state'] if content['state']
        event["cpee:description"] = content['dslx'] if content['dslx']
        unless parameters["arguments"]&.nil?
          event["data"] = parameters["arguments"]
        end
        if content['changed']&.any?
          event["data"] = content['values']
        end
        if receiving && !receiving.empty?
          event["raw"] = receiving
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
        notification  = @p[3].value.read
        EM.defer do
          doc topic, event_name, log_dir, template, notification
        end
        nil
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
