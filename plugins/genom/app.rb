require 'genom/lib/genom-tools'

module Roby::Genom
    # Genom plugin for Roby
    #
    # General principles: modules are loaded and a task model is created for each 
    # of the module requests. For instance, given the 'foo' module defined by 
    #
    #   module foo {
    #     ...
    #   };
    #
    #   request Go {
    #   ...
    #   };
    #
    #   request Init {
    #   ...
    #   };
    #
    # Roby/Genom will create a Roby::Genom::Foo module with the Roby::Genom::Foo::Go and
    # Roby::Genom::Foo::Init task models.
    #
    # == Runner tasks
    # The request tasks all have for {execution agent}[Roby::TaskStructure::ExecutionAgent]
    # 
    #
    # == Configuration files
    # ROBOT-genom.rb
    #
    # == Simulation support
    # pocosim/ simulation
    #
    # NOTE: if two simulations are run on the same host, do NOT use the multi-robot server.
    # Otherwise, position changes done by one of the controllers will be overridden by the
    # multi-robot server
    #
    # == Test support
    module Application
	attribute(:pocosim) do
	    Hash[ 'display' => nil, 'gdhe' => nil, 'gazebo' => nil ]
	end
	attribute(:genom) do
	    Hash[ 'mem_size' => nil ]
	end

	def self.load(config, options)
	    config.load_option_hashes(options, %w{pocosim genom})
	end

	def self.setup(config)
	    if genom_loglevel = config.log['levels']['Genom']
		::Genom.logger.level = Logger.const_get(genom_loglevel)
	    end
	    if config.simulation?
		if !config.pocosim['gazebo']
		    raise ArgumentError, "configuration is missing the gazebo terrain file"
		end
	    end

	    Roby::State.genom do |g|
		include Roby::Genom

		if config.robot_name
		    genom_tasks = File.join(APP_DIR, 'tasks', 'genom')
		    if File.directory?(genom_tasks)
			g.autoload_path << genom_tasks
		    end

		    g.output_io = File.join(config.log_dir, "#{config.robot_name}-%m.log")
		    config.require_robotfile(File.join(APP_DIR, 'config', "ROBOT-genom.rb"))

		    ::MainPlanner.class_eval do
			using *g.used_modules.values.
			    map { |mod| mod::Planning rescue nil }.
			    compact
		    end
		end
	    end
	end

	DEFAULT_MULTI_PORT = 2000

	def self.start_distributed(config)
	    unless config.pocosim['server']
		return "no pocosim server defined, nothing to do"
	    end
	    port = DEFAULT_MULTI_PORT
	    if config.pocosim['server'] =~ /:(\d+)$/
		port = Integer($1)
	    end
	    multi_conf = <<-EOD
bridge: gazebo-multi
gazebo
{
  world: #{config.pocosim['gazebo']}
}
multi
{
  port: #{port}
}
	    EOD
	    conffile = File.join(config.log_dir, 'distributed.pocosim')
	    File.open(conffile, 'w') do |io|
		io.write multi_conf
	    end

	    @pocosim_server = fork do
		Genom::Runner.h2 :env => 'roby-distributed-server' do
		    system("sim global #{conffile}")
		end
	    end
	end
	def self.stop_distributed(config)
	    return unless @pocosim_server

	    Process.kill('INT', @pocosim_server)
	    Process.waitpid(@pocosim_server)
	rescue Errno::ECHILD
	rescue Interrupt
	    Process.kill('KILL', @pocosim_server)
	end

	def self.run(config, &block)
	    if config.simulation?
		run_simulation(config) do |env|
		    Roby::State.genom.used_modules.each_value do |modname|
			Roby::Genom.genom_rb::GenomModule.killmodule(modname)
		    end
		    yield(env)
		end
	    else
		Genom::Runner.h2(:env => config.robot.name) do |env|
		    yield(env)
		end
	    end
	end

	def self.generate_simulation_config(config)
	    bridge_config = ""

	    if config.pocosim['server'] && !config.single?
		config.pocosim['server'] =~ /^([\w\.]+)(?::(\d+))?$/
		host = $1
		port = Integer($2) if $2 && !$2.empty?

		bridge_config << "bridge: gazebo-multi\n"
		bridge_config << "multi {\n"
		bridge_config << "  server: #{host}\n"
		bridge_config << "  port: #{port}\n" if port
		bridge_config << "}\n"
	    else
		bridge_config = "bridge: gazebo\n"
	    end
	    
	    filename = File.join(config.log_dir, "#{config.robot_name}.pocosim")
	    File.open(filename, 'w') do |io|
		io.puts bridge_config
		io.puts <<-EOF
name: #{config.robot_name}
log: #{config.log_dir}/#{config.robot_name}
models: #{APP_DIR}/config/pocosim/#{config.robot_type}

gazebo
{
    world: data/#{config.pocosim['gazebo']}
}

host
{
    name: #{config.robot_name}
    # map is map: pocosim_name gazebo_name
    map: #{config.robot_type} #{config.robot_name}
    own: #{config.robot_name}
}
		EOF

		template = File.join(APP_DIR, 'config', 'pocosim', "#{config.robot_name}.conf")
		if File.file?(template)
		    io.puts File.read(template)
		end
		template = File.join(APP_DIR, 'config', 'pocosim', "#{config.robot_type}.conf")
		if File.file?(template)
		    io.puts File.read(template)
		end
	    end

	    filename
	end

	def self.run_simulation(config)
	    # Build the simulation configuration file based on configuration in config/#{ROBOT}.conf
	    conffile = generate_simulation_config(config) 
	    # Start simulation
	    reuse_gazebo(Genom::Runner.method(:simulation), conffile, :mem_size => config.genom['mem_size'], 
			 :env => config.robot_name, :hostname => config.robot_name) do |env|
		::Genom.connect do
		    STDERR.puts "Connected to the Genom environment"
		    begin
			yield(env)
		    ensure
			Roby::Control.instance.disable_propagation
			STDERR.puts "Leaving Genom"
		    end
		end
	    end
	end

	# Returns the name of the data source type for +filename+ if it is
	# known to this component
	def self.data_source(filenames)
	    if filenames.all? { |f| f =~ /\.\d+\.log/ }
		Roby::Log::DataSource.new(filenames, 'pocosim')
	    end
	end

	# Returns the list of data sources known to this component
	def self.data_sources(logdir)
	    pocosim_logs = Dir.enum_for(:glob, File.join(logdir, '*.log')).
		inject({}) { |h, name| name =~ /\.\d+\.log/ ; (h[$`] ||= []) << name ; h }
	    pocosim_logs.delete(nil) # remove unmatched files
	    pocosim_logs.map do |_, fileset|
		fileset = fileset.sort_by { |name| name =~ /\.(\d+)\.log$/ ; Integer($1) }
		Roby::Log::DataSource.new(fileset, 'pocosim')
	    end
	end

	# Reload the Genom framework. Reload the Genom files only if the .gen
	# file has changes. The runner task does not have to be reloaded
	#
	# Note that the plugin code itself is 
	def self.reload(config)
	end
    end
end

Roby::Application.register_plugin('genom', Roby::Genom::Application) do
    require 'lib/genom'
    Roby::Application.filter_reloaded_models do |model|
	!(model < Roby::Genom::RequestTask)
    end
end

