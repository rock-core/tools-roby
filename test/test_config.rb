require 'test/unit'
require 'utilrb/objectstats'
require 'roby/task'
require 'roby/event'

BASE_TEST_DIR=File.expand_path(File.dirname(__FILE__)) unless defined? BASE_TEST_DIR
$LOAD_PATH.unshift BASE_TEST_DIR
$LOAD_PATH.unshift File.expand_path("../lib", File.dirname(__FILE__))

path=ENV['PATH'].split(':')
pkg_config_path=(ENV['PKG_CONFIG_PATH'] || "").split(':')

Dir.glob("#{BASE_TEST_DIR}/prefix.*") do |p|
    path << "#{p}/bin"
    pkg_config_path << "#{p}/lib/pkgconfig"
end
ENV['PATH'] = path.join(':')
ENV['PKG_CONFIG_PATH'] = pkg_config_path.join(':')

module CommonTestBehaviour
    class << self
	attr_accessor :check_allocation_count
    end

    attribute(:original_collections) { Array.new }
    def save_collection(obj)
	original_collections << [obj, obj.dup]
    end
    def restore_collections
	original_collections.each do |col, backup|
	    col.clear
	    backup.each(&col.method(:<<))
	end
    end

    def setup
	# Save and restore Control's global arrays
	if defined? Roby::Control
	    save_collection Roby::Control.event_processing
	    save_collection Roby::Control.structure_checks
	    Roby::Control.instance.abort_on_exception = true
	    Roby::Control.instance.abort_on_application_exception = true
	    Roby::Control.instance.abort_on_framework_exception = true
	end

	if defined? Roby.exception_handlers
	    save_collection Roby.exception_handlers
	end
    end

    def teardown
	restore_collections

	if respond_to?(:plan) && plan
	    plan.clear
	end

	# Clear all relation graphs in TaskStructure and EventStructure
	[Roby::TaskStructure, Roby::EventStructure].each do |space|
	    space.relations.each { |rel| rel.each_vertex { |v| v.clear_vertex } }
	end
	

	if defined? Roby::Control
	    Roby::Control.instance.abort_on_exception = false
	    Roby::Control.instance.abort_on_application_exception = false
	    Roby::Control.instance.abort_on_framework_exception = false
	end

	if CommonTestBehaviour.check_allocation_count
	    count = ObjectStats.count
	    GC.start
	    remains = ObjectStats.count
	    STDERR.puts "#{count} -> #{remains} (#{count - remains})"
	end
    end
end

#require 'roby/log/console'
#Roby::Log.loggers << Roby::Log::ConsoleLogger.new(STDERR)
Roby.logger.level = Logger::DEBUG

module Test::Unit::Assertions
    class FailedTimeout < RuntimeError; end
    def assert_doesnt_timeout(seconds, message = "watchdog #{seconds} failed")
        watched_thread = Thread.current
        watchdog = Thread.new do
            sleep(seconds)
            watched_thread.raise FailedTimeout
        end

	assert_block(message) do
	    begin
		yield
		watchdog.kill
		true
	    rescue FailedTimeout
	    end
	end
    end

    def assert_event(event, timeout = 5)
	assert_doesnt_timeout(timeout, "event #{event.symbol} never happened") do
	    while !event.happened?
		Roby::Control.instance.process_events({}, false)
		sleep(0.1)
	    end
	end
    end

    def assert_marshallable(object)
	begin
	    Marshal.dump(object)
	    true
	rescue TypeError
	end
    end
end


