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

require 'weel'
require 'digest/sha1'

class StreamPoint
  attr_accessor :value, :timestamp, :source, :meta, :id

  def initialize(id=nil)
    @id = id
    @value = nil
    @timestamp = Time.now
    @source = nil
    @meta = nil
  end

  def to_h
    tp = { }
    tp['stream:id'] = @id
    tp['stream:value'] = @value
    tp['stream:timestamp'] = @timestamp
    tp['stream:source'] = @source unless @source.nil?
    tp['stream:meta'] = @meta unless @meta.nil?
    tp
  end
end
class Stream
  attr_accessor :id, :source, :meta
  attr_reader :name

  def initialize(name)
    @name = name
    @id = nil
    @source = nil
    @meta = nil
    @values = []
  end

  def <<(val)
    @values << val
  end

  def to_list
    tp = []
    tp << {'stream:name' => @name}
    tp << {'stream:id' => @id} unless @id.nil?
    tp << {'stream:source' => @source} unless @source.nil?
    tp << {'stream:meta' => @meta} unless @meta.nil?
    @values.each do |e|
      if e.is_a? Stream
        e.source = @source if e.source.nil? && !@source.nil?
        tp << { 'stream:datastream' => e.to_list }
      elsif e.is_a? StreamPoint
        e.source = @source if e.source.nil? && !@source.nil?
        tp << { 'stream:point' => e.to_h }
      end
    end
    tp
  end
end

module CPEE
  module Logging

    def self::notify(opts,topic,event_name,payload)
      opts[:subscriptions].each do |e,urls|
        if e == topic + '/' + event_name
          urls.each do |url|
            client = Riddl::Client.new(url)
            client.post [
              Riddl::Parameter::Simple::new('type','event'),
              Riddl::Parameter::Simple::new('topic',topic),
              Riddl::Parameter::Simple::new('event',event_name),
              Riddl::Parameter::Complex::new('notification','application/json',payload)
            ]
          end
        end
      end
    end

    def self::val_merge(target,val,tid,tso)
      if val.is_a? Stream
        val.source = tso if val.source.nil?
        target.push *val.to_list
      else
        tp = nil
        if val.is_a? StreamPoint
          tp = val
          tp.id = tid if tp.id.nil?
          tp.source = tso if tp.source.nil?
        else
          tp = StreamPoint.new(tid)
          tp.source =  tso
          tp.value = val
        end
        target << { 'stream:point' => tp.to_h }
      end
    end

    def self::extract_probes(where,xml)
      XML::Smart::string(xml) do |doc|
        doc.register_namespace 'd', 'http://cpee.org/ns/description/1.0'
        doc.find('//d:call').each do |c|
          File.unlink(where + '_' + c.attributes['id'] + '.probe') rescue nil
          c.find('d:annotations/d:_context_data_analysis/d:probes[d:probe]').each do |p|
            File.write(where + '_' + c.attributes['id'] + '.probe', p.dump)
          end
        end
      end
    end
    def self::extract_annotations(where,xml)
      ret = {}
      XML::Smart::string(xml) do |doc|
        doc.register_namespace 'd', 'http://cpee.org/ns/description/1.0'
        doc.find('/d:description | //d:call').each do |c|
          tid = c.attributes['id'] || 'start'
          fname = where + '_' + tid + '.anno'
          nset = if tid == 'start'
            c.find('d:*[starts-with(name(),"_")]')
          else
            c.find('d:annotations')
          end
          nset.each do |p|
            anno = p.dump
            ret[tid] ||= []
            ret[tid] << anno
          end
          if ret[tid]
            if ret[tid].length > 1
              ret[tid] = "<annotations xmlns=\"http://cpee.org/ns/description/1.0\">\n" +
                ret[tid].join("\n") + "\n" +
                '</annotations>'
            else
              ret[tid] = ret[tid][0]
            end
            hash = Digest::SHA1.hexdigest(ret[tid])
            if !File.exist?(fname) || (File.exist?(fname) && File.read(fname) !=  hash)
              File.write(fname,hash)
            end
          end
        end
      end
      ret
    end

    def self::extract_result(result)
      ret = result.map do |res|
        if res['mimetype'].nil?
          res['value']
        elsif res['mimetype'] == 'application/json'
          JSON::parse(res['data'])
        elsif res['mimetype'] == 'application/xml' || res['mimetype'] == 'text/xml'
          XML::Smart::string(res['data']) rescue nil
        elsif res['mimetype'] == 'text/yaml'
          YAML::load(res['data']) rescue nil
        elsif res['mimetype'] == 'text/plain'
          t = res['data']
          if t.start_with?('<?xml version=')
            t = XML::Smart::string(t)
          else
            t = t.to_f if t == t.to_f.to_s
            t = t.to_i if t == t.to_i.to_s
          end
          t
        elsif res['mimetype'] == 'text/html'
          t = res['data']
          t = t.to_f if t == t.to_f.to_s
          t = t.to_i if t == t.to_i.to_s
          t
        else
          res['data']
        end
      end
      ret.length == 1 ? ret[0] : ret
    end

    def self::extract_sensor(rs,code,pid,result)
      rs.instance_eval(code,'probe',1)
    rescue => e
      e.backtrace[0].gsub(/(\w+):(\d+):in.*/,'Probe ' + pid + ' Line \2: ') + e.message
    end

    def self::persist_values(where,values)
      unless File.exist?(where)
        File.write(where,'{}')
      end
      f = File.open(where,'r+')
      f.flock(File::LOCK_EX)
      json = JSON::load(f) || {}
      json.merge!(values)
      f.rewind
      f.truncate(0)
      f.write(JSON.generate(json))
      f.close
    end

    def self::forward(opts,topic,event_name,payload)
      if topic == 'state' && event_name == 'change'
        self::notify(opts,topic,event_name,payload)
      elsif topic == 'state' && event_name == 'change'
        self::notify(opts,topic,event_name,payload)
      elsif topic == 'gateway' && event_name == 'join'
        self::notify(opts,topic,event_name,payload)
      end
    end

    def self::doc(opts,topic,event_name,payload)
      notification = JSON.parse(payload)
      instance = notification['instance-uuid']
      return unless instance

      log_dir = opts[:log_dir]
      template = opts[:template]

      instancenr = notification['instance']

      content = notification['content']
      activity = content['activity']
      parameters = content['parameters']
      receiving = content['received']

      if content['dslx']
        CPEE::Logging::extract_probes(File.join(log_dir,instance),content['dslx'])
        CPEE::Logging::extract_annotations(File.join(log_dir,instance),content['dslx']).each do |k,v|
          so = Marshal.load(Marshal.dump(notification))
          so['content'].delete('dslx')
          so['content'].delete('dsl')
          so['content'].delete('description')
          so['content']['annotation'] = v
          so['content']['activity'] = k
          so['topic'] = 'annotation'
          so['name'] = 'change'
          EM.defer do
            self::notify(opts,'annotation','change',so.to_json)
          end
        end
      end

      if topic == 'dataelements' && event_name == 'change'
        if content['changed']&.any?
          CPEE::Logging::persist_values(File.join(log_dir,instance + '.data.json'),content['values'])
        end
      end

      event = {}
      event['concept:instance'] = instancenr
      event['concept:name'] = content['label'] if content['label']
      if content['endpoint']
        event['concept:endpoint'] = content['endpoint']
      end
      event['id:id'] = (activity.nil? || activity == '') ? 'external' : activity
      event['cpee:activity'] = event['id:id']
      event['cpee:activity_uuid'] = content['activity-uuid'] if content['activity-uuid']
      event['cpee:instance'] = instance
      case event_name
        when 'calling'
          event['lifecycle:transition'] = 'start'
        when 'done'
          event['lifecycle:transition'] = 'complete'
        else
          event['lifecycle:transition'] = 'unknown'
      end
      event['cpee:lifecycle:transition'] = "#{topic}/#{event_name}"
      event['cpee:state'] = content['state'] if content['state']
      event['cpee:description'] = content['dslx'] if content['dslx']
      event['cpee:change_uuid'] = content['change_uuid'] if content['change_uuid']
      event['cpee:exposition'] = content['exposition'] if content['exposition']
      unless parameters['arguments']&.nil?
        event['data'] = parameters['arguments']
      end if parameters
      if content['changed']&.any?
        event['data'] = content['values'].map do |k,v|
          { 'name' => k, 'value' => v }
        end

        fname = File.join(log_dir,instance + '_' + event['id:id'] + '.probe')
        dname = File.join(log_dir,instance + '.data.json')

        if File.exist?(fname)
          rs = WEEL::ReadStructure.new(File.exist?(dname) ? JSON::load(File::open(dname)) : {},{},{},{})
          XML::Smart::open_unprotected(fname) do |doc|
            doc.register_namespace 'd', 'http://cpee.org/ns/description/1.0'
            doc.find('//d:probe[d:extractor_type="intrinsic"]').each do |p|
              pid = p.find('string(d:id)')
              event['stream:datastream'] ||= []
              val = CPEE::Logging::extract_sensor(rs,p.find('string(d:extractor_code)'),pid,nil) rescue nil
              CPEE::Logging::val_merge(event['stream:datastream'],val,pid,p.find('string(d:source)'))
            end
          end
          notification['datastream'] = event['stream:datastream']
          EM.defer do
            notification['topic'] = 'stream'
            notification['name'] = 'extraction'
            self::notify(opts,'stream','extraction',notification.to_json)
          end
        end
      end
      if topic == 'activity' && event_name == 'receiving' && receiving && !receiving.empty?
        fname = File.join(log_dir,instance + '_' + event['id:id'] + '.probe')
        dname = File.join(log_dir,instance + '.data.json')

        if File.exist?(fname)
          te = event.dup

          rs = WEEL::ReadStructure.new(File.exist?(dname) ? JSON::load(File::open(dname)) : {},{},{},{})
          XML::Smart::open_unprotected(fname) do |doc|
            doc.register_namespace 'd', 'http://cpee.org/ns/description/1.0'
            if doc.find('//d:probe/d:extractor_type[.="extrinsic"]').any?
              rc = CPEE::Logging::extract_result(receiving)
              doc.find('//d:probe[d:extractor_type="extrinsic"]').each do |p|
                pid = p.find('string(d:id)')
                te['stream:datastream'] ||= []
                val = CPEE::Logging::extract_sensor(rs,p.find('string(d:extractor_code)'),pid,rc) rescue nil
                CPEE::Logging::val_merge(te['stream:datastream'],val,pid,p.find('string(d:source)'))
              end
            end
          end
          if te['stream:datastream']
            te['cpee:lifecycle:transition'] = 'stream/data'
            File.open(File.join(log_dir,instance+'.xes.yaml'),'a') do |f|
              f << {'event' => te}.to_yaml
            end
            notification['datastream'] = te['stream:datastream']
            EM.defer do
              notification['topic'] = 'stream'
              notification['name'] = 'extraction'
              self::notify(opts,'stream','extraction',notification.to_json)
            end
          end
        end
      end
      if receiving && !receiving.empty?
        event['data'] = receiving
      end
      if content['data'] && !content['data'].empty?
        event['data'] = content['data']
      end
      event['time:timestamp']= notification['timestamp'] || Time.now.xmlschema(4)
      File.open(File.join(log_dir,instance+'.xes.yaml'),'a') do |f|
        f << {'event' => event}.to_yaml
      end
    end

  end
end

