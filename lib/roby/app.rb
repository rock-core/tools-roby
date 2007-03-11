require 'roby'
require 'roby/distributed'
require 'roby/planning'

module Roby
    # Returns the only one Application object
    def self.app; Application.instance end

    # This class handles all application loading and configuration. It it set
    # up by two means: first, a YAML configuration file is loaded in config/roby.yml.
    # Second, it can be directly accessed, using Roby.app, in the config/init.rb and
    # config/ROBOT.rb files.
    class Application
	include Singleton

	ROBY_LIB_DIR  = File.expand_path( File.join(File.dirname(__FILE__)) )
	ROBY_ROOT_DIR = File.expand_path( File.join(ROBY_LIB_DIR, '..', '..') )

	# The plain option hash
	attr_reader :options

	# Logging options.
	# timings:: save a log/ROBOT-timings.log file with the timings of each step in the event loop
	#           This log can be read using roby-cntrllog
	# events:: save a log of all events in the system. This log can be read using scripts/replay
	# levels:: a component => level hash of the minimum level of the messages that 
	#	   should be displayed on the console. The levels are DEBUG, INFO, WARN and FATAL.
	#	     Roby: FATAL
	#	     Roby::Distributed: INFO
	attr_reader :log
	
	# A [name, file, module] array of available plugins
	attr_reader :available_plugins
	# An [name, module] array of the loaded plugins
	attr_reader :plugins

	# The discovery options in multi-robot mode
	attr_reader :discovery
	# The robot's dRoby options
	# period:: the period of neighbour discovery
	# max_errors:: disconnect from a peer if there is more than +max_errors+ consecutive errors
	#              detected
	attr_reader :droby
	
	# Configuration of the control loop
	# abort_on_exception:: if the control loop should abort if an uncaught task or event exception is received
	# abort_on_application_exception:: if the control should abort if an uncaught application exception (not originating
	#                                  from a task or event) is caught
	attr_reader :control

	# An array of directories in which to search for plugins
	attr_reader :plugin_dirs

	def initialize
	    @plugins = Array.new
	    @available_plugins = Array.new
	    @log = Hash['timings' => false, 'events' => false, 'levels' => Hash.new] 
	    @discovery = Hash.new
	    @droby     = Hash['period' => 0.5, 'max_errors' => 1] 
	    @control   = Hash[ 'abort_on_exception' => false, 
		'abort_on_application_exception' => true ]

	    @plugin_dirs = []
	end

	# Adds +dir+ in the list of directories searched for plugins
	def plugin_dir(dir)
	    dir = File.expand_path(dir)
	    @plugin_dirs << dir
	    $LOAD_PATH.unshift File.expand_path(dir)

	    Dir.new(dir).each do |subdir|
		subdir = File.join(dir, subdir)
		next unless File.directory?(subdir)
		appfile = File.join(subdir, "app.rb")
		next unless File.file?(appfile)

		begin
		    require appfile
		rescue
		    Roby.warn "cannot load plugin in #{subdir}: #{$!.message}"
		end
		Roby.info "loaded plugin in #{subdir}"
	    end
	end

	# Returns true if +name+ is a loaded plugin
	def loaded_plugin?(name)
	    plugins.any? { |plugname, _, _| plugname == name }
	end

	# Yields each extension modules that respond to +method+
	def each_responding_plugin(method, on_available = false)
	    plugins = self.plugins
	    if on_available
		plugins = available_plugins.map { |name, _, mod| [name, mod] }
	    end

	    plugins.each do |_, mod|
		yield(mod) if mod.respond_to?(method)
	    end
	end
	
	# Call +method+ on each loaded extension module which define it, with
	# arguments +args+
	def call_plugins(method, *args)
	    each_responding_plugin(method) do |config_extension|
		config_extension.send(method, *args)
	    end
	end

	# Load configuration from the given option hash
	def load(options)
	    options = options.dup

	    if robot_name && (robot_config = options['robots'])
		if robot_config = robot_config[robot_name]
		    robot_config.each do |section, values|
			if options[section]
			    options[section].merge! values
			else
			    options[section] = values
			end
		    end
		    options.delete('robots')
		end
	    end

	    @options = options

	    load_option_hashes(options, %w{log control discovery droby})
	    call_plugins(:load, self, options)
	end

	def load_option_hashes(options, names)
	    names.each do |optname|
		if options[optname]
		    send(optname).merge! options[optname]
		end
	    end
	end

	# Loads the plugins whose name are listed in +names+
	def using(*names)
	    names.each do |name|
		unless plugin = available_plugins.find { |plugname, file, mod| plugname == name.to_s }
		    raise ArgumentError, "#{name} is not a known plugin (#{available_plugins.map { |n, _, _| n }.join(", ")})"
		end
		_, file, mod = *plugin

		begin
		    require file
		rescue LoadError => e
		    Roby.fatal "cannot load plugin #{name}: #{e.full_message}"
		    exit(1)
		end

		plugins << [name, mod]
		extend mod
		# If +load+ has already been called, call it on the module
		if mod.respond_to?(:load) && options
		    mod.load(self, options)
		end
	    end
	end

	attr_reader :robot_name, :robot_type
	def robot(name, type = name)
	    if @robot_name
		raise ArgumentError, "the robot is already set to #{name}, of type #{type}"
	    end
	    @robot_name = name
	    @robot_type = type
	end
	
	def setup
	    # Set up log levels
	    log['levels'].each do |name, value|
		if (mod = constant(name) rescue nil)
		    mod.logger.level = Logger.const_get(value)
		end
	    end

	    # Require all common task models
	    task_dir = File.join(APP_DIR, 'tasks')
	    Dir.new(task_dir).each do |task_file|
		task_file = File.expand_path(task_file, task_dir)
		require task_file if task_file =~ /\.rb$/ && File.file?(task_file)
	    end

	    # Set up some directories
	    logdir = File.join(APP_DIR, 'log')
	    if !File.exists?(logdir)
		Dir.mkdir(logdir)
	    end
	    Roby::State.datadirs = []
	    datadir = File.join(APP_DIR, "data")
	    if File.directory?(datadir)
		Roby::State.datadirs << datadir
	    end

	    # Import some constants directly at toplevel
	    Object.const_set(:Application, Roby::Application)
	    Object.const_set(:State, Roby::State)

	    # Load robot-specific configuration
	    if robot_name
		require_robotfile(File.join(APP_DIR, 'config', "ROBOT.rb"))
	    end
	    
	    # Load the main planner definitions
	    planner_dir = File.join(APP_DIR, 'planners')

	    if robot_name
		robot_planner_dir = File.join(planner_dir, robot_name)
		robot_planner_dir = nil unless File.directory?(robot_planner_dir)

		# First, load the main planner
		if robot_planner_dir
		    begin
			require File.join(robot_planner_dir, 'main')
		    rescue LoadError => e
			raise unless e.message =~ /no such file to load -- #{robot_planner_dir}\/main/
			require File.join(APP_DIR, 'planners', 'main')
		    end
		else
		    require File.join(APP_DIR, 'planners', 'main')
		end
	    else
		require File.join(APP_DIR, "planners", "main")
	    end

	    # Load the other planners
	    [robot_planner_dir, planner_dir].compact.each do |base_dir|
		Dir.new(base_dir).each do |file|
		    if File.file?(file) && file =~ /\.rb$/ && file !~ 'main\.rb$'
			require file
		    end
		end
	    end

	    # Set filters for subsystem selection
	    MainPlanner.class_eval do
		Roby::State.services.each_member do |name, value|
		    if value.respond_to?(:mode)
			filter(name) do |options, method|
			    options[:id] || method.id == value.mode
			end
		    end
		end
	    end

	    # MainPlanner is always included in the planner list
	    Roby::Control.instance.planners << MainPlanner
	   
	    # Set up dRoby
	    host = droby['host']
	    if single? || !robot_name
		host =~ /:(\d+)$/
		DRb.start_service "roby://:#{$1 || '0'}"
	    else
		if host =~ /^:\d+$/
		    host = "#{Socket.gethostname}#{host}"
		end

		DRb.start_service "roby://#{host}"
		droby_config = { :ring_discovery => !!discovery['ring'],
		    :name => robot_name, 
		    :plan => Roby::Control.instance.plan, 
		    :period => droby['period'] }

		if discovery['tuplespace']
		    droby_config[:discovery_tuplespace] = DRbObject.new_with_uri("roby://#{discovery['tuplespace']}")
		end
		Roby::Distributed.state = Roby::Distributed::ConnectionSpace.new(droby_config)

		if discovery['ring']
		    Roby::Distributed.publish discovery['ring']
		end
		Roby::Control.every(discovery['period']) do
		    Roby::Distributed.state.start_neighbour_discovery
		end
	    end

	    # Set up the loaded plugins
	    call_plugins(:setup, self)
	end

	def run(&block)
	    if !robot_name
		raise ArgumentError, "no robot defined"
	    end

	    control_config = self.control
	    control = Roby::Control.instance
	    options = { :detach => true, :control_gc => false }
	    if log['timings']
		logfile = File.join(APP_DIR, 'log', "#{robot_name}-timings.log")
		options[:log] = File.open(logfile, 'w')
	    end
	    if log['events']
		if log['events'] == 'sqlite'
		    require 'roby/log/sqlite'
		    logfile = File.join(APP_DIR, 'log', "#{robot_name}-events.db")
		    Roby::Log.loggers << Roby::Log::SQLiteLogger.new(logfile)
		else
		    require 'roby/log/file'
		    logfile = File.join(APP_DIR, 'log', "#{robot_name}-events.log")
		    Roby::Log.loggers << Roby::Log::FileLogger.new(logfile)
		end
	    end
	    control.abort_on_exception = 
		control_config['abort_on_exception']
	    control.abort_on_application_exception = 
		control_config['abort_on_application_exception']
	    control.run options

	    plugins = self.plugins.map { |_, mod| mod if mod.respond_to?(:run) }.compact
	    run_plugins(plugins, &block)
	end
	def run_plugins(mods, &block)
	    control = Roby::Control.instance
	    if mods.empty?
		begin
		    yield
		    control.join
		rescue Interrupt
		    control.quit
		    control.join
		end
	    else
		mod = mods.shift
		mod.run(self) do
		    run_plugins(mods, &block)
		end
	    end
	end

	def stop; call_plugins(:stop, self) end

	DISCOVERY_TEMPLATE = [:host, nil, nil, nil]
	def start_distributed
	    unless single? || !discovery['tuplespace']
		ts = Rinda::TupleSpace.new
		DRb.start_service "roby://#{discovery['tuplespace']}", ts

		new_db = ts.notify('write', DISCOVERY_TEMPLATE)
		take_db = ts.notify('take', DISCOVERY_TEMPLATE)

		Thread.start do
		    new_db.each { |_, t| STDERR.puts "new host #{t[3]}" }
		end
		Thread.start do
		    take_db.each { |_, t| STDERR.puts "host #{t[3]} has disconnected" }
		end
		STDERR.puts "Started service discovery on #{discovery['tuplespace']}"
	    end

	    call_plugins(:start_distributed, self)
	end

	def stop_distributed
	    DRb.stop_service

	    call_plugins(:stop_distributed, self)
	rescue Interrupt
	end

	def require_robotfile(pattern)
	    robot_config = pattern.gsub /ROBOT/, robot_name
	    if File.file?(robot_config)
		require robot_config
	    else
		robot_config = pattern.gsub /ROBOT/, robot_type
		if File.file?(robot_config)
		    require robot_config
		end
	    end
	end

	def simulation; @simulation = true end
	def simulation?; @simulation end
	def single; @single = true end
	def single?; @single || discovery.empty? end

	# Guesses the type of +filename+ if it is a source suitable for
	# data display in this application
	def data_source(filenames)
	    if filenames.size == 1 && filenames.first =~ /-events\.log(\.gz)$/
		Roby::Log::DataSource.new filenames.first
	    else
		each_responding_plugin(:data_source, true) do |config|
		    if source = config.data_source(filenames)
			return source
		    end
		end
	    end
	    nil
	end

	# Returns the list of data sources suitable for data display known
	# to the application
	def data_sources(logdir = nil)
	    logdir ||= File.join(APP_DIR, 'log')
	    sources = []
	    Dir.glob(File.join(logdir, '*-events.log*')).each do |file|
		next unless file =~ /-events\.log(\.gz)?$/
		sources << Roby::Log::PlanRebuild.new(file)
	    end
	    each_responding_plugin(:data_sources, true) do |config|
		if s = config.data_sources(logdir)
		    sources += s
		end
	    end
	    sources
	end

	def self.find_data(name)
	    Roby::State.datadirs.each do |dir|
		path = File.join(dir, name)
		return path if File.exists?(path)
	    end
	    raise Errno::ENOENT, "no such file #{path}"
	end

	def self.register_plugin(name, file, mod)
	    caller(1)[0] =~ /^([^:]+):\d/
	    file = File.join(File.expand_path(File.dirname($1)), file)

	    Roby.app.available_plugins << [name, file, mod]
	end
    end

    # Load the plugins 'main' files
    Roby.app.plugin_dir File.join(Application::ROBY_ROOT_DIR, 'plugins')
end

