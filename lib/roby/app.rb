require 'roby/support'
require 'roby/robot'
require 'roby/app/robot_names'
require 'singleton'
require 'utilrb/hash'
require 'utilrb/module/attr_predicate'
require 'yaml'
require 'utilrb/pathname/find_matching_parent'
require 'roby/app/base'

module Roby
    # Regular expression that matches backtrace paths that are within the
    # Roby framework
    RX_IN_FRAMEWORK = /^((?:\s*\(druby:\/\/.+\)\s*)?#{Regexp.quote(ROBY_LIB_DIR)}\/)|^\(eval\)|^\/usr\/lib\/ruby/
    RX_IN_METARUBY = /^(?:\s*\(druby:\/\/.+\)\s*)?#{Regexp.quote(MetaRuby::LIB_DIR)}\//
    RX_IN_UTILRB = /^(?:\s*\(druby:\/\/.+\)\s*)?#{Regexp.quote(Utilrb::LIB_DIR)}\//
    # Regular expression that matches backtrace paths that are require lines
    RX_REQUIRE = /in `(gem_original_)?require'$/

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
    #
    # == Plugin Integration
    # Plugins are integrated by providing methods that get called during setup
    # and teardown of the application. It is therefore important to understand
    # the order in which methods get called, and where the plugins can
    # 'plug-in' this process.
    #
    # On setup, the following methods are called:
    # - load base configuration files. app.yml and init.rb
    # - load_base_config hook
    # - set up directories (log dir, ...) and loggers
    # - set up singletons
    # - base_setup hook
    # - setup hook. The difference is that the setup hook is called only if
    #   #setup is called. base_setup is always called.
    # - load models in models/tasks
    # - require_models hook
    # - load models in models/planners and models/actions
    # - require_planners hook
    # - load additional model files
    # - finalize_model_loading hook
    # - load config file config/ROBOT.rb
    # - require_config hook
    # - setup main planner
    # - setup testing if in testing mode
    # - setup shell interface
    class Application
        extend Logger::Hierarchy
        extend Logger::Forward

        # The main plan on which this application acts
        attr_reader :plan

        # The engine associated with {#plan}
        def engine; plan.engine if plan end
        
	# A set of planners declared in this application
	attr_reader :planners

	# Applicatio configuration information is stored in a YAML file
        # config/app.yml. The options are saved in a hash.
        #
        # This attribute contains the raw hash as read from the file. It is
        # overlaid 
	attr_reader :options

        # A set of exceptions that have been encountered by the application
        # The associated string, if given, is a hint about in which context
        # this exception got raised
        # @return [Array<(Exception,String)>]
        # @see #register_exception #clear_exceptions
        attr_reader :registered_exceptions

        # Allows to attribute configuration keys to override configuration
        # parameters stored in config/app.yml
        #
        # For instance,
        #
        #    attr_config 'log'
        #
        # creates a log_overrides attribute, which contains a hash. Any value
        # stored in this hash will override those stored in the config file. The
        # final value can be accessed by accessing the generated #config_key
        # method:
        #
        # E.g.,
        #
        # in config/app.yml:
        #
        #   log:
        #       dir: test
        #
        # in config/init.rb:
        #
        #   Roby.app.log_overrides['dir'] = 'bla'
        #
        # Then, Roby.app.log will return { 'dir' => 'bla }
        #
        # This override mechanism is not meant to be used directly by the user,
        # but as a tool for the rest of the framework
        def self.attr_config(config_key)
            config_key = config_key.to_s

            # Ignore if already done
            return if method_defined?("#{config_key}_overrides")

            attribute("#{config_key}_overrides") { Hash.new }
            define_method(config_key) do
                plain     = self.options[config_key] || Hash.new
                overrides = instance_variable_get "@#{config_key}_overrides"
                if overrides
                    plain.recursive_merge(overrides)
                else
                    plain
                end
            end
        end

        # Defines accessors for a configuration parameter stored in #options
        #
        # This method allows to define a getter and a setter for a parameter
        # stored in #options that should be user-overridable. It builds upon
        # #attr_config.
        #
        # For instance:
        #
        #   overridable_configuration 'log', 'filter_backtraces'
        #
        # will create a #filter_backtraces getter and a #filter_backtraces=
        # setter which allow to respectively access the log/filter_backtraces
        # configuration value, and override it from its value in config/app.yml
        #
        # The :predicate option allows to make the setter look like a predicate:
        #
        #   overridable_configuration 'log', 'filter_backtraces', :predicate => true
        #
        # will define #filter_backtraces? instead of #filter_backtraces
        def self.overridable_configuration(config_set, config_key, options = Hash.new)
            options = Kernel.validate_options options, :predicate => false, :attr_name => config_key
            attr_config(config_set)
            define_method("#{options[:attr_name]}#{"?" if options[:predicate]}") do
                send(config_set)[config_key]
            end
            define_method("#{options[:attr_name]}=") do |new_value|
                send("#{config_set}_overrides")[config_key] = new_value
            end
        end

        # Allows to override the application base directory. See #app_dir
        attr_writer :app_dir

        # If set to true, files that generate errors while loading will be
        # ignored. This is used for model browsing GUIs to be usable even if
        # there are errors
        #
        # It is false by default
        attr_predicate :ignore_all_load_errors?, true

        # If set to true, tests will show detailed execution timings
        #
        # It is false by default
        attr_predicate :test_show_timings?, true

        # The options passed to Utilrb::Timepoints#format_timepoints if
        # {#test_show_timings?} is true
        attr_reader :test_format_timepoints_options

        # How many times each test should be repeated (defaults to 1)
        #
        # This is mostly useful when profiling is enabled
        #
        # @return [Integer]
        attr_accessor :test_repeat

        # List of subsystems that should be profiles during testing
        #
        # Profiling is done using perftools.rb. All profiles are aggregated
        # (run the tests separately if you need one profile per test)
        #
        # Roby knows 'test', which profiles the test without setup and teardown.
        # The default is empty (no profiling)
        #
        # @return [Array<String>]
        attr_reader :test_profile

        # Returns the name of the application
        def app_name
            if @app_name
                @app_name
            else
                File.basename(app_dir)
            end
        end

        # Allows to override the app name
        #
        # The default is to convert the app dir's basename to camelcase, but
        # that fails in some cases (mostly, when there are acronyms in the name)
        attr_writer :app_name

        # Returns the name of this app's toplevel module
        def module_name
            app_name.camelize
        end

        # Returns the application base directory
        def app_dir
            if defined?(APP_DIR)
                APP_DIR
            elsif @app_dir
                @app_dir
            end
        end

        # Tests if the given directory looks like the root of a Roby app
        def self.is_app_dir?(test_dir)
            File.file?(File.join(test_dir, 'config', 'app.yml')) ||
                File.directory?(File.join(test_dir, 'models')) ||
                File.directory?(File.join(test_dir, 'scripts', 'controllers')) ||
                File.directory?(File.join(test_dir, 'config', 'robots'))
        end

        # Guess the app directory based on the current directory. It will not do
        # anything if the current directory is not in a Roby app. Moreover, it
        # does nothing if #app_dir is already set
        #
        # @return [String] the selected app directory
        def guess_app_dir
            return if @app_dir
            app_dir = Pathname.new(Dir.pwd).find_matching_parent do |test_dir|
                Application.is_app_dir?(test_dir.to_s)
            end
            if app_dir
                @app_dir = app_dir.to_s
            end
        end

        # Call to require this roby application to be in a Roby application
        #
        # It tries to guess the app directory. If none is found, it raises.
        def require_app_dir
            guess_app_dir
            if !@app_dir
                raise ArgumentError, "your current directory does not seem to be a Roby application directory; did you forget to run 'roby init'?"
            end
        end

        # A list of paths in which files should be looked for in #find_dirs,
        # #find_files and #find_files_in_dirs
        #
        # If uninitialized, [app_dir] is used
        attr_writer :search_path

        # The list of paths in which the application should be looking for files
        def search_path
            if !@search_path
                if app_dir
                    [app_dir]
                else []
                end
            else
                @search_path
            end
        end

	# Logging options.
	# events:: save a log of all events in the system. This log can be read using scripts/replay
	#          If this value is 'stats', only the data necessary for timing statistics is saved.
	# levels:: a component => level hash of the minimum level of the messages that 
	#	   should be displayed on the console. The levels are DEBUG, INFO, WARN and FATAL.
	#	     Roby: FATAL
	#	     Roby::Distributed: INFO
	# dir:: the log directory. Uses $app_dir/log if not set
        # results:: the 
	# filter_backtraces:: true if the framework code should be removed from the error backtraces
	attr_config :log

        # ExecutionEngine setup
        attr_config :engine
	
	# A [name, dir, file, module] array of available plugins, where 'name'
	# is the plugin name, 'dir' the directory in which it is installed,
	# 'file' the file which should be required to load the plugin and
	# 'module' the Application-compatible module for configuration of the
	# plug-in
	attr_reader :available_plugins
	# An [name, module] array of the loaded plugins
	attr_reader :plugins

	# The discovery options in multi-robot mode
	attr_config :discovery

	# The robot's dRoby options
	# period:: the period of neighbour discovery
	# max_errors:: disconnect from a peer if there is more than +max_errors+ consecutive errors
	#              detected
	attr_config :droby
	
	# If true, abort if an unhandled exception is found
	attr_predicate :abort_on_exception, true
	# If true, abort if an application exception is found
	attr_predicate :abort_on_application_exception, true

	# True if user interaction is disabled during tests
	attr_predicate :automatic_testing?, true

        # True if plugins should be discovered, registered and loaded (true by
        # default)
        attr_predicate :plugins_enabled?, true

        # @return [Array<String>] list of paths to files not in models/ that
        #   contain some models. This is mainly used by the command-line tools
        #   so that the user can load separate "model-based scripts" files.
        attr_reader :additional_model_files

        # @return [Array<#call>] list of objects called when the app gets
        #   initialized (i.e. just after init.rb is loaded)
        attr_reader :init_handlers

        # @return [Array<#call>] list of objects called when the app gets
        #   initialized (i.e. in {setup} after {base_setup})
        attr_reader :setup_handlers

        # @return [Array<#call>] list of objects called when the app gets
        #   to require its models (i.e. after {require_models})
        attr_reader :require_handlers

        # @return [Array<#call>] list of objects called when the app loaded
        #   its configuration (i.e. after {require_config})
        attr_reader :config_handlers

        # @return [Array<#call>] list of objects called when the app cleans up
        #   (it is the opposite of setup)
        attr_reader :cleanup_handlers

        # @return [Array<#call>] list of blocks that should be executed once the
        #   application is started
        attr_reader :controllers

        # @return [Array<#call>] list of blocks that should be executed once the
        #   application is started
        attr_reader :action_handlers

        # Defines common configuration options valid for all Roby-oriented
        # scripts
        def self.common_optparse_setup(parser)
            Roby.app.load_config_yaml
            parser.on("--log=SPEC", String, "configuration specification for text loggers. SPEC is of the form path/to/a/module:LEVEL[:FILE][,path/to/another]") do |log_spec|
                log_spec.split(',').each do |spec|
                    mod, level, file = spec.split(':')
                    Roby.app.log_setup(mod, level, file)
                end
            end
            parser.on('-r NAME', '--robot=NAME[,TYPE]', String, 'the robot name and type') do |name|
                robot_name, robot_type = name.split(',')
                Roby.app.robot(robot_name, robot_type)
            end
            parser.on('--debug', 'run in debug mode') do
                Roby.app.public_logs = true
                Roby.app.filter_backtraces = false
            end
            parser.on_tail('-h', '--help', 'this help message') do
                STDERR.puts parser
                exit
            end
        end

        # Array of regular expressions used to filter out backtraces
        attr_reader :filter_out_patterns

        # Configures a text logger in the system. It has to be called before
        # #setup to have an effect.
        #
        # It overrides configuration from the app.yml file
        #
        # For instance,
        #
        #   log_setup 'roby/execution_engine', 'DEBUG'
        #
        # will be equivalent to having the following entry in config/app.yml:
        #
        #   log:
        #       levels:
        #           roby/execution_engine: DEBUG
        def log_setup(mod_path, level, file = nil)
            levels = (log_overrides['levels'] ||= Hash.new)
            levels[mod_path] = [level, file].compact.join(":")
        end

	##
        # :method: filter_backtraces?
        #
        # True if we should remove the framework code from the error backtraces

        ##
        # :method: filter_backtraces=
        #
        # Override the value stored in configuration files for filter_backtraces?

        overridable_configuration 'log', 'filter_backtraces', :predicate => true

	##
        # :method: log_server?
        #
        # True if the log server should be started

        ##
        # :method: log_server=
        #
        # Sets whether the log server should be started

        overridable_configuration 'log', 'server', :predicate => true, :attr_name => 'log_server'

        DEFAULT_OPTIONS = {
	    'log' => Hash['events' => true, 'levels' => Hash.new, 'filter_backtraces' => true],
	    'discovery' => Hash.new,
	    'droby' => Hash['period' => 0.5, 'max_errors' => 1],
            'engine' => Hash.new
        }

	def initialize
            @auto_load_all = false
            @auto_load_models = true
            @app_dir = nil
            @search_path = nil
	    @plugins = Array.new
            @plugins_enabled = true
            @plan = Plan.new
	    @available_plugins = Array.new
            @options = DEFAULT_OPTIONS.dup
            @created_log_dirs = []
            @additional_model_files = []

	    @automatic_testing = true
            @registered_exceptions = []

            @filter_out_patterns = [Roby::RX_IN_FRAMEWORK,
                                    Roby::RX_IN_METARUBY,
                                    Roby::RX_IN_UTILRB,
                                    Roby::RX_REQUIRE]
            self.abort_on_application_exception = true

            @planners    = []
            @notification_listeners = Array.new
            @test_format_timepoints_options = Hash.new
            @test_repeat = 1
            @test_profile = []

            @init_handlers = Array.new
            @setup_handlers = Array.new
            @require_handlers = Array.new
            @config_handlers = Array.new
            @cleanup_handlers = Array.new
            @controllers = Array.new
            @action_handlers = Array.new
	end

        # The robot names configuration
        #
        # @return [App::RobotNames]
        def robots
            if !@robots
                robots = App::RobotNames.new(options['robots'] || Hash.new)
                robots.strict = !!options['robots']
                @robots = robots
            end
            @robots
        end

        # Declares a block that should be executed when the Roby app gets
        # initialized (i.e. just after init.rb gets loaded)
        def on_init(&block)
            init_handlers << block
        end

        # Declares a block that should be executed when the Roby app loads
        # models (i.e. in {require_models})
        def on_require(&block)
            require_handlers << block
        end

        # Declares a block that should be executed when the Roby app sets itself
        # up (i.e. in {setup})
        def on_config(&block)
            config_handlers << block
        end

        # Declares that the following block should be used as the robot
        # controller
        def controller(&block)
            controllers << block
        end

        # Declares that the following block should be used to setup the main
        # action interface
        def actions(&block)
            action_handlers << block
        end

        # Looks into subdirectories of +dir+ for files called app.rb and
        # registers them as Roby plugins
        def load_plugins_from_prefix(dir)
            dir = File.expand_path(dir)
	    $LOAD_PATH.unshift dir

	    Dir.new(dir).each do |subdir|
		subdir = File.join(dir, subdir)
		next unless File.directory?(subdir)
		appfile = File.join(subdir, "app.rb")
		next unless File.file?(appfile)
                load_plugin_file(appfile)
	    end
        ensure
            $LOAD_PATH.shift
        end

        # Load the given Roby plugin file. It is usually called app.rb, and
        # should call register_plugin with the relevant information
        #
        # Note that the file should not do anything yet. The actions required to
        # have a functional plugin should be taken only in the block given to
        # register_plugin or in the relevant plugin methods.
        def load_plugin_file(appfile)
            begin
                require appfile
            rescue
                Roby.warn "cannot load plugin #{appfile}: #{$!.full_message}\n"
            end
            Roby.info "loaded plugin #{appfile}"
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

        # Enumerates all available plugins, yielding only the plugin module
        # (i.e. the plugin object itself)
	def each_plugin(on_available = false)
	    plugins = self.plugins
	    if on_available
		plugins = available_plugins.map { |name, _, mod, _| [name, mod] }
	    end
	    plugins.each do |_, mod|
		yield(mod)
	    end
	end

	# Yields each plugin object that respond to +method+
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
		    robot_config.delete_if do |section, values|
			if section != "robots" && options[section]
			    options[section].merge! values
			end
		    end
		end
	    end
            options = options.map_value do |k, val|
                val || Hash.new
            end
            @options = @options.recursive_merge(options)
	end

        # DEPRECATED. Use #using instead
        def using_plugins(*names)
            using(*names)
        end
        
        def register_plugins
            if !plugins_enabled?
                return
            end

            # Load the plugins 'main' files
            if plugin_path = ENV['ROBY_PLUGIN_PATH']
                plugin_path.split(':').each do |plugin|
                    if File.directory?(plugin)
                        load_plugins_from_prefix plugin
                    elsif File.file?(plugin)
                        load_plugin_file plugin
                    end
                end
            end
        end

	# Loads the plugins whose name are listed in +names+
	def using(*names)
            register_plugins
	    names.map do |name|
		name = name.to_s
		unless plugin = plugin_definition(name)
		    raise ArgumentError, "#{name} is not a known plugin (available plugins: #{available_plugins.map { |n, *_| n }.join(", ")})"
		end
		name, dir, mod, init = *plugin
		if already_loaded = plugins.find { |n, m| n == name && m == mod }
		    next(already_loaded[1])
		end

                if dir
                    filter_out_patterns.push(/#{Regexp.quote(dir)}/)
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

                add_plugin(name, mod)
	    end
	end

        def add_plugin(name, mod)
            plugins << [name, mod]
            extend mod
            # If +load+ has already been called, call it on the module
            if mod.respond_to?(:load) && options
                mod.load(self, options)
            end
            mod
        end

        # The robot name
        #
        # @return [String,nil]
	def robot_name
            if @robot_name then @robot_name
            else robots.default_robot_name
            end
        end

        # The robot type
        #
        # @return [String,nil]
        def robot_type
            if @robot_type then @robot_type
            else robots.default_robot_type
            end
        end

        # Sets up the name and type of the robot. This can be called only once
        # in a given Roby controller.
	def robot(name, type = nil)
            name, type = robots.resolve(name, type)

	    if @robot_name
		if name != @robot_name && (@robot_type && type != @robot_type)
		    raise ArgumentError, "the robot is already set to #{name}, of type #{type}"
		end
		return
	    end
	    @robot_name, @robot_type = name, type
	end

        # The base directory in which logs should be saved
        #
        # Logs are saved in log_base_dir/$time_tag by default, and a
        # log_base_dir/current symlink gets updated to reflect the most current
        # log directory.
        #
        # The path is controlled by the log/dir configuration variable. If the
        # provided value, it is interpreted relative to the application
        # directory. It defaults to "data".
        def log_base_dir
            File.expand_path(log['dir'] || 'logs', app_dir || Dir.pwd)
        end

	# The directory in which logs are to be saved
	# Defaults to app_dir/data/$time_tag
	def log_dir
            if @log_dir
                return @log_dir
            else
                base_dir = log_base_dir
                final_path = Roby::Application.unique_dirname(base_dir, '', time_tag)
                @log_dir = final_path
            end
	end

        # The time tag. It is a time formatted as YYYYMMDD-HHMM used to mark log
        # directories
	def time_tag
	    @time_tag ||= Time.now.strftime('%Y%m%d-%H%M')
	end

        # Save a time tag file in the current log directory. This is used in
        # case the log directory gets renamed
        def log_save_time_tag
            path = File.join(log_dir, 'time_tag')
            if !File.file?(path)
	        tag = time_tag
                File.open(path, 'w') do |io|
                    io.write tag
                end
            end
        end

        # Read the time tag from the current log directory
        def log_read_time_tag
            dir = begin
                      log_current_dir
                  rescue ArgumentError
                  end

            if dir && File.exists?(File.join(log_dir, 'time_tag'))
                File.read(File.join(log_dir, 'time_tag')).strip
            end
        end

        # The path to the current log directory
        def log_current_dir
            basedir = self.log_base_dir
            if !File.symlink?(File.join(basedir, "current"))
                raise ArgumentError, "no data/current symlink found, cannot guess the current log directory"
            end
            File.readlink(File.join(basedir, "current"))
        end

	# A path => File hash, to re-use the same file object for different
	# logs
	attribute(:log_files) { Hash.new }

        # Returns a unique directory name as a subdirectory of
        # +base_dir+, based on +path_spec+. The generated name
        # is of the form
        #   <base_dir>/a/b/c/YYYYMMDD-HHMM-basename
        # if <tt>path_spec = "a/b/c/basename"</tt>. A .<number> suffix
        # is appended if the path already exists.
	def self.unique_dirname(base_dir, path_spec, date_tag = nil)
	    if path_spec =~ /\/$/
		basename = ""
		dirname = path_spec
	    else
		basename = File.basename(path_spec)
		dirname  = File.dirname(path_spec)
	    end

	    date_tag ||= Time.now.strftime('%Y%m%d-%H%M')
	    if basename && !basename.empty?
		basename = date_tag + "-" + basename
	    else
		basename = date_tag
	    end

	    # Check if +basename+ already exists, and if it is the case add a
	    # .x suffix to it
	    full_path = File.expand_path(File.join(dirname, basename), base_dir)
	    base_dir  = File.dirname(full_path)

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
            Robot.logger.progname = robot_name || 'Robot'
            return if !log['levels']

	    # Set up log levels
	    log['levels'].each do |name, value|
		name = name.modulize
                mod = Kernel.constant(name)
		if value =~ /^(\w+):(.+)$/
		    value, file = $1, $2
		    file = file.gsub('ROBOT', robot_name) if robot_name
		end
                level = Logger.const_get(value)

                io = if file
                         path = File.expand_path(file, log_dir)
                         log_files[path] ||= File.open(path, 'w')
                     else 
                         STDOUT
                     end
                new_logger = Logger.new(io)
		new_logger.level     = level
		new_logger.formatter = mod.logger.formatter
                new_logger.progname = [name, robot_name].compact.join(" ")
                mod.logger = new_logger
	    end
	end

	def setup_dirs
            if !File.directory?(log_dir)
                dir = log_dir
                while !File.directory?(dir)
                    @created_log_dirs << dir
                    dir = File.dirname(dir)
                end
                FileUtils.mkdir_p(log_dir)
            end
            if public_logs?
                FileUtils.rm_f File.join(log_base_dir, "current")
                FileUtils.ln_s log_dir, File.join(log_base_dir, 'current')
            end

            find_dirs('lib', 'ROBOT', :all => true, :order => :specific_last).
                each do |libdir|
                    if !$LOAD_PATH.include?(libdir)
                        $LOAD_PATH.unshift libdir
                    end
                end

            if defined? Roby::Conf
                Roby::Conf.datadirs = find_dirs('data', 'ROBOT', :all => true, :order => :specific_first)
            end
	end

        # Transforms +path+ into a path relative to an entry in +search_path+
        # (usually the application root directory)
        def make_path_relative(path)
            path = path.dup
            search_path.each do |p|
                relative_path = path.gsub(/^#{Regexp.quote(p)}\//, '')
                if File.file?(File.join(p, relative_path)) || File.file?(File.join(p, "#{relative_path}.rb"))
                    path = relative_path
                end
            end
            path
        end

        def register_exception(e, reason = nil)
            registered_exceptions << [e, reason]
        end

        def clear_exceptions
            registered_exceptions.clear
        end

        def isolate_load_errors(message, logger = Application, level = :warn)
            begin
                yield
            rescue Interrupt
                raise
            rescue ::Exception => e
                register_exception(e, message)
                if ignore_all_load_errors?
                    Robot.warn message
                    Roby.log_exception(e, logger, level)
                    Roby.log_backtrace(e, logger, level)
                else raise
                end
            end
        end

        def require(absolute_path)
            # Make the file relative to the search path
            file = make_path_relative(absolute_path)
            Roby::Application.info "loading #{file} (#{absolute_path})"
            isolate_load_errors("ignored file #{file}") do
                if file != absolute_path
                    Kernel.require(file)
                else
                    Kernel.require absolute_path
                end
            end
        end

        # Loads the models, based on the given robot name and robot type
	def require_models
	    # Require all common task models and the task models specific to
	    # this robot
            if auto_load_models?
                search_path = self.auto_load_search_path
                all_files =
                    find_files_in_dirs('models', 'tasks', 'ROBOT', :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                    find_files_in_dirs('tasks', 'ROBOT', :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/)
                all_files.each do |p|
                    require(p)
                end
            end

	    # Set up the loaded plugins
	    call_plugins(:require_models, self)
            require_handlers.each(&:call)

            require_planners

            additional_model_files.each do |path|
                require path
            end

	    # Set up the loaded plugins
	    call_plugins(:finalize_model_loading, self)
	end

        # Helper to the robot config files to load the root files in models/
        # (e.g. models/tasks.rb)
        def load_default_models
            ['tasks.rb', 'actions.rb'].each do |root_type|
                if path = app.find_file('models', root_type)
                    require path
                end
            end
	    call_plugins(:load_default_models, self)
        end

        def register_generators
            Roby.app.load_base_config
            RubiGen::Base.__sources = [RubiGen::PathSource.new(:roby, File.join(Roby::ROBY_ROOT_DIR, "generators"))]
            call_plugins(:register_generators, self)
        end

        # Loads the planner models
        #
        # This method is called at the end of require_models, before the
        # plugins' require_models hook is called
        def require_planners
            search_path = self.auto_load_search_path
            if auto_load_models?
                main_files =
                    find_files('models', 'actions', 'ROBOT', 'main.rb', :path => search_path, :all => true, :order => :specific_first) +
                    find_files('models', 'planners', 'ROBOT', 'main.rb', :path => search_path, :all => true, :order => :specific_first) +
                    find_files('planners', 'ROBOT', 'main.rb', :all => true, :order => :specific_first)
                main_files.each do |path|
                    require path
                end
            end

            if !defined?(Main)
                Object.const_set(:Main, Class.new(Roby::Actions::Interface))
            end
            action_handlers.each do |act|
                Main.class_eval(&act)
            end

            if auto_load_models?
                all_files =
                    find_files_in_dirs('models', 'actions', 'ROBOT', :path => search_path, :all => true, :order => :specific_first, :pattern => /\.rb$/) +
                    find_files_in_dirs('models', 'planners', 'ROBOT', :path => search_path, :all => true, :order => :specific_first, :pattern => /\.rb$/) +
                    find_files_in_dirs('planners', 'ROBOT', :path => search_path, :all => true, :order => :specific_first, :pattern => /\.rb$/)
                all_files.each do |p|
                    require(p)
                end
            end

	    call_plugins(:require_planners, self)
        end

        def load_config_yaml
            if file = find_file('config', 'app.yml', :order => :specific_first)
                Application.info "loading config file #{file}"
                file = YAML.load(File.open(file)) || Hash.new
                load_yaml(file)
            end
        end

        # Loads the base configuration
        #
        # This method loads the two most basic configuration files:
        #
        #  * config/app.yml
        #  * config/init.rb
        #
        # It also calls the plugin's 'load' method
        def load_base_config
            load_config_yaml

	    # Get the application-wide configuration
            register_plugins
            if initfile = find_file('config', 'init.rb', :order => :specific_first)
                Application.info "loading init file #{initfile}"
                require initfile
            end

            search_path.reverse.each do |app_dir|
                $LOAD_PATH.unshift(app_dir) if !$LOAD_PATH.include?(app_dir)
                libdir = File.join(app_dir, 'lib')
                $LOAD_PATH.unshift(libdir) if !$LOAD_PATH.include?(libdir)
            end

            call_plugins(:load, self, options)
            call_plugins(:load_base_config, self, options)

	    setup_dirs
	    setup_loggers
        end

        def base_setup
	    STDOUT.sync = true

            require 'roby/interface'

            setup_robot_names_from_config_dir
	    load_base_config
            require_robot_file
            init_handlers.each(&:call)

            if !Roby.control
                Roby.control = DecisionControl.new
            end
            if !plan.engine || (plan.engine.plan != plan)
                plan.engine = ExecutionEngine.new(plan, Roby.control)
            end
            if Roby.scheduler
                plan.engine.scheduler = Roby.scheduler
            end

	    # Set up the loaded plugins
	    call_plugins(:base_setup, self)
        end

        class NoSuchRobot < ArgumentError; end

        def setup_robot_names_from_config_dir
            robot_config_files = find_files_in_dirs 'config', 'robots', 
                all: true,
                order: :specific_first,
                pattern: lambda { |p| File.extname(p) == ".rb" }

            robots.strict = !robot_config_files.empty?
            robot_config_files.each do |path|
                robot_name = File.basename(path, ".rb")
                robots.robots[robot_name] = robot_name
            end
        end

        def require_robot_file
            p = find_file('config', 'robots', "#{robot_name}.rb", order: :specific_first) ||
                find_file('config', 'robots', "#{robot_type}.rb", order: :specific_first)

            if p
                self.auto_load_models = false
                require p
                if !robot_type
                    robot(robot_name, robot_name)
                end
            elsif robots.strict? && find_dir('config', 'robots')
                raise NoSuchRobot, "cannot find config file for robot #{robot_name} of type #{robot_type} in config/robots/"
            end
        end

        # Does basic setup of the Roby environment. It loads configuration files
        # and sets up singleton objects.
        #
        # After a call to #setup, the Roby services that do not require an
        # execution loop to run should be available
        #
        # Plugins that define a setup(app) method will see their method called
        # at this point
        #
        # The #cleanup method is the reverse of #setup
	def setup
            base_setup
	    # Set up the loaded plugins
	    call_plugins(:setup, self)
            # And run the setup handlers
            setup_handlers.each(&:call)

	    require_models
            require_config

	    # Main is always included in the planner list
            self.planners << Main
	   
            # Attach the global fault tables to the plan
            self.planners.each do |planner|
                if planner.respond_to?(:each_fault_response_table)
                    planner.each_fault_response_table do |table, arguments|
                        plan.use_fault_response_table table, arguments
                    end
                end
            end

            if public_shell_interface?
                setup_shell_interface
            end
            setup_drb_service

        rescue Exception
            begin cleanup
            rescue Exception
            end
            raise
	end

        # Load all configuration files (i.e. files in config/) except init.rb
        # and app.yml
        #
        # init.rb and app.yml are loadedd "early" in #setup by calling
        # #load_base_config
        #
        # It calls the corresponding hook on enabled plugins
        def require_config
            if file = find_file('config', "ROBOT.rb", :order => :specific_first)
                require file
            end

            call_plugins(:require_config, self)
            config_handlers.each(&:call)
        end

        # Publishes a shell interface
        #
        # This method publishes a Roby::Interface object as the front object of
        # the local DRb server. The port on which this object is published can
        # be configured through the droby/host configuration variable, i.e.:
        #
        #   droby:
        #       host: ":7873"
        #
        # As this variable is also used by the Roby shell to automatically
        # access a remote shell, one can provide a host part. This part will
        # simply be ignored in #setup_shell_interface
        #
        # The shell interface is started in #setup and teared down in #cleanup
        #
        # The default port is defined in Roby::Distributed::DEFAULT_DROBY_PORT
        def setup_shell_interface
	    # Set up dRoby, setting an Interface object as front server, for shell access
	    host = droby['host'] || ""
            if host =~ /:(\d+)$/
                port = Integer($1)
            else
		port = Distributed::DEFAULT_DROBY_PORT
	    end

            @shell_server = Interface::TCPServer.new(self, port)
        end

        def stop_shell_interface
            if @shell_server
                @shell_server.close
            end
        end

        def setup_drb_service
	    host = droby['host'] || ""
            if host !~ /:\d+$/
                host = host + ":0"
            end
	    if single? || !robot_name
		host =~ /:(\d+)$/
		DRb.start_service "druby://:#{$1 || '0'}"
	    else
		DRb.start_service "druby://#{host}"
            end
        end

        def stop_drb_service
            begin
                DRb.current_server
                DRb.stop_service
            rescue DRb::DRbServerNotFound
            end
        end

        # Prepares the environment to actually run
        def prepare
            log_save_time_tag

            if !single? && discovery.empty?
                Application.info "dRoby disabled as no discovery configuration has been provided"
	    elsif !single? && robot_name
		droby_config = { :ring_discovery => !!discovery['ring'],
		    :name => robot_name, 
		    :plan => plan, 
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

            if !robot_name
                @robot_name = 'common'
            end
            if !robot_type
                @robot_type = 'common'
            end

	    if log['events'] && public_logs?
		require 'roby/log/file'
		logfile = File.join(log_dir, robot_name)
		logger  = Roby::Log::FileLogger.new(logfile, :plugins => plugins.map { |n, _| n })
		logger.stats_mode = (log['events'] == 'stats')
		Roby::Log.add_logger logger

                start_log_server(logfile)
	    end

            call_plugins(:prepare, self)
        end

	def run(&block)
            prepare

	    engine_config = self.engine
	    engine = self.plan.engine
	    options = { :cycle => engine_config['cycle'] || 0.1 }
	    
	    engine.run options
	    plugins = self.plugins.map { |_, mod| mod if (mod.respond_to?(:start) || mod.respond_to?(:run)) }.compact
	    run_plugins(plugins, &block)

        ensure
            cleanup
	end

        # Helper for Application#run to call the plugin's run or start methods
        # while guaranteeing the system's cleanup
        #
        # This method recursively calls each plugin's #run method (if defined)
        # in block forms. This guarantees that the plugins can use a
        # begin/rescue/end mechanism to do their cleanup
        #
        # If no run-related cleanup is required, the plugin can define a #start(app)
        # method instead.
        #
        # Note that the cleanup we talk about here is related to running.
        # Cleanup required after #setup must be done in #cleanup
	def run_plugins(mods, &block)
            engine = plan.engine
	    if mods.empty?
		yield if block_given?

                Robot.info "ready"
		engine.join
	    else
		mod = mods.shift
                if mod.respond_to?(:start)
                    mod.start(self)
                    run_plugins(mods, &block)
                else
                    mod.run(self) do
                        run_plugins(mods, &block)
                    end
                end
	    end

	rescue Exception => e
	    if engine.running?
		engine.quit
		engine.join
		raise e, e.message, e.backtrace
	    else
		raise
	    end
	end

        # The inverse of #setup. It gets called either at the end of #run or at
        # the end of #setup if there is an error during loading
        def cleanup
            call_plugins(:cleanup, self)
            # Deprecated version of #cleanup
            call_plugins(:reset, self)

            planners.clear
            plan.clear
            clear_models
            clear_config

            if !public_logs?
                @created_log_dirs.each do |dir|
                    FileUtils.rm_rf dir
                end
            end

            stop_log_server
            stop_shell_interface
            stop_drb_service
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

        def start_log_server(logfile)
	    # Start a log server if needed, and poll the log directory for new
	    # data sources
	    if log_server = (log.has_key?('server') ? log['server'] : true)
		require 'roby/log/server'

                port = Log::Server::DEFAULT_PORT
                sampling_period = Log::Server::DEFAULT_SAMPLING_PERIOD
                if log_server.kind_of?(Hash)
                    port = Integer(log_server['port'] || port)
                    sampling_period = Float(log_server['sampling_period'] || sampling_period)
                    debug = log_server['debug']
                end

                @log_server = fork do
                    exec("roby-display#{" --debug" if debug} --server=#{port} --sampling=#{sampling_period} #{logfile}-events.log")
                end
	    end
        end

        def stop_log_server
            if @log_server
                Process.kill('INT', @log_server)
                @log_server = nil
            end
        end

        # @overload find_files_in_dirs(*path, options)
        #
        # Enumerates the subdirectories of paths in {#search_path} matching the
        # given path. The subdirectories are resolved using File.join(*path)
        # If one of the elements of the path is the string 'ROBOT', it gets
        # replaced by the robot name and type.
        #
        # @option options [Boolean] :all (true) if true, all matching
        #   directories are returned. Otherwise, only the first one is (the
        #   meaning of 'first' is controlled by the order option below)
        # @option options [:specific_first,:specific_last] :order if
        #   :specific_first, the first returned match is the one that is most
        #   specific. The sorting order is to first sort by ROBOT and then by
        #   the place in search_dir. From the most specific to the least
        #   specific, ROBOT is assigned the robot name, the robot type and
        #   finally an empty string.
        # @return [Array<String>]
        #
        # Given a search dir of [app2, app1]
        #
        #   app1/models/tasks/goto.rb
        #   app1/models/tasks/v3/goto.rb
        #   app2/models/tasks/asguard/goto.rb
        #
        # @example
        #   find_dirs('tasks', 'ROBOT', :all => true, :order => :specific_first)
        #   # returns [app1/models/tasks/v3,
        #   #          app2/models/tasks/asguard,
        #   #          app1/models/tasks/]
        #
        # @example
        #   find_dirs('tasks', 'ROBOT', :all => false, :order => :specific_first)
        #   # returns [app1/models/tasks/v3/goto.rb]
        def find_dirs(*dir_path)
            Application.debug { "find_dirs(#{dir_path.map(&:inspect).join(", ")})" }
            if dir_path.last.kind_of?(Hash)
                options = dir_path.pop
            end
            options = Kernel.validate_options(options || Hash.new, :all, :order, :path)
            search_path = options[:path] || self.search_path
            if !options.has_key?(:all)
                raise ArgumentError, "no :all argument given"
            elsif !options.has_key?(:order)
                raise ArgumentError, "no :order argument given"
            elsif ![:specific_first, :specific_last].include?(options[:order])
                raise ArgumentError, "expected either :specific_first or :specific_last for the :order argument, but got #{options[:order]}"
            end

            relative_paths = []

            base_dir_path = dir_path.dup
            base_dir_path.delete_if { |p| p =~ /ROBOT/ }
            relative_paths = [base_dir_path]
            if dir_path.any? { |p| p =~ /ROBOT/ } && robot_name && robot_type
                replacements = [robot_type]
                if robot_type != robot_name
                    replacements << robot_name
                end
                replacements.each do |replacement|
                    robot_dir_path = dir_path.map do |s|
                        s.gsub('ROBOT', replacement)
                    end
                    relative_paths << robot_dir_path
                end
            end

            root_paths = search_path.dup
            if options[:order] == :specific_first
                relative_paths = relative_paths.reverse
            else
                root_paths = root_paths.reverse
            end

            result = []
            Application.debug { "  relative paths: #{relative_paths.inspect}" }
            relative_paths.each do |rel_path|
                root_paths.each do |root|
                    abs_path = File.expand_path(File.join(*rel_path), root)
                    Application.debug { "  absolute path: #{abs_path}" }
                    if File.directory?(abs_path)
                        Application.debug { "    selected" }
                        result << abs_path 
                    end
                end
            end

            if result.empty?
                return result
            elsif !options[:all]
                return [result.first]
            else
                return result
            end
        end

        # @overload find_files_in_dirs(*path, options)
        #
        # Enumerates the files that are present in subdirectories of paths in
        # {#search_dir}. The subdirectories are resolved using File.join(*path)
        # If one of the elements of the path is the string 'ROBOT', it gets
        # replaced by the robot name and type.
        #
        # @option (see find_dirs)
        # @option options [#===] :pattern a filter to apply on the matching
        #   results
        # @option options [Symbol] :all (false) if true, all files from all
        #   matching directories are returned. Otherwise, only the files from
        #   the first matching directory is searched
        # @return [Array<String>]
        #
        # Given a search dir of [app2, app1]
        #
        #   app1/models/tasks/goto.rb
        #   app1/models/tasks/v3/goto.rb
        #   app2/models/tasks/asguard/goto.rb
        #
        # @example
        #   find_files_in_dirs('tasks', 'ROBOT', :all => true, :order => :specific_first)
        #   # returns [app1/models/tasks/v3/goto.rb,
        #   #          app2/models/tasks/asguard/goto.rb,
        #   #          app1/models/tasks/goto.rb]
        #
        # @example
        #   find_files_in_dirs('tasks', 'ROBOT', :all => false, :order => :specific_first)
        #   # returns [app1/models/tasks/v3/goto.rb,
        def find_files_in_dirs(*dir_path)
            Application.debug { "find_files_in_dirs(#{dir_path.map(&:inspect).join(", ")})" }
            if dir_path.last.kind_of?(Hash)
                options = dir_path.pop
            end
            options = Kernel.validate_options(options || Hash.new, :all, :order, :path, :pattern => Regexp.new(""))

            dir_search = dir_path.dup
            dir_search << { :all => true, :order => options[:order], :path => options[:path] }
            search_path = find_dirs(*dir_search)

            result = []
            search_path.each do |dirname|
                Application.debug { "  dir: #{dirname}" }
                Dir.new(dirname).each do |file_name|
                    file_path = File.join(dirname, file_name)
                    Application.debug { "    file: #{file_path}" }
                    if File.file?(file_path) && options[:pattern] === file_name
                        Application.debug "      added"
                        result << file_path
                    end
                end
                break if !options[:all]
            end
            return result
        end

        # @overload find_files(*path, options)
        #
        # Enumerates files based on their relative paths in {#search_path}.
        # The paths are resolved using File.join(*path)
        # If one of the elements of the path is the string 'ROBOT', it gets
        # replaced by the robot name and type.
        #
        # @option options [Boolean] :all (true) if true, all matching
        #   directories are returned. Otherwise, only the first one is (the
        #   meaning of 'first' is controlled by the order option below)
        # @option options [:specific_first,:specific_last] :order if
        #   :specific_first, the first returned match is the one that is most
        #   specific. The sorting order is to first sort by ROBOT and then by
        #   the place in search_dir. From the most specific to the least
        #   specific, ROBOT is assigned the robot name, the robot type and
        #   finally an empty string.
        # @return [Array<String>]
        #
        # Given a search dir of [app2, app1], a robot name of v3 and a robot
        # type of asguard,
        #
        #   app1/config/v3.rb
        #   app2/config/asguard.rb
        #
        # @example
        #   find_files('config', 'ROBOT.rb', :all => true, :order => :specific_first)
        #   # returns [app1/config/v3.rb,
        #   #          app2/config/asguard.rb]
        #
        # @example
        #   find_dirs('tasks', 'ROBOT', :all => false, :order => :specific_first)
        #   # returns [app1/config/v3.rb]
        #
        def find_files(*file_path)
            if file_path.last.kind_of?(Hash)
                options = file_path.pop
            end
            options = Kernel.validate_options(options || Hash.new, :all, :order, :path)

            # Remove the filename from the complete path
            filename = file_path.pop
            filename = filename.split('/')
            file_path.concat(filename[0..-2])
            filename = filename[-1]

            if filename =~ /ROBOT/ && robot_name
                args = file_path + [options.merge(:pattern => filename.gsub('ROBOT', robot_name))]
                robot_name_matches = find_files_in_dirs(*args)

                robot_type_matches = []
                if robot_name != robot_type
                    args = file_path + [options.merge(:pattern => filename.gsub('ROBOT', robot_type))]
                    robot_type_matches = find_files_in_dirs(*args)
                end

                if options[:order] == :specific_first
                    result = robot_name_matches + robot_type_matches
                else
                    result = robot_type_matches + robot_name_matches
                end
            else
                args = file_path.dup
                args << options.merge(:pattern => filename)
                result = find_files_in_dirs(*args)
            end

            orig_path = Pathname.new(File.join(*file_path))
            orig_path += filename
            if orig_path.absolute? && File.file?(orig_path.to_s)
                if options[:order] == :specific_first
                    result.unshift orig_path.to_s
                else
                    result.push orig_path.to_s
                end
            end

            return result
        end

        # Returns the first match from {#find_files}, or nil if nothing matches
        def find_file(*args)
            if !args.last.kind_of?(Hash)
                args.push(Hash.new)
            end
            args.last.delete('all')
            args.last.merge!(:all => true)
            find_files(*args).first
        end

        # Returns the first match from {#find_dirs}, or nil if nothing matches
        def find_dir(*args)
            if !args.last.kind_of?(Hash)
                args.push(Hash.new)
            end
            args.last.delete('all')
            args.last.merge!(:all => true)
            find_dirs(*args).first
        end

        def setup_for_minimal_tooling
            self.public_logs = false
            self.auto_load_models = false
            self.single = true
            self.modelling_only = true
            setup
        end

        # If set to true, this Roby application will publish a public shell
        # interface. Otherwise, no shell interface is going to be published at
        # all
        #
        # Only the run modes have a public shell interface
        attr_predicate :public_shell_interface?, true

        # If set to true, this Roby application will make its logs public, i.e.
        # will save the logs in logs/ and update the logs/current symbolic link
        # accordingly. Otherwise, the logs are saved in a temporary folder in
        # logs/ and current is not updated
        #
        # Only the run modes have public logs by default
        attr_predicate :public_logs?, true

	attr_predicate :simulation?, true
	def simulation; self.simulation = true end

	attr_predicate :testing?, true
	def testing; self.testing = true end
	attr_predicate :shell?, true
	def shell; self.shell = true end
	attr_predicate :single?, true
	def single;  @single = true end

        attr_predicate :modelling_only?, true
        def modelling_only; self.modelling_only = true end

        # @return [Boolean] true if Roby's auto-load feature should load all
        #   models in {search_path} or only the ones in {app_dir}. It influences
        #   the return value of {auto_load_search_path}
	attr_predicate :auto_load_all?, true

        # @return [Boolean] true if Roby should load the available the model
        #   files automatically in {require_models}
	attr_predicate :auto_load_models?, true

        # @return [Array<String>] the search path for the auto-load feature. It
        #   depends on the value of {auto_load_all}
        def auto_load_search_path
            if auto_load_all? then search_path
            elsif app_dir then [app_dir]
            else []
            end
        end

        def find_data(*name)
            Application.find_data(*name)
        end

	def self.find_data(*name)
            name = File.join(*name)
	    Roby::Conf.datadirs.each do |dir|
		path = File.join(dir, name)
		return path if File.exists?(path)
	    end
	    raise Errno::ENOENT, "no file #{name} found in #{Roby::Conf.datadirs.join(":")}"
	end

	def self.register_plugin(name, mod, &init)
	    caller(1)[0] =~ /^([^:]+):\d/
	    dir  = File.expand_path(File.dirname($1))
            Roby.app.available_plugins.delete_if { |n| n == name }
	    Roby.app.available_plugins << [name, dir, mod, init]
	end

        # Returns true if the given path points to a file in the Roby app
	def app_file?(path)
            search_path.any? do |app_dir|
                (path =~ %r{(^|/)#{app_dir}(/|$)}) ||
                    ((path[0] != ?/) && File.file?(File.join(app_dir, path)))
            end
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

        def unload_features(*pattern)
            patterns = search_path.map { |p| Regexp.new(File.join(p, *pattern)) }
            patterns << Regexp.new("^#{File.join(*pattern)}")
            $LOADED_FEATURES.delete_if { |path| patterns.any? { |p| p =~ path } }
        end

        def clear_config
            Conf.clear
            call_plugins(:clear_config, self)
            # Deprecated name for clear_config
            call_plugins(:reload_config, self)
        end

        def reload_config
            clear_config
            unload_features("config", ".*\.rb$")
            require_config
        end

        def model_defined_in_app?(model)
            model.definition_location.each do |file, _, method|
                return if method == :require
                return true if app_file?(file)
            end
            false
        end

        def root_models
            [Task, TaskService, TaskEvent, Actions::Interface, Actions::Library,
             Coordination::ActionScript, Coordination::ActionStateMachine, Coordination::TaskScript]
        end

        def clear_model?(m)
            !m.permanent_model? ||
                (!testing? && model_defined_in_app?(m))
        end

        def clear_models
            root_models.each do |root_model|
                submodels = root_model.each_submodel.to_a.dup
                submodels.each do |m|
                    if clear_model?(m)
                        m.clear_model
                    end
                    next if m.permanent_model?

                    Roby::Transaction::Proxying.proxying_modules.delete(m)
                end
            end
            call_plugins(:clear_models, self)
        end

        def reload_models
            clear_models
            unload_features("models", ".*\.rb$")
            additional_model_files.each do |path|
                unload_features(path)
            end
            require_models
        end

        def reload_actions
            unload_features("actions", ".*\.rb$")
            unload_features("models", "actions", ".*\.rb$")
            planners.each do |planner_model|
                planner_model.clear_model
            end
            require_planners
        end

        def reload_planners
            unload_features("planners", ".*\.rb$")
            unload_features("models", "planners", ".*\.rb$")
            planners.each do |planner_model|
                planner_model.clear_model
            end
            require_planners
        end

        # Find an action on the planning interface that can generate the given task
        # model
        #
        # Raises ArgumentError if there either none or more than one. Otherwise,
        # returns the action name.
        def action_from_model(model)
            candidates = []
            planners.each do |planner_model|
                planner_model.find_all_actions_by_type(model).each do |action|
                    candidates << [planner_model, action]
                end
            end
            candidates = candidates.uniq
                
            if candidates.empty?
                raise ArgumentError, "cannot find an action to produce #{model}"
            elsif candidates.size > 1
                raise ArgumentError, "more than one actions available produce #{model}: #{candidates.map { |pl, m| "#{pl}.#{m.name}" }.sort.join(", ")}"
            else
                candidates.first
            end
        end
        
        # Find an action with the given name on the action interfaces registered on
        # {#planners}
        #
        # @raise [ArgumentError] if more than one action interface provide an
        #   action with this name
        def find_action_from_name(name)
            candidates = []
            planners.each do |planner_model|
                if m = planner_model.find_action_by_name(name)
                    candidates << [planner_model, m]
                end
            end
            candidates = candidates.uniq

            if candidates.size > 1
                raise ArgumentError, "more than one action interface provide the #{name} action: #{candidates.map { |pl, m| "#{pl}" }.sort.join(", ")}"
            else candidates.first
            end
        end

        def action_from_name(name)
            action = find_action_from_name(name)
            if !action
                available_actions = planners.map do |planner_model|
                    planner_model.each_action.map(&:name)
                end.flatten
                if available_actions.empty?
                    raise ArgumentError, "cannot find an action named #{name}, there are no actions defined"
                else
                    raise ArgumentError, "cannot find an action named #{name}, available actions are: #{available_actions.sort.join(", ")}"
                end
            end
            action
        end

        # Generate the plan pattern that will call the required action on the
        # planning interface, with the given arguments.
        #
        # This returns immediately, and the action is not yet deployed at that
        # point.
        #
        # @return task, planning_task
        def prepare_action(name, arguments = Hash.new)
            if name.kind_of?(Class)
                planner_model, m = action_from_model(name)
            else
                planner_model, m = action_from_name(name)
            end
            plan.add(task = m.plan_pattern(arguments))
            return task, task.planning_task
        end

        # @return [#call] the blocks that listen to notifications. They are
        #   added with {#on_notification} and removed with
        #   {#remove_listener}
        attr_reader :notification_listeners

        # Enumerates the listeners currently registered through
        # #on_notification
        #
        # @yieldparam [#call] the job listener object
        def each_notification_listener(&block)
            notification_listeners.each(&block)
        end

        # Sends a message to all notification listeners
        def notify(source, level, message)
            each_notification_listener do |block|
                block.call(source, level, message)
            end
        end

        # Registers a block to be called when a message needs to be
        # dispatched
        #
        # @yieldparam [String] the source of the message
        # @yieldparam [String] level the log level
        # @yieldparam [String] message
        # @return [Object] the listener ID that can be given to
        #   {#remove_notification}
        def on_notification(&block)
            notification_listeners << block
            block
        end

        # Removes a notification listener
        #
        # @param [Object] listener the listener ID returned by
        #   {#on_notification}
        def remove_notification_listener(listener)
            notification_listeners.delete(listener)
        end
    end
end

