require 'roby'
require 'roby/distributed'
require 'roby/planning'
require 'roby/log'
require 'roby/log/event_stream'

require 'roby/robot'

module Roby
    # Returns the only one Application object
    def self.app; Application.instance end

    # = Roby Applications
    #
    # == Directory Layout
    # config/
    # tasks/
    # planners/
    # data/
    #
    # == Scripts
    #
    # == Configuration
    # * YAML configuration files (config/roby.yml and config/app.yml)
    # * init.rb
    # * robot-specific configuration files, robot kind and single robots
    # * load order (roby, plugins, init.rb, Roby and plugin configuration,
    #   robot-specific configuration files, controller)
    #
    # == Test support
    #
    class Application
	include Singleton

	# The plain option hash saved in config/app.yml
	attr_reader :options

	# Logging options.
	# timings:: saves a ROBOT-timings.log file with the timings of each step in the event loop
	#           This log can be read using roby-cntrllog
	# events:: save a log of all events in the system. This log can be read using scripts/replay
	# levels:: a component => level hash of the minimum level of the messages that 
	#	   should be displayed on the console. The levels are DEBUG, INFO, WARN and FATAL.
	#	     Roby: FATAL
	#	     Roby::Distributed: INFO
	# dir:: the log directory. Uses APP_DIR/log if not set
	attr_reader :log
	
	# A [name, dir, file, module] array of available plugins, where 'name'
	# is the plugin name, 'dir' the directory in which it is installed,
	# 'file' the file which should be required to load the plugin and
	# 'module' the Application-compatible module for configuration of the
	# plug-in
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

	# True if user interaction is disabled during tests
	attr_predicate :automatic_testing?, true

	# True if all logs should be kept after testing
	attr_predicate :testing_keep_logs?, true

	def initialize
	    @plugins = Array.new
	    @available_plugins = Array.new
	    @log = Hash['timings' => false, 'events' => false, 'levels' => Hash.new] 
	    @discovery = Hash.new
	    @droby     = Hash['period' => 0.5, 'max_errors' => 1] 
	    @control   = Hash[ 'abort_on_exception' => false, 
		'abort_on_application_exception' => true ]

	    @automatic_testing = true
	    @testing_keep_logs = false

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
		    Roby.warn "cannot load plugin in #{subdir}: #{$!.full_message}\n"
		end
		Roby.info "loaded plugin in #{subdir}"
	    end
	end

	# Returns true if +name+ is a loaded plugin
	def loaded_plugin?(name)
	    plugins.any? { |plugname, _| plugname == name }
	end

	# Returns the [name, dir, file, module] array definition of the plugin
	# +name+, or nil if +name+ is not a known plugin
	def plugin_definition(name)
	    available_plugins.find { |plugname, *_| plugname == name }
	end

	# True if +name+ is a plugin known to us
	def defined_plugin?(name)
	    available_plugins.any? { |plugname, *_| plugname == name }
	end

	def each_plugin(on_available = false)
	    plugins = self.plugins
	    if on_available
		plugins = available_plugins.map { |name, _, mod, _| [name, mod] }
	    end
	    plugins.each do |_, mod|
		yield(mod)
	    end
	end

	# Yields each extension modules that respond to +method+
	def each_responding_plugin(method, on_available = false)
	    each_plugin do |mod|
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
		name = name.to_s
		unless plugin = plugin_definition(name)
		    raise ArgumentError, "#{name} is not a known plugin (#{available_plugins.map { |n, *_| n }.join(", ")})"
		end
		name, dir, mod, init = *plugin
		if plugins.find { |n, m| n == name && m == mod }
		    next
		end

		if init
		    begin
			$LOAD_PATH.unshift dir
			init.call
			mod.reset(self) if mod.respond_to?(:reset)
		    rescue Exception => e
			Roby.fatal "cannot load plugin #{name}: #{e.full_message}"
			exit(1)
		    ensure
			$LOAD_PATH.shift
		    end
		end

		plugins << [name, mod]
		extend mod
		# If +load+ has already been called, call it on the module
		if mod.respond_to?(:load) && options
		    mod.load(self, options)
		end
	    end
	end

	def reset
	    if defined? State
		State.clear
	    else
		Roby.const_set(:State, StateSpace.new)
	    end
	    call_plugins(:reset, self)
	end

	attr_reader :robot_name, :robot_type
	def robot(name, type = name)
	    if @robot_name
		if name != @robot_name && type != @robot_type
		    raise ArgumentError, "the robot is already set to #{name}, of type #{type}"
		end
		return
	    end
	    @robot_name = name
	    @robot_type = type
	end

	# The directory in which logs are to be saved
	# Defaults to APP_DIR/log
	def log_dir
	    File.expand_path(log['dir'] || 'log', APP_DIR)
	end

	# A path => File hash, to re-use the same file object for different
	# logs
	attribute(:log_files) { Hash.new }

	# The directory in which results should be saved
	# Defaults to APP_DIR/results
	def results_dir
	    File.expand_path(log['results'] || 'results', APP_DIR)
	end

	def self.unique_dirname(base_dir, path_spec)
	    if path_spec =~ /\/$/
		basename = ""
		dirname = path_spec
	    else
		basename = File.basename(path_spec)
		dirname  = File.dirname(path_spec)
	    end

	    date = Date.today
	    date = "%i%02i%02i" % [date.year, date.month, date.mday]
	    if basename && !basename.empty?
		basename = date + "-" + basename
	    else
		basename = date
	    end

	    # Check if +basename+ already exists, and if it is the case add a
	    # .x suffix to it
	    full_path = File.expand_path(File.join(dirname, basename), base_dir)
	    base_dir  = File.dirname(full_path)

	    unless File.exists?(base_dir)
		FileUtils.mkdir_p(base_dir)
	    end

	    final_path, i = full_path, 0
	    while File.exists?(final_path)
		i += 1
		final_path = full_path + ".#{i}"
	    end

	    final_path
	end

	def setup
	    # Set up the log directory first
	    if testing? && File.exists?(log_dir)
		if !STDIN.ask("#{log_dir} still exists. I'll have to clean it up before starting the tests. Proceed ? [N,y]", false)
		    raise "user abort"
		end
		FileUtils.rm_rf log_dir
	    end

	    if !File.exists?(log_dir)
		Dir.mkdir(log_dir)
	    end

	    if File.directory?(File.join(APP_DIR, 'lib'))
		$LOAD_PATH.unshift File.join(APP_DIR, 'lib')
	    end

	    # Create the robot namespace
	    STDOUT.sync = true
	    Robot.logger = Logger.new(STDOUT)
	    Robot.logger.level = Logger::INFO
	    Robot.logger.formatter = Roby.logger.formatter
	    Robot.logger.progname = robot_name

	    # Set up log levels
	    log['levels'].each do |name, value|
		name = name.camelize
		if value =~ /^(\w+):(.+)$/
		    level, file = $1, $2
		    level = Logger.const_get(level)
		    file = file.gsub('ROBOT', robot_name) if robot_name
		else
		    level = Logger.const_get(value)
		end

		new_logger = if file
				 path = File.expand_path(file, log_dir)
				 io   = (log_files[path] ||= File.open(path, 'w'))
				 Logger.new(io)
			     else Logger.new(STDOUT)
			     end
		new_logger.level     = level
		new_logger.formatter = Roby.logger.formatter

		if (mod = name.constantize rescue nil)
		    if robot_name
			new_logger.progname = "#{name} #{robot_name}"
		    else
			new_logger.progname = name
		    end
		    mod.logger = new_logger
		end
	    end

	    # Require all common task models and the task models specific to
	    # this robot
	    require_dir(File.join(APP_DIR, 'tasks'))
	    require_robotdir(File.join(APP_DIR, 'tasks', 'ROBOT'))

	    Roby::State.datadirs = []
	    datadir = File.join(APP_DIR, "data")
	    if File.directory?(datadir)
		Roby::State.datadirs << datadir
	    end

	    # Import some constants directly at toplevel
	    Object.const_set(:Application, Roby::Application)
	    Object.const_set(:State, Roby::State)

	    # Load robot-specific configuration
	    planner_dir = File.join(APP_DIR, 'planners')
	    models_search = [planner_dir]
	    if robot_name
		load_robotfile(File.join(APP_DIR, 'config', "ROBOT.rb"))

		models_search << File.join(planner_dir, robot_name) << File.join(planner_dir, robot_type)
		if !require_robotfile(File.join(APP_DIR, 'planners', 'ROBOT', 'main.rb'))
		    require File.join(APP_DIR, "planners", "main")
		end
	    else
		require File.join(APP_DIR, "planners", "main")
	    end

	    # Load the other planners
	    models_search.each do |base_dir|
		next unless File.directory?(base_dir)
		Dir.new(base_dir).each do |file|
		    if File.file?(file) && file =~ /\.rb$/ && file !~ 'main\.rb$'
			require file
		    end
		end
	    end

	    # MainPlanner is always included in the planner list
	    Roby.control.planners << MainPlanner
	   
	    # Set up the loaded plugins
	    call_plugins(:setup, self)

	    # If we are in test mode, import the test extensions from plugins
	    if testing?
		require 'roby/test/testcase'
		each_plugin do |mod|
		    puts mod
		    if mod.const_defined?(:Test)
			Roby::Test::TestCase.include mod.const_get(:Test)
		    end
		end
	    end
	end

	def run(&block)
	    # Set up dRoby, setting an Interface object as front server, for shell access
	    host = droby['host'] || ""
	    if host !~ /:\d+$/
		host << ":#{Distributed::DEFAULT_DROBY_PORT}"
	    end

	    if single? || !robot_name
		host =~ /:(\d+)$/
		DRb.start_service "druby://:#{$1 || '0'}", Interface.new(Roby.control)
	    else
		DRb.start_service "druby://#{host}", Interface.new(Roby.control)
		droby_config = { :ring_discovery => !!discovery['ring'],
		    :name => robot_name, 
		    :plan => Roby.plan, 
		    :period => discovery['period'] || 0.5 }

		if discovery['tuplespace']
		    droby_config[:discovery_tuplespace] = DRbObject.new_with_uri("druby://#{discovery['tuplespace']}")
		end
		Roby::Distributed.state = Roby::Distributed::ConnectionSpace.new(droby_config)

		if discovery['ring']
		    Roby::Distributed.publish discovery['ring']
		end
		Roby::Control.every(discovery['period'] || 0.5) do
		    Roby::Distributed.state.start_neighbour_discovery
		end
	    end

	    @robot_name ||= 'common'
	    @robot_type ||= 'common'

	    control_config = self.control
	    control = Roby.control
	    options = { :detach => true, 
		:control_gc => control_config['control_gc'], 
		:cycle => control_config['cycle'] || 0.1 }
	    
	    # Add an executive if one is defined
	    if control_config['executive']
		self.executive = control_config['executive']
	    end

	    if log['events']
		require 'roby/log/file'
		logfile = File.join(log_dir, robot_name)
		logger  = Roby::Log::FileLogger.new(logfile)
		logger.stats_mode = log['events'] == 'stats'
		Roby::Log.add_logger logger
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
	    control = Roby.control
	    if mods.empty?
		begin
		    yield
		    control.join
		rescue Exception => e
		    control.quit
		    control.join
		    if e.kind_of?(Interrupt)
			Roby.fatal "interrupted"
		    else
			raise e, e.message, Roby.filter_backtrace(e.backtrace)
		    end
		end
	    else
		mod = mods.shift
		mod.run(self) do
		    run_plugins(mods, &block)
		end
	    end
	end

	attr_reader :executive

	def executive=(name)
	    if executive
		Control.event_processing.delete(executive.method(:initial_events))
		@executive = nil
	    end
	    return unless name

	    full_name = "roby/executives/#{name}"
	    require full_name
	    @executive = full_name.camelize.constantize.new
	    Control.event_processing << executive.method(:initial_events)
	end

	def stop; call_plugins(:stop, self) end

	DISCOVERY_TEMPLATE = [:droby, nil, nil]

	# Starts services needed for distributed operations. These services are
	# supposed to be started only once for a whole system
	#
	# If you have external servers to start for every robot, plug it into
	# #start_server
	def start_distributed
	    Thread.abort_on_exception = true

	    if !File.exists?(log_dir)
		Dir.mkdir(log_dir)
	    end

	    unless single? || !discovery['tuplespace']
		ts = Rinda::TupleSpace.new
		DRb.start_service "druby://#{discovery['tuplespace']}", ts

		new_db  = ts.notify('write', DISCOVERY_TEMPLATE)
		take_db = ts.notify('take', DISCOVERY_TEMPLATE)

		Thread.start do
		    new_db.each { |_, t| STDERR.puts "new host #{t[1]}" }
		end
		Thread.start do
		    take_db.each { |_, t| STDERR.puts "host #{t[1]} has disconnected" }
		end
		Roby.warn "Started service discovery on #{discovery['tuplespace']}"
	    end

	    call_plugins(:start_distributed, self)
	end

	# Stop services needed for distributed operations. See #start_distributed
	def stop_distributed
	    DRb.stop_service

	    call_plugins(:stop_distributed, self)
	rescue Interrupt
	end

	attr_reader :log_server
	attr_reader :log_sources

	# Start services that should exist for every robot in the system. Services that
	# are needed only once for all robots should be started in #start_distributed
	def start_server
	    Thread.abort_on_exception = true

	    # Start a log server if needed, and poll the log directory for new
	    # data sources
	    if log_server = (log.has_key?('server') ? log['server'] : true)
		require 'roby/log/server'
		port = if log_server.kind_of?(Hash) && log_server['port']
			   Integer(log_server['port'])
		       end

		@log_server  = Log::Server.new(port ||= Log::Server::RING_PORT)
		Roby::Log::Server.info "log server published on port #{port}"
		@log_streams = []
		@log_streams_poll = Thread.new do
		    begin
			loop do
			    Thread.exclusive do
				known_streams = @log_server.streams
				streams	  = data_streams

				(streams - known_streams).each do |s|
				    Roby::Log::Server.info "new stream found #{s.name} [#{s.type}]"
				    s.open
				    @log_server.added_stream(s)
				end
				(known_streams - streams).each do |s|
				    Roby::Log::Server.info "end of stream #{s.name} [#{s.type}]"
				    s.close
				    @log_server.removed_stream(s)
				end
			    end
			    sleep(5)
			end
		    rescue Interrupt
		    rescue
			Roby::Log::Server.fatal $!.full_message
		    end
		end
	    end

	    call_plugins(:start_server, self)
	end

	# Stop server. See #start_server
	def stop_server
	    if @log_server
		@log_streams_poll.raise Interrupt, "quitting"
		@log_streams_poll.join

		@log_server.quit
		@log_streams.clear
	    end

	    call_plugins(:stop_server, self)
	end

	def require_dir(dirname)
	    Dir.new(dirname).each do |file|
		file = File.join(dirname, file)
		file = file.gsub /^#{Regexp.quote(APP_DIR)}\//, ''
		require file if file =~ /\.rb$/ && File.file?(file)
	    end
	end

	def require_robotdir(pattern)
	    return unless robot_name && robot_type

	    [robot_name, robot_type].each do |name|
		dirname = pattern.gsub /ROBOT/, name
		require_dir(dirname) if File.directory?(dirname)
	    end
	end

	def load_robotfile(pattern)
	    require_robotfile(pattern, :load)
	end

	def require_robotfile(pattern, method = :require)
	    return unless robot_name && robot_type

	    robot_config = pattern.gsub /ROBOT/, robot_name
	    if File.file?(robot_config)
		Kernel.send(method, robot_config)
		true
	    else
		robot_config = pattern.gsub /ROBOT/, robot_type
		if File.file?(robot_config)
		    Kernel.send(method, robot_config)
		    true
		else
		    false
		end
	    end
	end

	attr_predicate :simulation?, true
	def simulation; self.simulation = true end
	attr_predicate :testing?, true
	def testing; self.testing = true end
	def single?; @single || discovery.empty? end
	def single;  @single = true end

	# Guesses the type of +filename+ if it is a source suitable for
	# data display in this application
	def data_streams_of(filenames)
	    if filenames.size == 1
		path = filenames.first
		path = if path =~ /-(events|timings)\.log$/
			   $`
		       elsif File.exists?("#{path}-events.log")
			   path
		       end
		if path
		    return [Roby::Log::EventStream.new(path)]
		end
	    end

	    each_responding_plugin(:data_streams_of, true) do |config|
		if streams = config.data_streams_of(filenames)
		    return streams
		end
	    end
	    nil
	end

	# Returns the list of data streams suitable for data display known
	# to the application
	def data_streams(log_dir = nil)
	    log_dir ||= self.log_dir
	    streams = []
	    Dir.glob(File.join(log_dir, '*-events.log*')).each do |file|
		next unless file =~ /-events\.log$/
		streams << Roby::Log::EventStream.new($`)
	    end
	    each_responding_plugin(:data_streams, true) do |config|
		if s = config.data_streams(log_dir)
		    streams += s
		end
	    end
	    streams
	end

	def self.find_data(name)
	    Roby::State.datadirs.each do |dir|
		path = File.join(dir, name)
		return path if File.exists?(path)
	    end
	    raise Errno::ENOENT, "no file #{name} found in #{Roby::State.datadirs.join(":")}"
	end

	def self.register_plugin(name, mod, &init)
	    caller(1)[0] =~ /^([^:]+):\d/
	    dir  = File.expand_path(File.dirname($1))
	    Roby.app.available_plugins << [name, dir, mod, init]
	end

	@@reload_model_filter = []
	# Add a filter to model reloading. A task or planner model is
	# reinitialized only if all filter blocks return true for it
	def self.filter_reloaded_models(&block)
	    @@reload_model_filter << block
	end

	def model?(model)
	    (model <= Roby::Task) || (model.kind_of?(Roby::TaskModelTag)) || 
		(model <= Planning::Planner) || (model <= Planning::Library)
	end

	def reload_model?(model)
	    @@reload_model_filter.all? { |filter| filter[model] }
	end

	def app_file?(path)
	    (path =~ %r{(^|/)#{APP_DIR}(/|$)}) ||
		((path[0] != ?/) && File.file?(File.join(APP_DIR, path)))
	end
	def framework_file?(path)
	    if path =~ /roby\/.*\.rb$/
		true
	    else
		Roby.app.plugins.any? do |name, _|
		    _, dir, _, _ = Roby.app.plugin_definition(name)
		    path =~ %r{(^|/)#{dir}(/|$)}
		end
	    end
	end

	def reload
	    # Always reload this file first. This ensure that one can use #reload
	    # to fix the reload code itself
	    load __FILE__

	    # Clear all event definitions in task models that are filtered out by
	    # Application.filter_reloaded_models
	    ObjectSpace.each_object(Class) do |model|
		next unless model?(model)
		next unless reload_model?(model)

		model.clear_model
	    end

	    # Remove what we want to reload from LOADED_FEATURES and use
	    # require. Do not use 'load' as the reload order should be the
	    # require order.
	    needs_reload = []
	    $LOADED_FEATURES.delete_if do |feature|
		if framework_file?(feature) || app_file?(feature)
		    needs_reload << feature
		end
	    end

	    needs_reload.each do |feature|
		begin
		    require feature.gsub(/\.rb$/, '')
		rescue Exception => e
		    STDERR.puts e.full_message
		end
	    end
	end
    end

    # Load the plugins 'main' files
    Roby.app.plugin_dir File.join(ROBY_ROOT_DIR, 'plugins')
    if plugin_path = ENV['ROBY_PLUGIN_PATH']
	plugin_path.split(':').each do |dir|
	    if File.directory?(dir)
		Roby.app.plugin_dir File.expand_path(dir)
	    end
	end
    end
end

