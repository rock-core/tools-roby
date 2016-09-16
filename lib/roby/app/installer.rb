require 'find'
require 'fileutils'
module Roby
    class Installer
	# The directory in which we are installing
	attr_reader :app

	def initialize(app)
	    @app = app
            init = File.join(app.app_dir, "config", "init.rb")
            if File.file?(init)
                require init
            end
	end

        def plugin_dirs
            app.plugins.map do |plugin_name, _|
                _, dir, _ = app.plugin_definition(plugin_name)
                if File.file?(dir)
                    File.dirname(dir)
                else dir
                end
            end
        end

	# Install the template files for a core Roby application and the provided
	# plugins
	def install
	    install_dir(plugin_dirs) do |file|
		next if file =~ /ROBOT/
		file
	    end
	end

	# Installs the template files for a new robot named +name+
	def robot(name)
	    install_dir(plugin_dirs) do |file|
		next if file !~ /ROBOT/
		file.gsub /ROBOT/, name
	    end
	end

	# Copies the template files into the application directory, without erasing
	# already existing files. +plugins+ is the list of plugins we should copy
	# files from
	def install_dir(plugin_dirs = [], &filter)
	    Installer.copy_tree(File.join(Roby::ROBY_ROOT_DIR, 'app'), app.app_dir, &filter)
	    plugin_dirs.each do |dir|
		plugin_app_dir = File.join(dir, 'app')
		next unless File.directory?(plugin_app_dir)
		Installer.copy_tree(plugin_app_dir, app.app_dir, &filter)
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
			FileUtils.cp file, destfile, preserve: true
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

