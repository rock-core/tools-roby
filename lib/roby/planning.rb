require 'roby'

module Roby
    module Planning
        extend Logger::Hierarchy
        extend Logger::Forward
    end
end

require 'roby/planning/task'
require 'roby/planning/model'

module Roby
    def Planning.component_name; "planning" end
    module Planning::ApplicationConfig
	def self.setup(config)
	    # Load the main planner definitions
	    planner_dir = File.join(APP_DIR, 'planners')

	    if config.robot_name
		robot_planner_dir = File.join(planner_dir, config.robot_name)
		robot_planner_dir = nil unless File.directory?(robot_planner_dir)

		# First, load the main planner
		if robot_planner_dir
		    begin
			require File.join(robot_planner_dir, 'main')
		    rescue LoadError => e
			raise unless e.message =~ /no such file to load -- #{robot_planner_dir}\/main/
			require File.join(APP_DIR, 'planners', 'main')
		    end
		else
		    require File.join(APP_DIR, 'planners', 'main')
		end
	    else
		require File.join(APP_DIR, "planners", "main")
	    end

	    # Load the other planners
	    [robot_planner_dir, planner_dir].compact.each do |base_dir|
		Dir.new(base_dir).each do |file|
		    if File.file?(file) && file =~ /\.rb$/ && file !~ 'main\.rb$'
			require file
		    end
		end
	    end

	    # Set filters for subsystem selection
	    MainPlanner.class_eval do
		Roby::State.services.each_member do |name, value|
		    if value.respond_to?(:mode)
			filter(name) do |options, method|
			    options[:id] || method.id == value.mode
			end
		    end
		end
	    end

	    # MainPlanner is always included in the planner list
	    Roby::Control.instance.planners << MainPlanner
	end
    end
end

