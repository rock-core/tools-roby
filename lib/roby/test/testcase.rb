require 'active_support/core_ext/string/inflections'
class String
    include ActiveSupport::CoreExtensions::String::Inflections
end

require 'roby/test/common'
require 'fileutils'

module Roby
    module Test
	@waiting_threads = []
	def self.waiting_threads; @waiting_threads end

	module Assertions
	    def assert_events(positive, negative = [])
		done_mutex = Mutex.new
		done       = ConditionVariable.new
		positive = Array[*positive]
		negative = Array[*negative]

		done_mutex.synchronize do
		    loop do
			Roby::Control.synchronize do
			    if positive.any? { |ev| ev.happened? }
				return
			    elsif failure = negative.find { |ev| ev.happened? }
				flunk("event #{failure} happened")
			    else
				(positive + negative).each do |ev| 
				    ev.on do 
					done_mutex.synchronize do
					    done.broadcast 	
					end
				    end
				end
			    end
			end
			yield if block_given?
			Roby::Test.waiting_threads << Thread.current
			done.wait(done_mutex)
		    end
		end

	    ensure
		Roby::Test.waiting_threads.delete(Thread.current)
	    end

	    # Starts +task+ and checks it succeeds
	    def assert_succeeds(task)
		plan.permanent(task)
		assert_events(task.event(:success), task.event(:stop)) do
		    Roby::Control.once { task.start! }
		end
	    end
	end

	class ControlQuitError < RuntimeError; end
	class TestCase < Test::Unit::TestCase
	    include Roby::Test
	    include Assertions

	    def self.robot(name, kind = name)
		Roby.app.robot name, kind
		require 'roby/app/config/app-load'
	    end

	    def run(result)
		Roby::Test.waiting_threads.clear
		Roby::Control.finalizers << method(:control_finalizer)

		Roby.app.simulation
		Roby.app.single
		Roby.app.setup
		Roby.app.run do
		    super
		end

	    ensure
		Roby::Control.finalizers.delete(method(:control_finalizer))
	    end

	    attr_reader :waiting_threads
	    def control_finalizer
		Roby::Test.waiting_threads.each do |task|
		    task.raise ControlQuitError
		end
	    end

	    def datasets_dir
		"#{APP_DIR}/test/datasets" 
	    end
	    def dataset_prefix
		"#{Roby.app.robot_name}-#{self.class.name.gsub('TC_', '').underscore}-#{@method_name.gsub('test_', '')}"
	    end

	    # Saves +file+, which is taken in the log directory, in the
	    # test/datasets directory.  The data set is saved as
	    # 'robot-testname-testmethod-suffix'
	    def save_dataset(file, suffix = '')
		unless File.directory?(datasets_dir)
		    FileUtils.mkdir_p(datasets_dir)
		end
		destname = "#{datasets_dir}/#{dataset_prefix}"
		destname << "-#{suffix}" unless suffix.empty?
		destname << File.extname(file)

		FileUtils.cp "#{Roby.app.logdir}/#{file}", destname
	    end
	end
    end
end


