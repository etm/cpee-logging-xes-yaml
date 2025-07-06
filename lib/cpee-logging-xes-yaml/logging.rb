# This file is part of CPEE-LOGGING-XES-YAML.
#
# CPEE-LOGGING-XES-YAML is free software: you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# CPEE-LOGGING-XES-YAML is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for
# more details.
#
# You should have received a copy of the GNU Lesser General Public License along with
# CPEE-LOGGING-XES-YAML (file LICENSE in the main directory).  If not, see
# <http://www.gnu.org/licenses/>.

require 'rubygems'
require 'redis'
require 'json'
require 'yaml'
require 'riddl/server'
require 'time'

require_relative 'tools'

module CPEE
  module Logging

    SERVER = File.expand_path(File.join(__dir__,'logging.xml'))

    class Handler < Riddl::Implementation
      def response
        opts       = @a[0]
        type       = @p[0].value
        topic      = @p[1].value
        event_name = @p[2].value
        payload    = @p[3].value.read

        unless File.exist? File.join(opts[:log_dir],@h['CPEE_INSTANCE_UUID']+'.xes.yaml')
          notification = JSON.parse(payload)
          log = YAML::load(File.read(opts[:template]))
          log["log"]["trace"]["concept:name"] ||= notification['instance']
          log["log"]["trace"]["cpee:name"] ||= notification['instance-name'] if notification['instance-name']
          log["log"]["trace"]["cpee:instance"] ||= notification['instance-uuid']
          File.open(File.join(opts[:log_dir],@h['CPEE_INSTANCE_UUID']+'.xes.yaml'),'w'){|f| f.puts log.to_yaml}
        end

        EM.defer do
          CPEE::Logging::forward opts, topic, event_name, payload
        end if type == 'event'
        EM.defer do
          CPEE::Logging::doc opts, topic, event_name, payload
        end
        nil
      end
    end

    class Overview < Riddl::Implementation #{{{
      def response
        Riddl::Parameter::Complex.new("overview","text/xml") do
          <<-END
            <overview xmlns='http://riddl.org/ns/common-patterns/notifications-producer/2.0'>
              <topics/>
              <subscriptions/>
            </overview>
          END
        end
      end
    end #}}}

    class Topics < Riddl::Implementation #{{{
      def response
        opts = @a[0]
        Riddl::Parameter::Complex.new("overview","text/xml") do
          File.read(opts[:topics])
        end
      end
    end #}}}

    class Subscriptions < Riddl::Implementation #{{{
      def response
        opts = @a[0]
        Riddl::Parameter::Complex.new("subscriptions","text/xml") do
          ret = XML::Smart::string <<-END
            <subscriptions xmlns='http://riddl.org/ns/common-patterns/notifications-producer/2.0'/>
          END
          Dir.glob(File.join(opts[:notifications_dir],'*','subscription.xml')).each do |f|
            ret.root.add('subscription').tap do |n|
              n.attributes['id'] = File.basename(File.dirname(f))
              XML::Smart.open_unprotected(f) do |doc|
                n.attributes['url'] =  doc.root.attributes['url']
              end
            end
          end
          ret.to_s
        end
      end
    end #}}}

    class Subscription < Riddl::Implementation #{{{
      def response
        opts = @a[0]
        id = @r[-1]
        doc = XML::Smart::open_unprotected(File.join(opts[:notifications_dir],id,'subscription.xml'))
        doc.root.attributes['id'] = id
        Riddl::Parameter::Complex.new("subscriptions","text/xml",doc.to_s)
      end
    end #}}}

    def self::implementation(opts)
      opts[:log_dir]           ||= File.expand_path(File.join(__dir__,'logs'))
      opts[:notifications_dir] ||= File.expand_path(File.join(__dir__,'notifications'))
      opts[:template]          ||= File.expand_path(File.join(__dir__,'template.xes_yaml'))
      opts[:topics]            ||= File.expand_path(File.join(__dir__,'topics.xml'))
      opts[:subscriptions]     =  {}

      Dir.glob(File.join(opts[:notifications_dir],'*','subscription.xml')).each do |f|
        XML::Smart::open_unprotected(f) do |doc|
          doc.register_namespace :p, 'http://riddl.org/ns/common-patterns/notifications-producer/2.0'
          doc.find('/p:subscription/p:topic').each do |t|
            t.find('p:event').each do |e|
              opts[:subscriptions][t.attributes['id']+'/'+e.text] ||= []
              opts[:subscriptions][t.attributes['id']+'/'+e.text] << doc.root.attributes['url']
            end
          end
        end
      end

      Proc.new do
        interface 'events' do
          run Handler, opts if post 'event'
        end
        interface 'notifications' do
          on resource "notifications" do
            run Overview if get
            on resource "topics" do
              run Topics, opts if get
            end
            on resource "subscriptions" do
              run Subscriptions, opts if get
              run CreateSubscription, opts if post 'create_subscription'
              on resource do
                run Subscription, opts if get
                run UpdateSubscription, opts if put 'change_subscription'
                run DeleteSubscription, opts if delete
              end
            end
          end
        end
      end
    end

  end
end
