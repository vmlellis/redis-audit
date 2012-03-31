#!/usr/bin/ruby
require 'rubygems'
require 'redis'

class KeyStats
  attr_accessor :total_instances, 
                :total_idle_time, 
                :total_serialized_length,
                :total_expirys_set,
                :min_serialized_length,
                :max_serialized_length,
                :min_idle_time,
                :max_idle_time,
                :max_ttl,
                :sample_keys
  
  def initialize
    @total_instances = 0
    @total_idle_time = 0
    @total_serialized_length = 0
    @total_expirys_set = 0
    
    @min_serialized_length = nil
    @max_serialized_length = nil
    @min_idle_time = nil
    @max_idle_time = nil
    @max_ttl = nil
    
    @sample_keys = {}
  end
  
  def add_stats_for_key(key, type, idle_time, serialized_length, ttl)
    @total_instances += 1
    @total_idle_time += idle_time
    @total_expirys_set += 1 if ttl != nil
    @total_serialized_length += serialized_length
    
    @min_idle_time = idle_time if @min_idle_time.nil? || @min_idle_time > idle_time
    @max_idle_time = idle_time if @max_idle_time.nil? || @max_idle_time < idle_time
    @min_serialized_length = serialized_length if @min_serialized_length.nil? || @min_serialized_length > serialized_length
    @max_serialized_length = serialized_length if @max_serialized_length.nil? || @max_serialized_length < serialized_length
    @max_ttl = expiry_time if ttl != nil && ( @max_ttl == nil || @max_ttl < ttl )
    
    @sample_keys[key] = type if @sample_keys.count < 10
  end
end

class RedisAudit
  def initialize(redis, sample_size)
    @redis = redis
    @keys = Hash.new
    @sample_size = sample_size
    @dbsize = 0
  end
  
  def audit_keys
    debug_regex = /serializedlength:(\d*).*lru_seconds_idle:(\d*)/
    @dbsize = @redis.dbsize
    
    @sample_size.times do
      key = @redis.randomkey
      pipeline = @redis.pipelined do
        @redis.type(key)
        @redis.ttl(key)
        @redis.debug("object", key)
      end
      type = pipeline[0]
      ttl = pipeline[1] == -1 ? nil : pipeline[1]
      debug_fields = debug_regex.match(pipeline[2])
      serialized_length = debug_fields[1].to_i
      idle_time = debug_fields[2].to_i
      @keys[group_key(key, type)] ||= KeyStats.new
      @keys[group_key(key, type)].add_stats_for_key(key, type, idle_time, serialized_length, ttl)
    end
  end
  
  def group_key(key, type)
    return key.delete("0-9") + ":#{type}"
  end
  
  def output_stats
    key_regex = /^(.*):(.*)$/
    complete_serialized_length = @keys.map {|key, value| value.total_serialized_length }.reduce(:+)
    
    puts "DB has #{@dbsize} keys"
    puts
    puts "Stats for #{@keys.count} sampled keys..."
    puts
    @keys.each do |key, value|
      key_fields = key_regex.match(key)
      common_key = key_fields[1]
      common_type = key_fields[2]
      
      puts "=============================================================================="
      puts "Keys of the form #{common_key} with type #{common_type}"
      puts "For example:"
      puts value.sample_keys.keys.join(", ")
      puts
      puts "#{make_proportion_percentage(value.total_expirys_set/value.total_instances.to_f)} of these keys expire (#{value.total_expirys_set}), with maximum ttl of #{value.max_ttl}"
      puts "These keys use #{make_proportion_percentage(value.total_serialized_length/complete_serialized_length.to_f)} of the total sampled memory (#{value.total_serialized_length} bytes)"
      puts "Average idle time: #{value.total_idle_time/value.total_instances.to_f} seconds - (Max: #{value.max_idle_time} Min:#{value.min_idle_time})"
      puts
    end
  end
  
  def make_proportion_percentage(value)
    return "#{(value * 10000).round/100.0}%"
  end
end

if ARGV.length != 4
    puts "Usage: redis-audit.rb <host> <port> <dbnum> <sample_size>"
    exit 1
end

host = ARGV[0]
port = ARGV[1].to_i
db = ARGV[2].to_i
sample_size = ARGV[3].to_i

redis = Redis.new(:host => host, :port => port, :db => db)
auditor = RedisAudit.new(redis, sample_size)
puts "Auditing #{host}:#{port} db:#{db} sampling #{sample_size} keys"
auditor.audit_keys
auditor.output_stats