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

