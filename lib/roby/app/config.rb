require 'roby'

module Roby
    def self.app
	Application::Config.instance
    end

    module Application
	ROBY_DIR = File.expand_path( File.join(File.dirname(__FILE__), '..') )
	COMPONENTS = { 
	    'genom' => ['roby/adapters/genom', 'Roby::Genom'],
	    'distributed' => ['roby/distributed', 'Roby::Distributed'],
	    'planning' => ['roby/planning', 'Roby::Planning']
	}

	class Config
	    include Singleton
	    attribute(:log) { Hash['timings' => false, 'events' => false, 'levels' => Hash.new] }

	    attr_reader :options

	    attribute(:components) { Array.new }

	    # Returns true if +component+ is loaded
	    def loaded_component?(name)
		components.any? { |mod, _| mod.component_name == name }
	    end

	    # Call +method+ on each configuration extension module, with arguments +args+
	    def call_components(method, *args)
		components.each do |_, config_extension|
		    config_extension.send(method, *args) if config_extension.respond_to?(method)
		end
	    end

	    # Load configuration from +options+
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

		load_option_hashes(options, %w{log control})
		call_components(:load, self, options)
	    end

	    def load_option_hashes(options, names)
		names.each do |optname|
		    if options[optname]
			send(optname).merge! options[optname]
		    end
		end
	    end

	    # Loads the components in +components+. All defined components are defined in Application::COMPONENTS
	    def using(*load_components)
		load_components.each do |name|
		    file, mod = *COMPONENTS[name]
		    unless file
			raise ArgumentError, "#{name} is not a known component (#{COMPONENTS.keys.join(", ")})"
		    end

		    begin
			require file
		    rescue LoadError => e
			Roby.fatal "cannot load component #{name}: #{e.full_message}"
			exit(1)
		    end

		    begin
			mod = constant(mod)
		    rescue NameError
			Roby.fatal "internal error: #{mod} is not a valid module name, while loading the '#{name}' component"
			exit(1)
		    end

		    config_extension = mod::ApplicationConfig rescue nil
		    components << [mod, config_extension]
		    if config_extension
			extend config_extension
			if config_extension.respond_to?(:load) && options
			    config_extension.load(self, options)
			end
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
	    
	    # Robot-specific config: configuration of the control instance
	    attribute(:control) do
	       	Hash[ 'timings' => false, 
		    'events' => false, 
		    'abort_on_exception' => false, 
		    'abort_on_application_exception' => true, 
		    'control_gc' => false ]
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

		# Load robot-specific configuration
		if robot_name
		    require_robotfile(File.join(APP_DIR, 'config', "ROBOT.rb"))
		end

		# Set up the loaded components
		call_components(:setup, self)
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
		    require 'roby/log/file'
		    logfile = File.join(APP_DIR, 'log', "#{robot_name}-events.log")
		    Roby::Log.loggers << Roby::Log::FileLogger.new(File.open(logfile, 'w'))
		end
		control.abort_on_exception = 
		    control_config['abort_on_exception']
		control.abort_on_application_exception = 
		    control_config['abort_on_application_exception']
		control.run options

		config_extensions = components.map { |_, config| config if config.respond_to?(:run) }.compact
		run_components(config_extensions, &block)
	    end
	    def run_components(mods, &block)
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
			run_components(mods, &block)
		    end
		end
	    end

	    def stop; call_components(:stop, self) end
	    def start_distributed; call_components(:start_distributed, self) end
	    def stop_distributed; call_components(:stop_distributed, self) end

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
	    def single?; @single end
	end
	def self.config; Roby::Application::Config.instance end
    end
end

