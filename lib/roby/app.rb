module Roby
    # = Roby Applications
    #
    # There is one and only one Application object, which holds mainly the
    # system-wide configuration and takes care of file loading and system-wide
    # setup (#setup). A Roby application can be started in multiple modes. The
    # first and most important mode is the runtime mode
    # (<tt>scripts/run</tt>). Other modes are the testing mode (#testing?
    # returns true, entered through <tt>scripts/test</tt>) and the shell mode
    # (#shell? returns true, entered through <tt>scripts/shell</tt>). Usually,
    # user code does not have to take the modes into account, but it is
    # sometime useful.
    #
    # Finally, in both testing and runtime mode, the code can be started in
    # simulation or live setups (see #simulation?). Specific plugins can for
    # instance start and set up a simulation system in simulation mode, and as
    # well set up some simulation-specific configuration for the functional
    # layer of the architecture.
    #
    # == Configuration files
    #
    # In all modes, a specific set of configuration files are loaded.  The
    # files that are actually loaded are defined by the robot name and type, as
    # specified to #robot. The loaded files are, in order, the following:
    # [config/app.yml]
    #   the application configuration as a YAML file. See the comments in that
    #   file for more details.
    # [config/init.rb]
    #   Ruby code for the common configuration of all robots
    # [config/ROBOT_NAME.rb or config/ROBOT_TYPE.rb]
    #   Ruby code for the configuration of either all robots of the same type,
    #   or a specific robot. It is one or the other. If a given robot needs to
    #   inherit the configuration of its type, explicitely require the
    #   ROBOT_TYPE.rb file in config/ROBOT_NAME.rb.
    #
    # == Runtime mode (<tt>scripts/run</tt>)
    # Then, in runtime mode the robot controller
    # <tt>controller/ROBOT_NAME.rb</tt> or <tt>controller/ROBOT_TYPE.rb</tt> is
    # loaded. The same rules than for the configuration file
    # <tt>config/ROBOT_NAME.rb</tt> apply.
    #
    # == Testing mode (<tt>scripts/test</tt>)
    # This mode is used to run test suites in the +test+ directory. See
    # Roby::Test::TestCase for a description of Roby-specific tests.
    class Application
	include Singleton
        
	# A set of planners declared in this application
	attr_reader :planners

	# The plain option hash saved in config/app.yml
	attr_reader :options

	# Logging options.
	# events:: save a log of all events in the system. This log can be read using scripts/replay
	#          If this value is 'stats', only the data necessary for timing statistics is saved.
	# levels:: a component => level hash of the minimum level of the messages that 
	#	   should be displayed on the console. The levels are DEBUG, INFO, WARN and FATAL.
	#	     Roby: FATAL
	#	     Roby::Distributed: INFO
	# dir:: the log directory. Uses APP_DIR/log if not set
	# filter_backtraces:: true if the framework code should be removed from the error backtraces
	attr_reader :log

        # ExecutionEngine setup
        attr_reader :engine
	
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
	
	# If true, abort if an unhandled exception is found
	attr_predicate :abort_on_exception, true
	# If true, abort if an application exception is found
	attr_predicate :abort_on_application_exception, true

	# An array of directories in which to search for plugins
	attr_reader :plugin_dirs

	# True if user interaction is disabled during tests
	attr_predicate :automatic_testing?, true

	# True if all logs should be kept after testing
	attr_predicate :testing_keep_logs?, true

	# True if all logs should be kept after testing
	attr_predicate :testing_overwrites_logs?, true

	# True if we should remove the framework code from the error backtraces
	def filter_backtraces?; log['filter_backtraces'] end
	def filter_backtraces=(value); log['filter_backtraces'] = value end

	def initialize
	    @plugins = Array.new
	    @available_plugins = Array.new
	    @log = Hash['events' => 'stats', 'levels' => Hash.new, 'filter_backtraces' => true] 
	    @discovery = Hash.new
	    @droby     = Hash['period' => 0.5, 'max_errors' => 1] 
            @engine    = Hash.new

	    @automatic_testing = true
	    @testing_keep_logs = false

	    @plugin_dirs = []
            @planners    = []
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
	def load_yaml(options)
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

	    load_option_hashes(options, %w{log engine discovery droby})
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

        # The robot name
	attr_reader :robot_name
        # The robot type
        attr_reader :robot_type
        # Sets up the name and type of the robot. This can be called only once
        # in a given Roby controller.
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

        # Returns a unique directory name as a subdirectory of
        # +base_dir+, based on +path_spec+. The generated name
        # is of the form
        #   <base_dir>/a/b/c/YYYYMMDD-basename
        # if <tt>path_spec = "a/b/c/basename"</tt>. A .<number> suffix
        # is appended if the path already exists.
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

        # Sets up all the default loggers. It creates the logger for the Robot
        # module (accessible through Robot.logger), and sets up log levels as
        # specified in the <tt>config/app.yml</tt> file.
	def setup_loggers
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
	end

	def setup_dirs
	    FileUtils.mkdir_p(log_dir) unless File.exists?(log_dir)
	    if File.directory?(libdir = File.join(APP_DIR, 'lib'))
		if !$LOAD_PATH.include?(libdir)
		    $LOAD_PATH.unshift File.join(APP_DIR, 'lib')
		end
	    end

	    Roby::State.datadirs = []
	    datadir = File.join(APP_DIR, "data")
	    if File.directory?(datadir)
		Roby::State.datadirs << datadir
	    end
	end

        # Loads the models, based on the given robot name and robot type
	def require_models
	    # Require all common task models and the task models specific to
	    # this robot
	    require_dir(File.join(APP_DIR, 'tasks'))
	    require_robotdir(File.join(APP_DIR, 'tasks', 'ROBOT'))

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
	end

	def setup
            if !Roby.plan
                Roby.instance_variable_set :@plan, Plan.new
            end

	    reset
            require 'roby/planning'
            require 'roby/interface'

	    $LOAD_PATH.unshift(APP_DIR) unless $LOAD_PATH.include?(APP_DIR)

	    # Get the application-wide configuration
	    file = File.join(APP_DIR, 'config', 'app.yml')
	    file = YAML.load(File.open(file))
	    load_yaml(file)
	    if File.exists?(initfile = File.join(APP_DIR, 'config', 'init.rb'))
		load initfile
	    end

	    setup_dirs
	    setup_loggers

	    # Import some constants directly at toplevel before loading the
	    # user-defined models
	    unless Object.const_defined?(:Application)
		Object.const_set(:Application, Roby::Application)
		Object.const_set(:State, Roby::State)
	    end

	    require_models

	    # MainPlanner is always included in the planner list
	    self.planners << MainPlanner
	   
	    # Set up the loaded plugins
	    call_plugins(:setup, self)

	    # If we are in test mode, import the test extensions from plugins
	    if testing?
		require 'roby/test/testcase'
		each_plugin do |mod|
		    if mod.const_defined?(:Test)
			Roby::Test::TestCase.include mod.const_get(:Test)
		    end
		end
	    end
	end

	def run(&block)
            setup_global_singletons

	    # Set up dRoby, setting an Interface object as front server, for shell access
	    host = droby['host'] || ""
	    if host !~ /:\d+$/
		host << ":#{Distributed::DEFAULT_DROBY_PORT}"
	    end

	    if single? || !robot_name
		host =~ /:(\d+)$/
		DRb.start_service "druby://:#{$1 || '0'}", Interface.new(Roby.engine)
	    else
		DRb.start_service "druby://#{host}", Interface.new(Roby.engine)
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
		Roby.every(discovery['period'] || 0.5) do
		    Roby::Distributed.state.start_neighbour_discovery
		end
	    end

	    @robot_name ||= 'common'
	    @robot_type ||= 'common'

	    engine_config = self.engine
	    engine = Roby.engine
	    options = { :cycle => engine_config['cycle'] || 0.1 }
	    
	    if log['events']
		require 'roby/log/file'
		logfile = File.join(log_dir, robot_name)
		logger  = Roby::Log::FileLogger.new(logfile)
		logger.stats_mode = log['events'] == 'stats'
		Roby::Log.add_logger logger
	    end
	    engine.run options

	    plugins = self.plugins.map { |_, mod| mod if mod.respond_to?(:run) }.compact
	    run_plugins(plugins, &block)

        rescue Exception => e
            if e.respond_to?(:pretty_print)
                pp e
            else
                pp e.full_message
            end
	end
	def run_plugins(mods, &block)
	    engine = Roby.engine

	    if mods.empty?
		yield
		engine.join
	    else
		mod = mods.shift
		mod.run(self) do
		    run_plugins(mods, &block)
		end
	    end

	rescue Exception => e
	    if Roby.engine.running?
		engine.quit
		engine.join
		raise e, e.message, e.backtrace
	    else
		raise
	    end
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
		FileUtils.mkdir_p(log_dir)
	    end

	    unless single? || !discovery['tuplespace']
		ts = Rinda::TupleSpace.new


		discovery['tuplespace'] =~ /(:\d+)$/
		DRb.start_service "druby://#{$1}", ts

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

	# Require all files in +dirname+
	def require_dir(dirname)
	    Dir.new(dirname).each do |file|
		file = File.join(dirname, file)
		file = file.gsub(/^#{Regexp.quote(APP_DIR)}\//, '')
		require file if file =~ /\.rb$/ && File.file?(file)
	    end
	end

	# Require all files in the directories matching +pattern+. If +pattern+
	# contains the word ROBOT, it is replaced by -- in order -- the robot
	# name and then the robot type
	def require_robotdir(pattern)
	    return unless robot_name && robot_type

	    [robot_name, robot_type].each do |name|
		dirname = pattern.gsub(/ROBOT/, name)
		require_dir(dirname) if File.directory?(dirname)
	    end
	end

	# Loads the first file found matching +pattern+
	#
	# See #require_robotfile
	def load_robotfile(pattern)
	    require_robotfile(pattern, :load)
	end

	# Requires or loads (according to the value of +method+) the first file
	# found matching +pattern+. +pattern+ can contain the word ROBOT, in
	# which case the file is first checked against the robot name and then
	# against the robot type
	def require_robotfile(pattern, method = :require)
	    return unless robot_name && robot_type

	    robot_config = pattern.gsub(/ROBOT/, robot_name)
	    if File.file?(robot_config)
		Kernel.send(method, robot_config)
		true
	    else
		robot_config = pattern.gsub(/ROBOT/, robot_type)
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
	attr_predicate :shell?, true
	def shell; self.shell = true end
	def single?; @single || discovery.empty? end
	def single;  @single = true end

        def setup_global_singletons
            if !Roby.plan
                Roby.instance_variable_set :@plan, Plan.new
            end

            if !Roby.engine && Roby.plan.engine
                # This checks coherence with Roby.control, and sets it
                # accordingly
                Roby.engine  = Roby.plan.engine
            elsif !Roby.control
                Roby.control = DecisionControl.new
            end

            if !Roby.engine
                Roby.engine  = ExecutionEngine.new(Roby.plan, Roby.control)
            end

            if Roby.control != Roby.engine.control
                raise "inconsistency between Roby.control and Roby.engine.control"
            elsif Roby.engine != Roby.plan.engine
                raise "inconsistency between Roby.engine and Roby.plan.engine"
            end

            if !Roby.engine.scheduler && Roby.scheduler
                Roby.engine.scheduler = Roby.scheduler
            end
        end

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

    @app = Application.instance
    class << self
        # The one and only Application object
        attr_reader :app

        # The scheduler object to be used during execution. See
        # ExecutionEngine#scheduler.
        #
        # This is only used during the configuration of the application, and
        # not afterwards. It is also possible to set per-engine through
        # ExecutionEngine#scheduler=
        attr_accessor :scheduler
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

