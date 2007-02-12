if genom_loglevel = LOG['levels']['Genom']
    ::Genom.logger.level = Logger.const_get(genom_loglevel)
end

if defined? NAME
    Roby::State.genom do |g|
	include Roby::Genom

	genom_tasks = File.join(APP_DIR, 'tasks', 'genom')
	if File.directory?(genom_tasks)
	    g.autoload_path << genom_tasks
	end
	g.output_io = File.join(APP_DIR, "log", "#{NAME}-%m.log")

	genom_config = File.join(APP_DIR, 'config', "#{ROBOT}-genom.rb")
	if File.file?(genom_config)
	    require genom_config
	end

	MainPlanner.class_eval do
	    using *g.used_modules.values.
		map { |mod| mod::Planning rescue nil }.
		compact
	end
    end
end

# Checks if a lockfile named 'name' is present. If it is the case, yield false.
# Otherwise, it creates the file, yields true and deletes the file after the block
# has returned
def lockfile(name)
    filename = File.join(APP_DIR, "log", "#{name}.lock")
    if File.file?(filename)
	yield(true)
    else
	begin
	    FileUtils.touch filename
	    yield(false)
	ensure
	    FileUtils.rm_f filename
	end
    end
end

# Start the GDHE display if needed
def gdhe_display(env, display = nil)
    return yield unless (display ||= TERRAIN['display'])
    lockfile("gdhe-#{display}") do |present|
	if present
	    STDERR.puts "Not connecting to GDHE server, there is already a simulation environment connected"
	    yield

	else
	    config = {}
	    if TERRAIN['gdhe']
		config.merge!(:init_script => TERRAIN['gdhe'], :init_dir => 'data', :poll => 500)
	    end
	    env.to_gdhe display, config

	    yield
	end
    end
end

def reuse_gazebo(sim, conffile, options, &block)
    lockfile("gazebo") do |present|
	options[:reuse_gazebo] = present
	sim.call(conffile, options, &block)
    end
end

def GenomSimulation
    control = Roby::Control.instance
    # Build the simulation configuration file based on configuration in config/#{ROBOT}.conf
    Tempfile.open("pocosim.conf") do |io|
	io.puts <<-EOF
	name: #{NAME}
	log: #{APP_DIR}/log/#{NAME}
	bridge: gazebo
	models: #{APP_DIR}/config/pocosim/#{ROBOT}

	gazebo
	{
	    world: data/#{TERRAIN['gazebo']}
	}

	host
	{
	    name: #{NAME}
	    # map is map: pocosim_name gazebo_name
	    map: #{ROBOT} #{NAME}
	    own: #{NAME}
	}

	EOF

	template = File.join(APP_DIR, 'config', 'pocosim', "#{ROBOT}.conf")
	if File.file?(template)
	    io.puts File.read(template)
	end
	io.flush

	# Start simulation
	reuse_gazebo(Genom::Runner.method(:simulation), io.path, :env => NAME, :hostname => NAME) do |env|
	    gdhe_display(env) do
		::Genom.connect do
		    STDERR.puts "Connected to the Genom environment"
		    begin
			Roby::Control.once do
			    yield(env)
			end
			control.join

		    rescue Interrupt
			control.quit
			control.join

		    ensure
			control.disable_propagation
			STDERR.puts "Leaving Genom"
		    end
		end
	    end
	end
    end

ensure
    control.quit
    control.join
end


