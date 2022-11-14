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

require_relative 'tools'

module CPEE
  module Logging

    SERVER = File.expand_path(File.join(__dir__,'logging.xml'))

    class Handler < Riddl::Implementation
      def response
        topic         = @p[1].value
        event_name    = @p[2].value
        log_dir       = @a[0]
        template      = @a[1]
        notification  = @p[3].value.read
        EM.defer do
          CPEE::Logging::doc topic, event_name, log_dir, template, notification
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


    def self::implementation(opts)
      opts[:log_dir]           ||= File.expand_path(File.join(__dir__,'logs'))
      opts[:notifications_dir] ||= File.expand_path(File.join(__dir__,'notifications'))
      opts[:template]          ||= File.expand_path(File.join(__dir__,'template.xes_yaml'))
      opts[:topics]            ||= File.expand_path(File.join(__dir__,'topics.xml'))

      Proc.new do
        interface 'events' do
          run Handler, opts[:log_dir], opts[:template] if post 'event'
        end
        interface 'notifications' do
          on resource "notifications" do
            run Overview if get
            on resource "topics" do
              run Topics, opts if get
            end
            on resource "subscriptions" do
              run Subscriptions, id, opts if get
              run CreateSubscription, id, opts if post 'create_subscription'
              on resource do
                run Subscription, id, opts if get
                run UpdateSubscription, id, opts if put 'change_subscription'
                run DeleteSubscription, id, opts if delete
              end
            end
          end
        end
      end
    end

  end
end
