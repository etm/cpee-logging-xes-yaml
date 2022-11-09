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

matze = 'localhostr:9318'

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
