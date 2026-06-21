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

require 'redis'
require 'json'
require 'yaml'
require 'riddl/server'
require 'time'

require_relative 'tools'

module CPEE
  module Logging

    SERVER = File.expand_path(File.join(__dir__,'implementation.xml'))

    class HeaderAndFile #{{{
      def initialize(header, io)
        @header = header
        @io = io
        @position = 0
      end

      def read(length = nil, outbuf = nil)
        if @position < @header.bytesize
          data = read_header(length)

          if length && data.bytesize < length
            remaining_length = length - data.bytesize
            file_data = @io.read
            data << file_data if file_data
          end
        else
          data = @io.read(length)
        end

        return data.nil? || data.empty? && length ? nil : append_to_outbuf(data, outbuf)
      end

      def rewind
        @io&.rewind
        @position = 0 # returning position is the way rewind does it
      end

      def close
        @io&.close
        @io = nil
      end

      def read_header(length)
        chunk = if length
          @header.byteslice(@position, length)
        else
          @header.byteslice(@position..-1)
        end
        @position += chunk.bytesize
        chunk
      end
      private :read_header

      def append_to_outbuf(data, outbuf)
        outbuf ? outbuf.replace(data || '') : data
      end
      private :append_to_outbuf
    end #}}}

    class DownloadYAML < Riddl::Implementation
      def response
        opts = @a[0]
        fname = File.join(opts[:log_dir],@r[-1])
        if File.exist?(fname)
          io = File.open fname
          header = File.read(fname.sub(/yaml$/,'header')) if File.exist?(fname.sub(/yaml$/,'header'))
          Riddl::Parameter::Complex::new('log','text/yaml',HeaderAndFile.new(header || '',File.open(fname)))
        else
          @status = 404
        end
      end
    end

    class Handler < Riddl::Implementation
      def response
        opts       = @a[0]
        type       = @p[0].value
        topic      = @p[1].value
        event_name = @p[2].value
        payload    = @p[3].value.read

        ### we write headers into its own file. If race condition at first, no problemo
        unless File.exist? File.join(opts[:log_dir],@h['CPEE_INSTANCE_UUID'] + '.xes.header')
          notification = JSON.parse(payload)
          log = YAML::load(File.read(opts[:template]))
          log['log']['trace']['concept:name']                    ||= notification['instance']
          log['log']['trace']['cpee:name']                       ||= notification['instance-name'] if notification['instance-name']
          log['log']['trace']['cpee:instance']                   ||= notification['instance-uuid']
          log['log']['trace']['cpee:parent_instance']            ||= notification.dig('content','attributes','parent_instance').to_i       if notification.dig('content','attributes','parent_instance')
          log['log']['trace']['cpee:parent_instance_uuid']       ||= notification.dig('content','attributes','parent_instance_uuid')       if notification.dig('content','attributes','parent_instance_uuid')
          log['log']['trace']['cpee:parent_instance_model']      ||= notification.dig('content','attributes','parent_instance_model')      if notification.dig('content','attributes','parent_instance_model')
          log['log']['trace']['cpee:parent_instance_task_id']    ||= notification.dig('content','attributes','parent_instance_task_id')    if notification.dig('content','attributes','parent_instance_task_id')
          log['log']['trace']['cpee:parent_instance_task_label'] ||= notification.dig('content','attributes','parent_instance_task_label') if notification.dig('content','attributes','parent_instance_task_label')
          File.open(File.join(opts[:log_dir],@h['CPEE_INSTANCE_UUID']+'.xes.header'),'w'){|f| f.puts log.to_yaml}
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
        Riddl::Parameter::Complex.new('overview','text/xml') do
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
        Riddl::Parameter::Complex.new('overview','text/xml') do
          File.read(opts[:topics])
        end
      end
    end #}}}

    class Subscriptions < Riddl::Implementation #{{{
      def response
        opts = @a[0]
        Riddl::Parameter::Complex.new('subscriptions','text/xml') do
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
        Riddl::Parameter::Complex.new('subscriptions','text/xml',doc.to_s)
      end
    end #}}}

    def self::implementation(opts)
      opts[:log_dir]           ||= File.expand_path(File.join(__dir__,'logs'))
      opts[:notifications_dir] ||= File.expand_path(File.join(__dir__,'notifications'))
      opts[:template]          ||= File.expand_path(File.join(__dir__,'template.xes_yaml'))
      opts[:topics]            ||= File.expand_path(File.join(__dir__,'topics.xml'))
      opts[:subscriptions]     =  {}

      opts[:sse_keepalive_frequency]    ||= 10

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
        interface 'access' do
          on resource '[a-f0-9-]+.xes.yaml' do
            run DownloadYAML, opts if get
          end
          on resource '[a-f0-9-]+.xes.xml' do
            run DownloadXML, opts if get
          end
        end
        interface 'events' do
          run Handler, opts if post 'event'
        end
        interface 'notifications' do
          on resource 'notifications' do
            run Overview if get
            on resource 'topics' do
              run Topics, opts if get
            end
            on resource 'subscriptions' do
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
