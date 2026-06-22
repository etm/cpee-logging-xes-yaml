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

    TEMPLATE_XES_XML_START = <<-END
<log xmlns="http://www.xes-standard.org/" xes.version="2.0" xes.features="nested-attributes">
  <string key="creator" value="cpee.org"/>
  <extension name="Time" prefix="time" uri="http://www.xes-standard.org/time.xesext"/>
  <extension name="Concept" prefix="concept" uri="http://www.xes-standard.org/concept.xesext"/>
  <extension name="ID" prefix="id" uri="http://www.xes-standard.org/identity.xesext"/>
  <extension name="Lifecycle" prefix="lifecycle" uri="http://www.xes-standard.org/lifecycle.xesext"/>
  <extension name="CPEE" prefix="cpee" uri="http://cpee.org/cpee.xesext"/>
  <extension name="stream" prefix="stream" uri="https://cpee.org/datastream/datastream.xesext"/>
  <global scope="trace">
    <string key="concept:name" value="__NOTSPECIFIED__"/>
    <string key="cpee:name" value="__NOTSPECIFIED__"/>
  </global>
  <global scope="event">
    <string key="concept:name" value="__NOTSPECIFIED__"/>
    <string key="concept:instance" value="-1"/>
    <string key="concept:endpoint" value="__NOTSPECIFIED__"/>
    <string key="id:id" value="__NOTSPECIFIED__"/>
    <string key="lifecycle:transition" value="complete" />
    <string key="cpee:lifecycle:transition" value="activity/calling"/>
    <date key="time:timestamp" value="__NOTSPECIFIED__"/>
  </global>
    END
    TEMPLATE_XES_XML_TRC = <<-END
<trace xmlns="http://www.xes-standard.org/"/>
    END
    TEMPLATE_XES_XML_EVT = <<-END
<event xmlns="http://www.xes-standard.org/"/>
    END
    TEMPLATE_XES_XML_MID = <<-END
  <trace>
    END
    TEMPLATE_XES_XML_END = <<-END
  </trace>
</log>
    END

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

    class DownloadXML < Riddl::Implementation
      def self::rec_type(it) #{{{
        if it.is_a?(String) && it =~ /^[\dT:+.-]+$/ && (Time.parse(it) rescue nil)
          'x:date'
        elsif it.is_a? Float
          'x:float'
        elsif it.is_a? Integer
          'x:int'
        elsif it.is_a? String
          'x:string'
        end
      end #}}}

      def self::format_secs(s) #{{{
        return 'long' if s.infinite?
        s = s.to_i
        m = s / 60
        m < 0 ? "#{s}s" : "#{'%02d' % m}m #{'%02d' % (s%60)}s"
      end #}}}

      def self::rec_a_insert(event,node,level=0) #{{{
        event.each do |i|
          tnode = node
          case i
            when Hash
              tnode = node.add('x:list', 'key' => 'element')
              self::rec_insert(i,tnode,level+1)
            when Array
              tnode = node.add('x:list', 'key' => 'element')
              self::rec_insert(i,tnode,level+1)
            when String
              node.add(rec_type(i), 'key' => 'element', 'value' => (i.empty? ? "__UNSPECIFIED__" : i))
            when Integer, Float
              node.add(rec_type(i), 'key' => 'element', 'value' => i)
          end
        end
      end #}}}

      def self::rec_insert(event,node,level=0) #{{{
        event.each do |k,v|
          case v
            when String
              node.add(rec_type(v), 'key' => k, 'value' => (v.empty? ? "__UNSPECIFIED__" : v))
            when Integer
              node.add(rec_type(v), 'key' => k, 'value' => v)
            when Float
              node.add(rec_type(v), 'key' => k, 'value' => v)
            when Array
              tnode = node.add('x:list', 'key' => k)
              self::rec_a_insert(v,tnode,level+1)
            when Hash
              tnode = node.add('x:list', 'key' => k)
              self::rec_insert(v,tnode)
          end
        end
      end #}}}

      def response
        opts = @a[0]
        fname = File.join(opts[:log_dir],@r[-1]).sub(/xml$/,'yaml')
        if File.exist?(fname)
          body = StringIO.new

          body.write(TEMPLATE_XES_XML_START)

          io = File.open(fname)
          YAML.load_stream(io) do |e|
            if trace = e.dig('log','trace')
              xml = XML::Smart.string(TEMPLATE_XES_XML_TRC)
              xml.register_namespace 'x', 'http://www.xes-standard.org/'
              trace.each do |t,tv|
                xml.find('//x:trace').each do |ele|
                  ele.add('x:string', 'key' => t, 'value' => tv)
                end
              end
              body.write('  ' + xml.root.dump.gsub(/\n/,"\n  ") + "\n")
              body.write(TEMPLATE_XES_XML_MID)
            end
            if e.dig('event')
              xml = XML::Smart.string(TEMPLATE_XES_XML_EVT)
              xml.register_namespace 'x', 'http://www.xes-standard.org/'
              DownloadXML::rec_insert(e.dig('event'),xml.root)
              body.write('    ' + xml.root.dump.gsub(/\n/,"\n    ") + "\n")
            end
          end
          body.write(TEMPLATE_XES_XML_END)
          body.rewind

          Riddl::Parameter::Complex::new('log','application/xml',body)
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
