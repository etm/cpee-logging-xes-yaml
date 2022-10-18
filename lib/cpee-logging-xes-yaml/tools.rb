require 'weel'

class StreamPoint
  attr_accessor :value, :timestamp, :source, :meta

  def initialize
    @value = nil
    @timestamp = Time.now
    @source = nil
    @meta = nil
  end

  def to_h(id)
    tp = { 'stream:point' => { } }
    tp['stream:point']['stream:id'] = id
    tp['stream:point']['stream:value'] = @value
    tp['stream:point']['stream:timestamp'] = @timestamp
    tp['stream:point']['stream:source'] = @source unless @source.nil?
    tp['stream:point']['stream:meta'] = @meta unless @meta.nil?
    tp
  end
end

module CPEE
  module Logging

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

    def self::extract_sensor(rs,code,result)
      result.map! do |res|
        if res['mimetype'].nil?
          res['value']
        elsif res['mimetype'] == 'application/json'
          JSON::parse(res['data'])
        elsif res['mimetype'] == 'application/xml' || res['mimetype'] == 'text/xml'
          XML::Smart::string(res['data']) rescue nil
        elsif res.mimetype == 'text/yaml'
          YAML::load(res['data']) rescue nil
        elsif result[0].mimetype == 'text/plain'
          t = res['data']
          if t.start_with?("<?xml version=")
            t = XML::Smart::string(t)
          else
            t = t.to_f if t == t.to_f.to_s
            t = t.to_i if t == t.to_i.to_s
          end
          t
        elsif res.mimetype == 'text/html'
          t = res['data']
          t = t.to_f if t == t.to_f.to_s
          t = t.to_i if t == t.to_i.to_s
          t
        else
          res['data']
        end
      end
      result = result[0] if result.length == 1
      rs.instance_eval(code)
    end

    def self::persist_values(where,values)
      unless File.exists?(where)
        File.write(where,'{}')
      end
      f = File.open(where,'r+')
      f.flock(File::LOCK_EX)
      json = JSON::load(f).merge(values)
      f.rewind
      f.truncate(0)
      f.write(JSON.generate(json))
      f.close
    end

    def self::doc(topic,event_name,log_dir,template,payload)
      notification = JSON.parse(payload)
      instance = notification['instance-uuid']
      return unless instance

      instancenr = notification['instance']
      content = notification['content']
      activity = content['activity']
      parameters = content['parameters']
      receiving = content['received']

      if content['dslx']
        CPEE::Logging::extract_probes(File.join(log_dir,instance),content['dslx'])
      end

      if topic == 'dataelements' && event_name == 'change'
        if content['changed']&.any?
          CPEE::Logging::persist_values(File.join(log_dir,instance + '.data.json'),content['values'])
        end
      end

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
      end if parameters
      if content['changed']&.any?
        event["data"] = content['values'].map do |k,v|
          { 'name' => k, 'value' => v }
        end
      end
      if receiving && !receiving.empty?
        fname = File.join(log_dir,instance + '_' + event["id:id"] + '.probe')
        dname = File.join(log_dir,instance + '.data.json')

        if File.exists?(fname)
          te = event.dup
          te['stream:sensorstream'] = []

          rs = WEEL::ReadStructure.new(File.exists?(dname) ? JSON::load(File::open(dname)) : {},{},{})
          XML::Smart::open_unprotected(fname) do |doc|
            doc.register_namespace 'd', 'http://cpee.org/ns/description/1.0'
            doc.find('//d:probe').each do |p|
              tid = p.find('string(d:id)')
              tso = p.find('string(d:source)')
              if p.find('d:extractor_type[.="extrinsic"]')
                val = CPEE::Logging::extract_sensor(rs,p.find('string(d:extractor_code)'),receiving) rescue nil
                if val.is_a? Array
                  val.each do |e|
                    if e.is_a? StreamPoint
                      e.source ||= tso
                      te['stream:sensorstream'] << e.to_h(tid)
                    end
                  end
                else
                  tp = StreamPoint.new
                  tp.source =  tso
                  tp.value = val
                  te['stream:sensorstream'] << tp.to_h(tid)
                end
              end
            end
          end
          te["cpee:lifecycle:transition"] = "sensor/stream"
          File.open(File.join(log_dir,instance+'.xes.yaml'),'a') do |f|
            f << {'event' => te}.to_yaml
          end
        end

        event["raw"] = receiving
      end
      event["time:timestamp"]= event['cpee:timestamp'] || Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L%:z")
      File.open(File.join(log_dir,instance+'.xes.yaml'),'a') do |f|
        f << {'event' => event}.to_yaml
      end
    end

  end
end

