module Roby
    # Implementation module for the task scripting capabilities. See
    # TaskScripting::Script for details
    module Coordination
        extend Logger::Forward
        extend Logger::Hierarchy

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
                result_model = self.class.superclass.new_submodel(task.model)
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
                        task = model_task.instanciate(nil, root_task.plan, Hash.new)
                        script_task.bind(task)

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

            def resolve_task(task)
                if task.kind_of?(Roby::Task)
                    model_task = Coordination::Models::Task.new(task.model)
                    script_task = instance_for(model_task)
                    script_task.bind(task)
                else
                    model_task = self.model.task(task)
                    script_task = instance_for(model_task)
                end

                return script_task, model_task
            end

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

            def start(task, dependency_options = Hash.new)
                task, model_task = resolve_task(task)
                model.start(model_task, dependency_options)
                task
            end

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

            def wait(event, options = Hash.new)
                event, model_event = resolve_event(event)
                model.wait(model_event, options)
                event
            end

            def wait_any(event, options = Hash.new)
                wait(event, options.merge(:after => Time.at(0)))
            end

            def sleep(seconds)
                task = start(Tasks::Timeout.new(:delay => seconds))
                wait task.stop_event
            end

            def emit(event)
                event, model_event = resolve_event(event)
                model.emit(model_event)
                event
            end

            def poll(&block)
                poll_until(poll_transition_event, &block)
            end

            def poll_until(event, &block)
                event, model_event = resolve_event(event)
                model.instructions << Script::Models::PollUntil.new(model_event, block)
                event
            end

            def transition!
                root_task.poll_transition_event.emit
            end

            def timeout(seconds, options = Hash.new, &block)
                timeout = timeout_start(seconds, options)
                parse(&block)
                timeout_stop(timeout)
            end

            def timeout_start(seconds, options = Hash.new)
                options, timeout_options  = Kernel.filter_options options, :emit => nil
                if event = options[:emit]
                    script_event, model_event = resolve_event(event)
                end
                model.timeout_start(seconds, timeout_options.merge(:emit => model_event))
            end

            def timeout_stop(timeout)
                model.timeout_stop(timeout)
            end

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
            script_model = Coordination::TaskScript.new_submodel(self)
            script = script_model.new(*task)
            if block_given?
                script.parse(&block)
            end
            script
        end

        # Adds a script that is going to be executed for every instance of this
        # task model
        def self.script(&block)
            scripts << create_script(&block)
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
    end
end



