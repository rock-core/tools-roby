#! /usr/bin/env ruby

require 'roby/log'
require 'roby/log/event_stream'
STDOUT.sync = true

class Roby::LogReplay::EventMatcher
    attr_reader :remote_ids
    attr_reader :predicate_id
    attr_reader :notifications
    def initialize
	@remote_ids = Hash.new
	@notifications = Hash.new
	@predicate_id = 0
    end

    def local_object(remote_id)
	if remote_id.kind_of?(Roby::Distributed::RemoteID)
	    unless obj = remote_ids[remote_id]
		raise "no object for #{remote_id}: #{remote_ids.keys}"
	    end
	    obj
	else
	    remote_id
	end
    end

    def filter(log)
	while log.has_sample?
	    log.read.each_slice(4) do |m, sec, usec, args|
		event(m, sec, usec, args)
	    end
	end
    end

    def event(m, sec, usec, args)
	if m == :added_tasks || m == :added_events
	    objects = args[1]
	    for object in objects
		for remote_id in object.remote_siblings.values
		    remote_ids[remote_id] = object
		end
	    end

	elsif m == :finalized_task || m == :finalized_event
	    object = args[1]
	    remote_ids.delete(object)
	end

	time = nil
	if predicate_set = notifications[m]
	    for p, callback in predicate_set
		if result = p.call(args)
		    time ||= Time.at(sec, usec)
		    callback.call(time, *result)
		end
	    end
	end
    end

    def parse(expr, &block)
	case expr
	when /^(\w+)\((.*)\)$/
	    method = :generator_fired
	    task_model = Regexp.new($2)
	    symbol = $1.to_sym
	    predicate = lambda do |args|
		generator = local_object(args[0])
		if generator.respond_to?(:task) && generator.symbol == symbol
		    task = local_object(generator.task)
		    if Regexp.new(task_model) === task.model.ancestors[0][0]
                        [task.model.ancestors[0][0], generator.symbol]
                    end
		end
	    end
	when /^((?:\w|::)+)$/
	    method = :generator_fired
	    task_model = Regexp.new($1)
	    predicate = lambda do |args|
		generator = local_object(args[0])
		if generator.respond_to?(:task)
		    task = local_object(generator.task)
		    if Regexp.new(task_model) === task.model.ancestors[0][0]
                        [task.model.ancestors[0][0], generator.symbol]
                    end
		end
	    end
	end

	if predicate
	    notifications[method] ||= Array.new
	    notifications[method] << [predicate, block]
	end
    end
end

time_format = 'hms'
opts = OptionParser.new do |opt|
    opt.banner = <<-EOD
find-events [options] file event_spec [event_spec ...]
Where event_spec is:
  model_name: match the model of a fired event
  event: match the event name
  event(model_name): match the event of a specific task model
    EOD
    opt.on('--time=FORMAT', String, 'the format in which to display the time: hms or sec') do |frmt|
        if ['hms', 'sec'].include?(frmt)
            time_format = frmt
        else
            raise "invalid time format provided: expected hms or sec, got #{frmt}"
        end
    end
    opt.on('--help') do
        puts opt
        exit 0
    end
end
remaining = opts.parse(ARGV)
event_path  = remaining.shift
if !event_path || remaining.empty?
    puts opts
    exit 1
end

filter = Roby::LogReplay::EventMatcher.new
ARGV.each do |filter_str|
    filter.parse(filter_str) do |time, task_model, symbol|
        puts "#{Roby.format_time(time, time_format)} #{task_model} #{symbol}"
    end
end

log = Roby::LogReplay::EventFileStream.open(event_path)
begin
    filter.filter(log)
rescue Errno::EPIPE
    exit 0
end

