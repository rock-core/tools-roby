#! /usr/bin/env ruby

require 'roby/log/event_stream'
STDOUT.sync = true

class Roby::Log::EventMatcher
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
	    log.read_and_decode.each_slice(4) do |m, sec, usec, args|
		event(m, sec, usec, args)
	    end
	end
    end

    def event(m, sec, usec, args)
	if m == :discovered_tasks || m == :discovered_events
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
		if p.call(args)
		    time ||= Time.at(sec, usec)
		    callback.call(time, args)
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
		    Regexp.new(task_model) === local_object(task).model.ancestors[0][0]
		end
	    end
	end

	if predicate
	    notifications[method] ||= Array.new
	    notifications[method] << [predicate, block]
	end
    end
end

config_path = ARGV[0]
event_path  = ARGV[1]
unless config_path && event_path
    STDERR.puts <<-EOU
Usage: scripts/generate/bookmarks config.yml event_set

  This script generates a bookmark file suitable for roby-log replay based on a
  log file and on a configuration file. The configuration file format is as
  follows:

    event_name:
      - start_point
      - end_point

  where start_point and end_point are matching expressions. The following
  expressions are recognized:

    start(task_model)
    ready(task_model)
    stop(task_model

  they trigger when, respectively, a task instance of the specified model is
  started, its ready event has emitted and it stopped. 
  
  For instance, to get a 'localization_initialized' bookmark for a Localization
  task, you would write the following configuration file:

    localization_initialized:
	- start(Localization)
	- ready(Localization)

    EOU

    exit(1)

end

# Reverse the config file from a 'bookmark_name => event' into a 'event' =>
# 'bookmark_name'
config = YAML.load(File.open(ARGV[0]))
bookmarks = Hash.new

filter = Roby::Log::EventMatcher.new
config.each do |name, (start_point, end_point)|
    bookmarks[name] = []
    filter.parse(start_point) do |time, args|
	STDERR.puts "#{time.to_hms} starting point for #{name}"
	bookmarks[name] << [time]
    end
    filter.parse(end_point) do |time, args|
	if bookmarks[name].last && bookmarks[name].last[0] && !bookmarks[name].last[1]
	    STDERR.puts "#{time.to_hms} end point for #{name}"
	    bookmarks[name].last[1] = time
	end
    end
end

log = Roby::Log::EventStream.open(ARGV[1])
filter.filter(log)

bookmark_data = Hash.new
bookmarks.each do |name, ranges|
    if ranges.size == 1
	bookmark_data[name] = ranges[0].map { |t| t.to_hms }
    else
	ranges.each_with_index do |r, i|
	    bookmark_data["#{name}-#{i}"] = r.map { |t| t.to_hms }
	end
    end
end

puts YAML.dump(bookmark_data)

