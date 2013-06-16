module Roby
    module Coordination
        # Common logic for script-based coordination models
        module Script
            DeadInstruction = Models::Script::DeadInstruction

            class BlockExecute
                attr_reader :task

                attr_reader :block

                def initialize(block)
                    @block = block
                end

                def new(task)
                    @task = task
                    self
                end

                def execute(script)
                    script.root_task.instance_eval(&block)
                    true
                end
            end

            module Models
                class PollUntil
                    attr_reader :event, :block
                    def initialize(event, block)
                        @event, @block = event, block
                    end

                    def new(script)
                        Script::PollUntil.new(script.root_task, script.instance_for(event), block)
                    end
                end
            end

            class PollUntil
                attr_reader :root_task, :event, :block
                def initialize(root_task, event, block)
                    @root_task, @event, @block = root_task, event, block
                end

                def execute(script)
                    poll_handler_id = root_task.poll(&block)
                    event.resolve.on do |context|
                        root_task.remove_poll_handler(poll_handler_id)
                        script.step
                    end
                    event.resolve.when_unreachable(true) do |reason, generator|
                        raise Script::DeadInstruction.new(script.root_task), "the 'until' condition of #{self} will never be reached: #{reason}"
                    end
                    false
                end
            end

            class TimedOut < LocalizedError
                attr_reader :instruction

                def initialize(task, instruction)
                    super(task)
                    @instruction = instruction
                end
            end

            class TimeoutStart < ScriptInstruction
                attr_reader :model
                attr_reader :event
                attr_accessor :timeout_stop

                def initialize(model, event)
                    @model = model
                    @event = event
                end

                def execute(script)
                    script.root_task.plan.engine.delayed(model.seconds) do
                        if !self.disabled?
                            # Remove all instructions that are within the
                            # timeout's scope
                            if event
                                event.resolve.emit
                                script.jump_to(timeout_stop)
                            else
                                raise TimedOut.new(script.root_task, script.current_instruction), "#{script.current_instruction} timed out"
                            end
                        end
                    end
                end
            end

            class TimeoutStop < ScriptInstruction
                attr_reader :timeout_start

                def initialize(timeout_start)
                    @timeout_start = timeout_start
                    timeout_start.timeout_stop = self
                end

                def execute(script)
                    timeout_start.cancel
                end
            end

            attr_reader :current_instruction

            attr_reader :instructions

            def prepare
                @instructions = Array.new
                resolve_instructions
                @current_instruction = nil
            end

            def resolve_instructions
                model.instructions.each do |ins|
                    instructions << instance_for(ins)
                end
            end

            def dependency_options_for(toplevel, task, roles)
                options = super
                if current_instruction.respond_to?(:task) && current_instruction.task == task
                    options = options.merge(current_instruction.dependency_options)
                end
                options
            end

            def step
                while @current_instruction = instructions.shift
                    if !current_instruction.execute(self)
                        break
                    end
                end
            rescue LocalizedError => e
                raise e
            rescue Exception => e
                raise CodeError.new(e, root_task), e.message, e.backtrace
            end

            def jump_to(target)
                # Verify that the jump is valid
                if current_instruction != target && !instructions.find { |ins| ins == target }
                    raise ArgumentError, "#{target} is not an instruction in #{self}"
                end

                if current_instruction != target
                    current_instruction.cancel
                end
                while instructions.first != target
                    instructions.shift
                end
                step
            end

            def finished?
                instructions.empty? && !@current_instruction
            end
        end
    end
end
