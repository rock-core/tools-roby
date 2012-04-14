require 'find'
module Roby
    class Installer
	# The directory in which we are installing
	attr_reader :app_dir

	# The configuration hash saved in config/roby.yml
	attr_reader :config

	def config_path; File.join(app_dir, 'config', 'roby.yml') end
	def installed_plugins; config['plugins'] || [] end

	def check_plugins(plugins)
	    if name = plugins.find { |name| !Roby.app.defined_plugin?(name) }
		known_plugins = Roby.app.available_plugins.map { |name, _| name }
		raise ArgumentError, "unknown plugin #{name}. Available plugins are #{known_plugins.join(", ")}"
	    end
	end

	def initialize(app_dir)
	    @app_dir = File.expand_path(app_dir)

	    # Read the application configuration from config/roby.yml if the file exists,
	    @config = if File.file?(config_path)
			  YAML.load_file(config_path)
		      else
			  Hash['plugins', []]
		      end
	    check_plugins(config['plugins'])
	end

	def save_config
	    File.open(config_path, 'w') do |io|
		io << YAML.dump(config)
	    end
	end

	# Install the template files for a core Roby application and the provided
	# plugins
	def install(plugins)
	    check_plugins(plugins)
	    install_dir(plugins) do |file|
		next if file =~ /ROBOT/
		file
	    end

	    config['plugins'] |= plugins
	    save_config
	end

	# Installs the template files for a new robot named +name+
	def robot(name)
	    install_dir(installed_plugins) do |file|
		next if file !~ /ROBOT/
		file.gsub /ROBOT/, name
	    end
	end

	# Copies the template files into the application directory, without erasing
	# already existing files. +plugins+ is the list of plugins we should copy
	# files from
	def install_dir(plugins = [], &filter)
	    Installer.copy_tree(File.join(Roby::ROBY_ROOT_DIR, 'app'), app_dir, &filter)
	    plugins.each do |enabled_name|
		plugin_desc = Roby.app.available_plugins.find { |name, dir, _, _| enabled_name == name }

		plugin_app_dir = File.join(plugin_desc[1], 'app')
		next unless File.directory?(plugin_app_dir)
		Installer.copy_tree(plugin_app_dir, app_dir, &filter)
	    end
	end

	# Copy all files that are in +basedir+ into +destdir+. If a block is given,
	# it is called with each file relative path. The block must then return the
	# destination name, or nil if the file is to be skipped.
	def self.copy_tree(basedir, destdir)
	    basedir = File.expand_path(basedir)
	    destdir = File.expand_path(destdir)

	    Find.find(basedir) do |file|
		relative = file.gsub /#{Regexp.quote("#{basedir}")}\/?/, ''
		relative = yield(relative) if block_given?
		# The block can return nil if the file shouldn't be installed
		next unless relative

		destfile = File.join(destdir, relative)
		if File.directory?(file)
		    if !File.exists?(destfile)
			puts "creating #{relative}/"
			Dir.mkdir destfile
		    elsif !File.directory?(destfile)
			STDERR.puts "#{destfile} exists but it is not a directory"
			exit(1)
		    end
		else
		    if !File.exists?(destfile)
			FileUtils.cp file, destfile, :preserve => true
			puts "creating #{relative}"
		    elsif !File.file?(destfile)
			STDERR.puts "#{destfile} exists but it is not a file"
			exit(1)
		    end
		end
	    end
	end
    end
end

