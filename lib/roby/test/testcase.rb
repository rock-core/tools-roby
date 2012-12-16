require 'roby'
require 'test/unit'
require 'roby/test/common'
require 'roby/test/tools'
require 'fileutils'

module Roby
    module Test
	extend Logger::Hierarchy
	extend Logger::Forward

	# This is the base class for running tests which uses a Roby control
	# loop (i.e. plan execution).
	#
	# Because configuration and planning can be robot-specific, parts of
	# the tests can also be splitted into generic parts and specific parts.
	# The TestCase.robot statement allows to specify that a given test case
	# is specific to a given robot, in which case it is ran only if the
	# call to <tt>scripts/test</tt> specified a robot which matches (i.e.
	# same name and type).
	#
	# Finally, two other mode of operation control the way tests are ran
	# [simulation]
	#   if the <tt>--sim</tt> flag is given to <tt>scripts/test</tt>, the
	#   tests are ran under simulation. Otherwise, they are run in live
	#   mode (see Roby::Application for a description of simulation and
	#   live modes). It is possible to constrain that a given test method
	#   is run only in simulation or live mode with the TestCase.sim and
	#   TestCase.nosim statements:
	#
	#     sim :sim_only
	#     def test_sim_only
	#     end
	#
	#     nosim :live_only
	#     def test_live_only
	#     end
	# [interactive]
	#   Sometime, it is hard to actually assess the quality of processing
	#   results automatically. In these cases, it is possible to show the
	#   user the result of data processing, and then ask if the result is
	#   valid by using the #user_validation method. Nonetheless, the tests
	#   can be ran in automatic mode, in which the assertions which require
	#   user validation are simply skipped. The <tt>--interactive</tt> or
	#   <tt>-i</tt> flags of <tt>scripts/test</tt> specify that user
	#   interaction is possible.
	class TestCase < Test::Unit::TestCase
	    include Roby::Test
	    include Assertions
	    class << self
		attribute(:case_config) { Hash.new }
		attribute(:methods_config) { Hash.new }
		attr_reader :app_setup
	    end

	    # Sets the robot configuration for this test case. If a block is
	    # given, it is called between the time the robot configuration is
	    # loaded and the time the test methods are started. It can
	    # therefore be used to change the robot configuration for the need
	    # of this particular test case
	    def self.robot(name, kind = name, &block)
		@app_setup = [name, kind, block]
	    end

	    # Loads the configuration as specified by TestCase.robot
	    def self.apply_robot_setup
		app = Roby.app

		name, kind, block = app_setup
		# Ignore the test suites which use a different robot
		if name || kind && (app.robot_name && 
		    (app.robot_name != name || app.robot_type != kind))
                    Test.info "ignoring #{self} as it is for robot #{name} and we are running for #{app.robot_name}:#{app.robot_type}"
		    return
		end
		if block
		    block.call
		end

		yield if block_given?
	    end

	    # Returns a fresh MainPlanner object for the current plan
	    def planner
		MainPlanner.new(plan)
	    end

	    def setup # :nodoc:
                @plan = Roby.plan
                @engine = plan.engine
                @control = plan.engine.control

		super
	    end

	    # Returns true if user interaction is to be disabled during this test
	    def automatic_testing?
		Roby.app.automatic_testing?
	    end

	    # Progress report for the curren test. If +max+ is given, then
	    # +value+ is assumed to be between 0 and +max+. Otherwise, +value+
	    # is a float value between 0 and 1 and is displayed as a percentage.
	    def progress(value, max = nil)
		if max
		    print "\rprogress: #{value}/#{max}"
		else
		    print "\rprogress: #{"%.2f %%" % [value * 100]}"
		end
		STDOUT.flush
	    end

	    def user_interaction
		return unless automatic_testing?

		test_result = catch(:validation_result) do
		    yield 
		    return
		end
		if test_result
		    flunk(*test_result)
		end
	    end

	    # Ask for user validation. The method first yields, and then asks
	    # the user if the showed dataset is nominal. If the tests are ran
	    # in automated mode (#automatic_testing? returns true), it does
	    # nothing.
	    def user_validation(msg)
		return if automatic_testing?

		assert_block(msg) do
		    STDOUT.puts "Now validating #{msg}"
		    yield

		    STDIN.ask("\rIs the result OK ? [N,y]", false)
		end
	    end

	    # Do not run +test_name+ inside a simulation environment
	    # +test_name+ is the name of the method without +test_+. For
	    # instance:
	    #   nosim :init
	    #   def test_init
	    #   end
	    #
	    # See also TestCase.sim
	    def self.nosim(*names)
		names.each do |test_name|
		    config = (methods_config[test_name.to_s] ||= Hash.new)
		    config[:mode] = :nosim
		end
	    end

	    # Run +test_name+ only inside a simulation environment
	    # +test_name+ is the name of the method without +test_+. For
	    # instance:
	    #   sim :init
	    #   def test_init
	    #   end
	    #
	    # See also TestCase.nosim
	    def self.sim(*names)
		names.each do |test_name|
		    config = (methods_config[test_name.to_s] ||= Hash.new)
		    config[:mode] = :sim
		end
	    end

	    def run(result) # :nodoc:
                if self.class == TestCase
                    return
                end

		self.class.apply_robot_setup do
		    yield if block_given?

		    @failed_test = false
		    begin
                        super
		    rescue Exception => e
			if @_result
			    add_error(e)
			else
			    raise
			end
		    end
		end
	    end

	    def add_error(*args, &block) # :nodoc:
		@failed_test = true
		super
	    end
	    def add_failure(*args, &block) # :nodoc:
		@failed_test = true
		super
	    end

	    # The directory in which datasets are to be saved
	    def datasets_dir
		"#{Roby.app.app_dir}/test/datasets" 
	    end
	    # The directory into which the datasets generated by the current
	    # testcase are to be saved.
	    def dataset_prefix
		"#{Roby.app.robot_name}-#{self.class.name.gsub('TC_', '').underscore}-#{@method_name.gsub(/(?:test|dataset)_/, '')}"
	    end
	    # Returns the full path of the file name into which the log file +file+
	    # should be saved to be referred to as the +dataset_name+ dataset
	    def dataset_file_path(dataset_name, file)
		path = File.join(datasets_dir, dataset_name, file)
		if !File.file?(path)
		    raise "#{path} does not exist"
		end

		path
	    rescue
		flunk("dataset #{dataset_name} has not been generated: #{$!.message}")
	    end



	    # Saves +file+, which is taken in the log directory, in the
	    # test/datasets directory.  The data set is saved as
	    # 'robot-testname-testmethod-suffix'
	    def save_dataset(files = nil, suffix = '')
		destname = dataset_prefix
		destname << "-#{suffix}" unless suffix.empty?

		dir = File.join(datasets_dir, destname)
		if File.exists?(dir)
		    relative_dir = dir.gsub(/^#{Regexp.quote(Roby.app.app_dir)}/, '')
		    unless STDIN.ask("\r#{relative_dir} already exists. Delete ? [N,y]", false)
			raise "user abort"
		    end
		    FileUtils.rm_rf dir
		end
		FileUtils.mkdir_p(dir)

		files ||= Dir.entries(Roby.app.log_dir).find_all do |path|
		    File.file? File.join(Roby.app.log_dir, path)
		end

		[*files].each do |path|
		    FileUtils.mv "#{Roby.app.log_dir}/#{path}", dir
		end
	    end

	    def sampling(*args, &block); Test.sampling(engine, *args, &block) end
	    def stats(*args, &block); Test.stats(*args, &block) end
	end
    end
end


