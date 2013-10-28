module Roby
    module Coordination
        extend Logger::Forward
        extend Logger::Hierarchy

        # Implementation of a task script
        #
        # The model-level accessors and API is described in {Models::Script}
        class TaskScript < Base
            extend Models::Script
            include Script

            attr_reader :definition_block

            # @deprecated
            #
            # Use #root_task instead
            def task
                root_task
            end

            def parse(&block)
                @definition_block = block
                instance_eval(&block)
            end

            def bind(task)
                result_model = self.class.superclass.new_submodel(:root => model.root.model)
                result = result_model.new(task)
                result.parse(&definition_block)
                result.prepare
                result
            end

            def resolve_instructions
                super
                model.each_task do |model_task|
                    script_task = instance_for(model_task)
                    if script_task.respond_to?(:task) && !script_task.task # Not bound ? Check if the model can be instanciated
                        task = model_task.instanciate(root_task.plan)
                        bind_coordination_task_to_instance(script_task, task, :on_replace => :copy)

                        # Protect from scheduling until the start is executed
                        #
                        # #start_task will be called by the Start instruction
                        root_task.start_event.add_causal_link(task.start_event)
                    end
                end
                # Now, make the dependencies based on what we do / wait for with
                # the tasks. Namely, we look at Start (dependency options) and
                # Wait (success events)
                instructions.each do |ins|
                    case ins
                    when Coordination::Models::Script::Start
                        task = ins.task.resolve
                        root_task.depends_on task, ins.dependency_options
                    end
                end
            end

            # Resolve the given event object into a Coordination::Task and a
            # Coordination::Models::Task
            def resolve_task(task)
                if root_task && task.kind_of?(Roby::Task)
                    root_task.plan.add(task)
                    model_task = Coordination::Models::Task.new(task.model)
                    script_task = instance_for(model_task)
                    bind_coordination_task_to_instance(script_task, task, :on_replace => :copy)
                else
                    model_task = self.model.task(task)
                    script_task = instance_for(model_task)
                end

                return script_task, model_task
            end

            # Resolve the given event object into a Coordination::Event and a
            # Coordination::Models::Event
            def resolve_event(event)
                if event.respond_to?(:to_sym)
                    symbol = event
                    if root_task
                        event = root_task.find_event(symbol)
                    else
                        event = model.root.find_event(symbol)
                    end
                    if !event
                        raise ArgumentError, "#{model.root} has no event called #{symbol}"
                    end
                end
                script_task, model_task = resolve_task(event.task)
                model_event  = model_task.find_event(event.symbol)
                script_event = instance_for(model_event)
                return script_event, model_event
            end

            # Start the given task at that point in the script, and wait for it
            # to emit its start event
            #
            # @param [Task] task the task that should be started
            # @param [Hash] dependency_options options that should be passed to
            #   TaskStructure::DependencyGraphClass::Extension#depends_on
            def start(task, dependency_options = Hash.new)
                task, model_task = resolve_task(task)
                model.start(model_task, dependency_options)
                task
            end

            # @overload execute(task)
            #   Deploy and start the given task, and wait for it to finish
            #   successfully
            #
            # @overload execute { ... }
            #   Execute the content of the given block once
            def execute(task = nil, &block)
                if task
                    task, model_task = resolve_task(task)
                    model.execute(model_task)
                    task
                else
                    model.instructions << BlockExecute.new(block)
                    nil
                end
            end

            # Wait for an event to be emitted
            #
            # @param [Hash] options
            # @option options [Time,nil] after (nil) if set, only event
            #   emissions that happened after this value will make the script
            #   pass this instruction. The default of nil means "from the point
            #   of this instruction on"
            #
            # @example wait first_child.start_event
            #   Waits until start event has been emitted. Will wait forever if
            #   the start event has already been emitted
            # @example wait first_child.start_event, :after => Time.at(0)
            #   Waits for start event to be emitted. Will return immediately if
            #   it has already been emitted.
            def wait(event, options = Hash.new)
                event, model_event = resolve_event(event)
                model.wait(model_event, options)
                event
            end

            # @deprecated
            #
            # Use wait(event :after => Time.at(0)) instead
            def wait_any(event, options = Hash.new)
                wait(event, options.merge(:after => Time.at(0)))
            end

            # Sleep for a given number of seconds
            #
            # @param [Float] seconds the number of seconds to stop the script
            #   execution
            def sleep(seconds)
                task = start(Tasks::Timeout.new(:delay => seconds))
                wait task.stop_event
            end

            # Emit the given event
            def emit(event)
                event, model_event = resolve_event(event)
                model.emit(model_event)
                event
            end

            # Executes the provided block once per execution cycle
            #
            # Call {#transition!} to quit the block
            def poll(&block)
                poll_until(poll_transition_event, &block)
            end

            # Execute the provided block once per execution cycle, until the
            # given event is emitted
            def poll_until(event, &block)
                event, model_event = resolve_event(event)
                model.instructions << Script::Models::PollUntil.new(model_event, block)
                event
            end

            # Quit a {#poll} block
            def transition!
                root_task.poll_transition_event.emit
            end

            # Execute the script instructions given as block. If they take more
            # than the specified number of seconds, either generate an error or
            # emit an event (and quit the block)
            #
            # @param [Hash] options
            # @option options [Event] :event (nil) if set, the given event will
            #   be emitted when the timeout is reached. Otherwise, a
            #   Script::TimedOut exception is generated with the script's
            #   supporting task as origin
            def timeout(seconds, options = Hash.new, &block)
                timeout = timeout_start(seconds, options)
                parse(&block)
                timeout_stop(timeout)
            end

            # Start a timeout operation. Usually not used directly
            #
            # @see timeout
            def timeout_start(seconds, options = Hash.new)
                options, timeout_options  = Kernel.filter_options options, :emit => nil
                if event = options[:emit]
                    script_event, model_event = resolve_event(event)
                end
                model.timeout_start(seconds, timeout_options.merge(:emit => model_event))
            end

            # Stop a timeout operation. Usually not used directly
            #
            # @see timeout
            def timeout_stop(timeout)
                model.timeout_stop(timeout)
            end

            # Used by Script
            def start_task(task)
                root_task.start_event.remove_causal_link(task.resolve.start_event)
            end

            def method_missing(m, *args, &block)
                case m.to_s
                when /(.*)_(event|child)$/
                    instance_for(model.root).send(m, *args, &block)
                else super
                end
            end
        end
    end

    class Task
        class << self
            inherited_attribute(:script, :scripts) { Array.new }
        end

        event :poll_transition

        def self.create_script(*task, &block)
            script_model = Coordination::TaskScript.new_submodel(:root => self)
            script = script_model.new(*task)
            if block_given?
                script.parse(&block)
            end
            script
        end

        # Adds a script that is going to be executed for every instance of this
        # task model
        def self.script(&block)
            s = create_script(&block)
            scripts << s
            s
        end

        on :start do |event|
            model.each_script do |s|
                s = s.bind(self)
                s.step
            end
        end

        # Adds a task script that is going to be executed while this task
        # instance runs.
        def script(options = Hash.new, &block)
            execute do |task|
                script = model.create_script(task, &block)
                script.prepare
                script.step
            end
            model.create_script(self, &block)
        end

        def transition!
            emit :poll_transition
        end
    end
end



