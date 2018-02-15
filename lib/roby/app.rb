require 'facets/string/camelcase'
require 'roby/support'
require 'roby/robot'
require 'roby/app/robot_names'
require 'roby/interface'
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

        class NoSuchRobot < ArgumentError; end
        class NotInCurrentApp < RuntimeError; end
        class LogDirNotInitialized < RuntimeError; end
        class PluginsDisabled < RuntimeError; end

        # The main plan on which this application acts
        #
        # @return [ExecutablePlan]
        attr_reader :plan

        # The engine associated with {#plan}
        #
        # @return [ExecutionEngine,nil]
        def execution_engine; plan.execution_engine if plan end
        
        # A set of planners declared in this application
        # 
        # @return [Array]
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
        #
        # @return [Array<(Exception,String)>]
        # @see #register_exception #clear_exceptions
        attr_reader :registered_exceptions

        # @!method development_mode?
        #
        # Whether the app should run in development mode
        #
        # Some expensive tests are disabled when not in development mode. This
        # is the default
        attr_predicate :development_mode?, true

        # The --set options passed on the command line
        attr_reader :argv_set

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
        #   overridable_configuration 'log', 'filter_backtraces', predicate: true
        #
        # will define #filter_backtraces? instead of #filter_backtraces
        def self.overridable_configuration(config_set, config_key, options = Hash.new)
            options = Kernel.validate_options options, predicate: false, attr_name: config_key
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

        # @!method ignore_all_load_errors?
        # @!method ignore_all_load_errors=(flag)
        #
        # If set to true, files that generate errors while loading will be
        # ignored. This is used for model browsing GUIs to be usable even if
        # there are errors
        #
        # It is false by default
        attr_predicate :ignore_all_load_errors?, true

        # @!method backward_compatible_naming?
        # @!method backward_compatible_naming=(flag)
        #
        # If set to true, the app will enable backward-compatible behaviour
        # related to naming schemes, file placements and so on
        #
        # The default is true
        attr_predicate :backward_compatible_naming?, true

        # Returns the name of the application
        def app_name
            if @app_name
                @app_name
            elsif app_dir
                @app_name = File.basename(app_dir).gsub(/[^\w]/, '_')
            else 'default'
            end
        end

        # Allows to override the app name
        attr_writer :app_name

        # Allows to override the app's module name
        #
        # The default is to convert the app dir's basename to camelcase, but
        # that fails in some cases (mostly, when there are acronyms in the name)
        attr_writer :module_name

        # Returns the name of this app's toplevel module
        def module_name
            @module_name || app_name.camelcase(:upper)
        end

        # Returns this app's toplevel module
        def app_module
            constant("::#{module_name}")
        end

        # Returns this app's main action interface
        #
        # This is usually set up in the robot configuration file by calling
        # Robot.actions
        def main_action_interface
            app_module::Actions::Main
        end

        # Returns the application base directory
        #
        # @return [String,nil]
        def app_dir
            if defined?(APP_DIR)
                APP_DIR
            elsif @app_dir
                @app_dir
            end
        end

        def app_path
            @app_path ||= Pathname.new(app_dir)
        end

        # The PID of the server that gives access to the log file
        #
        # Its port is allocated automatically, and must be discovered through
        # the Roby interface
        #
        # @return [Integer,nil]
        attr_reader :log_server_pid

        # The port on which the log server is started
        #
        # It is by default started on an ephemeral port, that needs to be
        # discovered by clients through the Roby interface's
        # {Interface#log_server_port}
        #
        # @return [Integer,nil]
        attr_reader :log_server_port

        # The TCP server that gives access to the {Interface}
        attr_reader :shell_interface

        # Tests if the given directory looks like the root of a Roby app
        #
        # @param [String] test_dir the path to test
        def self.is_app_dir?(test_dir)
            File.file?(File.join(test_dir, 'config', 'app.yml')) ||
                File.directory?(File.join(test_dir, 'models')) ||
                File.directory?(File.join(test_dir, 'scripts', 'controllers')) ||
                File.directory?(File.join(test_dir, 'config', 'robots'))
        end

        class InvalidRobyAppDirEnv < ArgumentError; end

        # Guess the app directory based on the current directory
        #
        # @return [String,nil] the base of the app, or nil if the current
        #   directory is not within an app
        def self.guess_app_dir
            if test_dir = ENV['ROBY_APP_DIR']
                if !Application.is_app_dir?(test_dir)
                    raise InvalidRobyAppDirEnv, "the ROBY_APP_DIR envvar is set to #{test_dir}, but this is not a valid Roby application path"
                end
                return test_dir
            end

            path = Pathname.new(Dir.pwd).find_matching_parent do |test_dir|
                Application.is_app_dir?(test_dir.to_s)
            end
            if path
                path.to_s
            end
        end

        # Whether there is a supporting app directory
        def has_app?
            !!@app_dir
        end

        # Guess the app directory based on the current directory, and sets
        # {#app_dir}. It will not do anything if the current directory is not in
        # a Roby app. Moreover, it does nothing if #app_dir is already set
        #
        # @return [String] the selected app directory
        def guess_app_dir
            return if @app_dir
            if app_dir = self.class.guess_app_dir
                @app_dir = app_dir
            end
        end

        # Call to require this roby application to be in a Roby application
        #
        # It tries to guess the app directory. If none is found, it raises.
        def require_app_dir(needs_current: false, allowed_outside: true)
            guess_app_dir
            if !@app_dir
                raise ArgumentError, "your current directory does not seem to be a Roby application directory; did you forget to run 'roby init'?"
            end
            if needs_current
                needs_to_be_in_current_app(allowed_outside: allowed_outside)
            end
        end

        # Call to check whether the current directory is within {#app_dir}. If
        # not, raises
        #
        # This is called by tools for which being in another app than the
        # currently selected would be really too confusing
        def needs_to_be_in_current_app(allowed_outside: true)
            guessed_dir = self.class.guess_app_dir
            if guessed_dir && (@app_dir != guessed_dir)
                raise NotInCurrentApp, "#{@app_dir} is currently selected, but the current directory is within #{guessed_dir}"
            elsif !guessed_dir && !allowed_outside
                raise NotInCurrentApp, "not currently within an app dir"
            end
        end

        # A list of paths in which files should be looked for in {#find_dirs},
        # {#find_files} and {#find_files_in_dirs}
        #
        # If uninitialized, [app_dir] is used
        attr_writer :search_path

        # The list of paths in which the application should be looking for files
        #
        # @return [Array<String>]
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
        #          should be displayed on the console. The levels are DEBUG, INFO, WARN and FATAL.
        #            Roby: FATAL
        #            Roby::Interface: INFO
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

        # @!method abort_on_exception?
        # @!method abort_on_exception=(flag)
        #
        # Controls whether the application should quit if an unhandled plan
        # exception is received
        #
        # The default is false
        attr_predicate :abort_on_exception, true

        # @!method abort_on_application_exception?
        # @!method abort_on_application_exception=(flag)
        #
        # Controls whether the Roby app should quit if an application (i.e.
        # non-plan) exception is received
        #
        # The default is true
        attr_predicate :abort_on_application_exception, true

        # @!method automatic_testing?
        # @!method automatic_testing=(flag)
        #
        # True if user interaction is disabled during tests
        attr_predicate :automatic_testing?, true

        # @!method plugins_enabled?
        # @!method plugins_enabled=(flag)
        #
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
        #   initialized (i.e. in {#setup} after {#base_setup})
        attr_reader :setup_handlers

        # @return [Array<#call>] list of objects called when the app gets
        #   to require its models (i.e. after {#require_models})
        attr_reader :require_handlers

        # @return [Array<#call>] list of objects called when the app is doing
        #   {#clear_models}
        attr_reader :clear_models_handlers

        # @return [Array<#call>] list of objects called when the app cleans up
        #   (it is the opposite of setup)
        attr_reader :cleanup_handlers

        # @return [Array<#call>] list of blocks that should be executed once the
        #   application is started
        attr_reader :controllers

        # @return [Array<#call>] list of blocks that should be executed once the
        #   application is started
        attr_reader :action_handlers

        # The list of log directories created by this app
        #
        # They are deleted on cleanup if {#public_logs?} is false. Unlike with
        # {#created_log_base_dirs}, they are deleted even if they are not empty.
        #
        # @return [Array<String>]
        attr_reader :created_log_dirs

        # The list of directories created by this app in the paths to
        # {#created_log_dirs}
        #
        # They are deleted on cleanup if {#public_logs?} is false. Unlike with
        # {#created_log_dirs}, they are not deleted if they are not empty.
        #
        # @return [Array<String>]
        attr_reader :created_log_base_dirs

        # Additional metadata saved in log_dir/info.yml by the app
        #
        # Do not modify directly, use {#add_app_metadata} instead
        attr_reader :app_extra_metadata

        # Defines common configuration options valid for all Roby-oriented
        # scripts
        def self.common_optparse_setup(parser)
            Roby.app.load_config_yaml
            parser.on("--set=KEY=VALUE", String, "set a value on the Conf object") do |value|
                Roby.app.argv_set << value
                key, value = value.split('=')
                path = key.split('.')
                base_conf = path[0..-2].inject(Conf) { |c, name| c.send(name) }
                base_conf.send("#{path[-1]}=", YAML.load(value))
            end
            parser.on("--log=SPEC", String, "configuration specification for text loggers. SPEC is of the form path/to/a/module:LEVEL[:FILE][,path/to/another]") do |log_spec|
                log_spec.split(',').each do |spec|
                    mod, level, file = spec.split(':')
                    Roby.app.log_setup(mod, level, file)
                end
            end
            parser.on('-r NAME', '--robot=NAME[,TYPE]', String, 'the robot name and type') do |name|
                robot_name, robot_type = name.split(',')
                Roby.app.setup_robot_names_from_config_dir
                Roby.app.robot(robot_name, robot_type)
            end
            parser.on('--debug', 'run in debug mode') do
                Roby.app.public_logs = true
                Roby.app.filter_backtraces = false
                require 'roby/app/debug'
            end
            parser.on_tail('-h', '--help', 'this help message') do
                STDERR.puts parser
                exit
            end
        end

        # Sets up provided option parser to add the --host and --vagrant option
        #
        # When added, a :host entry will be added to the provided options hash
        def self.host_options(parser, options)
            options[:host] ||= Roby.app.shell_interface_host || 'localhost'
            options[:port] ||= Roby.app.shell_interface_port || Interface::DEFAULT_PORT

            parser.on('--host URL', String, "sets the host to connect to as hostname[:PORT]") do |url|
                if url =~ /(.*):(\d+)$/
                    options[:host] = $1
                    options[:port] = Integer($2)
                else
                    options[:host] = url
                end
            end
            parser.on('--vagrant NAME[:PORT]', String, "connect to a vagrant VM") do |vagrant_name|
                require 'roby/app/vagrant'
                if vagrant_name =~ /(.*):(\d+)$/
                    vagrant_name, port = $1, Integer($2)
                end
                options[:host] = Roby::App::Vagrant.resolve_ip(vagrant_name)
                options[:port] = port
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

        overridable_configuration 'log', 'filter_backtraces', predicate: true

        ##
        # :method: log_server?
        #
        # True if the log server should be started

        ##
        # :method: log_server=
        #
        # Sets whether the log server should be started

        overridable_configuration 'log', 'server', predicate: true, attr_name: 'log_server'

        DEFAULT_OPTIONS = {
            'log' => Hash['events' => true, 'server' => true, 'levels' => Hash.new, 'filter_backtraces' => true],
            'discovery' => Hash.new,
            'engine' => Hash.new
        }

        # @!method public_rest_interface?
        # @!method public_rest_interface=(flag)
        #
        # If set to true, this Roby application will publish a
        # {Interface::REST::API} object
        attr_predicate :public_rest_interface?, true

        # The host to which the REST interface server should bind
        #
        # @return [String]
        attr_accessor :rest_interface_host
        # The port on which the REST interface server should be
        #
        # @return [Integer]
        attr_accessor :rest_interface_port

        # The host to which the shell interface server should bind
        #
        # @return [String]
        attr_accessor :shell_interface_host
        # The port on which the shell interface server should be
        #
        # @return [Integer]
        attr_accessor :shell_interface_port
        # Whether an unexpected (non-comm-related) failure in the shell should
        # cause an abort
        #
        # The default is yes
        attr_predicate :shell_abort_on_exception?, true
        # The {Interface} bound to this app
        # @return [Interface]
        attr_reader :shell_interface

        def initialize
            @plan = ExecutablePlan.new
            @argv_set = Array.new

            @auto_load_all = false
            @default_auto_load = true
            @auto_load_models = nil
            @app_name = nil
            @module_name = nil
            @app_dir = nil
            @backward_compatible_naming = true
            @development_mode = true
            @search_path = nil
            @plugins = Array.new
            @plugins_enabled = true
            @available_plugins = Array.new
            @options = DEFAULT_OPTIONS.dup

            @public_logs = false
            @log_create_current = true
            @created_log_dirs = []
            @created_log_base_dirs = []
            @additional_model_files = []
            @restarting = false

            @shell_interface = nil
            @shell_interface_host = nil
            @shell_interface_port = Interface::DEFAULT_PORT
            @shell_abort_on_exception = true

            @rest_interface = nil
            @rest_interface_host = nil
            @rest_interface_port = Interface::DEFAULT_REST_PORT

            @automatic_testing = true
            @registered_exceptions = []
            @app_extra_metadata = Hash.new

            @filter_out_patterns = [Roby::RX_IN_FRAMEWORK,
                                    Roby::RX_IN_METARUBY,
                                    Roby::RX_IN_UTILRB,
                                    Roby::RX_REQUIRE]
            self.abort_on_application_exception = true

            @planners    = []
            @notification_listeners = Array.new
            @ui_event_listeners = Array.new

            @init_handlers         = Array.new
            @setup_handlers        = Array.new
            @require_handlers      = Array.new
            @clear_models_handlers = Array.new
            @cleanup_handlers      = Array.new
            @controllers           = Array.new
            @action_handlers       = Array.new
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
            setup_loggers(ignore_missing: true, redirections: false)

            setup_robot_names_from_config_dir

            # Get the application-wide configuration
            if plugins_enabled?
                register_plugins
            end

            update_load_path

            if initfile = find_file('config', 'init.rb', order: :specific_first)
                Application.info "loading init file #{initfile}"
                require initfile
            end

            update_load_path

            # Deprecated hook
            call_plugins(:load, self, deprecated: "define 'load_base_config' instead")
            call_plugins(:load_base_config, self)

            update_load_path

            if defined? Roby::Conf
                Roby::Conf.datadirs = find_dirs('data', 'ROBOT', all: true, order: :specific_first)
            end

            if has_app?
                require_robot_file
            end

            init_handlers.each(&:call)
            update_load_path

            # Define the app module if there is none, and define a root logger
            # on it
            app_module =
                begin self.app_module
                rescue NameError
                    Object.const_set(module_name, Module.new)
                end
            if !app_module.respond_to?(:logger)
                module_name = self.module_name
                app_module.class_eval do
                    extend ::Logger::Root(module_name, Logger::INFO)
                end
            end
        end

        def base_setup
            STDOUT.sync = true

            load_base_config
            if !@log_dir
                find_and_create_log_dir
            end
            setup_loggers(redirections: true)

            # Set up the loaded plugins
            call_plugins(:base_setup, self)
        end

        # The inverse of #base_setup
        def base_cleanup
            if !public_logs?
                created_log_dirs.each do |dir|
                    FileUtils.rm_rf dir
                end
                created_log_base_dirs.sort_by(&:length).reverse_each do |dir|
                    # .rmdir will ignore nonempty / nonexistent directories
                    FileUtils.rmdir(dir)
                end
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

            # Main is always included in the planner list
            self.planners << app_module::Actions::Main
           
            # Attach the global fault tables to the plan
            self.planners.each do |planner|
                if planner.respond_to?(:each_fault_response_table)
                    planner.each_fault_response_table do |table, arguments|
                        plan.use_fault_response_table table, arguments
                    end
                end
            end

        rescue Exception
            begin cleanup
            rescue Exception => e
                Roby.warn "failed to cleanup after #setup raised"
                Roby.log_exception_with_backtrace(e, Roby, :warn)
            end
            raise
        end

        # The inverse of #setup. It gets called at the end of #run
        def cleanup
            # Run the cleanup handlers first, we want the plugins to still be
            # active
            cleanup_handlers.each(&:call)

            call_plugins(:cleanup, self)
            # Deprecated version of #cleanup
            call_plugins(:reset, self, deprecated: "define 'cleanup' instead")

            planners.clear
            plan.execution_engine.gather_propagation do
                plan.clear
            end
            clear_models
            clear_config

            stop_shell_interface
            base_cleanup
        end

        # @api private
        def prepare_event_log
            require 'roby/droby/event_logger'
            require 'roby/droby/logfile/writer'

            logfile_path = File.join(log_dir, "#{robot_name}-events.log")
            event_io = File.open(logfile_path, 'w')
            logfile = DRoby::Logfile::Writer.new(event_io, plugins: plugins.map { |n, _| n })
            plan.event_logger = DRoby::EventLogger.new(logfile)
            plan.execution_engine.event_logger = plan.event_logger

            Robot.info "logs are in #{log_dir}"
            logfile_path
        end

        # Prepares the environment to actually run
        def prepare
            if public_shell_interface?
                setup_shell_interface
            end
            if public_rest_interface?
                setup_rest_interface
            end

            if public_logs? && log_create_current?
                FileUtils.rm_f File.join(log_base_dir, "current")
                FileUtils.ln_s log_dir, File.join(log_base_dir, 'current')
            end

            if log['events'] && public_logs?
                logfile_path = prepare_event_log

                # Start a log server if needed, and poll the log directory for new
                # data sources
                if log_server_options = (log.has_key?('server') ? log['server'] : Hash.new)
                    if !log_server_options.kind_of?(Hash)
                        log_server_options = Hash.new
                    end
                    plan.event_logger.sync = true
                    start_log_server(logfile_path, log_server_options)
                    Roby.info "log server started"
                else
                    plan.event_logger.sync = false
                    Roby.warn "log server disabled"
                end
            end

            call_plugins(:prepare, self)
        end


        # The inverse of #prepare. It gets called either at the end of #run or
        # at the end of #setup if there is an error during loading
        def shutdown
            call_plugins(:shutdown, self)
            stop_log_server
            stop_shell_interface
            stop_rest_interface(join: true)
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
            if !block
                raise ArgumentError, "missing expected block argument"
            end
            init_handlers << block
        end

        # Declares a block that should be executed when the Roby app is begin
        # setup
        def on_setup(&block)
            if !block
                raise ArgumentError, "missing expected block argument"
            end
            setup_handlers << block
        end

        # Declares a block that should be executed when the Roby app loads
        # models (i.e. in {#require_models})
        def on_require(&block)
            if !block
                raise ArgumentError, "missing expected block argument"
            end
            require_handlers << block
        end

        # @deprecated use {#on_setup} instead
        def on_config(&block)
            on_setup(&block)
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

        # Declares that the following block should be called when
        # {#clear_models} is called
        def on_clear_models(&block)
            if !block
                raise ArgumentError, "missing expected block argument"
            end
            clear_models_handlers << block
        end

        # Declares that the following block should be called when
        # {#clear_models} is called
        def on_cleanup(&block)
            if !block
                raise ArgumentError, "missing expected block argument"
            end
            cleanup_handlers << block
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
        def call_plugins(method, *args, deprecated: nil)
            each_responding_plugin(method) do |config_extension|
                if deprecated
                    Roby.warn "#{config_extension} uses the deprecated .#{method} hook during setup and teardown, #{deprecated}"
                end
                config_extension.send(method, *args)
            end
        end

        def register_plugins(force: false)
            if !plugins_enabled? && !force
                raise PluginsDisabled, "cannot call #register_plugins while the plugins are disabled"
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
        def using(*names, force: false)
            if !plugins_enabled? && !force
                raise PluginsDisabled, "plugins are disabled, cannot load #{names.join(", ")}"
            end

            register_plugins(force: true)
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

            # Refresh the relation sets in #plan to include relations
            # possibly added by the plugin
            plan.refresh_relations

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
            @robot_name, @robot_type = robots.resolve(name, type)
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
            maybe_relative_dir =
                if @log_base_dir ||= log['dir']
                    @log_base_dir
                elsif global_base_dir = ENV['ROBY_BASE_LOG_DIR']
                    File.join(global_base_dir, app_name)
                else
                    'logs'
                end
            File.expand_path(maybe_relative_dir, app_dir || Dir.pwd)
        end

        # Sets the directory under which logs should be created
        #
        # This cannot be called after log_dir has been set
        def log_base_dir=(dir)
            @log_base_dir = dir
        end

        # Create a log directory for the given time tag, and make it this app's
        # log directory
        #
        # The time tag given to this method also becomes the app's time tag
        #
        # @param [String] time_tag
        # @return [String] the path to the log directory
        def find_and_create_log_dir(time_tag = self.time_tag)
            base_dir  = log_base_dir
            @time_tag = time_tag

            while true
                log_dir  = Roby::Application.unique_dirname(base_dir, '', time_tag)
                new_dirs = Array.new

                dir = log_dir
                while !File.directory?(dir)
                    new_dirs << dir
                    dir = File.dirname(dir)
                end

                # Create all paths necessary, but check for possible concurrency
                # issues with other Roby-based tools creating a log dir with the
                # same name
                failed = new_dirs.reverse.any? do |dir|
                    begin FileUtils.mkdir(dir)
                        false
                    rescue Errno::EEXIST
                        true
                    end
                end

                if !failed
                    new_dirs.delete(log_dir)
                    created_log_dirs << log_dir
                    created_log_base_dirs.concat(new_dirs)
                    @log_dir = log_dir
                    log_save_metadata
                    return log_dir
                end
            end
        end

        # The directory in which logs are to be saved
        # Defaults to app_dir/data/$time_tag
        def log_dir
            if !@log_dir
                raise LogDirNotInitialized, "the log directory has not been initialized yet"
            end
            @log_dir
        end

        # Reset the current log dir so that {#setup} picks a new one
        def reset_log_dir
            @log_dir = nil
        end

        # Reset the plan to a new Plan object
        def reset_plan(plan = ExecutablePlan.new)
            @plan = plan
        end

        # Explicitely set the log directory
        #
        # It is usually automatically created under {#log_base_dir} during
        # {#base_setup}
        def log_dir=(dir)
            if !File.directory?(dir)
                raise ArgumentError, "log directory #{dir} does not exist"
            end
            @log_dir = dir
        end

        # The time tag. It is a time formatted as YYYYMMDD-HHMM used to mark log
        # directories
        def time_tag
            @time_tag ||= Time.now.strftime('%Y%m%d-%H%M')
        end

        # Add some metadata to {#app_metadata}, and save it to the log dir's
        # info.yml if it is already created
        def add_app_metadata(metadata)
            app_extra_metadata.merge!(metadata)
            if created_log_dir?
                log_save_metadata
            end
        end

        # Metadata used to describe the app
        #
        # It is saved in the app's log directory under info.yml
        #
        # @see add_app_metadata
        def app_metadata
            Hash['time' => time_tag, 'cmdline' => "#{$0} #{ARGV.join(" ")}",
                 'robot_name' => robot_name, 'robot_type' => robot_type,
                 'app_name' => app_name, 'app_dir' => app_dir].merge(app_extra_metadata)
        end

        # Test whether this app already created its log directory
        def created_log_dir?
            @log_dir && File.directory?(@log_dir)
        end

        # Save {#app_metadata} in the log directory
        #
        # @param [Boolean] append if true (the default), the value returned by
        #   {#app_metadata} is appended to the existing data. Otherwise, it
        #   replaces the last entry in the file
        def log_save_metadata(append: true)
            path = File.join(log_dir, 'info.yml')

            info = Array.new
            current =
                if File.file?(path)
                    YAML.load(File.read(path)) || Array.new
                else Array.new
                end

            if append || current.empty?
                current << app_metadata
            else
                current[-1] = app_metadata
            end
            File.open(path, 'w') do |io|
                YAML.dump(current, io)
            end
        end

        # Read the time tag from the current log directory
        def log_read_metadata
            dir = begin
                      log_current_dir
                  rescue ArgumentError
                  end

            if dir && File.exists?(File.join(dir, 'info.yml'))
                YAML.load(File.read(File.join(dir, 'info.yml')))
            else
                Array.new
            end
        end

        def log_read_time_tag
            metadata = log_read_metadata.last
            metadata && metadata['time_tag']
        end

        # The path to the current log directory
        #
        # If {#log_dir} is set, it is used. Otherwise, the current log directory
        # is inferred by the directory pointed to the 'current' symlink
        def log_current_dir
            if @log_dir
                @log_dir
            else
                current_path = File.join(log_base_dir, "current")
                self.class.read_current_dir(current_path)
            end
        end

        class NoCurrentLog < RuntimeError; end

        # The path to the current log file
        def log_current_file
            log_current_dir = self.log_current_dir
            metadata = log_read_metadata
            if metadata.empty?
                raise NoCurrentLog, "#{log_current_dir} is not a valid Roby log dir, it does not have an info.yml metadata file"
            elsif !(robot_name = metadata.map { |h| h['robot_name'] }.compact.last)
                raise NoCurrentLog, "#{log_current_dir}'s metadata does not specify the robot name"
            end

            full_path = File.join(log_current_dir, "#{robot_name}-events.log")
            if !File.file?(full_path)
                raise NoCurrentLog, "inferred log file #{full_path} for #{log_current_dir}, but that file does not exist"
            end
            full_path
        end

        # @api private
        #
        # Read and validate the 'current' dir by means of the 'current' symlink
        # that Roby maintains in its log base directory
        #
        # @param [String] current_path the path to the 'current' symlink
        def self.read_current_dir(current_path)
            if !File.symlink?(current_path)
                raise ArgumentError, "#{current_path} does not exist or is not a symbolic link"
            end
            resolved_path = File.readlink(current_path)
            if !File.exist?(resolved_path)
                raise ArgumentError, "#{current_path} points to #{resolved_path}, which does not exist"
            elsif !File.directory?(resolved_path)
                raise ArgumentError, "#{current_path} points to #{resolved_path}, which is not a directory"
            end
            resolved_path
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

        class InvalidLoggerName < ArgumentError; end

        # Sets up all the default loggers. It creates the logger for the Robot
        # module (accessible through Robot.logger), and sets up log levels as
        # specified in the <tt>config/app.yml</tt> file.
        def setup_loggers(ignore_missing: false, redirections: true)
            Robot.logger.progname = robot_name || 'Robot'
            return if !log['levels']

            # Set up log levels
            log['levels'].each do |name, value|
                const_name = name.modulize
                mod =
                    begin Kernel.constant(const_name)
                    rescue NameError => e
                        if ignore_missing
                            next
                        elsif name != const_name
                            raise InvalidLoggerName, "cannot resolve logger #{name} (resolved as #{const_name}): #{e.message}"
                        else
                            raise InvalidLoggerName, "cannot resolve logger #{name}: #{e.message}"
                        end
                    end

                if value =~ /^(\w+):(.+)$/
                    value, file = $1, $2
                    file = file.gsub('ROBOT', robot_name) if robot_name
                end
                level = Logger.const_get(value)

                io = if redirections && file
                         path = File.expand_path(file, log_dir)
                         Robot.info "redirected logger for #{mod} to #{path} (level #{level})"
                         io = File.open(path, 'w')
                         io.sync = true
                         log_files[path] ||= io
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

        # Register a server port that can be discovered later
        def register_server(name, port)
        end

        # Transforms +path+ into a path relative to an entry in +search_path+
        # (usually the application root directory)
        def make_path_relative(path)
            if !File.exists?(path)
                path
            elsif root_path = find_base_path_for(path)
                return Pathname.new(path).relative_path_from(root_path).to_s
            else
                path
            end
        end

        def register_exception(e, reason = nil)
            registered_exceptions << [e, reason]
        end

        def clear_exceptions
            registered_exceptions.clear
        end

        def isolate_load_errors(message, logger = Application, level = :warn)
            yield
        rescue Interrupt
            raise
        rescue ::Exception => e
            register_exception(e, message)
            if ignore_all_load_errors?
                Robot.warn message
                Roby.log_exception_with_backtrace(e, logger, level)
            else raise
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
            # Set up the loaded plugins
            call_plugins(:require_config, self, deprecated: "define 'require_models' instead")
            call_plugins(:require_models, self)

            require_handlers.each do |handler|
                isolate_load_errors("while calling #{handler}") do
                    handler.call
                end
            end

            define_actions_module
            if auto_load_models?
                auto_require_planners
            end
            define_main_planner_if_needed

            action_handlers.each do |act|
                isolate_load_errors("error in #{act}") do
                    app_module::Actions::Main.class_eval(&act)
                end
            end

            additional_model_files.each do |path|
                require File.expand_path(path)
            end

            if auto_load_models?
                auto_require_models
            end

            # Set up the loaded plugins
            call_plugins(:finalize_model_loading, self)

            plan.refresh_relations
        end

        def load_all_model_files_in(prefix_name, ignored_exceptions: Array.new)
            search_path = auto_load_search_path
            dirs = find_dirs(
                "models", prefix_name,
                path: search_path,
                all: true,
                order: :specific_last)

            dirs.each do |dir|
                all_files = Set.new
                Find.find(dir) do |path|
                    # Skip the robot-specific bits that don't apply on the
                    # selected robot
                    if File.directory?(path)
                        suffix = File.basename(File.dirname(path))
                        if robots.has_robot?(suffix) && ![robot_name, robot_type].include?(suffix)
                            Find.prune
                        end
                    end

                    if File.file?(path) && path =~ /\.rb$/
                        all_files << path
                    end
                end

                all_files.each do |path|
                    begin
                        require(path)
                    rescue *ignored_exceptions => e
                        ::Robot.warn "ignored file #{path}: #{e.message}"
                    end
                end
            end
        end
        
        def auto_require_models
            # Require all common task models and the task models specific to
            # this robot
            if auto_load_models?
                load_all_model_files_in('tasks')
                
                if backward_compatible_naming?
                    search_path = self.auto_load_search_path
                    all_files = find_files_in_dirs('tasks', 'ROBOT', path: search_path, all: true, order: :specific_last, pattern: /\.rb$/)
                    all_files.each do |p|
                        require(p)
                    end
                end
                call_plugins(:auto_require_models, self)
            end
        end

        # Test if the given name is a valid robot name
        def robot_name?(name)
            !robots.strict? || robots.has_robot?(name)
        end

        # Helper to the robot config files to load the root files in models/
        # (e.g. models/tasks.rb)
        def load_default_models
            ['tasks.rb', 'actions.rb'].each do |root_type|
                if path = find_file('models', root_type, path: [app_dir], order: :specific_first)
                    require path
                end
            end
            call_plugins(:load_default_models, self)
        end

        # Returns the downmost app file that was involved in the given model's
        # definition
        def definition_file_for(model)
            return if !model.respond_to?(:definition_location) || !model.definition_location 
            model.definition_location.each do |location|
                file = location.absolute_path
                next if !(base_path = find_base_path_for(file))
                relative = Pathname.new(file).relative_path_from(base_path)
                split = relative.each_filename.to_a
                next if split[0] != 'models'
                return file
            end
            nil
        end

        # Given a model class, returns the full path of an existing test file
        # that is meant to verify this model
        def test_files_for(model)
            return [] if !model.respond_to?(:definition_location) || !model.definition_location 

            test_files = Array.new
            model.definition_location.each do |location|
                file = location.absolute_path
                next if !(base_path = find_base_path_for(file))
                relative = Pathname.new(file).relative_path_from(base_path)
                split = relative.each_filename.to_a
                next if split[0] != 'models'
                split[0] = 'test'
                split[-1] = "test_#{split[-1]}"
                canonical_testpath = [base_path, *split].join(File::SEPARATOR)
                if File.exist?(canonical_testpath)
                    test_files << canonical_testpath
                end
            end
            test_files
        end

        def define_actions_module
            if !app_module.const_defined_here?(:Actions)
                app_module.const_set(:Actions, Module.new)
            end
        end

        def define_main_planner_if_needed
            if !app_module::Actions.const_defined_here?(:Main)
                app_module::Actions.const_set(:Main, Class.new(Roby::Actions::Interface))
            end
            if backward_compatible_naming?
                if !Object.const_defined_here?(:Main)
                    Object.const_set(:Main, app_module::Actions::Main)
                end
            end
        end

        # Loads the planner models
        #
        # This method is called at the end of {#require_models}, before the
        # plugins' require_models hook is called
        def require_planners
            Roby.warn_deprecated "Application#require_planners is deprecated and has been renamed into #auto_require_planners"
            auto_require_planners
        end

        def auto_require_planners
            search_path = self.auto_load_search_path

            prefixes = ['actions']
            if backward_compatible_naming?
                prefixes << 'planners'
            end
            prefixes.each do |prefix|
                load_all_model_files_in(prefix)
            end

            if backward_compatible_naming?
                main_files = find_files('planners', 'ROBOT', 'main.rb', all: true, order: :specific_first)
                main_files.each do |path|
                    require path
                end
                planner_files = find_files_in_dirs('planners', 'ROBOT', all: true, order: :specific_first, pattern: /\.rb$/)
                planner_files.each do |path|
                    require path
                end
            end
            call_plugins(:require_planners, self)
        end

        def load_config_yaml
            file = find_file('config', 'app.yml', order: :specific_first)
            return if !file

            Application.info "loading config file #{file}"
            options = YAML.load(File.open(file)) || Hash.new

            if robot_name && (robot_config = options.delete('robots'))
                options = options.recursive_merge(robot_config[robot_name] || Hash.new)
            end
            options = options.map_value do |k, val|
                val || Hash.new
            end
            options = @options.recursive_merge(options)
            apply_config(options)
            @options = options
        end

        # @api private
        #
        # Sets relevant configuration values from a configuration hash
        def apply_config(config)
            if host_port = config['interface']
                apply_config_interface(host_port)
            elsif host_port = config.fetch('droby', Hash.new)['host']
                Roby.warn_deprecated 'the droby.host configuration parameter in config/app.yml is deprecated, use "interface" at the toplevel instead'
                apply_config_interface(host_port)
            end
        end

        # @api private
        #
        # Parses and applies the 'interface' value from a configuration hash
        #
        # It is a helper for {#apply_config}
        def apply_config_interface(host_port)
            if host_port !~ /:\d+$/
                host_port += ":#{Interface::DEFAULT_PORT}"
            end

            match = /(.*):(\d+)$/.match(host_port)
            host = match[1]
            @shell_interface_host =
                if !host.empty?
                    host
                end
            @shell_interface_port = Integer(match[2])
        end

        def update_load_path
            search_path.reverse.each do |app_dir|
                $LOAD_PATH.delete(app_dir)
                $LOAD_PATH.unshift(app_dir)
                libdir = File.join(app_dir, 'lib')
                if File.directory?(libdir)
                    $LOAD_PATH.delete(libdir)
                    $LOAD_PATH.unshift(libdir)
                end
            end

            find_dirs('lib', 'ROBOT', all: true, order: :specific_last).
                each do |libdir|
                    if !$LOAD_PATH.include?(libdir)
                        $LOAD_PATH.unshift libdir
                    end
                end
        end

        def setup_robot_names_from_config_dir
            robot_config_files = find_files_in_dirs 'config', 'robots', 
                all: true,
                order: :specific_first,
                pattern: lambda { |p| File.extname(p) == ".rb" }

            robots.strict = !robot_config_files.empty?
            robot_config_files.each do |path|
                robot_name = File.basename(path, ".rb")
                robots.robots[robot_name] ||= robot_name
            end
        end

        def require_robot_file
            p = find_file('config', 'robots', "#{robot_name}.rb", order: :specific_first) ||
                find_file('config', 'robots', "#{robot_type}.rb", order: :specific_first)

            if p
                @default_auto_load = false
                require p
                if !robot_type
                    robot(robot_name, robot_name)
                end
            elsif !find_dir('config', 'robots', order: :specific_first) || (robot_name == robots.default_robot_name) || !robots.strict?
                Roby.warn "#{robot_name}:#{robot_type} is selected as the robot, but there is"
                if robot_name == robot_type
                    Roby.warn "no file named config/robots/#{robot_name}.rb"
                else
                    Roby.warn "neither config/robots/#{robot_name}.rb nor config/robots/#{robot_type}.rb"
                end
                Roby.warn "run roby gen robot #{robot_name} in your app to create one"
                Roby.warn "initialization will go on, but this behaviour is deprecated and will be removed in the future"
            else
                raise NoSuchRobot, "cannot find config file for robot #{robot_name} of type #{robot_type} in config/robots/"
            end
        end

        # Publishes a shell interface
        #
        # This method publishes a Roby::Interface object using
        # {Interface::TCPServer}. It is published on {Interface::DEFAULT_PORT}
        # by default. This default can be overriden by setting
        # {#shell_interface_port} either in config/init.rb, or in a
        # {Robot.setup} block in the robot configuration file.
        #
        # The shell interface is started in #setup and stopped in #cleanup
        #
        # @see stop_shell_interface
        def setup_shell_interface
            require 'roby/interface'

            if @shell_interface
                raise RuntimeError, "there is already a shell interface started, call #stop_shell_interface first"
            end
            @shell_interface = Interface::TCPServer.new(
                self, host: shell_interface_host, port: shell_interface_port)
            shell_interface.abort_on_exception = shell_abort_on_exception?
            if shell_interface_port != Interface::DEFAULT_PORT
                Robot.info "shell interface started on port #{shell_interface_port}"
            else
                Robot.debug "shell interface started on port #{shell_interface_port}"
            end
        end

        # Stops a running shell interface
        #
        # This is a no-op if no shell interface is currently running
        def stop_shell_interface
            if @shell_interface
                @shell_interface.close
                @shell_interface = nil
            end
        end

        # Publishes a REST API
        #
        # The REST API will long-term replace the shell interface. It is however
        # currently too limited for this purpose. Whether one should use one or
        # the other is up to the application, but prefer the REST API if it
        # suits your needs
        def setup_rest_interface
            require 'roby/interface/rest'

            if @rest_interface
                raise RuntimeError, "there is already a REST interface started, call #stop_rest_interface first"
            end
            composite_api = Class.new(Grape::API)
            composite_api.mount Interface::REST::API
            call_plugins(:setup_rest_interface, self, composite_api)

            @rest_interface = Interface::REST::Server.new(
                self, host: rest_interface_host, port: rest_interface_port,
                api: composite_api)
            @rest_interface.start

            if rest_interface_port != Interface::DEFAULT_REST_PORT
                Robot.info "REST interface started on port #{@rest_interface.port(timeout: nil)}"
            else
                Robot.debug "REST interface started on port #{rest_interface_port}"
            end
            @rest_interface
        end

        # Stops a running REST interface
        def stop_rest_interface(join: false)
            if @rest_interface
                # In case we're shutting down while starting up,
                # we must synchronize with the start to ensure that
                # EventMachine will be properly stopped
                @rest_interface.wait_start
                @rest_interface.stop
                @rest_interface.join if join
            end
        end

        def run(thread_priority: 0, &block)
            prepare

            engine_config = self.engine
            engine = self.plan.execution_engine
            plugins = self.plugins.map { |_, mod| mod if (mod.respond_to?(:start) || mod.respond_to?(:run)) }.compact
            engine.once do
                run_plugins(plugins, &block)
            end
            @thread = Thread.new do
                Thread.current.priority = thread_priority
                engine.run cycle: engine_config['cycle'] || 0.1
            end
            join

        ensure
            shutdown
            @thread = nil
            if restarting?
                Kernel.exec *@restart_cmdline
            end
        end

        def join
            @thread.join

        rescue Exception => e
            if execution_engine.running?
                if execution_engine.forced_exit?
                    raise
                else
                    execution_engine.quit
                    retry
                end
            else
                raise
            end
        end

        # Whether we're inside {#run}
        def running?
            !!@thread
        end

        # Whether {#run} should exec a new process on quit or not
        def restarting?
            !!@restarting
        end

        # Quits this app and replaces with a new one after a proper cleanup
        #
        # @param [String] cmdline the command line to exec after quitting. If
        #   not given, will restart using the same command line as the one that
        #   started this process
        def restart(*cmdline)
            @restarting = true
            @restart_cmdline =
                if cmdline.empty?
                    if defined? ORIGINAL_ARGV
                        [$0, *ORIGINAL_ARGV]
                    else
                        [$0, *ARGV]
                    end
                else cmdline
                end
            plan.execution_engine.quit
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
            engine = plan.execution_engine
            if mods.empty?
                yield if block_given?
                Robot.info "ready"
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
        end

        def stop; call_plugins(:stop, self) end

        def start_log_server(logfile, options = Hash.new)
            require 'roby/droby/logfile/server'

            # Allocate a TCP server to get an ephemeral port, and pass it to
            # roby-display
            sampling_period = DRoby::Logfile::Server::DEFAULT_SAMPLING_PERIOD
            sampling_period = Float(options['sampling_period'] || sampling_period)

            tcp_server = TCPServer.new(Integer(options['port'] || 0))
            server_flags = ["--fd=#{tcp_server.fileno}", "--sampling=#{sampling_period}", logfile]
            redirect_flags = Hash[tcp_server => tcp_server]
            if options['debug']
                server_flags << "--debug"
            elsif options['silent']
                redirect_flags[:out] = redirect_flags[:err] = :close
            end

            @log_server_port = tcp_server.local_address.ip_port
            @log_server_pid = Kernel.spawn("roby-display", 'server', *server_flags, redirect_flags)
        ensure
            tcp_server.close if tcp_server
        end

        def stop_log_server
            if @log_server_pid
                Process.kill('INT', @log_server_pid)
                @log_server_pid = nil
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
        #   find_dirs('tasks', 'ROBOT', all: true, order: :specific_first)
        #   # returns [app1/models/tasks/v3,
        #   #          app2/models/tasks/asguard,
        #   #          app1/models/tasks/]
        #
        # @example
        #   find_dirs('tasks', 'ROBOT', all: false, order: :specific_first)
        #   # returns [app1/models/tasks/v3/goto.rb]
        def find_dirs(*dir_path)
            Application.debug { "find_dirs(#{dir_path.map(&:inspect).join(", ")})" }
            if dir_path.last.kind_of?(Hash)
                options = dir_path.pop
            end
            options = Kernel.validate_options(options || Hash.new, :all, :order, :path)

            if dir_path.empty?
                raise ArgumentError, "no path given"
            end

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
        # {#search_path}. The subdirectories are resolved using File.join(*path)
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
        #   find_files_in_dirs('tasks', 'ROBOT', all: true, order: :specific_first)
        #   # returns [app1/models/tasks/v3/goto.rb,
        #   #          app2/models/tasks/asguard/goto.rb,
        #   #          app1/models/tasks/goto.rb]
        #
        # @example
        #   find_files_in_dirs('tasks', 'ROBOT', all: false, order: :specific_first)
        #   # returns [app1/models/tasks/v3/goto.rb,
        def find_files_in_dirs(*dir_path)
            Application.debug { "find_files_in_dirs(#{dir_path.map(&:inspect).join(", ")})" }
            if dir_path.last.kind_of?(Hash)
                options = dir_path.pop
            end
            options = Kernel.validate_options(options || Hash.new, :all, :order, :path, pattern: Regexp.new(""))

            dir_search = dir_path.dup
            dir_search << { all: true, order: options[:order], path: options[:path] }
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
        #   find_files('config', 'ROBOT.rb', all: true, order: :specific_first)
        #   # returns [app1/config/v3.rb,
        #   #          app2/config/asguard.rb]
        #
        # @example
        #   find_dirs('tasks', 'ROBOT', all: false, order: :specific_first)
        #   # returns [app1/config/v3.rb]
        #
        def find_files(*file_path)
            if file_path.last.kind_of?(Hash)
                options = file_path.pop
            end
            options = Kernel.validate_options(options || Hash.new, :all, :order, :path)

            if file_path.empty?
                raise ArgumentError, "no path given"
            end

            # Remove the filename from the complete path
            filename = file_path.pop
            filename = filename.split('/')
            file_path.concat(filename[0..-2])
            filename = filename[-1]

            if filename =~ /ROBOT/ && robot_name
                args = file_path + [options.merge(pattern: filename.gsub('ROBOT', robot_name))]
                robot_name_matches = find_files_in_dirs(*args)

                robot_type_matches = []
                if robot_name != robot_type
                    args = file_path + [options.merge(pattern: filename.gsub('ROBOT', robot_type))]
                    robot_type_matches = find_files_in_dirs(*args)
                end

                if options[:order] == :specific_first
                    result = robot_name_matches + robot_type_matches
                else
                    result = robot_type_matches + robot_name_matches
                end
            else
                args = file_path.dup
                args << options.merge(pattern: filename)
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
            args.last.merge!(all: true)
            find_files(*args).first
        end

        # Returns the first match from {#find_dirs}, or nil if nothing matches
        def find_dir(*args)
            if !args.last.kind_of?(Hash)
                args.push(Hash.new)
            end
            args.last.delete('all')
            args.last.merge!(all: true)
            find_dirs(*args).first
        end

        def setup_for_minimal_tooling
            self.public_logs = false
            self.auto_load_models = false
            self.single = true
            self.modelling_only = true
            setup
        end

        # @!method public_shell_interface?
        # @!method public_shell_interface=(flag)
        #
        # If set to true, this Roby application will publish a
        # {Interface::Interface} object as a TCP server.
        attr_predicate :public_shell_interface?, true

        # @!method public_logs?
        # @!method public_logs=(flag)
        #
        # If set to true, this Roby application will make its logs public, i.e.
        # will save the logs in logs/ and update the logs/current symbolic link
        # accordingly. Otherwise, the logs are saved in a folder in logs/ that
        # is deleted on teardown, and current is not updated
        #
        # Only the run modes have public logs by default
        attr_predicate :public_logs?, true

        # @!method log_create_current?
        # @!method log_create_current=(flag)
        #
        # If set to true, this Roby application will create a 'current' entry in
        # {#log_base_dir} that points to the latest log directory. Otherwise, it
        # will not. It is false when 'roby run' is started with an explicit log
        # directory (the --log-dir option)
        #
        # This symlink will never be created if {#public_logs?} is false,
        # regardless of this setting.
        attr_predicate :log_create_current?, true

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

        # @!method auto_load_all?
        # @!method auto_load_all=(flag)
        #
        # Controls whether Roby's auto-load feature should load all models in
        # {#search_path} or only the ones in {#app_dir}. It influences the
        # return value of {#auto_load_search_path}
        #
        # @return [Boolean]
        attr_predicate :auto_load_all?, true

        # @!method auto_load_models?
        # @!method auto_load_models=(flag)
        # 
        # Controls whether Roby should load the available the model files
        # automatically in {#require_models}
        #
        # @return [Boolean]
        attr_writer :auto_load_models

        def auto_load_models?
            if @auto_load_models.nil?
                @default_auto_load
            else
                @auto_load_models
            end
        end

        # @return [Array<String>] the search path for the auto-load feature. It
        #   depends on the value of {#auto_load_all?}
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

        # Returns the path in search_path that contains the given file or path
        #
        # @param [String] path
        # @return [nil,String]
        def find_base_path_for(path)
            if @find_base_path_rx_paths != search_path
                @find_base_path_rx = search_path.map { |app_dir| [Pathname.new(app_dir), app_dir, %r{(^|/)#{app_dir}(/|$)}] }.
                    sort_by { |_, app_dir, _| app_dir.size }.
                    reverse
                @find_base_path_rx_paths = search_path.dup
            end

            longest_prefix_path, _ = @find_base_path_rx.find do |app_path, app_dir, rx|
                (path =~ rx) ||
                    ((path[0] != ?/) && File.file?(File.join(app_dir, path)))
            end
            longest_prefix_path
        end

        # Returns true if the given path points to a file under {#app_dir}
        def self_file?(path)
            find_base_path_for(path) == app_path
        end

        # Returns true if the given path points to a file in the Roby app
        #
        # @param [String] path
        def app_file?(path)
            !!find_base_path_for(path)
        end

        # Tests whether a path is within a framework library
        #
        # @param [String] path
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

        # Ensure tha require'd files that match the given pattern can be
        # re-required
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

        # Reload files in config/
        def reload_config
            clear_config
            unload_features("config", ".*\.rb$")
            if has_app?
                require_robot_file
            end
            call_plugins(:require_config, self)
        end

        # Tests whether a model class has been defined in this app's code
        def model_defined_in_app?(model)
            model.definition_location.each do |location|
                return if location.label == 'require'
                return true if app_file?(location.absolute_path)
            end
            false
        end

        # The list of model classes that allow to discover all models in this
        # app
        #
        # @return [Array<#each_submodel>]
        def root_models
            models = [Task, TaskService, TaskEvent, Actions::Interface, Actions::Library,
             Coordination::ActionScript, Coordination::ActionStateMachine, Coordination::TaskScript]

            each_responding_plugin(:root_models) do |config_extension|
                models.concat(config_extension.root_models)
            end
            models
        end

        # Enumerate all models registered in this app
        #
        # It basically enumerate all submodels of all models in {#root_models}
        #
        # @param [nil,#each_submodel] root_model if non-nil, limit the
        #   enumeration to the submodels of this root
        # @yieldparam [#each_submodel]
        def each_model(root_model = nil)
            return enum_for(__method__, root_model) if !block_given?

            if !root_model
                self.root_models.each { |m| each_model(m, &Proc.new) }
                return
            end

            yield(root_model)
            root_model.each_submodel do |m|
                yield(m)
            end
        end

        # Whether this model should be cleared in {#clear_models}
        #
        # The default implementation returns true for the models that are not
        # registered as constants (more precisely, for which MetaRuby's
        # #permanent_model? returns false) and for the models defined in this
        # app.
        def clear_model?(m)
            !m.permanent_model? ||
                (!testing? && model_defined_in_app?(m))
        end

        # Clear all models for which {#clear_model?} returns true
        def clear_models
            root_models.each do |root_model|
                submodels = root_model.each_submodel.to_a.dup
                submodels.each do |m|
                    if clear_model?(m)
                        m.permanent_model = false
                        m.clear_model
                    end
                end
            end
            DRoby::V5::DRobyConstant.clear_cache
            clear_models_handlers.each { |b| b.call }
            call_plugins(:clear_models, self)
        end

        # Reload model files in models/
        def reload_models
            clear_models
            unload_features("models", ".*\.rb$")
            additional_model_files.each do |path|
                unload_features(path)
            end
            require_models
        end

        # Reload action models defined in models/actions/
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

        class ActionResolutionError < ArgumentError; end

        # Find an action on the planning interface that can generate the given task
        # model
        #
        # @return [Actions::Models::Action]
        # @raise [ActionResolutionError] if there either none or more than one matching
        #   action
        def action_from_model(model)
            candidates = []
            planners.each do |planner_model|
                planner_model.find_all_actions_by_type(model).each do |action|
                    candidates << [planner_model, action]
                end
            end
            candidates = candidates.uniq
                
            if candidates.empty?
                raise ActionResolutionError, "cannot find an action to produce #{model}"
            elsif candidates.size > 1
                raise ActionResolutionError, "more than one actions available produce #{model}: #{candidates.map { |pl, m| "#{pl}.#{m.name}" }.sort.join(", ")}"
            else
                candidates.first
            end
        end
        
        # Find an action with the given name on the action interfaces registered on
        # {#planners}
        #
        # @return [(ActionInterface,Actions::Models::Action),nil]
        # @raise [ActionResolutionError] if more than one action interface provide an
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
                raise ActionResolutionError, "more than one action interface provide the #{name} action: #{candidates.map { |pl, m| "#{pl}" }.sort.join(", ")}"
            else candidates.first
            end
        end

        # Finds the action matching the given name
        #
        # Unlike {#find_action_from_name}, it raises if no matching action has
        # been found
        #
        # @return [Actions::Models::Action]
        # @raise [ActionResolutionError] if either none or more than one action
        #   interface provide an action with this name
        def action_from_name(name)
            action = find_action_from_name(name)
            if !action
                available_actions = planners.map do |planner_model|
                    planner_model.each_action.map(&:name)
                end.flatten
                if available_actions.empty?
                    raise ActionResolutionError, "cannot find an action named #{name}, there are no actions defined"
                else
                    raise ActionResolutionError, "cannot find an action named #{name}, available actions are: #{available_actions.sort.join(", ")}"
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
        def prepare_action(name, mission: false, **arguments)
            if name.kind_of?(Class)
                planner_model, m = action_from_model(name)
            else
                planner_model, m = action_from_name(name)
            end

            if mission
                plan.add_mission_task(task = m.plan_pattern(arguments))
            else
                plan.add(task = m.plan_pattern(arguments))
            end
            return task, task.planning_task
        end

        # @return [#call] the blocks that listen to ui events. They are
        #   added with {#on_ui_event} and removed with
        #   {#remove_ui_event}
        attr_reader :ui_event_listeners

        # Enumerates the listeners currently registered through
        # #on_ui_event
        #
        # @yieldparam [#call] the job listener object
        def each_ui_event_listener(&block)
            ui_event_listeners.each(&block)
        end

        # Sends a message to all UI event listeners
        def ui_event(name, *args)
            each_ui_event_listener do |block|
                block.call(name, *args)
            end
        end

        # Registers a block to be called when a message needs to be
        # dispatched from {#ui_event}
        #
        # @yieldparam [String] name the event name
        # @yieldparam args the UI event listener arguments
        # @return [Object] the listener ID that can be given to
        #   {#remove_ui_event_listener}
        def on_ui_event(&block)
            if !block
                raise ArgumentError, "missing expected block argument"
            end
            ui_event_listeners << block
            block
        end

        # Removes a notification listener added with {#on_ui_event}
        #
        # @param [Object] listener the listener ID returned by
        #   {#on_ui_event}
        def remove_ui_event_listener(listener)
            ui_event_listeners.delete(listener)
        end

        # @return [#call] the blocks that listen to notifications. They are
        #   added with {#on_notification} and removed with
        #   {#remove_notification_listener}
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
        # dispatched from {#notify}
        #
        # @yieldparam [String] source the source of the message
        # @yieldparam [String] level the log level
        # @yieldparam [String] message the message itself
        # @return [Object] the listener ID that can be given to
        #   {#remove_notification_listener}
        def on_notification(&block)
            if !block
                raise ArgumentError, "missing expected block argument"
            end
            notification_listeners << block
            block
        end

        # Removes a notification listener added with {#on_notification}
        #
        # @param [Object] listener the listener ID returned by
        #   {#on_notification}
        def remove_notification_listener(listener)
            notification_listeners.delete(listener)
        end

        # Discover which tests should be run, and require them
        #
        # @param [Boolean] all if set, list all files in {#app_dir}/test.
        #   Otherwise, list only the tests that are related to the loaded
        #   models.
        # @param [Boolean] only_self if set, list only test files from within
        #   {#app_dir}. Otherwise, consider test files from all over {#search_path}
        # @return [Array<String>]
        def discover_test_files(all: true, only_self: false)
            if all
                test_files = each_test_file_in_app.inject(Hash.new) do |h, k|
                    h[k] = Array.new
                    h
                end
                if !only_self
                    test_files.merge!(Hash[each_test_file_for_loaded_models.to_a])
                end
            else
                test_files = Hash[each_test_file_for_loaded_models.to_a]
                if only_self
                    test_files = test_files.find_all { |f, _| self_file?(f) }
                end
            end
            test_files
        end

        # Hook for the plugins to filter out some paths that should not be
        # auto-loaded by {#each_test_file_in_app}. It does not affect
        # {#each_test_file_for_loaded_models}.
        #
        # @return [Boolean]
        def autodiscover_tests_in?(path)
            suffix = File.basename(path)
            if robots.has_robot?(suffix) && ![robot_name, robot_type].include?(suffix)
                false
            elsif defined? super
                super
            else
                true
            end
        end

        # Enumerate all the test files in this app and for this robot
        # configuration
        def each_test_file_in_app
            return enum_for(__method__) if !block_given?

            dir = File.join(app_dir, 'test')
            return if !File.directory?(dir)

            Find.find(dir) do |path|
                # Skip the robot-specific bits that don't apply on the
                # selected robot
                if File.directory?(path)
                    Find.prune if !autodiscover_tests_in?(path)
                end

                if File.file?(path) && path =~ /test_.*\.rb$/
                    yield(path)
                end
            end
        end

        # Enumerate the test files that should be run to test the current app
        # configuration
        #
        # @yieldparam [String] path the file's path
        # @yieldparam [Array<Class<Roby::Task>>] models the models that are
        #   meant to be tested by 'path'. It can be empty for tests that involve
        #   lib/
        def each_test_file_for_loaded_models(&block)
            models_per_file = Hash.new { |h, k| h[k] = Set.new }
            each_model do |m|
                next if m.respond_to?(:has_ancestor?) && m.has_ancestor?(Roby::Event)
                next if m.respond_to?(:private_specialization?) && m.private_specialization?
                next if !m.name

                test_files_for(m).each do |test_path|
                    models_per_file[test_path] << m
                end
            end

            find_files('test', 'actions', 'ROBOT', 'test_main.rb', order: :specific_first, all: true).each do |path|
                models_per_file[path] = Set[main_action_interface]
            end

            find_dirs('test', 'lib', order: :specific_first, all: true).each do |path|
                Pathname.new(path).find do |p|
                    if p.basename.to_s =~ /^test_.*.rb$/ || p.basename.to_s =~ /_test\.rb$/
                        models_per_file[p.to_s] = Set.new
                    end
                end
            end

            models_per_file.each(&block)
        end
    end
end

