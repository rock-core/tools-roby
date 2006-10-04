require 'test/unit'
require 'mockups/tasks'
require 'roby/control'

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

def clear_plan_objects
    ObjectSpace.each_object(Roby::Task) do |t|
	t.clear_vertex
    end
    ObjectSpace.each_object(Roby::EventGenerator) do |e|
	e.clear_vertex
    end
end

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


