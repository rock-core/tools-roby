require 'utilrb/logger'

module Robot
    class << self
	attr_accessor :logger
    end
    extend Logger::Forward

    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
    @logger.formatter = Roby.logger.formatter
    @logger.progname = "Robot"

    def self.action_from_model(model)
	candidates = []
        Roby.app.planners.each do |planner_model|
            planner_model.planning_methods_names.each do |method_name|
                if result = planner_model.find_methods(method_name, :returns => model)
                    result.each do |m|
                        candidates << [planner_model, m]
                    end
                end
            end
        end
            
        if candidates.empty?
            raise ArgumentError, "cannot find a planning method that returns #{model}"
        elsif candidates.size > 1
            raise ArgumentError, "more than one planning method found that returns #{model}: #{candidates.map { |pl, m| "#{pl}.#{m.name}" }.sort.join(", ")}"
        else
            candidates.first
        end
    end

    def self.prepare_action(plan, name, arguments = Hash.new)
        if name.kind_of?(Class)
            planner_model, m = action_from_model(name)
        else
            # Check if +name+ is a planner method, and in that case
            # add a planning method for it and plan it
            planner_model = Roby.app.planners.find do |planner_model|
                planner_model.has_method?(name)
            end
            if !planner_model
                raise ArgumentError, "no such planning method #{name}"
            end

            m = planner_model.model_of(name, arguments)
        end

	returns_model = (m.returns if m && m.returns) || Roby::Task

	if returns_model.kind_of?(Roby::TaskModelTag)
	    task = Roby::Task.new
	    task.extend returns_model
	else
	    # Create an abstract task which will be planned
	    task = returns_model.new
	end

	planner = Roby::PlanningTask.new(:planner_model => planner_model,
                                         :planning_method => m,
                                         :method_options => arguments)
        if plan
            plan.add([task, planner])
        end
	task.planned_by planner
        task.abstract = true
	return task, planner
    end

    def self.method_missing(name, *args)
	if name.to_s =~ /!$/
	    name = $`.to_sym
	else
	    super
	end

	if args.size > 1
	    raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in #{name}!"
	end

	options = args.first || {}
	task, planner = Robot.prepare_action(Roby.plan, name, options)
	Roby.plan.add_mission(task)

	return task, planner
    end
end

