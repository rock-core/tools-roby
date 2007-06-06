
module Roby
    # Subsystem plugin for Roby
    #
    # This plugin manages a set of  services that should be available at all
    # times (for instance: localization). This allows to make Roby start them
    # at initialization time, and other planning methods to 
    #
    # == Configuration
    # The set of subsystems that should be considered is to be set through the State.subsystems
    # configuration object:
    #
    #   State.subsystems do |sys|
    #	  sys.localization = 'pom'
    #	  sys.laser_ranges = 'sick'
    #	  sys.on_demand    = 'ranges'
    #	end
    #
    # The subsystem plugin will then use <tt>MainPlanner#subsystem_name(:id =>
    # 'subsystem_selected')</tt> to start the subsystems that are not listed in
    # +on_demand+. In the example above, the initial plan will be made using
    #
    #   planner.localization(:id => 'pom')
    #
    # The resulting plan is then started one subsystem after the other
    # <b>before</b> the controller is loaded
    #
    # == Subsystems and state update
    module Subsystems
	module Application
	    def self.setup_main_planner
		MainPlanner.class_eval do
		    Roby::State.services.each_member do |name, value|
			filter(name) do |options, method|
			    options[:id] || method.id.to_s == value.to_s
			end
		    end
		end
	    end

	    def self.initialize_plan
		setup_main_planner
		plan = Transaction.new(Roby.plan)

		# Create the tasks and set them up
		planner = MainPlanner.new(plan)
		ready   = AndGenerator.new
		State.services.each_member do |name, value|
		    next if name == 'tasks'
		    new_task = begin
				   planner.send(name)
			       rescue Planning::NotFound => e
				   raise RuntimeError, e.full_message
			       end

		    State.services.tasks.send("#{name}=", new_task)

		    plan.permanent(new_task)
		    started_with = if new_task.has_event?(:ready) then :ready
				   else :start
				   end

		    ready << new_task.event(started_with)
		    new_task.on(started_with) do
			Robot.warn "#{name} subsystem started (#{value})"
		    end
		    new_task.on(:stop) do
			Robot.warn "#{name} subsystem stopped (#{value})"
		    end
		end

		tasks = State.services.tasks.to_hash.values
		start_with = []

		# Add links to start the tasks in order
		tasks.each do |task|
		    children = task.generated_subgraph(TaskStructure::Hierarchy) & tasks.to_value_set
		    children.delete(task)

		    if children.empty?
			start_with << task
			next
		    end
		    children.inject(ev = AndGenerator.new) do |ev, child|
			started_with = if child.has_event?(:ready) then :ready
				       else :start
				       end
			started_with = child.event(started_with)

			ready << started_with
			ev    << started_with
		    end
		    ev.on task.event(:start)
		end

		Roby.execute do
		    plan.commit_transaction
		end
		[start_with, ready]
	    end

	    def self.run(config, &block)
		Robot.info "Starting subsystems ..."

		start_with, ready = initialize_plan
		# Start the deepest tasks. The signalling order will do the rest.
		# The 'ready' event is emitted when all the subsystem tasks are
		Roby.wait_until(ready) do
		    Roby.execute do
			start_with.each { |t| t.start! }
		    end
		end

		yield
	    end
	end
    end

    Application.register_plugin('subsystems', Roby::Subsystems::Application) do
	Roby::Control.each_cycle do
	    srv = Roby::State.services
	    srv.each_member do |name, value|
		task = srv.tasks.send(name)
		next unless task.running?
		if task.has_event?(:ready)
		    next unless task.event(:ready).happened?
		end

		if task.respond_to?("update_#{name}")
		    begin
			task.send("update_#{name}", State)
		    rescue Exception => e
			Roby.warn "update_#{name} failed on #{task} with #{e}"
		    end
		end
	    end
	end
    end
end
