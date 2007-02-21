module Roby::Genom
    module Application
	attribute(:pocosim) do
	    Hash[ 'display' => nil, 'gdhe' => nil, 'gazebo' => nil ]
	end

	def self.load(config, options)
	    config.load_option_hashes(options, %w{pocosim})
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

		    g.output_io = File.join(APP_DIR, "log", "#{config.robot_name}-%m.log")
		    config.require_robotfile(File.join(APP_DIR, 'config', "ROBOT-genom.rb"))

		    ::MainPlanner.class_eval do
			using *g.used_modules.values.
			    map { |mod| mod::Planning rescue nil }.
			    compact
		    end
		end
	    end

	    require 'plugins/genom/lib/genom-tools'
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
	    conffile = File.join(APP_DIR, 'log', 'distributed.pocosim')
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
		run_simulation(config, &block)
	    else
		raise NotImplementedError
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
	    
	    filename = File.join(APP_DIR, "log", "#{config.robot_name}.pocosim")
	    File.open(filename, 'w') do |io|
		io.puts bridge_config
		io.puts <<-EOF
name: #{config.robot_name}
log: #{APP_DIR}/log/#{config.robot_name}
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
	    reuse_gazebo(Genom::Runner.method(:simulation), conffile, :env => config.robot_name, :hostname => config.robot_name) do |env|
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
		Roby::Log::DataSource.new(filenames, 'pocosim', nil)
	    end
	end

	# Returns the list of data sources known to this component
	def self.data_sources(logdir)
	    pocosim_logs = Dir.enum_for(:glob, File.join(logdir, '*.log')).
		inject({}) { |h, name| name =~ /\.\d+\.log/ ; (h[$`] ||= []) << name ; h }
	    pocosim_logs.delete(nil) # remove unmatched files
	    pocosim_logs.map do |_, fileset|
		fileset = fileset.sort_by { |name| name =~ /\.(\d+)\.log$/ ; Integer($1) }
		Roby::Log::DataSource.new(fileset, 'pocosim', nil)
	    end
	end
    end
end

Roby::Application.register_plugin 'genom', 'lib/genom', Roby::Genom::Application

